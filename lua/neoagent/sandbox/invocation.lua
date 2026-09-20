local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}

-- Forced lease disposal follows the RPC acknowledgement deadline, with time
-- left to close a cooperatively cancelled connection.
local CANCEL_LEASE_GRACE_MS = require("neoagent.rpc.protocol").CANCEL_GRACE_MS + 250
local WORKER_EXIT_GRACE_MS = 10000

---@class Neoagent.SandboxInvocation
---@field connection Neoagent.RpcConnection
---@field lease Neoagent.WorkerLease
---@field timer? uv.uv_timer_t
---@field disposed boolean
---@field cleanup? Neoagent.Run<Neoagent.WorkerResult, unknown>
local Invocation = {}
Invocation.__index = Invocation

---@type table<Neoagent.SandboxInvocation, boolean>
local pending_invocations = {}

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
  pcall(self.lease.dispose, self.lease, reason)
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

-- One invocation retains both resources until detached cleanup settles. The
-- deadline and disposal guard belong to that same owner across cancellation.
---@param cancelling boolean
function Invocation:retain(cancelling)
  pending_invocations[self] = true
  self.cleanup = async.run(function()
    if cancelling then
      local cancelled = pcall(self.connection.wait_cancelled, self.connection)
      local closed = cancelled and pcall(self.connection.close, self.connection)
      if not cancelled or not closed then
        self.connection:abort()
        self:dispose("restricted Tool worker cancellation failed")
      end
    end
    return self.lease:wait()
  end, {
    error_kind = "sandbox_unavailable",
    on_done = function(value)
      if value.ok == false then
        self:dispose("restricted Tool worker cleanup failed")
      end
      self:stop_timer()
      pending_invocations[self] = nil
    end,
  })
end

---@param reason string
function Invocation:cancel(reason)
  local cancelled = pcall(self.connection.cancel, self.connection)
  if not cancelled then
    self.connection:abort()
  end
  self:deadline(CANCEL_LEASE_GRACE_MS, reason)
  self:retain(true)
end

---@async
---@param reason string
function Invocation:abort(reason)
  self.connection:abort()
  self:dispose(reason)
  local run = async.current()
  if not run or run:is_cancelled() then
    self:retain(false)
  else
    local waited = pcall(self.lease.wait, self.lease)
    if not waited then
      self:retain(false)
    end
  end
end

---@async
---@return Neoagent.Error?
function Invocation:close()
  local closed, close_err = pcall(self.connection.close, self.connection)
  if not closed then
    local err = util.normalize_error(close_err, "protocol")
    if err.kind == "cancelled" then
      self:cancel("restricted Tool worker shutdown cancellation did not settle")
    else
      self:abort("restricted Tool worker failed to close")
    end
    return err
  end
  self:deadline(WORKER_EXIT_GRACE_MS, "restricted Tool worker did not exit after orderly shutdown")
  local waited, value = pcall(self.lease.wait, self.lease)
  if not waited then
    self:retain(false)
    return util.normalize_error(value, "sandbox_unavailable")
  end
  self:stop_timer()
  if value.error then
    return util.normalize_error(value.error, "sandbox_unavailable")
  end
  if value.code ~= 0 then
    return util.error("protocol", "Tool worker failed during shutdown", value.stderr ~= "" and value.stderr or nil)
  end
  -- The lease can deliver trailing bytes after close acknowledged the peer.
  -- Recheck the logical channel after all output and native cleanup settle.
  local finished, finish_err = pcall(self.connection.close, self.connection)
  if not finished then
    return util.normalize_error(finish_err, "protocol")
  end
end

---@param connection Neoagent.RpcConnection
---@param lease Neoagent.WorkerLease
---@return Neoagent.SandboxInvocation
function M.new(connection, lease)
  return setmetatable({ connection = connection, lease = lease, disposed = false }, Invocation)
end

return M
