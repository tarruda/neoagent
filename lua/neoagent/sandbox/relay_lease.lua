local async = require("neoagent.async")
local protocol = require("neoagent.sandbox.protocol")
local util = require("neoagent.util")

local M = {}

local MAX_STDERR = 16 * 1024
M.DEFAULT_ADMISSION_TIMEOUT_MS = 60 * 1000

---@class Neoagent.SandboxRelayLeaseOptions
---@field on_stdout? fun(data: string)
---@field on_stderr? fun(data: string)
---@field on_exit? fun(result: Neoagent.WorkerResult)
---@field cleanup? fun(): true?, string?
---@field admission_timeout_ms? integer

---@class Neoagent.SandboxRelayLease: Neoagent.WorkerLease
---@field _base? Neoagent.WorkerLease
---@field _decoder Neoagent.SandboxProtocolDecoder
---@field _opts Neoagent.SandboxRelayLeaseOptions
---@field _terminal? Neoagent.SandboxTerminalEvent
---@field _host_result? Neoagent.WorkerResult
---@field _result? Neoagent.WorkerResult
---@field _waiters Neoagent.AwaitCallbacks<Neoagent.WorkerResult>[]
---@field _ready boolean
---@field _ready_waiters Neoagent.AwaitCallbacks<true>[]
---@field _stderr string
---@field _failure? Neoagent.Error
---@field _disposed boolean
---@field _dispose_reason? string
---@field _admission_timeout_ms integer
local Relay = {}
Relay.__index = Relay

---@param self Neoagent.SandboxRelayLease
---@param err Neoagent.Error
local function reject_ready(self, err)
  local waiters = self._ready_waiters
  self._ready_waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter.reject(err)
  end
end

---@param self Neoagent.SandboxRelayLease
local function announce_ready(self)
  self._ready = true
  local waiters = self._ready_waiters
  self._ready_waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter.resolve(true)
  end
end

---@param self Neoagent.SandboxRelayLease
---@param value unknown
---@param kind? string
local function record_failure(self, value, kind)
  if not self._failure then
    self._failure = util.normalize_error(value, kind or "sandbox_unavailable")
    reject_ready(self, self._failure)
  end
  if self._base then
    self._base:terminate("native sandbox relay failed")
  end
end

