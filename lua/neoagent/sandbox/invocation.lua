local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}

-- Forced lease disposal follows the RPC acknowledgement deadline, with time
-- left to close a cooperatively cancelled connection.
local CANCEL_LEASE_GRACE_MS = require("neoagent.rpc.protocol").CANCEL_GRACE_MS + 250
local WORKER_EXIT_GRACE_MS = 10000

-- Resolve the complete shutdown budget before native startup. The invocation
-- owns protocol/worker shutdown; the platform contributes its native authority
-- finalization allowance, used by that platform's runtime as well.
---@param finalization_ms? integer
---@return integer
function M.shutdown_timeout(finalization_ms)
  local validate = require("neoagent.subprocess.validate")
  if finalization_ms == nil then
    finalization_ms = 0
  end
  assert(
    validate.integer(finalization_ms, 0, validate.MAX_TIMEOUT_MS - WORKER_EXIT_GRACE_MS),
    "sandbox finalization timeout must be a bounded non-negative integer"
  )
  return WORKER_EXIT_GRACE_MS + finalization_ms
end

---@class Neoagent.SandboxWorkerCleanupError: Neoagent.Error
---@field shutdown_error? Neoagent.Error Failure establishing shutdown before native cleanup completed.

---@class Neoagent.SandboxInvocation
---@field connection Neoagent.RpcConnection
---@field _lease Neoagent.WorkerLease
---@field _dispose_error? Neoagent.Error
---@field _shutdown_timeout_ms integer
---@field timer? uv.uv_timer_t
---@field disposed boolean
---@field opened boolean
---@field report fun(error?: Neoagent.Error)
---@field cleanup? Neoagent.Run<Neoagent.WorkerResult, unknown>
local Invocation = {}
Invocation.__index = Invocation

---@type table<Neoagent.SandboxInvocation, boolean>
local pending_invocations = {}

-- Publish the invocation to its caller before awaiting either admission or RPC
-- readiness. A failed open still has the same completion recipient.
---@async
---@param context Neoagent.JsonObject
function Invocation:open(context)
  local lease = self._lease
  if
    not (
      type(lease) == "table"
      and type(lease.write) == "function"
      and type(lease.close_stdin) == "function"
      and type(lease.terminate) == "function"
      and type(lease.wait) == "function"
      and type(lease.dispose) == "function"
      and type(lease.is_released) == "function"
      and type(lease.wait_release) == "function"
      and (lease.wait_ready == nil or type(lease.wait_ready) == "function")
    )
  then
    error(util.error("sandbox_unavailable", "sandbox platform returned an invalid worker lease"), 0)
  end
  self.connection:attach(lease)
  if lease.wait_ready then
    lease:wait_ready()
  end
  self.connection:open(context)
  self.opened = true
end

-- A rejected adapter can lack release observation. Cleanup completion alone
-- cannot release its capacity, even when the remaining lease methods work.
---@return boolean
function Invocation:is_released()
  local lease = self._lease
  if type(lease) ~= "table" or type(lease.is_released) ~= "function" then
    return false
  end
  local ok, released = pcall(lease.is_released, lease)
  return ok and released == true
end

-- Release observation remains independent of bounded cleanup, including for
-- rejected adapters. A successful query can confirm release without a waiter.
---@async
---@return true
function Invocation:wait_release()
  if not self:is_released() then
    local lease = self._lease
    assert(
      type(lease) == "table" and type(lease.wait_release) == "function",
      "Worker lease cannot observe native release"
    )
    lease:wait_release()
    assert(self:is_released(), "Worker lease did not confirm native release")
  end
  return true
end

---@async
---@return Neoagent.WorkerResult
function Invocation:wait()
  local lease = self._lease
  if type(lease) ~= "table" or type(lease.wait) ~= "function" then
    return {
      stderr = "",
      cleanup_error = util.with_cause(
        util.error("sandbox_unavailable", "Worker lease cannot observe cleanup"),
        self._dispose_error
      ),
    }
  end
  local result = lease:wait()
  if self._dispose_error then
    result = util.copy(result)
    result.cleanup_error = util.with_cause(self._dispose_error, result.cleanup_error)
  end
  return result
end

---@param err? Neoagent.Error
function Invocation:complete(err)
  self:stop_timer()
  pending_invocations[self] = nil
  self.report(err)
end

function Invocation:stop_timer()
  local timer = self.timer
  self.timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@param reason string
function Invocation:dispose(reason)
  if self.disposed then
    return
  end
  self.disposed = true
  local disposed, err = pcall(function()
    local lease = self._lease
    assert(type(lease) == "table" and type(lease.dispose) == "function", "Worker lease cannot dispose its resources")
    lease:dispose(reason)
  end)
  if not disposed then
    self._dispose_error = util.normalize_error(err, "sandbox_unavailable")
  end
end

---@param milliseconds integer
---@param reason string
---@param on_timeout? fun()
function Invocation:deadline(milliseconds, reason, on_timeout)
  self:stop_timer()
  local timer = assert(vim.uv.new_timer())
  self.timer = timer
  timer:start(milliseconds, 0, function()
    self:stop_timer()
    if on_timeout then
      on_timeout()
    end
    self:dispose(reason)
  end)
