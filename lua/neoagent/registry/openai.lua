local efforts = require("neoagent.model_efforts")
local rules = require("neoagent.model_rules")
local util = require("neoagent.util")

local M = {}
local no_source_options = require("neoagent.model_catalog.source").no_options
local CLOUD_TTL_MS = 14 * 24 * 60 * 60 * 1000

local function response_thinking(levels)
  return efforts.openai_responses(levels)
end

local excluded_openai_kinds = {
  "embedding", "moderation", "dall%-e", "image", "sora", "tts",
  "transcribe", "whisper", "audio", "realtime", "search",
}

local function conversational(model)
  for _, pattern in ipairs(excluded_openai_kinds) do
    if model.id:find(pattern) then return false end
  end
  return true
end

local function thinking_levels(levels)
  return function(model)
    model.thinking = response_thinking(levels)
    return model
  end
end

local function without_thinking(model)
  model.thinking = nil
  return model
end

local transform_openai = rules.compile({
  {
    match = function(model) return conversational(model) end,
    defaults = { input = { "text" } },
  },
  {
    match = function(model) return not conversational(model) end,
    apply = function() return false end,
  },
  {
    match = "^gpt%-4",
    set = { input = { "text", "image" }, max_output_tokens = 16384 },
  },
  {
    match = "^gpt%-4$",
    set = {
      input = { "text" },
      context_window = 8192,
      max_output_tokens = 8192,
    },
  },
  {
    match = "^gpt%-4%-turbo",
    set = { context_window = 128000, max_output_tokens = 4096 },
  },
  {
    match = "^gpt%-4o",
    set = { context_window = 128000 },
  },
  {
    match = "^gpt%-4%.1",
    set = { context_window = 1047576, max_output_tokens = 32768 },
  },
  {
    match = "^o[134]",
    set = {
      input = { "text", "image" },
      context_window = 200000,
      max_output_tokens = 100000,
    },
    apply = thinking_levels({ "low", "medium", "high" }),
  },
  {
    match = "^gpt%-5",
    set = {
      input = { "text", "image" },
      context_window = 400000,
      max_output_tokens = 128000,
    },
    apply = thinking_levels({ "minimal", "low", "medium", "high" }),
  },
  {
    match = "^gpt%-5%.1",
    apply = thinking_levels({ "off", "low", "medium", "high" }),
  },
  {
    match = "^gpt%-5%.[2-5]",
    apply = thinking_levels({ "off", "low", "medium", "high", "xhigh" }),
  },
  {
    match = "^gpt%-5%.[4-6]",
    set = { context_window = 1050000 },
  },
  {
    match = "^gpt%-5%.6",
    apply = thinking_levels({
      "off", "low", "medium", "high", "xhigh", "max",
    }),
  },
  {
    match = function(model)
      return model.id:match("^gpt%-5%.4%-mini") ~= nil
        or model.id:match("^gpt%-5%.4%-nano") ~= nil
    end,
    set = { context_window = 400000 },
  },
  {
    match = "^gpt%-5%.3%-codex%-spark",
    set = { context_window = 128000, max_output_tokens = 32000 },
  },
  {
    match = "^gpt%-5%-pro",
    set = { max_output_tokens = 272000 },
    apply = thinking_levels({ "high" }),
  },
  {
    match = "^gpt%-5%.2%-pro",
    apply = thinking_levels({ "medium", "high", "xhigh" }),
  },
  {
    match = "^gpt%-5%.[45]%-pro",
    apply = thinking_levels({ "medium", "high", "xhigh" }),
  },
  {
    match = "^gpt%-5.*%-chat",
    set = { context_window = 128000, max_output_tokens = 16384 },
    apply = without_thinking,
  },
  {
    match = "^chat%-latest$",
    set = {
      input = { "text", "image" },
      context_window = 400000,
      max_output_tokens = 128000,
    },
    apply = without_thinking,
  },
})

local openai_ids = {
  "gpt-4", "gpt-4-turbo", "gpt-4.1", "gpt-4.1-mini",
  "gpt-4.1-nano", "gpt-4o", "gpt-4o-2024-05-13",
  "gpt-4o-2024-08-06", "gpt-4o-2024-11-20", "gpt-4o-mini",
  "gpt-5", "gpt-5-chat-latest", "gpt-5-codex", "gpt-5-mini",
  "gpt-5-nano", "gpt-5-pro", "gpt-5.1", "gpt-5.1-chat-latest",
  "gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5.1-codex-mini",
  "gpt-5.2", "gpt-5.2-chat-latest", "gpt-5.2-codex",
  "gpt-5.2-pro", "gpt-5.3-chat-latest", "gpt-5.3-codex",
  "gpt-5.3-codex-spark", "gpt-5.4", "gpt-5.4-mini",
  "gpt-5.4-nano", "gpt-5.4-pro", "gpt-5.5", "gpt-5.5-pro",
  "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "o1", "o1-pro",
  "o3", "o3-deep-research", "o3-mini", "o3-pro", "o4-mini",
  "o4-mini-deep-research",
}
local openai_seed = {}
for _, id in ipairs(openai_ids) do openai_seed[#openai_seed + 1] = { id = id } end

local function codex_thinking(levels)
  local result = {}
  for _, level in ipairs(levels) do
    result[level] = level == "off" and {}
      or efforts.openai_response(level)
  end
  return result
end

local function transform_codex(model)
  local result = {
    id = model.id,
    api = "openai-codex-responses",
    name = model.name,
    hidden = model.hidden,
    input = util.copy(model.input or { "text" }),
    context_window = model.context_window,
    max_output_tokens = model.max_output_tokens,
    responses_lite = model.responses_lite,
    service_tiers = util.copy(model.service_tiers),
    text_verbosity = model.text_verbosity,
  }
  local levels = model.reasoning_levels
  if type(levels) == "table" and util.is_list(levels) and #levels > 0 then
    result.thinking = codex_thinking(levels)
  end
  return result
end

M.transform_openai = transform_openai
M.transform_codex = transform_codex

M.openai = {
  api = "openai-responses",
  base_url = "https://api.openai.com/v1",
  api_key = function() return vim.env.OPENAI_API_KEY end,
  auth = "openai",
  catalog = {
    source_id = "openai-models",
    source_revision = 1,
    source_options = no_source_options,
    account_scoped = true,
    ttl_ms = CLOUD_TTL_MS,
    seed = openai_seed,
    discover = require("neoagent.providers.openai").discover_models,
    transform_model = transform_openai,
  },
  models = {},
  service = require("neoagent.providers.openai").new,
}

M["openai-codex"] = {
  api = "openai-codex-responses",
  base_url = "https://chatgpt.com/backend-api",
  auth = "openai-codex",
  catalog = {
    source_id = "openai-codex-models",
    source_revision = 1,
    source_options = no_source_options,
    account_scoped = true,
    ttl_ms = CLOUD_TTL_MS,
    discover = require("neoagent.providers.codex.catalog").discover,
    transform_model = transform_codex,
  },
  models = {},
  service = require("neoagent.providers.codex").new,
}

return M
