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
---@field _lease Neoagent.WorkerOwner
---@field _shutdown_timeout_ms integer
---@field _notification Neoagent.Notification
---@field _opening boolean
---@field _admission? {error?: Neoagent.Error}
---@field _closing boolean
---@field _result? {error?: Neoagent.Error}
---@field _dispose_error? Neoagent.Error
---@field timer? uv.uv_timer_t
---@field disposed boolean
---@field opened boolean
---@field report fun(error?: Neoagent.Error)
local Invocation = {}
Invocation.__index = Invocation

---@type table<Neoagent.SandboxInvocation, true>
local pending_invocations = {}

-- Admission belongs to the invocation. Its observer can disappear while the
-- native host is still acquiring authority; that never abandons readiness or
-- prevents a later cooperative shutdown of the admitted RPC worker.
---@async
---@param context Neoagent.JsonObject
function Invocation:open(context)
  assert(not self._opening and not self._closing, "Invocation admission already started or closed")
  self._opening = true
  pending_invocations[self] = true
  async.run(function()
    self.connection:attach(self._lease)
    self._lease:start()
    self._lease:wait_ready()
    self.connection:open(context)
    self.opened = true
  end, {
    error_kind = "sandbox_unavailable",
    on_done = function(result)
      self._admission = { error = result.ok == false and result.error or nil }
      self._notification.notify()
    end,
  })
  while not self._admission do
    self._notification.wait()
  end
  local admission = assert(self._admission)
  if admission.error then
    error(admission.error, 0)
  end
end

---@return boolean
function Invocation:is_released()
  return self._lease:is_released()
end

---@async
---@return true
function Invocation:wait_release()
  return self._lease:wait_release()
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
  local ok, err = pcall(self._lease.dispose, self._lease, reason)
  if not ok then
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

function Invocation:begin_shutdown()
  self:deadline(self._shutdown_timeout_ms, "restricted worker shutdown and native finalization did not settle")
end

-- This is the only shutdown producer. Both close() and detached cancellation
-- observe its durable result, including trailing protocol and native failures.
-- Release can still continue after this bounded cleanup observation finishes.
---@param cancelling boolean
---@param operation_failed boolean
function Invocation:_shutdown(cancelling, operation_failed)
  if self._closing then
    return
  end
  self._closing = true
  pending_invocations[self] = true
  async.run(function()
    while self._opening and not self._admission do
      self._notification.wait()
    end
    local shutdown_error
    local prepared, err = pcall(function()
      if not self.opened or self.connection:is_failed() then
        if self.opened and not operation_failed then
          self.connection:close()
        end
        self.connection:abort()
        self:dispose("restricted worker admission or channel failed")
        return
      end
      if cancelling then
        self.connection:cancel()
        self:deadline(CANCEL_LEASE_GRACE_MS, "restricted worker cancellation did not settle")
        self.connection:wait_cancelled()
      end
      self.connection:close()
      self:begin_shutdown()
    end)
    if not prepared then
      shutdown_error = util.normalize_error(err, "protocol")
      self.connection:abort()
      self:dispose("restricted worker shutdown failed")
    end
    local value = self._lease:wait()
    local cleanup_error = value.cleanup_error
    if self._dispose_error then
      cleanup_error = util.with_cause(self._dispose_error, cleanup_error)
    end
    if self.opened and (not self.disposed or not operation_failed) then
      shutdown_error = shutdown_error or value.error
      if not shutdown_error and value.code ~= 0 then
        shutdown_error =
          util.error("protocol", "Worker failed during shutdown", value.stderr ~= "" and value.stderr or nil)
      end
      -- Native completion can deliver bytes after the close acknowledgement.
      local valid, protocol_error = pcall(self.connection.close, self.connection)
      if not valid then
        shutdown_error = shutdown_error or util.normalize_error(protocol_error, "protocol")
      end
    end
    if cleanup_error and shutdown_error then
      cleanup_error = util.copy(cleanup_error)
      ---@cast cleanup_error Neoagent.SandboxWorkerCleanupError
      cleanup_error.shutdown_error = shutdown_error
    end
    return { error = cleanup_error or shutdown_error }
  end, {
    error_kind = "sandbox_unavailable",
    on_done = function(result)
      if result.ok == false then
        self:dispose("restricted worker cleanup observation failed")
      end
      self:stop_timer()
      self._result = { error = result.error }
      pending_invocations[self] = nil
      pcall(self.report, util.copy(result.error))
      self._notification.notify()
    end,
  })
end

---@param _reason string
function Invocation:cancel(_reason)
  self:_shutdown(true, true)
end

---@async
---@param operation_failed boolean
---@return Neoagent.Error?
function Invocation:close(operation_failed)
  self:_shutdown(false, operation_failed)
  local ok, err = pcall(function()
    while not self._result do
      self._notification.wait()
    end
  end)
  if not ok then
    return util.normalize_error(err, "sandbox_unavailable")
  end
  return util.copy(assert(self._result).error)
end

---@param connection Neoagent.RpcConnection
---@param lease Neoagent.WorkerOwner Purely constructed; no native allocation before start().
---@param on_cleanup fun(error?: Neoagent.Error)
---@param shutdown_timeout_ms integer
---@return Neoagent.SandboxInvocation
function M.new(connection, lease, on_cleanup, shutdown_timeout_ms)
  assert(type(lease) == "table", "sandbox platform returned an invalid worker lease")
  for _, method in ipairs({
    "start",
    "wait_ready",
    "write",
    "close_stdin",
    "terminate",
    "wait",
    "dispose",
    "is_released",
    "wait_release",
  }) do
    if type(lease[method]) ~= "function" then
      error(util.error("sandbox_unavailable", "sandbox platform returned an invalid worker lease: " .. method), 0)
    end
  end
  return setmetatable({
    connection = connection,
    _lease = lease,
    _opening = false,
    _closing = false,
    _notification = async.notification(),
    disposed = false,
    opened = false,
    report = on_cleanup,
    _shutdown_timeout_ms = shutdown_timeout_ms,
  }, Invocation)
end

return M
