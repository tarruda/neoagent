local async = require("neoagent.async")
local util = require("neoagent.util")
local validate = require("neoagent.subprocess.validate")
local environment = require("neoagent.subprocess.environment")
local pipe = require("neoagent.subprocess.pipe")
local pty = require("neoagent.subprocess.pty")
local cleanup = require("neoagent.subprocess.cleanup")

local M = {}

---@class Neoagent.SubprocessOutcome
---@field code integer
---@field signal integer
---@field timed_out boolean
---@field started_at_ns integer
---@field finished_at_ns integer
---@field duration_ms number
---@field termination_reason? string

---@class Neoagent.SubprocessState
---@field phase "running"|"terminating"|"exited"|"failed"|"disposed"
---@field stdin_writable boolean
---@field resize_supported boolean
---@field terminal? Neoagent.SubprocessOutcome
---@field failure? Neoagent.Error

---@class Neoagent.SubprocessHandle
---@field state fun(self: Neoagent.SubprocessHandle): Neoagent.SubprocessState
---@field write fun(self: Neoagent.SubprocessHandle, bytes: string): true
---@field close_stdin fun(self: Neoagent.SubprocessHandle): true
---@field flush async fun(self: Neoagent.SubprocessHandle): true
---@field resize fun(self: Neoagent.SubprocessHandle, columns: integer, rows: integer): true
---@field terminate fun(self: Neoagent.SubprocessHandle, reason: string): true
---@field wait async fun(self: Neoagent.SubprocessHandle): Neoagent.SubprocessOutcome
---@field wait_cleanup async fun(self: Neoagent.SubprocessHandle): true
---@field dispose fun(self: Neoagent.SubprocessHandle, reason: string)

---@class Neoagent.OwnedSubprocess
---@field spec Neoagent.ValidatedSubprocessSpec
---@field env table<string, string>
---@field observer Neoagent.SubprocessObserver
---@field capture? Neoagent.SubprocessCapture
---@field handle Neoagent.SubprocessHandle
---@field driver? Neoagent.SubprocessDriver
---@field timer? uv.uv_timer_t
---@field kill_timer? uv.uv_timer_t
---@field cleanup? Neoagent.ProcessCleanupDeadline
---@field ready boolean
---@field early Neoagent.SubprocessOutputEvent[]
---@field early_bytes integer
---@field started_at integer
---@field draining boolean
---@field stdin_close_requested? boolean
---@field code? integer
---@field signal? integer
---@field terminating? boolean
---@field termination_reason? string
---@field timed_out boolean
---@field failure? Neoagent.Error
---@field disposal? Neoagent.Error
---@field cleanup_error? Neoagent.Error
---@field outcome? Neoagent.SubprocessOutcome
---@field settled boolean
---@field driver_closed? boolean
---@field waiters table<Neoagent.AwaitCallbacks<Neoagent.SubprocessOutcome>, boolean>
---@field cleanup_waiters table<Neoagent.AwaitCallbacks<true>, boolean>
---@field on_cleanup fun(owner: Neoagent.OwnedSubprocess, err?: Neoagent.Error)
local Owned = {}
Owned.__index = Owned

---@type table<Neoagent.OwnedSubprocess, boolean>
local disposing = {}

---@param timer? uv.uv_timer_t
local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

-- Cancelling an input waiter belongs to that observer. Process failure and
-- disposal still take precedence over write errors caused by closing stdin.
---@param self Neoagent.OwnedSubprocess
---@param ok boolean
---@param value unknown
---@return boolean, unknown
local function input_result(self, ok, value)
  if not ok and type(value) == "table" and value.kind == "cancelled" then
    return false, value
  end
  local failure = self.failure or self.disposal or self.cleanup_error
  if failure then
    return false, util.copy(failure)
  end
  return ok, value
end

---@param self Neoagent.OwnedSubprocess
local function notify(self)
  local failure = self.failure or self.disposal or self.cleanup_error
  if failure or self.outcome then
    local waiters = self.waiters
    self.waiters = {}
    for waiter in pairs(waiters) do
      if failure then
        waiter.reject(util.copy(failure))
      else
        waiter.resolve(util.copy(assert(self.outcome)))
      end
    end
  end
end

