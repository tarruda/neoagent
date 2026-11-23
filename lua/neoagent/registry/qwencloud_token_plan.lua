local plan = require("neoagent.providers.qwencloud_token_plan")

---@param enable boolean
---@param effort? string
---@return Neoagent.RequestOverride
local function thinking(enable, effort)
  return {
    body = {
      enable_thinking = enable,
      reasoning_effort = effort,
    },
  }
end

---@param levels Neoagent.ThinkingLevel[]
---@param always? boolean
---@return Neoagent.ThinkingOptions
local function effort_thinking(levels, always)
  ---@type Neoagent.ThinkingOptions
  local result = {}
  if not always then
    result.off = thinking(false)
  end
  for _, level in ipairs(levels) do
    result[level] = thinking(true, level)
  end
  return result
end

---@param context Neoagent.RequestOptionsContext
---@return Neoagent.RequestOverride
local function tool_stream(context)
  return #context.tools > 0 and { body = { tool_stream = true } } or {}
end

-- Keep the built-in choices to documented chat models shared by Individual and
-- Team Edition. Users can add other models through the provider's models table.
---@type Neoagent.DiscoveredModel[]
local seed = {
  { id = "auto", input = { "text" } },
  {
    id = "qwen4-max",
    context_window = 1000000,
    max_output_tokens = 262144,
    _completion_non_thinking_ceiling = 131072,
    input = { "text", "image" },
    thinking = {
      off = thinking(false),
      minimal = thinking(true, "low"),
      low = thinking(true, "low"),
      medium = thinking(true, "high"),
      high = thinking(true, "high"),
      xhigh = thinking(true, "xhigh"),
      max = thinking(true, "xhigh"),
    },
    request_opts = tool_stream,
  },
}

---@param ids string[]
---@param output_tokens integer
---@param image boolean
---@param settings Neoagent.ThinkingOptions
---@param stream_tools? boolean
local function add(ids, output_tokens, image, settings, stream_tools)
  for _, id in ipairs(ids) do
    seed[#seed + 1] = {
      id = id,
      context_window = 1000000,
      max_output_tokens = output_tokens,
      input = image and { "text", "image" } or { "text" },
      thinking = settings,
      request_opts = stream_tools and tool_stream or nil,
    }
  end
end

local qwen_effort = effort_thinking({ "low", "medium", "xhigh" })
add({ "qwen3.8-max", "qwen3.8-flash" }, 131072, true, qwen_effort, true)

local hybrid = { off = thinking(false), high = thinking(true) }
add({ "qwen3.7-max" }, 65536, false, hybrid, true)
add({ "qwen3.7-plus", "qwen3.6-flash" }, 65536, true, hybrid, true)

local deepseek_effort = effort_thinking({ "high", "max" })
add({ "deepseek-v4-pro" }, 393216, false, deepseek_effort)
add({ "deepseek-v4.1-flash", "deepseek-v4.1-flash-1017" }, 393216, true, deepseek_effort)
add({ "deepseek-v4-pro-0813", "deepseek-v4-flash-0731" }, 393216, false, effort_thinking({ "low", "high", "max" }))

add({ "glm-5.2" }, 131072, false, effort_thinking({ "minimal", "low", "medium", "high", "xhigh", "max" }), true)
add({ "glm-5.3" }, 131072, false, effort_thinking({ "low", "high", "max" }, true), true)

---@type Neoagent.ProviderDefinition
local provider = {
  api = "openai-completions",
  base_url = plan.base_url,
  api_key = function()
    return vim.env.QWENCLOUD_TOKEN_PLAN_API_KEY
  end,
  auth = "qwencloud-token-plan",
  auth_scopes = { usage = "qwencloud-token-plan-usage" },
  catalog = { seed = seed },
  request_opts = {
    headers = { ["User-Agent"] = "neoagent" },
    body = { stream_options = { include_usage = true } },
  },
  models = {},
  service = plan.new,
}

return provider