---@async
---@return true
function Relay:wait_ready()
  if self._failure then
    error(self._failure, 0)
  end
  if self._ready then
    return true
  end
  local timer = assert(vim.uv.new_timer())
  local completed, value = pcall(async.await, function(done)
    self._ready_waiters[#self._ready_waiters + 1] = done
    timer:start(self._admission_timeout_ms, 0, function()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      if not self._ready then
        record_failure(self, util.error("sandbox_unavailable", "Native sandbox admission timed out"))
      end
    end)
    return function()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      for index, waiter in ipairs(self._ready_waiters) do
        if waiter == done then
          table.remove(self._ready_waiters, index)
          break
        end
      end
    end
  end)
  if not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  if not completed then
    error(value, 0)
  end
  return value
end

---@param self Neoagent.SandboxRelayLease
local function finish(self)
  assert(self._host_result and not self._result, "native sandbox relay completion state is invalid")
  local terminal, finish_err = self._decoder:finish()
  if not terminal and not self._failure then
    record_failure(self, util.error("sandbox_unavailable", "Invalid native sandbox protocol", finish_err))
  end
  terminal = terminal or self._terminal
  if terminal and terminal.type == "error" and not self._failure then
    record_failure(self, util.error(
      "sandbox_unavailable",
      "Native sandbox setup failed at " .. terminal.stage,
      "errno=" .. tostring(terminal.errno)
    ))
  end
  if self._host_result.code ~= 0 and not self._failure then
    record_failure(self, util.error(
      "sandbox_unavailable",
      "Native sandbox runtime exited with status " .. tostring(self._host_result.code),
      self._host_result.stderr
    ))
  end
  if self._opts.cleanup then
    local called, cleaned, cleanup_err = pcall(self._opts.cleanup)
    if not called and not self._failure then
      record_failure(self, util.error("sandbox_unavailable", "Could not clean native sandbox resources", cleaned))
    elseif not cleaned and not self._failure then
      record_failure(self, util.error("sandbox_unavailable", "Could not clean native sandbox resources", cleanup_err))
    end
  end
  local exit = terminal and terminal.type == "exit" and terminal or nil
  self._result = {
    code = self._failure and 125 or (exit and exit.code or self._host_result.code),
    signal = exit and exit.signal or self._host_result.signal,
    stderr = self._stderr ~= "" and self._stderr or self._host_result.stderr,
    error = self._failure,
  }
  local waiters = self._waiters
  self._waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter.resolve(util.copy(self._result))
  end
  if self._opts.on_exit then
    pcall(self._opts.on_exit, util.copy(self._result))
  end
end

---@param lease Neoagent.WorkerLease
function Relay:attach(lease)
  assert(not self._base, "native sandbox relay lease is already attached")
  self._base = lease
  if self._disposed then
    lease:dispose(assert(self._dispose_reason))
  elseif self._failure and not self._host_result then
    lease:terminate("native sandbox relay failed before attachment")
  end
end

---@param data string
function Relay:feed(data)
  if self._result or self._disposed then
    return
  end
  local ok, err = pcall(self._decoder.feed, self._decoder, data)
  if not ok then
    record_failure(self, util.error("sandbox_unavailable", "Invalid native sandbox protocol", err))
  end
end

---@param result Neoagent.WorkerResult
function Relay:host_exited(result)
  if self._host_result then
    return
  end
  self._host_result = util.copy(result)
  finish(self)
end

---@param bytes string
---@return true?, Neoagent.Error?
function Relay:write(bytes)
  if not self._base or self._result or self._disposed then
    return nil, util.error("protocol", "Native sandbox worker stdin is closed")
  end
  local written, err = self._base:write(bytes)
  return written, err
end

---@return true?, Neoagent.Error?
function Relay:close_stdin()
  if not self._base then
    return nil, util.error("protocol", "Native sandbox worker is not attached")
  end
  local closed, err = self._base:close_stdin()
  return closed, err
end

---@param reason string
function Relay:terminate(reason)
  if self._base then
    self._base:terminate(reason)
  end
end

---@async
---@return Neoagent.WorkerResult
function Relay:wait()
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
function Relay:dispose(reason)
  assert(type(reason) == "string" and reason ~= "", "native sandbox worker disposal reason is required")
  if self._disposed then
    return
  end
  self._disposed = true
  self._dispose_reason = reason
  if self._base then
    self._base:dispose(reason)
  end
end

---@param opts? Neoagent.SandboxRelayLeaseOptions
---@return Neoagent.SandboxRelayLease
function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "native sandbox relay options must be a table")
  local admission_timeout_ms = opts.admission_timeout_ms or M.DEFAULT_ADMISSION_TIMEOUT_MS
  assert(
    type(admission_timeout_ms) == "number"
      and admission_timeout_ms % 1 == 0
      and admission_timeout_ms > 0,
    "native sandbox admission timeout must be a positive integer"
  )
  ---@type Neoagent.SandboxRelayLease
  local relay = setmetatable({
    _opts = opts,
    _waiters = {},
    _ready = false,
    _ready_waiters = {},
    _stderr = "",
    _disposed = false,
    _admission_timeout_ms = admission_timeout_ms,
  }, Relay)
  relay._decoder = protocol.new({
    on_event = function(event)
      if event.type == "ready" then
        announce_ready(relay)
      elseif event.type == "output" then
        ---@cast event Neoagent.SandboxOutputEvent
        local callback = event.stream == "stdout" and opts.on_stdout or opts.on_stderr
        if event.stream == "stderr" and #relay._stderr < MAX_STDERR then
          relay._stderr = (relay._stderr .. event.data):sub(1, MAX_STDERR)
        end
        if callback then
          local ok, err = pcall(callback, event.data)
          if not ok then
            record_failure(relay, util.error("protocol", "Native sandbox output callback failed", err), "protocol")
          end
        end
      elseif event.type == "exit" or event.type == "error" then
        relay._terminal = util.copy(event --[[@as Neoagent.SandboxTerminalEvent]])
      end
    end,
  })
  return relay
end

return M
