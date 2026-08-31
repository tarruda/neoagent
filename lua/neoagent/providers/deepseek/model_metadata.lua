local M = {}

local efforts = require("neoagent.model_efforts")
local util = require("neoagent.util")

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

function M.for_id(id)
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
  return util.deep_merge(result, util.copy(overrides[id] or {}))
end

return M