---@param force boolean
function Owned:signal_tree(force)
  if self.driver then
    pcall(force and self.driver.kill or self.driver.stop)
  end
end

---@param err? Neoagent.Error
function Owned:finish(err)
  if self.settled then
    return
  end
  self.settled = true
  close_timer(self.timer)
  close_timer(self.kill_timer)
  if self.cleanup then
    self.cleanup.close()
  end
  local driver_closed = pcall(function()
    if self.driver then
      self.driver.dispose()
    end
  end)
  if not driver_closed then
    err = err or validate.error("process_cleanup", "Could not close process resources")
  end
  if err then
    self.cleanup_error = util.with_cause(err, self.failure or self.disposal)
  end
  assert(
    self.code ~= nil or self.failure or self.disposal or self.cleanup_error,
    "process completion requires native status or failure"
  )
  -- Exit observation survives failed cleanup, operation failure, and disposal.
  -- Waiters still fail; state retains the independently observed native result.
  if self.code ~= nil then
    local finished = math.floor(vim.uv.hrtime())
    self.outcome = {
      code = self.signal ~= 0 and 128 + assert(self.signal) or assert(self.code),
      signal = assert(self.signal),
      timed_out = self.timed_out,
      started_at_ns = self.started_at,
      finished_at_ns = finished,
      duration_ms = (finished - self.started_at) / 1000000,
      termination_reason = self.termination_reason,
    }
  end
  self.early = {}
  self.observer = {}
  self.capture = nil
  disposing[self] = nil
  notify(self)
  local waiters = self.cleanup_waiters
  self.cleanup_waiters = {}
  for waiter in pairs(waiters) do
    if self.cleanup_error then
      waiter.reject(util.copy(self.cleanup_error))
    else
      waiter.resolve(true)
    end
  end
  self.on_cleanup(self, self.cleanup_error)
end

function Owned:reap()
  if self.settled then
    return
  end
  assert(self.cleanup).start(
    self.driver and self.driver.cleanup_ms or validate.REAP_MS,
    self.driver and self.driver.delivery_delay_ns
  )
end

function Owned:begin_drain()
  if self.settled or self.draining then
    return
  end
  -- Native exit begins cleanup independently of final I/O completion.
  self.draining = true
  close_timer(self.timer)
  -- Native liveness can establish exit before its status is delivered. Both
  -- observations share one cleanup deadline and retain any later status.
  self:signal_tree(true)
  self:reap()
end

function Owned:force()
  if self.settled then
    return
  end
  disposing[self] = true
  close_timer(self.timer)
  close_timer(self.kill_timer)
  self:signal_tree(true)
  self:reap()
end

---@param err Neoagent.Error
function Owned:fail(err)
  if self.settled or self.failure or self.disposal then
    return
  end
  self.failure = err
  self:force()
  notify(self)
end

---@param reason string
function Owned:dispose(reason)
  if self.settled or self.disposal then
    return
  end
  self.disposal = validate.error("process_disposed", "Process owner disposed the handle")
  self.termination_reason = self.termination_reason or reason
  self:force()
  notify(self)
end

---@param reason string
function Owned:terminate(reason)
  if self.settled or self.terminating or self.disposal or self.failure then
    return
  end
  self.terminating = true
  self.termination_reason = reason
  close_timer(self.timer)
  -- Arm escalation before requesting graceful termination, even if a native
  -- callback re-enters the handle while the signal is being delivered.
  vim.uv.update_time()
  assert(self.kill_timer):start(self.spec.kill_grace_ms, 0, function()
    self:force()
  end)
  self:signal_tree(false)
end

---@async
---@param input Neoagent.SubprocessInput
function Owned:send(input)
  local handle = self.handle
  local ok, err = pcall(function()
    local queued_bytes, queued_writes = 0, 0
    for _, chunk in ipairs(input.chunks) do
      for offset = 1, #chunk, validate.WRITE_BYTES do
        local bytes = chunk:sub(offset, offset + validate.WRITE_BYTES - 1)
        if queued_bytes + #bytes > validate.PENDING_BYTES or queued_writes == validate.PENDING_WRITES then
          handle:flush()
          queued_bytes, queued_writes = 0, 0
        end
        handle:write(bytes)
        queued_bytes = queued_bytes + #bytes
        queued_writes = queued_writes + 1
      end
    end
    if input.close then
      handle:close_stdin()
    end
    handle:flush()
  end)
  local accepted, failure = input_result(self, ok, err)
  if not accepted then
    -- Only the handle arbitrates input against its terminal state. A caller
    -- such as ImageMagick may deliberately consume a prefix; it still must
    -- inspect the eventual exit and output before accepting the operation.
    local closed = type(failure) == "table" and (failure.code == "stdin_closed" or failure.code == "process_terminal")
    if not (closed and (self.terminating or self.termination_reason or input.allow_early_close)) then
      error(failure, 0)
    end
  end
