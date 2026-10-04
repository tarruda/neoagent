local async = require("neoagent.async")
local util = require("neoagent.util")
local pipes = require("neoagent.subprocess.pipe")
local validate = require("neoagent.subprocess.validate")
local environment = require("neoagent.subprocess.environment")
local cleanup = require("neoagent.subprocess.cleanup")
local protocol = require("neoagent.rpc.protocol")

local M = {}

---@class Neoagent.WorkerRequest
---@field argv string[]
---@field cwd string
---@field env table<string, string>
---@field clear_env? boolean
---@field kill_grace_ms? integer
---@field reap_grace_ms? integer
---@field on_stdout? fun(data: string)
---@field on_stderr? fun(data: string)
---@field on_exit? fun(result: Neoagent.WorkerResult)

---@class Neoagent.WorkerResult
---@field code? integer Present only when native exit was observed.
---@field signal? integer Present only when native exit was observed.
---@field stderr string
---@field error? Neoagent.Error Startup, transport, or protocol failure.
---@field cleanup_error? Neoagent.Error Native cleanup failure, independent of the operation error.
-- If native exit was not observed, at least one failure field is present.

---@class Neoagent.WorkerLease: Neoagent.RpcTransport
---@field wait_ready? async fun(self: Neoagent.WorkerLease): true
---@field terminate fun(self: Neoagent.WorkerLease, reason: string)
---@field wait async fun(self: Neoagent.WorkerLease): Neoagent.WorkerResult
---@field dispose fun(self: Neoagent.WorkerLease, reason: string)
---@field is_released fun(self: Neoagent.WorkerLease): boolean
---@field wait_release async fun(self: Neoagent.WorkerLease): true

---@class Neoagent.ProcessWorkerLease: Neoagent.WorkerLease
---@field _driver? Neoagent.SubprocessDriver
---@field _result? Neoagent.WorkerResult
---@field _exit? {code: integer, signal: integer}
---@field _failure? Neoagent.Error
---@field _waiters Neoagent.AwaitCallbacks<Neoagent.WorkerResult>[]
---@field _stdin_closed boolean
---@field _terminating boolean
---@field _disposing boolean
---@field _starting boolean
---@field _driver_closed boolean
---@field _released boolean
---@field _release_waiters table<Neoagent.AwaitCallbacks<true>, boolean>
---@field _kill_timer? uv.uv_timer_t
---@field _cleanup? Neoagent.ProcessCleanupDeadline
---@field _kill_grace_ms integer
---@field _reap_grace_ms integer
---@field _kill_sent boolean
---@field _stderr string
---@field _on_exit? fun(result: Neoagent.WorkerResult)
local Lease = {}
Lease.__index = Lease

local MAX_STDERR = 16 * 1024
-- RPC can enqueue a complete request synchronously. Its wire representation
-- may be escaped again by a native sandbox relay. Local handles keep their
-- smaller input window; both consumers use the same write accounting.
local INPUT_LIMITS = { bytes = 8 * protocol.MAX_REQUEST, writes = 4096 }
---@type table<Neoagent.ProcessWorkerLease, boolean>
local active = {}

---@param timer? uv.uv_timer_t
local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Lease:_release()
  self._released = true
  local waiters = self._release_waiters
  self._release_waiters = {}
  for done in pairs(waiters) do
    done.resolve(true)
  end
end

function Lease:is_released()
  return self._released
end

---@async
function Lease:wait_release()
  return async.await(function(done)
    if self._released then
      done.resolve(true)
    else
      self._release_waiters[done] = true
    end
    return function()
      self._release_waiters[done] = nil
    end
  end)
end

---@param failure? Neoagent.Error
function Lease:_finish(failure)
  if self._result then
    return
  end
  close_timer(self._kill_timer)
  if self._cleanup then
    self._cleanup.close()
  end
  local closed, close_err = pcall(function()
    if self._driver then
      self._driver.dispose()
    else
      self:_release()
    end
  end)
  if not closed then
    local native_error = util.normalize_error(close_err, "worker_exit")
    failure = failure and util.with_cause(native_error, failure) or native_error
  end
  local exit = self._exit
  assert(exit or failure or self._failure, "worker completion requires native status or failure")
  self._stdin_closed = true
  self._result = {
    code = exit and exit.code,
    signal = exit and exit.signal,
    stderr = self._stderr,
    error = self._failure,
    cleanup_error = failure,
  }
  active[self] = nil
  local waiters = self._waiters
  self._waiters = {}
  for _, done in ipairs(waiters) do
    done.resolve(util.copy(self._result))
  end
  if self._on_exit then
    pcall(self._on_exit, util.copy(self._result))
  end
end

function Lease:_kill()
  if self._kill_sent or self._result then
    return
  end
  self._kill_sent = true
  if self._driver then
    pcall(self._driver.kill)
  end
end

function Lease:_reap()
  if self._result then
    return
  end
  assert(self._cleanup).start(self._reap_grace_ms, self._driver and self._driver.delivery_delay_ns)
end

---@return true
function Lease:wait_ready()
  if self._failure then
    error(util.copy(self._failure), 0)
  end
  return true
end

-- This transport accepts complete protocol frames synchronously. Native write
-- completion and input failures remain owned by the shared pipe driver.
---@param bytes string
---@return true?, Neoagent.Error?
function Lease:write(bytes)
  assert(type(bytes) == "string" and bytes ~= "", "worker write requires bytes")
  if self._disposing or self._result or self._stdin_closed then
    return nil, util.error("protocol", "Worker stdin is closed")
  end
  local ok = pcall(assert(self._driver).write, bytes)
  if not ok then
    self:terminate("worker input failed")
    return nil, util.error("protocol", "Could not write to worker")
  end
  return true
