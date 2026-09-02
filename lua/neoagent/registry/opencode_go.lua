local util = require("neoagent.util")
local no_source_options = require("neoagent.model_catalog.source").no_options

local function request(body)
  return { body = body }
end

local function response_efforts(values)
  local result = {}
  for level, effort in pairs(values) do
    result[level] = request({ reasoning = { effort = effort } })
  end
  return result
end

local function completion_efforts(values)
  local result = {}
  for level, effort in pairs(values) do
    result[level] = request({ reasoning_effort = effort })
  end
  return result
end

local function completion_thinking(values)
  local result = {
    off = request({ thinking = { type = "disabled" } }),
  }
  for _, effort in ipairs(values) do
    result[effort] = request({
      thinking = { type = "enabled" },
      reasoning_effort = effort,
    })
  end
  return result
end

local function message_efforts(values)
  local result = {
    off = request({ thinking = { type = "disabled" } }),
  }
  for _, effort in ipairs(values) do
    result[effort] = request({
      thinking = { type = "enabled" },
      output_config = { effort = effort },
    })
  end
  return result
end

local function toggle_thinking(enabled_type)
  return {
    off = request({ thinking = { type = "disabled" } }),
    high = request({ thinking = { type = enabled_type or "enabled" } }),
  }
end

local function model(context_window, max_output_tokens, options)
  local result = {
    context_window = context_window,
    max_output_tokens = max_output_tokens,
    input = { "text" },
  }
  options = options or {}
  if options.api then result.api = options.api end
  if options.image then result.input = { "text", "image" } end
  if options.thinking then result.thinking = util.copy(options.thinking) end
  return result
end

local responses = "openai-responses"
local messages = "anthropic-messages"
local known_models = {
  ["grok-4.5"] = model(500000, 500000, {
    api = responses,
    image = true,
    thinking = response_efforts({
      low = "low", medium = "medium", high = "high",
    }),
  }),
  ["grok-4.6"] = model(500000, 500000, {
    api = responses,
    image = true,
    thinking = response_efforts({
      low = "low", medium = "medium", high = "high", xhigh = "xhigh",
    }),
  }),
  ["gpt-5.6-luna"] = model(1050000, 128000, {
    api = responses,
    image = true,
    thinking = response_efforts({
      off = "none", low = "low", medium = "medium", high = "high",
      xhigh = "xhigh", max = "max",
    }),
  }),
  ["glm-5"] = model(202752, 32768, {
    thinking = toggle_thinking(),
  }),
  ["glm-5.1"] = model(202752, 32768, {
    thinking = toggle_thinking(),
  }),
  ["glm-5.2"] = model(1000000, 131072, {
    thinking = completion_efforts({ high = "high", max = "max" }),
  }),
  ["glm-5.3"] = model(1000000, 131072, {
    thinking = completion_efforts({ low = "low", high = "high", max = "max" }),
  }),
  ["glm-5.3-flash"] = model(1000000, 131072, {
    image = true,
    thinking = completion_efforts({ low = "low", high = "high", max = "max" }),
  }),
  ["kimi-k2.5"] = model(262144, 65536, {
    image = true,
    thinking = toggle_thinking(),
  }),
  ["kimi-k2.6"] = model(262144, 65536, {
    image = true,
    thinking = toggle_thinking(),
  }),
  ["kimi-k2.7-code"] = model(262144, 262144, { image = true }),
  ["kimi-k3"] = model(1048576, 131072, {
    image = true,
    thinking = completion_efforts({ max = "max" }),
  }),
  ["longcat-2.0"] = model(1000000, 131072, {
    thinking = toggle_thinking(),
  }),
  ["deepseek-v4-pro"] = model(1000000, 384000, {
    thinking = completion_thinking({ "high", "max" }),
  }),
  ["deepseek-v4-flash"] = model(1000000, 384000, {
    thinking = completion_thinking({ "low", "high", "max" }),
  }),
  ["deepseek-v4-flash-vision-exp"] = model(1000000, 384000, {
    image = true,
    thinking = completion_thinking({ "low", "high", "max" }),
  }),
  ["mimo-v2-pro"] = model(1048576, 128000),
  ["mimo-v2-omni"] = model(262144, 128000, { image = true }),
  ["mimo-v2.5"] = model(1000000, 128000, { image = true }),
  ["mimo-v2.5-pro"] = model(1048576, 128000),
  ["minimax-m3"] = model(1000000, 131072, {
    api = messages,
    image = true,
    thinking = toggle_thinking("adaptive"),
  }),
  ["minimax-m2.7"] = model(204800, 131072, { api = messages }),
  ["minimax-m2.5"] = model(204800, 65536, { api = messages }),
  ["muse-spark-1.2-contributor"] = model(1048576, 131072, {
    api = responses,
    image = true,
    thinking = response_efforts({
      minimal = "minimal", low = "low", medium = "medium",
      high = "high", xhigh = "xhigh",
    }),
  }),
  ["qwen3.8-max"] = model(1000000, 131072, {
    api = messages, image = true,
  }),
  ["qwen3.8-flash"] = model(1000000, 131072, {
    api = messages, image = true,
  }),
  ["qwen3.7-max"] = model(1000000, 65536, {
    api = messages,
  }),
  ["qwen3.7-plus"] = model(1000000, 65536, {
    api = messages, image = true,
  }),
  ["qwen3.6-plus"] = model(1000000, 65536, {
    api = messages, image = true,
  }),
  ["qwen3.5-plus"] = model(262144, 65536, {
    api = messages, image = true,
  }),
  hy3 = model(256000, 64000, {
    thinking = completion_efforts({ off = "none", low = "low", high = "high" }),
  }),
  ["hy3-preview"] = model(256000, 64000, {
    thinking = completion_efforts({ off = "none", low = "low", high = "high" }),
  }),
  ["hy4-preview"] = model(1024000, 64000, {
    thinking = completion_efforts({ off = "none", high = "high" }),
  }),
}