end

-- RPC acknowledgement ends protocol shutdown. The native lease then owns
-- worker exit and platform finalization; cancellation must enter this same
-- phase instead of retaining the shorter RPC cancellation watchdog.
function Invocation:begin_shutdown()
  self:deadline(self._shutdown_timeout_ms, "restricted worker shutdown and native finalization did not settle")
end

-- One invocation retains both resources until detached cleanup settles. The
-- deadline and disposal guard belong to that same owner across cancellation.
---@param cancelling boolean
---@param reason? string
function Invocation:retain(cancelling, reason)
  pending_invocations[self] = true
  self.cleanup = async.run(function()
    ---@type Neoagent.Error?
    local shutdown_error
    if cancelling then
      -- Establish cancellation supervision inside its retained owner. Any
      -- protocol or timer failure still reaches the native cleanup waiter.
      local prepared, err = pcall(function()
        self.connection:cancel()
        self:deadline(CANCEL_LEASE_GRACE_MS, assert(reason))
        self.connection:wait_cancelled()
        self.connection:close()
        self:begin_shutdown()
      end)
      if not prepared then
        shutdown_error = util.normalize_error(err, "sandbox_unavailable")
        self.connection:abort()
        self:dispose("restricted worker cancellation failed")
      end
    end
    local result = self:wait()
    if shutdown_error then
      result = util.copy(result)
      if result.cleanup_error then
        ---@type Neoagent.SandboxWorkerCleanupError
        local cleanup_error = result.cleanup_error
        cleanup_error.shutdown_error = shutdown_error
        result.cleanup_error = cleanup_error
      else
        result.cleanup_error = shutdown_error
      end
    end
    return result
  end, {
    error_kind = "sandbox_unavailable",
    on_done = function(value)
      if value.ok == false then
        self:dispose("restricted worker cleanup failed")
        self:complete(value.error)
      else
        self:complete(value.cleanup_error)
      end
    end,
  })
end

---@param reason string
function Invocation:cancel(reason)
  self:retain(true, reason)
end

---@async
---@param reason string
---@return Neoagent.Error?
function Invocation:abort(reason)
  self.connection:abort()
  self:dispose(reason)
  local run = async.current()
  if not run or run:is_cancelled() then
    self:retain(false)
    return run and async.cancelled_error or nil
  else
    local waited, value = pcall(self.wait, self)
    if not waited then
      self:retain(false)
      return util.normalize_error(value, "sandbox_unavailable")
    end
    self:complete(value.cleanup_error)
    return value.cleanup_error
  end
end

---@async
---@param self Neoagent.SandboxInvocation
---@param operation_failed boolean
---@return Neoagent.Error?
local function close(self, operation_failed)
  if not self.opened or operation_failed and self.connection:is_failed() then
    return self:abort("restricted worker admission or operation failed")
  end
  local closed, close_err = pcall(self.connection.close, self.connection)
  if not closed then
    local err = util.normalize_error(close_err, "protocol")
    if err.kind == "cancelled" then
      self:cancel("restricted worker shutdown cancellation did not settle")
    else
      return self:abort("restricted worker failed to close") or err
    end
    return err
  end
  self:begin_shutdown()
  local waited, value = pcall(self.wait, self)
  if not waited then
    self:retain(false)
    return util.normalize_error(value, "sandbox_unavailable")
  end
  self:complete(value.cleanup_error)
  if value.cleanup_error or value.error then
    return util.normalize_error(value.cleanup_error or value.error, "sandbox_unavailable")
  end
  if value.code ~= 0 then
    return util.error("protocol", "Worker failed during shutdown", value.stderr ~= "" and value.stderr or nil)
  end
  -- The lease can deliver trailing bytes after close acknowledged the peer.
  -- Recheck the logical channel after all output and native cleanup settle.
  local finished, finish_err = pcall(self.connection.close, self.connection)
  if not finished then
    return util.normalize_error(finish_err, "protocol")
  end
end

---@async
---@param operation_failed boolean
---@return Neoagent.Error?
function Invocation:close(operation_failed)
  -- Native supervision can fail before the cleanup waiter is installed. The
  -- invocation still owns disposal and observation on every such exit path.
  local ok, result = pcall(close, self, operation_failed)
  if ok then
    return result
  end
  local err = util.normalize_error(result, "sandbox_unavailable")
  return self:abort("restricted worker shutdown failed") or err
end

---@param connection Neoagent.RpcConnection
---@param lease Neoagent.WorkerLease
---@param on_cleanup fun(error?: Neoagent.Error) Reports final cleanup, including success, to the owning composition.
---@param shutdown_timeout_ms integer Validated complete shutdown budget from the platform composition.
---@return Neoagent.SandboxInvocation
function M.new(connection, lease, on_cleanup, shutdown_timeout_ms)
  return setmetatable({
    connection = connection,
    _lease = lease,
    disposed = false,
    opened = false,
    report = on_cleanup,
    _shutdown_timeout_ms = shutdown_timeout_ms,
  }, Invocation)
end

return M
