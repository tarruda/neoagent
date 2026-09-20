local artifacts = require("neoagent.rpc.artifacts")
local async = require("neoagent.async")
local codec = require("neoagent.rpc.codec")
local limits = require("neoagent.rpc.tool_limits")
local util = require("neoagent.util")

local M = {}

---@async
---@param connection Neoagent.RpcConnection
---@param method string
---@param request table
---@param call Neoagent.ToolOperationCall
---@param on_policy? fun(evidence: Neoagent.ToolRpcPolicyEvidence)
---@return Neoagent.ToolResult
function M.invoke(connection, method, request, call, on_policy)
  local importer = artifacts.importer(call)
  local owner = async.current()
  local update_count = 0
  local update_bytes = 0
  local policy_received = false
  ---@async
  local function on_event(message)
    if message.name == codec.events.policy then
      assert(not policy_received, "Tool worker sent duplicate policy evidence")
      local evidence = codec.decode_policy(message.value)
      policy_received = true
      if on_policy then
        on_policy(evidence)
      end
      return
    end
    if
      message.name == codec.events.artifact_begin
      or message.name == codec.events.artifact_chunk
      or message.name == codec.events.artifact_end
    then
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
    local update = codec.update(message.value)
    local checked, check_err = pcall(importer.check_result, importer, update)
    if not checked then
      error(util.error("artifact", "Tool update referenced an invalid artifact", check_err), 0)
    end
    if not connection:is_failed() and (not owner or not owner:is_cancelled()) then
      local observed, observation_err = pcall(call.on_update, update)
      if not observed then
        local err = util.normalize_error(observation_err, "protocol")
        if not owner or not owner:is_cancelled() or err.kind ~= "cancelled" then
          error(err, 0)
        end
      end
    end
  end
  local completed, value = pcall(connection.request, connection, method, request, { on_event = on_event })
  if not completed then
    importer:discard()
    error(value, 0)
  end
  local decoded, result = pcall(codec.result, value)
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

return M
