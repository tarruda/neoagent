local util = require("neoagent.util")

local M = {}

-- This checks the outer object shape; semantic message validation checks its
-- keys and values before accepting a complete tool call.
---@param value unknown
---@return table<unknown, unknown> arguments
---@return string? error
function M.normalize(value)
  if type(value) ~= "table" or util.is_list(value) then
    return vim.empty_dict(), "Tool arguments are not a JSON object"
  end
  return next(value) == nil and vim.empty_dict() or value
end

---@param raw string
---@return table<unknown, unknown> arguments
---@return string? error
function M.decode(raw)
  local decoded, value = pcall(vim.json.decode, raw ~= "" and raw or "{}")
  if not decoded then
    return vim.empty_dict(), "Tool arguments are not valid JSON"
  end
  return M.normalize(value)
end

return M