local response_models = {
  ["gpt-5.6-luna"] = true,
  ["grok-4.5"] = true,
  ["grok-4.6"] = true,
  ["muse-spark-1.2-contributor"] = true,
}

local message_models = {
  ["minimax-m3"] = true,
  ["minimax-m2.7"] = true,
  ["minimax-m2.5"] = true,
}

local function qwen_thinking(id)
  if id:match("^qwen3%.8%-") then
    return message_efforts({ "low", "medium", "xhigh" })
  end
  if id:match("^qwen3%.[5-7]%-") then return toggle_thinking() end
end

local function transform(source)
  local defaults = util.deep_merge(
    { input = { "text" } }, known_models[source.id] or {})
  if defaults.thinking == nil then
    defaults.thinking = qwen_thinking(source.id)
  end
  local result = util.deep_merge(defaults, source)
  if result.api == nil then
    if response_models[result.id] then
      result.api = responses
    elseif message_models[result.id]
        or result.id:match("^qwen3%.[5-8]%-") then
      result.api = messages
    end
  end
  return result
end

local ids = {
  "deepseek-v4-flash", "deepseek-v4-flash-vision-exp",
  "deepseek-v4-pro", "glm-5", "glm-5.1", "glm-5.2", "glm-5.3",
  "glm-5.3-flash", "gpt-5.6-luna", "grok-4.5", "grok-4.6",
  "hy3", "hy3-preview", "hy4-preview", "kimi-k2.5", "kimi-k2.6",
  "kimi-k2.7-code", "kimi-k3", "longcat-2.0", "mimo-v2-omni",
  "mimo-v2-pro", "mimo-v2.5", "mimo-v2.5-pro", "minimax-m2.5",
  "minimax-m2.7", "minimax-m3", "muse-spark-1.2-contributor",
  "qwen3.5-plus", "qwen3.6-plus", "qwen3.7-max", "qwen3.7-plus",
  "qwen3.8-flash", "qwen3.8-max",
}

local seed = {}
for _, id in ipairs(ids) do seed[#seed + 1] = { id = id } end

return {
  api = "openai-completions",
  base_url = "https://opencode.ai/zen/go/v1",
  api_key = function() return vim.env.OPENCODE_API_KEY end,
  auth = "opencode-go",
  catalog = {
    source_id = "opencode-go-models",
    source_revision = 1,
    source_options = no_source_options,
    ttl_ms = 14 * 24 * 60 * 60 * 1000,
    seed = seed,
    discover = require("neoagent.providers.opencode_go").discover_models,
    transform_model = transform,
  },
  models = {},
  service = require("neoagent.providers.opencode_go").new,
}
