local util = require("neoagent.util")

local M = {}

---@param value unknown
---@return boolean
function M.object(value)
  return type(value) == "table" and (next(value) == nil or not util.is_list(value))
end

---@param value table
---@param allowed table<string, boolean>
---@param label string
function M.fields(value, allowed, label)
  for key in pairs(value) do
    assert(type(key) == "string" and allowed[key] ~= nil, label .. " has an unknown field")
  end
end

---@param value table
---@param allowed table<string, boolean> True marks a required field.
---@param label string
function M.exact(value, allowed, label)
  M.fields(value, allowed, label)
  for key, required in pairs(allowed) do
    assert(not required or rawget(value, key) ~= nil, label .. " is missing " .. key)
  end
end

return M
