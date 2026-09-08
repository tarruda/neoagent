local M = {}

local efforts = require("neoagent.model_efforts")
local util = require("neoagent.util")

---@class Neoagent.DeepSeekModelMetadata: Neoagent.ModelConfigInput
---@field input? ("text"|"image")[]
---@field context_window? integer
---@field max_output_tokens? integer
---@field thinking? Neoagent.ThinkingOptions

---@type table<string, Neoagent.DeepSeekModelMetadata>
local overrides = {
  ["deepseek-v4-flash"] = {
    context_window = 1000000,
    max_output_tokens = 384000,
  },
  ["deepseek-v4-pro"] = {
    context_window = 1000000,
    max_output_tokens = 384000,
  },
  ["deepseek-v4-flash-vision-exp"] = {
    input = { "text", "image" },
    context_window = 1000000,
    max_output_tokens = 384000,
  },
}

---@param id string
---@return Neoagent.DeepSeekModelMetadata
function M.for_id(id)
  ---@type Neoagent.DeepSeekModelMetadata
  local result = {
    input = { "text" },
  }
  if id:find("vision", 1, true) then result.input = { "text", "image" } end
  if id:match("^deepseek%-v4%-flash") then
    result.thinking = efforts.thinking_completions({
      "off", "low", "high", "max",
    })
  elseif id:match("^deepseek%-v4%-pro") then
    result.thinking = efforts.thinking_completions({
      "off", "high", "max",
    })
  end
  local override = overrides[id]
  if override then
    result.input = util.copy(override.input or result.input)
    result.context_window = override.context_window
    result.max_output_tokens = override.max_output_tokens
  end
  return result
end

return M
