local util = require("neoagent.util")

local M = {}

function M.normalize(value)
  if type(value) ~= "table" or util.is_list(value) then
    return vim.empty_dict(), "Tool arguments are not a JSON object"
  end
  return next(value) == nil and vim.empty_dict() or value
end

function M.decode(raw)
  local decoded, value = pcall(vim.json.decode, raw ~= "" and raw or "{}")
  if not decoded then
    return vim.empty_dict(), "Tool arguments are not valid JSON"
  end
  return M.normalize(value)
end

return M
