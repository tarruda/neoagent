local artifacts = require("neoagent.rpc.artifacts")
local codec = require("neoagent.rpc.codec")
local limits = require("neoagent.rpc.tool_limits")
local methods = require("neoagent.rpc.methods")
local protocol = require("neoagent.rpc.protocol")
local util = require("neoagent.util")
local M = {}

---@class Neoagent.ToolServerFacts
---@field method string
---@field update_count integer
---@field update_bytes integer
---@field policy? Neoagent.ToolRpcPolicyEvidence

---@param active Neoagent.ToolServerFacts
---@param keywords string[]
---@return fun(output: string, is_stderr: boolean)?
local function policy_output_observer(active, keywords)
  if #keywords == 0 then
    return nil
  end
  local lowered = {}
  local overlap_bytes = 0
  for index, keyword in ipairs(keywords) do
    lowered[index] = keyword:lower()
    overlap_bytes = math.max(overlap_bytes, #keyword - 1)
  end
  local overlaps = { [false] = "", [true] = "" }
  return function(output, is_stderr)
    if active.policy and active.policy.denial_output or output == "" then
      return
    end
    local text = (overlaps[is_stderr] .. output):lower()
    for index, keyword in ipairs(lowered) do
      if text:find(keyword, 1, true) then
        active.policy = active.policy or {}
        active.policy.denial_output = assert(keywords[index])
        return
      end
    end
    overlaps[is_stderr] = overlap_bytes > 0 and text:sub(-overlap_bytes) or ""
  end
end

---@param dependencies Neoagent.ToolDependencyOverrides
---@param dispatch? async fun(name: string, payload: unknown, call: Neoagent.ToolOperationCall, options: Neoagent.ToolDependencyOverrides): Neoagent.ToolResult
---@return Neoagent.RpcServerDomain
function M.new(dependencies, dispatch)
  local processes = require("neoagent.subprocess_common").scope()
  ---@type {workspace: Neoagent.ToolWorkspace, denial_keywords: string[]}?
  local context
  ---@async
  local function dispatch_default(name, payload, call, options)
    local descriptor = assert(methods.by_name[name], "unknown Tool RPC method")
    return descriptor.execute(payload, call, options)
  end
  local execute = dispatch or dispatch_default
  return {
    error_kind = "tool",
    max_pending_events = 0,
    events = function() end,
    open = function(value)
      context = codec.decode_context(value)
    end,
    request = function(method, payload, emit, cancelled)
      processes = require("neoagent.subprocess_common").scope()
      local request_processes = processes
      local active = { method = method, update_count = 0, update_bytes = 0 }
      local publisher = artifacts.publisher(function(event)
        local value = util.copy(event)
        value.type = nil
        local name = event.type == "artifact_begin" and codec.events.artifact_begin
          or event.type == "artifact_chunk" and codec.events.artifact_chunk
          or codec.events.artifact_end
        emit(name, value)
      end)
      local selected_context = assert(context)
      ---@type Neoagent.ToolOperationCall
      local call = {
        workspace = util.copy(selected_context.workspace),
        on_update = function(value)
          if cancelled() then
            return
          end
          local valid = codec.update(value)
          local encoded, bytes = pcall(vim.mpack.encode, valid)
          if not encoded or type(bytes) ~= "string" then
            error("Tool update could not be encoded", 0)
          end
          if
            active.update_count + 1 > limits.MAX_UPDATE_COUNT
            or active.update_bytes + #bytes > limits.MAX_UPDATE_BYTES
          then
            -- Updates are transient progress. Once their bounded transport budget
            -- is exhausted, preserve the authoritative final Tool result.
            return
          end
          active.update_count = active.update_count + 1
          active.update_bytes = active.update_bytes + #bytes
          emit(codec.events.update, valid)
        end,
      }
      local dependency_options = util.copy(dependencies)
      local subprocesses = dependency_options.subprocesses
        or {
          ---@async
          run = function(spec, options)
            return request_processes:run(spec, options)
          end,
        }
      local observe = policy_output_observer(active, selected_context.denial_keywords)
      dependency_options.subprocesses = {
        ---@async
        run = function(spec, options)
          local selected = util.copy(options)
          local on_output = selected.on_output
          selected.on_output = function(event)
            -- Search stdout contains matched file content and names, not diagnostics.
            -- Shell commands may report failures on either stream.
            if observe and (event.stream == "stderr" or active.method == "shell") then
              observe(event.data, event.stream == "stderr")
            end
            if on_output then
              on_output(event)
            end
          end
          local result = subprocesses.run(spec, selected)
          -- Preserve native status before the Tool turns a failure into text.
          -- The parent decides whether these observations establish a denial.
          if result.code ~= 0 then
            active.policy = active.policy or {}
            active.policy.process_exit = { code = result.code, signal = result.signal }
          end
          return result
        end,
      }
      dependency_options.artifact_publisher = function()
        return publisher
      end

      return {
        ---@async
        execute = function()
          return execute(method, payload, call, dependency_options)
        end,
        ---@async
        finish = function(result)
          request_processes:close("Tool request finished")
          request_processes:wait(math.floor(protocol.CANCEL_GRACE_MS / 2))
          if
            not cancelled()
            and active.policy
            and (result.ok == false and result.error.kind ~= "cancelled" or result.isError)
          then
            emit(codec.events.policy, active.policy)
          end
          return result.ok == false and result or codec.result(result)
        end,
      }
    end,
    close = function(reason)
      processes:close(reason)
    end,
    is_quiescent = function()
      return processes:is_settled()
    end,
  }
end

return M
