local limits = require("neoagent.rpc.tool_limits")
local methods = require("neoagent.rpc.methods")
local identities = require("neoagent.tools.identities")
local common = require("neoagent.tools.common")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.ToolRpcAdapter
---@field method string

---@class Neoagent.ToolRpcProxyOptions
---@field call Neoagent.ToolOperationCall
---@field invoke async fun(method: string, request: table, call: Neoagent.ToolOperationCall): Neoagent.ToolResult

---@generic C
---@param tool Neoagent.Tool<C>
---@return Neoagent.ToolRpcAdapter?, Neoagent.ToolImplementationIdentity?
function M.resolve(tool)
  local identity = identities.identity(tool)
  if not identity then
    return nil
  end
  local descriptor = methods.by_token[identity.token]
  return descriptor and { method = descriptor.name } or nil, identity
end

---@param expected Neoagent.ToolOperationCall
---@param actual Neoagent.ToolOperationCall
local function same_workspace(expected, actual)
  if not vim.deep_equal(expected.workspace, actual.workspace) then
    error("Tool workspace changed during an RPC invocation", 0)
  end
end

---@generic C
---@param tool Neoagent.Tool<C>
---@param options Neoagent.ToolRpcProxyOptions
---@return Neoagent.Tool<C>?, fun()?
function M.proxy(tool, options)
  assert(type(options) == "table" and type(options.invoke) == "function", "Tool RPC proxy invoker is required")
  local expected_call = common.validate_call(options.call)
  local adapter, identity = M.resolve(tool)
  if not adapter or not identity then
    return nil
  end
  local inputs = require("neoagent.tools.limits")
  assert(
    inputs.MAX_INPUT_BYTES + inputs.MAX_INPUT_VALUES * limits.REQUEST_VALUE_OVERHEAD
      <= require("neoagent.rpc.protocol").MAX_REQUEST,
    "Tool request limit exceeds RPC transport capacity"
  )
  ---@type Neoagent.Tool<C>
  local proxy = {
    name = tool.name,
    description = tool.description,
    input_schema = tool.input_schema,
    execute = tool.execute,
  }
  for key, value in pairs(tool) do
    rawset(proxy, key, value)
  end
  local active = true
  ---@async
  local function execute(arguments, ctx)
    if not active then
      error("Tool RPC proxy invocation has expired", 0)
    end
    local call = common.call(ctx)
    local request = identity.prepare(arguments, identity.settings, call)
    same_workspace(expected_call, call)
    return options.invoke(adapter.method, request, call)
  end
  proxy.execute = execute
  return proxy, function()
    active = false
  end
end

return M
