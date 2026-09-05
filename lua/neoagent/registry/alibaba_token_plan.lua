local function request(body)
  return { body = body }
end

local BASE_URL = "https://token-plan.ap-southeast-1.maas.aliyuncs.com"
  .. "/compatible-mode/v1"

local function effort_thinking(levels)
  local result = {
    off = request({ enable_thinking = false }),
  }
  for _, level in ipairs(levels) do
    result[level] = request({
      enable_thinking = true,
      reasoning_effort = level,
    })
  end
  return result
end

local function hybrid_thinking()
  return {
    off = request({ enable_thinking = false }),
    high = request({ enable_thinking = true }),
  }
end

local function tool_stream(context)
  if #context.tools == 0 then return {} end
  return { body = { tool_stream = true } }
end

local function model(id, context_window, max_output_tokens, opts)
  opts = opts or {}
  return {
    id = id,
    context_window = context_window,
    max_output_tokens = max_output_tokens,
    input = opts.image and { "text", "image" } or { "text" },
    thinking = opts.thinking or hybrid_thinking(),
    request_opts = opts.tool_stream and tool_stream or nil,
  }
end

local qwen38 = function()
  return effort_thinking({ "low", "medium", "xhigh" })
end
local deepseek = function()
  return effort_thinking({ "high", "max" })
end
local deepseek_snapshot = function()
  return effort_thinking({ "low", "high", "max" })
end

return {
  api = "openai-completions",
  base_url = BASE_URL,
  api_key = function() return vim.env.BAILIAN_TOKEN_PLAN_API_KEY end,
  auth = "alibaba-token-plan",
  auth_scopes = {
    dashboard = "alibaba-token-plan-dashboard",
  },
  catalog = { seed = {
    model("qwen3.8-max", 1000000, 131072, {
      image = true, thinking = qwen38(), tool_stream = true,
    }),
    model("qwen3.8-flash", 1000000, 131072, {
      image = true, thinking = qwen38(), tool_stream = true,
    }),
    model("qwen3.7-plus", 1000000, 131072, {
      image = true, tool_stream = true,
    }),
    model("qwen3.7-max", 1000000, 131072, { tool_stream = true }),
    model("qwen3.6-flash", 1000000, 65536, {
      image = true, tool_stream = true,
    }),
    model("deepseek-v4-pro-0813", 1000000, 393216, {
      thinking = deepseek_snapshot(),
    }),
    model("deepseek-v4-pro", 1000000, 393216, {
      thinking = deepseek(),
    }),
    model("deepseek-v4-flash-0731", 1000000, 393216, {
      thinking = deepseek_snapshot(),
    }),
    model("glm-5.2", 1048576, 131072, {
      thinking = deepseek(), tool_stream = true,
    }),
  } },
  request_opts = {
    headers = { ["User-Agent"] = "neoagent" },
    body = {
      enable_thinking = true,
      stream_options = { include_usage = true },
    },
  },
  models = {},
  service = require("neoagent.providers.alibaba_token_plan").new,
}
