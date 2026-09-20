-- Private identities shared by bundled constructors and the fixed RPC map.
local util = require("neoagent.util")

local M = {
  read_file = {},
  write_file = {},
  edit_file = {},
  shell = {},
  grep = {},
  find = {},
}

---@class Neoagent.ToolImplementationIdentity
---@field token table
---@field settings table
---@field prepare fun(arguments: Neoagent.JsonObject, settings: table, call: Neoagent.ToolOperationCall): table

---@type table<function, Neoagent.ToolImplementationIdentity|true>
local implementations = setmetatable({}, { __mode = "k" })

---@generic C
---@param tool Neoagent.Tool<C>
---@param identity Neoagent.ToolImplementationIdentity
---@return Neoagent.Tool<C>
function M.bind(tool, identity)
  assert(type(tool.execute) == "function", "Tool implementation requires execute")
  assert(type(identity) == "table" and type(identity.token) == "table", "Tool implementation token is required")
  assert(type(identity.settings) == "table", "Tool implementation settings are required")
  assert(type(identity.prepare) == "function", "Tool implementation prepare is required")
  implementations[tool.execute] = {
    token = identity.token,
    settings = util.copy(identity.settings),
    prepare = identity.prepare,
  }
  return tool
end

---@generic C
---@param tool Neoagent.Tool<C>
---@return Neoagent.ToolImplementationIdentity?
function M.identity(tool)
  local identity = type(tool) == "table" and implementations[tool.execute] or nil
  if type(identity) ~= "table" then
    return nil
  end
  return {
    token = identity.token,
    settings = util.copy(identity.settings),
    prepare = identity.prepare,
  }
end

---@generic C
---@param tool Neoagent.Tool<C>
---@return Neoagent.Tool<C>
function M.bind_parent(tool)
  implementations[tool.execute] = true
  return tool
end

---@generic C
---@param tool Neoagent.Tool<C>
---@return boolean
function M.is_parent(tool)
  return implementations[tool.execute] == true
end

return M
