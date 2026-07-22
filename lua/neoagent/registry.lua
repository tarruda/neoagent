local util = require("neoagent.util")

local M = {}

-- Explicit model ids exposed by the built-in OpenAI Responses providers.
local function model_map(ids, options)
  local result = {}
  for _, id in ipairs(ids) do result[id] = util.copy(options or {}) end
  return result
end

local function reasoning_opts(effort)
  return {
    body = {
      reasoning = { effort = effort, summary = "auto" },
      include = { "reasoning.encrypted_content" },
    },
  }
end

local function thinking_map(off)
  return {
    off = util.copy(off or {}),
    minimal = reasoning_opts("minimal"),
    low = reasoning_opts("low"),
    medium = reasoning_opts("medium"),
    high = reasoning_opts("high"),
  }
end

local function add_thinking(models, ids, options)
  for _, id in ipairs(ids) do
    if models[id] then models[id].thinking = thinking_map(options and options.off) end
  end
end

local function configure_reasoning(thinking, options)
  for _, value in pairs(thinking or {}) do
    local body = type(value) == "table" and value.body or nil
    local reasoning = type(body) == "table" and body.reasoning or nil
    if type(reasoning) == "table" then
      if options.summary == false then
        reasoning.summary = nil
      elseif options.summary ~= nil then
        reasoning.summary = options.summary
      end
      if options.context ~= nil then reasoning.context = options.context end
    end
  end
end

local openai_models = model_map({
  "gpt-4",
  "gpt-4-turbo",
  "gpt-4.1",
  "gpt-4.1-mini",
  "gpt-4.1-nano",
  "gpt-4o",
  "gpt-4o-2024-05-13",
  "gpt-4o-2024-08-06",
  "gpt-4o-2024-11-20",
  "gpt-4o-mini",
  "gpt-5",
  "gpt-5-chat-latest",
  "gpt-5-codex",
  "gpt-5-mini",
  "gpt-5-nano",
  "gpt-5-pro",
  "gpt-5.1",
  "gpt-5.1-chat-latest",
  "gpt-5.1-codex",
  "gpt-5.1-codex-max",
  "gpt-5.1-codex-mini",
  "gpt-5.2",
  "gpt-5.2-chat-latest",
  "gpt-5.2-codex",
  "gpt-5.2-pro",
  "gpt-5.3-chat-latest",
  "gpt-5.3-codex",
  "gpt-5.3-codex-spark",
  "gpt-5.4",
  "gpt-5.4-mini",
  "gpt-5.4-nano",
  "gpt-5.4-pro",
  "gpt-5.5",
  "gpt-5.5-pro",
  "gpt-5.6-luna",
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-realtime-2.1",
  "o1",
  "o1-pro",
  "o3",
  "o3-deep-research",
  "o3-mini",
  "o3-pro",
  "o4-mini",
  "o4-mini-deep-research",
})

add_thinking(openai_models, {
  "gpt-5", "gpt-5-codex", "gpt-5-mini", "gpt-5-nano", "gpt-5-pro",
  "gpt-5.1", "gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5.1-codex-mini",
  "gpt-5.2", "gpt-5.2-codex", "gpt-5.2-pro", "gpt-5.3-codex",
  "gpt-5.3-codex-spark", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
  "gpt-5.4-pro", "gpt-5.5", "gpt-5.5-pro", "gpt-5.6-luna",
  "gpt-5.6-sol", "gpt-5.6-terra", "o1", "o1-pro", "o3",
  "o3-deep-research", "o3-mini", "o3-pro", "o4-mini", "o4-mini-deep-research",
}, { off = { body = { reasoning = { effort = "none" } } } })

for _, id in ipairs({
  "gpt-5.2", "gpt-5.2-codex", "gpt-5.3-codex", "gpt-5.3-codex-spark",
  "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.4-pro", "gpt-5.5",
  "gpt-5.5-pro", "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra",
}) do
  if openai_models[id] and openai_models[id].thinking then
    openai_models[id].thinking.xhigh = reasoning_opts("xhigh")
  end
end
for _, id in ipairs({ "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra" }) do
  openai_models[id].thinking.max = reasoning_opts("max")
end

local codex_models = model_map({
  "gpt-5.3-codex-spark",
  "gpt-5.4",
  "gpt-5.4-mini",
  "gpt-5.5",
  "gpt-5.6-luna",
  "gpt-5.6-sol",
  "gpt-5.6-terra",
}, { context_window = 272000 })
add_thinking(codex_models, {
  "gpt-5.3-codex-spark", "gpt-5.4", "gpt-5.4-mini", "gpt-5.5",
  "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra",
})
for _, model in pairs(codex_models) do
  model.thinking.minimal = reasoning_opts("low")
  model.thinking.xhigh = reasoning_opts("xhigh")
  configure_reasoning(model.thinking, { summary = false })
end
for _, id in ipairs({ "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra" }) do
  codex_models[id].responses_lite = true
  codex_models[id].thinking.max = reasoning_opts("max")
  configure_reasoning(codex_models[id].thinking, { summary = false })
end

local deepseek_models = model_map({
  "deepseek-v4-flash",
  "deepseek-v4-pro",
}, {
  context_window = 1000000,
  max_output_tokens = 384000,
})

local deepseek_thinking = {
  off = { body = { thinking = { type = "disabled" } } },
  high = { body = { thinking = { type = "enabled" }, reasoning_effort = "high" } },
  max = { body = { thinking = { type = "enabled" }, reasoning_effort = "max" } },
}
for _, model in pairs(deepseek_models) do
  model.thinking = util.copy(deepseek_thinking)
end

local defaults = {
  openai = {
    api = "openai-responses",
    base_url = "https://api.openai.com/v1",
    api_key = function() return vim.env.OPENAI_API_KEY end,
    models = openai_models,
  },
  deepseek = {
    api = "openai-completions",
    base_url = "https://api.deepseek.com",
    api_key = function() return vim.env.DEEPSEEK_API_KEY end,
    request_opts = { body = { stream_options = { include_usage = true } } },
    models = deepseek_models,
  },
  ["openai-codex"] = {
    api = "openai-codex-responses",
    base_url = "https://chatgpt.com/backend-api",
    auth = "openai-codex",
    models = codex_models,
  },
}

local function compose_models(base, user)
  if user == nil then return util.copy(base or {}) end
  if user == false then return {} end
  assert(type(user) == "table", "provider models must be a table or false")
  local result = util.copy(base or {})
  for id, model in pairs(user) do
    assert(type(id) == "string", "models must use string ids")
    if model == false then
      result[id] = nil
    else
      assert(type(model) == "table", "models must contain tables or false")
      result[id] = util.deep_merge(result[id], model)
    end
  end
  return result
end

function M.defaults()
  return util.copy(defaults)
end

function M.compose(user, include_defaults)
  assert(type(user) == "table", "providers must be a table")
  local result = include_defaults == false and {} or M.defaults()
  for id, provider in pairs(user) do
    assert(type(id) == "string", "providers must use string ids")
    if provider == false then
      result[id] = nil
    else
      assert(type(provider) == "table", "providers must contain tables or false")
      local base = result[id]
      local override = util.copy(provider)
      override.models = nil
      result[id] = util.deep_merge(base, override)
      result[id].models = compose_models(base and base.models, provider.models)
    end
  end
  return result
end

return M
