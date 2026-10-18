-- Private identities shared by bundled constructors and the fixed RPC map.
local util = require("neoagent.util")

local M = {
  apply_patch = {},
  view_image = {},
  read_file = {},
  write_file = {},
  edit_file = {},
  shell = {},
  exec_command = {},
  write_stdin = {},
  grep = {},
  find = {},
}

---@alias Neoagent.ToolPreparation fun(arguments: Neoagent.JsonObject, settings: table, ctx: Neoagent.ToolContext<unknown>): table, Neoagent.ToolWorkspace?

---@class Neoagent.ToolImplementationIdentity
---@field token table
---@field settings table
---@field prepare Neoagent.ToolPreparation
---@field run async fun(request: table, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<unknown>): Neoagent.ToolResult
---@field check_context? fun(ctx: Neoagent.ToolContext<unknown>, arguments: Neoagent.JsonObject)

---@type table<function, Neoagent.ToolImplementationIdentity|true>
local implementations = setmetatable({}, { __mode = "k" })

-- File and command implementations bind paths to a Workspace. Retained
-- process interactions need only their current ProcessSessions capability.
---@param prepare fun(arguments: Neoagent.JsonObject, settings: table, call: Neoagent.ToolOperationCall): table
---@return Neoagent.ToolPreparation
function M.workspace_prepare(prepare)
  return function(arguments, settings, ctx)
    local call = require("neoagent.tools.common").call(ctx)
    return prepare(arguments, settings, call), util.copy(call.workspace)
  end
end

---@generic C
---@param facets Neoagent.ToolFacets<C>
---@param identity Neoagent.ToolImplementationIdentity
---@return Neoagent.Tool<C>
function M.bind(facets, identity)
  assert(rawget(facets, "execute") == nil, "Prepared Tools supply prepare and run, not execute")
  assert(type(identity) == "table" and type(identity.token) == "table", "Tool implementation token is required")
  assert(type(identity.settings) == "table", "Tool implementation settings are required")
  assert(type(identity.prepare) == "function", "Tool implementation prepare is required")
  assert(type(identity.run) == "function", "Tool implementation run is required")
  ---@type Neoagent.Tool<C>
  local tool
  ---@async
  ---@param arguments Neoagent.JsonObject
  ---@param ctx Neoagent.ToolContext<C>
  ---@return Neoagent.ToolResult
  local function dispatch(arguments, ctx)
    local invocation = require("neoagent.tools.invocation")
    local prepared = invocation.current(dispatch, ctx) or assert(invocation.prepare(tool, arguments, ctx))
    return invocation.run(prepared, ctx)
  end
  tool = vim.tbl_extend("force", facets, { execute = dispatch })
  implementations[dispatch] = {
    token = identity.token,
    settings = util.copy(identity.settings),
    prepare = identity.prepare,
    run = identity.run,
    check_context = identity.check_context,
  }
  -- Retain a private definition for ordinary preparation. Renaming or copying
  -- the public Tool cannot change its implementation identity.
  return util.shallow_copy(tool)
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
    run = identity.run,
    check_context = identity.check_context,
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
  local identity = implementations[tool.execute]
  return identity == true or type(identity) == "table" and identity.token == M.write_stdin
end

return M
