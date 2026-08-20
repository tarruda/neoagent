local util = require("neoagent.util")

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

local function qwen_thinking(maximum)
  local high = math.floor(maximum / 2)
  return {
    high = request({ thinking = {
      type = "enabled", budget_tokens = high,
    } }),
    max = request({ thinking = {
      type = "enabled", budget_tokens = maximum,
    } }),
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
local models = {
  ["grok-4.5"] = model(500000, 500000, {
    api = responses,
    image = true,
    thinking = response_efforts({ low = "low", medium = "medium", high = "high" }),
  }),
  ["gpt-5.6-luna"] = model(1050000, 128000, {
    api = responses,
    image = true,
    thinking = response_efforts({
      off = "none", low = "low", medium = "medium", high = "high",
      xhigh = "xhigh", max = "max",
    }),
  }),
  ["glm-5.3"] = model(1000000, 131072, {
    thinking = completion_efforts({ low = "low", high = "high", max = "max" }),
  }),
  ["glm-5.2"] = model(1000000, 131072, {
    thinking = completion_efforts({ high = "high", max = "max" }),
  }),
  ["glm-5.1"] = model(202752, 32768),
  ["kimi-k3"] = model(1048576, 131072, {
    image = true,
    thinking = completion_efforts({ max = "max" }),
  }),
  ["kimi-k2.7-code"] = model(262144, 262144, { image = true }),
  ["kimi-k2.6"] = model(262144, 65536, { image = true }),
  ["deepseek-v4-pro"] = model(1000000, 384000, {
    thinking = completion_efforts({ high = "high", max = "max" }),
  }),
  ["deepseek-v4-flash"] = model(1000000, 384000, {
    thinking = completion_efforts({ low = "low", high = "high", max = "max" }),
  }),
  ["mimo-v2.5"] = model(1000000, 128000, { image = true }),
  ["mimo-v2.5-pro"] = model(1048576, 128000),
  ["minimax-m3"] = model(1000000, 131072, {
    api = messages,
    thinking = {
      off = request({ thinking = { type = "disabled" } }),
      high = request({ thinking = { type = "adaptive" } }),
    },
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
    api = messages, image = true, thinking = qwen_thinking(131071),
  }),
  ["qwen3.7-max"] = model(1000000, 65536, {
    api = messages, thinking = qwen_thinking(65535),
  }),
  ["qwen3.7-plus"] = model(1000000, 65536, {
    api = messages, image = true, thinking = qwen_thinking(65535),
  }),
  ["qwen3.6-plus"] = model(1000000, 65536, {
    api = messages, image = true, thinking = qwen_thinking(65535),
  }),
  hy3 = model(256000, 64000, {
    thinking = completion_efforts({ off = "none", low = "low", high = "high" }),
  }),
}

return {
  api = "openai-completions",
  base_url = "https://opencode.ai/zen/go/v1",
  api_key = function() return vim.env.OPENCODE_API_KEY end,
  auth = "opencode-go",
  catalog_cache = { ttl_ms = 60 * 60 * 1000 },
  models = models,
  service = require("neoagent.providers.opencode_go").new,
}