end

---@param stream "stdout"|"stderr"|"pty"
---@param bytes string
function Owned:output(stream, bytes)
  if self.settled or self.failure or self.disposal then
    return
  end
  for offset = 1, #bytes, validate.OUTPUT_BYTES do
    local event = { stream = stream, data = bytes:sub(offset, offset + validate.OUTPUT_BYTES - 1) }
    if not self.ready then
      self.early_bytes = self.early_bytes + #event.data
      if self.early_bytes > validate.PENDING_BYTES then
        self:fail(validate.error("process_stream", "Process startup output exceeded its buffer"))
        return
      end
      self.early[#self.early + 1] = event
    else
      local failure = self.capture and self.capture.append(event)
      if failure then
        self:fail(failure)
        return
      end
      if self.observer.on_output then
        local consumer = coroutine.create(self.observer.on_output)
        local ok = coroutine.resume(consumer, event)
        if not ok or coroutine.status(consumer) ~= "dead" then
          self:fail(validate.error("process_observer", "Process output observer failed or yielded"))
          return
        end
      end
      if self.failure or self.disposal then
        return
      end
    end
  end
end

function Owned:start()
  local started, driver = pcall(function()
    -- Reserve every lifecycle timer before native startup. Termination and
    -- cleanup must remain available after publication even under exhaustion.
    self.cleanup = cleanup.new(function()
      self:signal_tree(true)
    end, function()
      self:finish(validate.error("process_cleanup", "Process cleanup did not settle before its deadline"))
    end)
    if self.spec.timeout_ms then
      self.timer = assert(vim.uv.new_timer())
    end
    ---@type Neoagent.SubprocessCallbacks
    local callbacks = {
      output = function(stream, bytes)
        self:output(stream, bytes)
      end,
      exited = function(code, signal)
        if self.settled or self.code ~= nil then
          return
        end
        self.code, self.signal = code, signal
        self:begin_drain()
      end,
      closed = function()
        self.driver_closed = true
        if self.ready then
          self:finish()
        end
      end,
      failed = function(code, message)
        self:fail(validate.error(code, message))
      end,
    }
    local driver = (self.spec.stdio.kind == "pty" and pty or pipe).new(self.spec, self.env, callbacks)
    self.kill_timer = assert(vim.uv.new_timer())
    return driver
  end)
  if not started then
    self.failure = type(driver) == "table" and driver.kind and driver
      or validate.error("process_start", "Failed to start process")
    self:finish()
    error(self.failure, 0)
  end
  self.driver = driver
  local launched, failure = pcall(driver.start)
  if not launched then
    self:fail(
      type(failure) == "table" and failure.kind and failure
        or validate.error("process_start", "Failed to start process")
    )
    self.ready = true
    if self.driver_closed then
      self:finish()
    end
    error(self.failure or self.disposal or self.cleanup_error, 0)
  end
  self.started_at = math.floor(vim.uv.hrtime())
  if self.failure or self.disposal or self.draining then
    self:signal_tree(true)
  elseif self.spec.timeout_ms then
    local function observed(running)
      if not self.settled and not self.terminating and not self.failure and not self.disposal and not self.draining then
        if running then
          self.timed_out = true
          self:terminate("timeout")
        else
          self:begin_drain()
        end
      end
    end
    vim.uv.update_time()
    assert(self.timer):start(self.spec.timeout_ms, 0, function()
      if self.settled or self.terminating or self.failure or self.disposal or self.draining then
        return
      end
      local checked = pcall(driver.observe, observed)
      if not checked then
        self:fail(validate.error("process_supervision", "Could not observe process state"))
      end
    end)
  end
  if self.failure or self.disposal or self.cleanup_error then
    self.ready = true
    if self.driver_closed then
      self:finish()
    end
    error(self.failure or self.disposal or self.cleanup_error, 0)
  end
  local function publish()
    self.ready = true
    local early = self.early
    self.early, self.early_bytes = {}, 0
    for _, event in ipairs(early) do
      self:output(event.stream, event.data)
    end
    if self.driver_closed then
      self:finish()
    end
  end
  if #self.early > 0 then
    -- Startup can service the event loop while awaiting native exec. Keep
    -- buffering until the caller has received its handle, including output
    -- callbacks already queued ahead of this publication.
    vim.schedule(publish)
  else
    publish()
  end
  return self.handle
end

---@param self Neoagent.OwnedSubprocess
---@return Neoagent.SubprocessDriver
local function control(self)
  if self.settled or self.failure or self.disposal or self.terminating or self.draining then
    error(validate.error("process_terminal", "Process no longer accepts controls"), 0)
  end
  return assert(self.driver)
end

---@param spec Neoagent.ValidatedSubprocessSpec
---@param observer Neoagent.SubprocessObserver
---@param on_cleanup fun(owner: Neoagent.OwnedSubprocess, err?: Neoagent.Error)
---@param capture? Neoagent.SubprocessCapture
---@return Neoagent.OwnedSubprocess
function M.new(spec, observer, on_cleanup, capture)
  ---@type Neoagent.OwnedSubprocess
  local self = setmetatable({
    spec = spec,
    env = environment.normalize(spec.environment),
    observer = observer,
    on_cleanup = on_cleanup,
    capture = capture,
    handle = {},
    ready = false,
    early = {},
    early_bytes = 0,
    started_at = 0,
    draining = false,
    timed_out = false,
    settled = false,
    waiters = {},
    cleanup_waiters = {},
  }, Owned)
  -- Only these closures cross the API boundary; native objects stay private.
  self.handle = {
    state = function()
      local available = not (self.settled or self.failure or self.disposal or self.terminating or self.draining)
      return {
        phase = (self.failure or self.cleanup_error) and "failed"
          or self.disposal and "disposed"
          or self.outcome and "exited"
          or self.terminating and "terminating"
          or "running",
        stdin_writable = available and self.driver ~= nil and self.driver.writable(),
        resize_supported = available and spec.stdio.kind == "pty",
        terminal = util.copy(self.outcome),
        failure = util.copy(self.failure or self.cleanup_error or self.disposal),
      }
    end,
    write = function(_, bytes)
      if type(bytes) ~= "string" or #bytes > validate.WRITE_BYTES then
        error(validate.error("process_validation", "Process writes require at most 65536 bytes"), 0)
      end
      local driver = control(self)
      if not driver.writable() then
        error(validate.error("stdin_closed", "Process stdin is closed"), 0)
      end
      return bytes == "" or driver.write(bytes)
    end,
    close_stdin = function()
      if self.stdin_close_requested then
        return true
      end
      control(self).close_stdin()
      self.stdin_close_requested = true
      return true
    end,
    ---@async
    flush = function()
      if self.failure or self.disposal then
        error(util.copy(self.failure or self.disposal), 0)
      end
      local ok, result = input_result(self, pcall(assert(self.driver).flush))
      if not ok then
        error(result, 0)
      end
      return true
    end,
    resize = function(_, columns, rows)
      validate.dimensions(columns, rows)
      return control(self).resize(columns, rows)
    end,
    terminate = function(_, reason)
      self:terminate(validate.reason(reason))
      return true
    end,
    ---@async
    wait = function()
      return async.await(function(done)
        self.waiters[done] = true
        notify(self)
        return function()
          self.waiters[done] = nil
        end
      end)
    end,
    ---@async
    wait_cleanup = function()
      return async.await(function(done)
        if self.settled then
          if self.cleanup_error then
            done.reject(util.copy(self.cleanup_error))
          else
            done.resolve(true)
          end
        else
          self.cleanup_waiters[done] = true
        end
        return function()
          self.cleanup_waiters[done] = nil
        end
      end)
    end,
    dispose = function(_, reason)
      self:dispose(validate.reason(reason))
    end,
  }
  return self
end

return M
