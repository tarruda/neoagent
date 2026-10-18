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
  ---@type (fun(name: string, value: table))?
  local notify
  return {
    error_kind = "tool",
    events = function(send)
      notify = send
    end,
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
        on_file_changed = function(path)
          assert(notify)(codec.events.file_changed, { path = path })
        end,
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
      local observe = require("neoagent.rpc.output_matcher").new(selected_context.denial_keywords, function(keyword)
        active.policy = active.policy or {}
        active.policy.denial_output = keyword
      end)
      dependency_options.subprocesses = {
        ---@async
        run = function(spec, options)
          local selected = util.copy(options)
          local on_output = selected.on_output
          selected.on_output = function(event)
            -- Search stdout contains matched file content and names, not diagnostics.
            -- Shell commands may report failures on either stream.
            if event.stream == "stderr" or active.method == "shell" then
              observe(event.stream, event.data)
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
