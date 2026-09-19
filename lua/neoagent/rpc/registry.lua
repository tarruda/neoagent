local artifacts = require("neoagent.rpc.artifacts")
local codec = require("neoagent.rpc.codec")
local limits = require("neoagent.rpc.limits")
local methods = require("neoagent.rpc.methods")
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
  local identity = common.identity(tool)
  if not identity then
    return nil
  end
  local descriptor = methods.by_token[identity.token]
  return descriptor and { method = descriptor.name } or nil, identity
end

---@param expected Neoagent.ToolOperationCall
---@param actual Neoagent.ToolOperationCall
local function same_call(expected, actual)
  if not vim.deep_equal(codec.encode_context(expected), codec.encode_context(actual)) then
    error("Tool operation context changed during an RPC invocation", 0)
  end
end

---@async
---@param connection Neoagent.RpcConnection
---@param method string
---@param request table
---@param call Neoagent.ToolOperationCall
---@param on_policy? fun(evidence: Neoagent.ToolRpcPolicyEvidence)
---@return Neoagent.ToolResult
function M.invoke(connection, method, request, call, on_policy)
  local importer = artifacts.importer(call)
  local update_count = 0
  local update_bytes = 0
  ---@async
  local function on_event(message)
    if message.name == codec.events.artifact_begin
        or message.name == codec.events.artifact_chunk
        or message.name == codec.events.artifact_end then
      local artifact = util.copy(message.value)
      artifact.type = message.name == codec.events.artifact_begin and "artifact_begin"
        or message.name == codec.events.artifact_chunk and "artifact_chunk"
        or "artifact_end"
      local accepted, accept_err = pcall(importer.accept, importer, artifact)
      if not accepted then
        local err = util.normalize_error(accept_err, "artifact")
        if err.kind == "cancelled" then
          error(err, 0)
        end
        error(util.error("artifact", "Could not import a Tool worker artifact", err.message), 0)
      end
      return
    end
    assert(message.name == codec.events.update, "Tool RPC received an unknown event")
    local encoded, bytes = pcall(vim.mpack.encode, message.value)
    assert(encoded and type(bytes) == "string", "Tool update could not be encoded")
    update_count = update_count + 1
    update_bytes = update_bytes + #bytes
    assert(
      update_count <= limits.MAX_UPDATE_COUNT and update_bytes <= limits.MAX_UPDATE_BYTES,
      "Tool worker updates exceeded the aggregate protocol limit"
    )
    local update = common.update(message.value)
    local checked, check_err = pcall(importer.check_result, importer, update)
    if not checked then
      error(util.error("artifact", "Tool update referenced an invalid artifact", check_err), 0)
    end
    call.on_update(update)
  end
  local completed, value = pcall(
    connection.request,
    connection,
    method,
    request,
    { on_event = on_event }
  )
  if not completed then
    importer:discard()
    error(value, 0)
  end
  local decoded, result = pcall(function()
    local valid, evidence = codec.decode_result(value)
    if evidence and on_policy then
      on_policy(evidence)
    end
    return valid
  end)
  if not decoded then
    connection:abort()
    importer:discard()
    error(util.error("protocol", util.safe_message(result)), 0)
  end
  local checked, check_err = pcall(importer.check_result, importer, result)
  if not checked then
    connection:abort()
    importer:discard()
    error(util.error("artifact", "Tool result referenced an invalid artifact", check_err), 0)
  end
  return result
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
    local request = identity.prepare(arguments, identity.settings)
    local call = common.call(ctx)
    same_call(expected_call, call)
    return options.invoke(adapter.method, request, call)
  end
  proxy.execute = execute
  return proxy, function()
    active = false
  end
end

return M
