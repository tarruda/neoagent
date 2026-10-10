local async = require("neoagent.async")
local util = require("neoagent.util")
local validate = require("neoagent.subprocess.validate")
local M = {}

---@param spec Neoagent.SubprocessSpec
---@param output_bytes integer
---@param on_cleanup? fun(error: Neoagent.Error)
---@param on_released? fun()
---@return Neoagent.ProcessController
function M.new(spec, output_bytes, on_cleanup, on_released)
  local scope, wait_cleanup = require("neoagent.subprocess.scope").new(on_released)
  local buffer = require("neoagent.process_sessions.buffer").new(output_bytes)
  ---@type Neoagent.SubprocessHandle?
  local handle
  ---@type Neoagent.Error?
  local failure, cleanup_error
  local started, done, disposed = false, false, false
  local notification = async.notification()
  local notify, changed = notification.notify, notification.wait
  local function state()
    local native = handle and handle:state()
    return {
      done = done,
      cleanup_done = done,
      released = started and scope:is_released(),
      stdin_writable = native ~= nil and native.stdin_writable,
      resize_supported = native ~= nil and native.resize_supported,
      outcome = native and native.terminal,
      error = util.copy(failure or native and native.failure),
      cleanup_error = util.copy(cleanup_error),
    }
  end
  return {
    start = function()
      if disposed then
        error(validate.error("process_disposed", "Process controller is disposed"), 0)
      end
      assert(not started, "process controller already started")
      started = true
      local launched, value = pcall(scope.spawn, scope, spec, {
        on_output = function(event)
          buffer.append(event)
          notify()
        end,
      })
      if launched then
        handle = value
      else
        failure = util.normalize_error(value, "process_start")
        scope:close("Process session failed to start")
      end
      -- This cleanup observer belongs to the controller, not to the caller
      -- waiting for admission, input, or output.
      async.run(function()
        wait_cleanup()
      end, {
        on_done = function(result)
          if result.ok == false then
            cleanup_error = result.error
          end
          done = true
          if cleanup_error and on_cleanup then
            pcall(on_cleanup, util.copy(cleanup_error))
          end
          notify()
        end,
      })
      if failure then
        error(failure, 0)
      end
      return true
    end,
    state = state,
    ---@async
    collect = function(_, wait_ms, until_exit)
      local deadline = vim.uv.hrtime() + wait_ms * 1000000
      while not done and not disposed and (until_exit or buffer.empty()) do
        local remaining = math.ceil((deadline - vim.uv.hrtime()) / 1000000)
        if remaining <= 0 then
          break
        end
        changed(remaining)
      end
      local result = state()
      local events, dropped = buffer.take()
      return vim.tbl_extend("force", result, { events = events, dropped_bytes = dropped })
    end,
    control = function(_, command)
      if disposed or not handle then
        error(validate.error("process_disposed", "Process controller is unavailable"), 0)
      end
      if command.kind == "write" then
        return handle:write(assert(command.data))
      elseif command.kind == "close_stdin" then
        return handle:close_stdin()
      elseif command.kind == "resize" then
        return handle:resize(assert(command.columns), assert(command.rows))
      elseif command.kind == "interrupt" then
        return handle:interrupt()
      end
      return handle:terminate(assert(command.reason))
    end,
    ---@async
    wait_cleanup = function()
      while not done do
        changed()
      end
      return true
    end,
    dispose = function(_, reason)
      disposed = true
      scope:close(reason)
      if not started then
        started, done = true, true
      end
      notify()
    end,
  }
end

return M
