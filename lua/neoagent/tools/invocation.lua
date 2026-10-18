local common = require("neoagent.tools.common")
local identities = require("neoagent.tools.identities")
local util = require("neoagent.util")
local M = {}

---@class Neoagent.PreparedToolInvocation
---@field definition function
---@field identity Neoagent.ToolImplementationIdentity
---@field arguments Neoagent.JsonObject
---@field request table
---@field workspace? Neoagent.ToolWorkspace

---@class Neoagent.PreparedToolContext<C>: Neoagent.ToolContext<C>
---@field prepared_tool? Neoagent.PreparedToolInvocation

-- Preparation captures semantic input, not runtime owners. The execution
-- context remains borrowed from the invocation's current admission authority.
---@generic C
---@param tool Neoagent.Tool<C>
---@param arguments Neoagent.JsonObject
---@param ctx Neoagent.ToolContext<C>
---@return Neoagent.PreparedToolInvocation?
function M.prepare(tool, arguments, ctx)
  local identity = identities.identity(tool)
  if not identity then
    return nil
  end
  if identity.check_context then
    identity.check_context(ctx, arguments)
  end
  local copied = util.copy(arguments)
  local request, workspace = identity.prepare(copied, identity.settings, ctx)
  return {
    definition = tool.execute,
    identity = identity,
    arguments = copied,
    request = request,
    workspace = util.copy(workspace),
  }
end

---@param definition function
---@param ctx? table
---@return Neoagent.PreparedToolInvocation?
function M.current(definition, ctx)
  local prepared = ctx and rawget(ctx, "prepared_tool")
  if prepared and prepared.definition == definition then
    return prepared
  end
end

---@generic C
---@param ctx Neoagent.ToolContext<C>
---@param prepared? Neoagent.PreparedToolInvocation
---@return Neoagent.ToolContext<C>
function M.context(ctx, prepared)
  local forwarded = util.shallow_copy(ctx)
  rawset(forwarded, "prepared_tool", prepared)
  return forwarded
end

---@param prepared Neoagent.PreparedToolInvocation
---@param call Neoagent.ToolOperationCall
---@return table
function M.request(prepared, call)
  assert(vim.deep_equal(prepared.workspace, call.workspace), "Tool workspace changed during execution")
  return util.copy(prepared.request)
end

---@async
---@param prepared Neoagent.PreparedToolInvocation
---@param ctx Neoagent.ToolContext<unknown>
---@return Neoagent.ToolResult
function M.run(prepared, ctx)
  local request = prepared.workspace and M.request(prepared, common.call(ctx)) or util.copy(prepared.request)
  return prepared.identity.run(request, util.copy(prepared.arguments), ctx)
end

return M
