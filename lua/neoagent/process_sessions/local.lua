local async = require("neoagent.async")
local util = require("neoagent.util")
local validate = require("neoagent.subprocess.validate")
local M = {}

---@class Neoagent.ProcessControllerState
---@field done boolean
---@field released boolean
---@field stdin_writable boolean
---@field resize_supported boolean
---@field outcome? Neoagent.SubprocessOutcome
---@field error? Neoagent.Error
---@field cleanup_error? Neoagent.Error

---@class Neoagent.ProcessCollection: Neoagent.ProcessControllerState
---@field events Neoagent.SubprocessOutputEvent[] Raw bytes in callback order.
---@field dropped_bytes integer

---@class Neoagent.ProcessControl
---@field kind "write"|"close_stdin"|"resize"|"interrupt"|"terminate"
---@field data? string
---@field columns? integer
---@field rows? integer
---@field reason? string

-- Both concrete controllers reserve ownership before start. A remote
-- controller acknowledges controls asynchronously without changing the
-- synchronous local subprocess API.
---@class Neoagent.ProcessController
---@field start async fun(self: Neoagent.ProcessController): true
---@field state fun(self: Neoagent.ProcessController): Neoagent.ProcessControllerState
---@field collect async fun(self: Neoagent.ProcessController, wait_ms: integer, until_exit?: boolean): Neoagent.ProcessCollection
---@field control async fun(self: Neoagent.ProcessController, command: Neoagent.ProcessControl): true
---@field wait async fun(self: Neoagent.ProcessController): true
---@field dispose fun(self: Neoagent.ProcessController, reason: string)

---@alias Neoagent.ProcessControllerFactory fun(spec: Neoagent.SubprocessSpec, output_bytes: integer, on_cleanup: fun(error: Neoagent.Error)): Neoagent.ProcessController

---@param command unknown
---@return Neoagent.ProcessControl
function M.validate_control(command)
  local fields = {
    write = { kind = true, data = true },
    close_stdin = { kind = true },
    resize = { kind = true, columns = true, rows = true },
    interrupt = { kind = true },
    terminate = { kind = true, reason = true },
  }
  assert(type(command) == "table" and fields[command.kind], "invalid process control")
  validate.fields(command, fields[command.kind], "Process control")
  if command.kind == "write" then
    assert(
      type(command.data) == "string" and #command.data <= validate.WRITE_BYTES,
      "process input exceeds 65536 bytes"
    )
  elseif command.kind == "resize" then
    validate.dimensions(command.columns, command.rows)
  elseif command.kind == "terminate" then
    validate.reason(command.reason)
  end
  ---@cast command Neoagent.ProcessControl
  return util.copy(command)
end

---@param spec Neoagent.SubprocessSpec
---@param output_bytes integer
---@param on_cleanup? fun(error: Neoagent.Error)
---@param on_released? fun()
---@return Neoagent.ProcessController
function M.new(spec, output_bytes, on_cleanup, on_released)
  local scope = require("neoagent.subprocess.scope").new(on_released)
  local buffer = require("neoagent.process_sessions.buffer").new(output_bytes)
  ---@type Neoagent.SubprocessHandle?
  local handle
  ---@type Neoagent.Error?
  local failure, cleanup_error
  local started, done, disposed = false, false, false
  ---@type table<Neoagent.AwaitCallbacks<true>, fun()>
  local waiters = {}
  local function notify()
    local current = waiters
    waiters = {}
    for waiter, cleanup in pairs(current) do
      cleanup()
      waiter.resolve(true)
    end
  end
  local function state()
    local native = handle and handle:state()
    return {
      done = done,
      released = started and scope:is_released(),
      stdin_writable = native ~= nil and native.stdin_writable,
      resize_supported = native ~= nil and native.resize_supported,
      outcome = native and native.terminal,
      error = util.copy(failure or native and native.failure),
      cleanup_error = util.copy(cleanup_error),
    }
  end
  ---@async
  local function changed(milliseconds)
    return async.await(function(waiter)
      local timer
      local function cleanup()
        waiters[waiter] = nil
        if timer and not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      end
      if milliseconds then
        timer = assert(vim.uv.new_timer())
        vim.uv.update_time()
        timer:start(milliseconds, 0, function()
          cleanup()
          waiter.resolve(true)
        end)
      end
      waiters[waiter] = cleanup
      return cleanup
    end)
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
        if handle then
          handle:wait_cleanup()
        else
          scope:wait(validate.REAP_MS + 1000)
        end
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
      M.validate_control(command)
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
    wait = function()
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
