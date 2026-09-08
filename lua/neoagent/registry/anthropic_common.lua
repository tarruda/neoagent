local util = require("neoagent.util")
local efforts = require("neoagent.model_efforts")

local M = {}

---@class Neoagent.AnthropicWireMessage: Neoagent.JsonObject
---@field role string
---@field content string|Neoagent.JsonObject[]

---@class Neoagent.AnthropicCacheBody: Neoagent.JsonObject
---@field messages Neoagent.AnthropicWireMessage[]
---@field tools? Neoagent.JsonObject[]

local CACHE_CONTROL = { type = "ephemeral" }
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
    result.thinking = model.thinking_type == "adaptive"
      and efforts.anthropic_adaptive(levels) or effort_levels(levels)
  end
  if model.thinking_type == "enabled" then
    result.request_opts = {
      headers = { ["anthropic-beta"] = INTERLEAVED_THINKING },
    }
  end
  return result
end

---@param system_prompt? string
---@return Neoagent.JsonObject[]
local function cache_system(system_prompt)
  local result = {}
  if type(system_prompt) == "string" and system_prompt ~= "" then
    result[#result + 1] = {
      type = "text",
      text = system_prompt,
      cache_control = util.copy(CACHE_CONTROL),
    }
  end
  return result
end

---@param messages Neoagent.AnthropicWireMessage[]
---@return Neoagent.AnthropicWireMessage[]
local function cache_messages(messages)
  local result = util.copy(messages)
  local last = result[#result]
  if not last or last.role ~= "user" then return result end
  if type(last.content) == "string" then
    last.content = { {
      type = "text",
      text = last.content,
      cache_control = util.copy(CACHE_CONTROL),
    } }
  elseif type(last.content) == "table" and #last.content > 0 then
    local block = last.content[#last.content]
    if block.type == "text" or block.type == "image" or block.type == "tool_result" then
      block.cache_control = util.copy(CACHE_CONTROL)
    end
  end
  return result
end

---@param tools Neoagent.JsonObject[]
---@return Neoagent.JsonObject[]
local function cache_tools(tools)
  local result = util.copy(tools)
  for _, tool in ipairs(result) do tool.eager_input_streaming = true end
  if #result > 0 then result[#result].cache_control = util.copy(CACHE_CONTROL) end
  return result
end

---@return fun(context: Neoagent.RequestOptionsContext): Neoagent.RequestOverride
function M.request_opts()
  return function(context)
    -- The Anthropic adapter supplies this wire body before request layers.
    local body = context.request.body
    ---@cast body Neoagent.AnthropicCacheBody
    ---@type Neoagent.JsonObject
    local override = { messages = cache_messages(body.messages) }
    if body.tools then override.tools = cache_tools(body.tools) end
    local system = cache_system(context.system_prompt)
    if #system > 0 then override.system = system end
    return { body = override }
  end
end

return M
