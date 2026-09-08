local auth = require("neoagent.auth")
local util = require("neoagent.util")

local M = {}

---@param initial? table<string, Neoagent.JsonValue>
---@return Neoagent.AuthStorage
function M.store(initial)
  local values = util.copy(initial or {})
  return {
    read = function(_, id) return util.copy(values[id]) end,
    write = function(_, id, value)
      values[id] = util.copy(value)
      return true
    end,
  }
end

---@param methods? table<string, Neoagent.AuthMethod<Neoagent.Credential>>
---@return Neoagent.AuthManager
function M.new(methods)
  return auth.new({ methods = methods or {}, store = M.store() })
end

return M
