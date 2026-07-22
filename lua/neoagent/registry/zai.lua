local util = require("neoagent.util")

local function thinking(enabled, effort)
  local body = {
    thinking = enabled
      and { type = "enabled", clear_thinking = false }
      or { type = "disabled" },
  }
  if effort then body.reasoning_effort = effort end
  return { body = body }
end

local toggle_thinking = {
  off = thinking(false),
  minimal = thinking(true),
  low = thinking(true),
  medium = thinking(true),
  high = thinking(true),
}

local models = {
  ["glm-4.5"] = { context_window = 131072, max_output_tokens = 98304 },
  ["glm-4.5-air"] = { context_window = 131072, max_output_tokens = 98304 },
  ["glm-4.5-flash"] = { context_window = 131072, max_output_tokens = 98304 },
  ["glm-4.5v"] = { context_window = 64000, max_output_tokens = 16384 },
  ["glm-4.6"] = { context_window = 204800, max_output_tokens = 131072 },
  ["glm-4.6v"] = { context_window = 128000, max_output_tokens = 32768 },
  ["glm-4.7"] = { context_window = 204800, max_output_tokens = 131072 },
  ["glm-4.7-flash"] = { context_window = 200000, max_output_tokens = 131072 },
  ["glm-4.7-flashx"] = { context_window = 200000, max_output_tokens = 131072 },
  ["glm-5"] = { context_window = 204800, max_output_tokens = 131072 },
  ["glm-5-turbo"] = { context_window = 200000, max_output_tokens = 131072 },
  ["glm-5.1"] = { context_window = 200000, max_output_tokens = 131072 },
  ["glm-5.2"] = { context_window = 1000000, max_output_tokens = 131072 },
  ["glm-5v-turbo"] = { context_window = 200000, max_output_tokens = 131072 },
}

local function tool_stream(context)
  if #context.tools == 0 then return {} end
  return { body = { tool_stream = true } }
end

local tool_stream_unsupported = {
  ["glm-4.5"] = true,
  ["glm-4.5-air"] = true,
  ["glm-4.5-flash"] = true,
  ["glm-4.5v"] = true,
}

for id, model in pairs(models) do
  if id == "glm-5.2" then
    model.thinking = {
      off = thinking(false),
      low = thinking(true, "high"),
      medium = thinking(true, "high"),
      high = thinking(true, "high"),
      max = thinking(true, "max"),
    }
  else
    model.thinking = util.copy(toggle_thinking)
  end
  if not tool_stream_unsupported[id] then model.request_opts = tool_stream end
end

return {
  api = "openai-completions",
  base_url = "https://api.z.ai/api/paas/v4",
  api_key = function() return vim.env.ZAI_API_KEY end,
  auth = "zai",
  request_opts = { body = { stream_options = { include_usage = true } } },
  models = models,
}