end

---@return true?, Neoagent.Error?
function Lease:close_stdin()
  if self._stdin_closed then
    return true
  end
  self._stdin_closed = true
  if not pcall(assert(self._driver).close_stdin) then
    return nil, util.error("protocol", "Could not close worker stdin")
  end
  return true
end

---@param reason string
function Lease:terminate(reason)
  assert(type(reason) == "string", "worker termination reason is required")
  if self._result or self._terminating then
    return
  end
  self._terminating = true
  self._stdin_closed = true
  if self._exit then
    self:_reap()
    return
  end
  -- Reserve timers before native startup and arm escalation before signalling.
  vim.uv.update_time()
  assert(self._kill_timer):start(self._kill_grace_ms, 0, function()
    close_timer(self._kill_timer)
    self:_kill()
    self:_reap()
  end)
  if self._driver then
    pcall(self._driver.close_stdin)
    pcall(self._driver.stop)
  end
end

---@async
---@return Neoagent.WorkerResult
function Lease:wait()
  if self._result then
    return util.copy(self._result)
  end
  return async.await(function(done)
    self._waiters[#self._waiters + 1] = done
    return function()
      for index, waiter in ipairs(self._waiters) do
        if waiter == done then
          table.remove(self._waiters, index)
          break
        end
      end
    end
  end)
end

---@param reason string
function Lease:dispose(reason)
  assert(type(reason) == "string" and reason ~= "", "worker disposal reason is required")
  if self._disposing or self._result then
    return
  end
  self._disposing = true
  self:terminate(reason)
end

-- Validation throws before ownership begins. Once native startup is attempted,
-- always return its owner, including on failure: wait_ready reports startup,
-- while wait/on_exit observe the independently retained native cleanup.
---@param request Neoagent.WorkerRequest
---@return Neoagent.WorkerLease
function M.start(request)
  assert(type(request) == "table", "worker request must be an object")
  local spec = validate.spec({
    argv = request.argv,
    cwd = request.cwd,
    stdio = { kind = "pipes", stdin = "open" },
    environment = { inherit = request.clear_env == false, set = request.env },
  })
  assert(
    request.kill_grace_ms == nil or validate.integer(request.kill_grace_ms, 0, validate.MAX_TIMEOUT_MS),
    "worker kill grace must be a bounded non-negative integer"
  )
  assert(
    request.reap_grace_ms == nil or validate.integer(request.reap_grace_ms, 0, validate.MAX_TIMEOUT_MS),
    "worker reap grace must be a bounded non-negative integer"
  )
  local env = environment.normalize(spec.environment)
  ---@type Neoagent.ProcessWorkerLease
  local lease = setmetatable({
    _waiters = {},
    _release_waiters = {},
    _released = false,
    _stdin_closed = false,
    _terminating = false,
    _disposing = false,
    _starting = true,
    _driver_closed = false,
    _kill_sent = false,
    _kill_grace_ms = request.kill_grace_ms or 500,
    _reap_grace_ms = request.reap_grace_ms or validate.REAP_MS,
    _stderr = "",
    _on_exit = request.on_exit,
  }, Lease)
  active[lease] = true
  local function failed(message)
    if not lease._result then
      lease._failure = lease._failure or util.error("worker_exit", message)
      lease:terminate(message)
    end
  end
  local ok, err = pcall(function()
    lease._kill_timer = assert(vim.uv.new_timer())
    lease._cleanup = cleanup.new(function()
      lease:_kill()
    end, function()
      lease:_finish(util.error("worker_exit", "Worker cleanup did not settle before its deadline"))
    end)
    lease._driver = pipes.new(spec, env, {
      output = function(stream, bytes)
        if lease._result then
          return
        end
        if stream == "stderr" and #lease._stderr < MAX_STDERR then
          lease._stderr = (lease._stderr .. bytes):sub(1, MAX_STDERR)
        end
        local callback
        if stream == "stdout" then
          callback = request.on_stdout
        else
          callback = request.on_stderr
        end
        if callback and not pcall(callback, bytes) then
          failed("Worker " .. stream .. " callback failed")
        end
      end,
      exited = function(code, signal)
        if lease._result or lease._exit then
          return
        end
        lease._exit = { code = signal ~= 0 and 128 + signal or code, signal = signal }
        lease._stdin_closed = true
        close_timer(lease._kill_timer)
        lease:_kill()
        lease:_reap()
      end,
      closed = function()
        lease._driver_closed = true
        if not lease._starting then
          lease:_finish()
        end
      end,
      released = function()
        lease:_release()
      end,
      failed = function(_, message)
        failed(message)
      end,
      input_failed = function()
        if not lease._terminating and not lease._exit then
          failed("Worker input failed")
        end
      end,
    }, INPUT_LIMITS)
    lease._driver.start()
  end)
  lease._starting = false
  if not ok then
    local cause = util.normalize_error(err)
    lease._failure = util.error("worker_start", "Could not start worker", cause.message)
    lease._stdin_closed = true
    lease._terminating = true
    if lease._driver then
      close_timer(lease._kill_timer)
      lease:_kill()
      lease:_reap()
    end
    if not lease._driver or lease._driver_closed then
      lease:_finish()
    end
    return lease
  end
  if lease._driver_closed then
    lease:_finish()
  end
  return lease
end

return M
