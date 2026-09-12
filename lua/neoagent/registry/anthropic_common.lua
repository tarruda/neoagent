local util = require("neoagent.util")
local efforts = require("neoagent.model_efforts")

local M = {}

local INTERLEAVED_THINKING = "interleaved-thinking-2025-05-14"

---@param levels Neoagent.ThinkingLevel[]
---@return Neoagent.ThinkingOptions
local function effort_levels(levels)
  local result = {}
  for _, level in ipairs(levels) do
    result[level] = { body = { output_config = { effort = level } } }
  end
  return result
end

---@param model Neoagent.AnthropicCatalogModel
---@return Neoagent.ModelConfig
function M.transform(model)
  ---@type Neoagent.ModelConfig
  local result = {
    id = model.id,
    name = model.name,
    hidden = model.hidden,
    input = util.copy(model.input or { "text" }),
    context_window = model.context_window,
    max_output_tokens = model.max_output_tokens,
  }
  local levels = model.reasoning_levels
  if type(levels) == "table" and #levels > 0 then
    result.thinking = model.thinking_type == "adaptive" and efforts.anthropic_adaptive(levels) or effort_levels(levels)
  end
  if model.thinking_type == "enabled" then
    result.request_opts = {
      headers = { ["anthropic-beta"] = INTERLEAVED_THINKING },
    }
  end
  return result
end

---@return fun(context: Neoagent.RequestOptionsContext): Neoagent.RequestOverride
function M.request_opts()
  return function(context)
    local tools = context.request.body and context.request.body.tools
    if type(tools) ~= "table" then
      return {}
    end
    tools = util.copy(tools)
    for _, tool in ipairs(tools) do
      tool.eager_input_streaming = true
    end
    local override = { tools = tools }
    return { body = override }
  end
end

return M
