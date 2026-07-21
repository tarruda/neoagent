local util = require("neoagent.util")

local M = {}

function M.normalize(schema)
  assert(type(schema) == "table", "tool input_schema must be a table")
  local normalized = util.copy(schema)
  if next(normalized) == nil then return vim.empty_dict() end
  if normalized.type == "object" and type(normalized.properties) == "table"
      and next(normalized.properties) == nil then
    normalized.properties = vim.empty_dict()
  end
  return normalized
end

return M
