local async = require("neoagent.async")
local protocol = require("neoagent.rpc.protocol")
local util = require("neoagent.util")

local M = {}

local CANCEL_GRACE_MS = 500
local START_GRACE_MS = 60000
local SHUTDOWN_GRACE_MS = 10000
local next_call_id = 0

---@class Neoagent.RpcRequest
---@field id integer
---@field method string
---@field sequence integer
---@field on_event? async fun(message: table)
---@field terminal_received boolean

---@class Neoagent.RpcConnection
---@field _lease? Neoagent.WorkerLease
---@field _decoder Neoagent.FrameDecoder
---@field _queue table[]
---@field _queued_bytes integer
---@field _waiter? Neoagent.AwaitCallbacks<table>
---@field _state "new"|"waiting_ready"|"opening"|"open"|"request"|"cancelling"|"closing"|"closed"|"failed"
---@field _call_id string
---@field _wire_context? Neoagent.JsonObject
---@field _request_id integer
---@field _event_sequence integer
---@field _active? Neoagent.RpcRequest
---@field _failure? Neoagent.Error
---@field _exit? Neoagent.WorkerResult
---@field _ready_received? boolean
---@field _opened_received? boolean
---@field _close_received? boolean
---@field _cancel_timer? uv.uv_timer_t
---@field _start_grace_ms integer
---@field _shutdown_grace_ms integer
---@field _on_failure? fun(error: Neoagent.Error)
---@field _on_event? fun(message: table)
---@field _failure_reported? boolean
---@field _cancel_waiters Neoagent.AwaitCallbacks<true>[]
local RpcConnection = {}
RpcConnection.__index = RpcConnection

---@param self Neoagent.RpcConnection
local function close_cancel_timer(self)
  local timer = self._cancel_timer
  self._cancel_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@param value unknown
---@return Neoagent.Error
local function protocol_error(value)
  return util.error(
    "protocol",
    util.safe_message(value, {
      fallback = "RPC protocol failed",
      max_characters = protocol.MAX_ERROR_BYTES,
      max_source_bytes = protocol.MAX_ERROR_BYTES,
    })
  )
end

---@param self Neoagent.RpcConnection
---@param err Neoagent.Error
local function fail(self, err)
  if self._state == "failed" then
    return
  end
  self._state = "failed"
  self._failure = util.normalize_error(err, "protocol")
  close_cancel_timer(self)
  local waiter = self._waiter
  self._waiter = nil
  if waiter then
    waiter.reject(self._failure)
  end
  local cancel_waiters = self._cancel_waiters
  self._cancel_waiters = {}
  for _, waiting in ipairs(cancel_waiters) do
    waiting.reject(self._failure)
  end
  if self._on_failure and not self._failure_reported then
    self._failure_reported = true
    pcall(self._on_failure, self._failure)
  end
end

---@param self Neoagent.RpcConnection
---@return never
local function raise_failure(self)
  error(self._failure or util.error("protocol", "RPC protocol failed"), 0)
end

---@param message table
---@return integer payload_bytes, integer queued_bytes
local function message_sizes(message)
  local ok, encoded = pcall(vim.mpack.encode, message)
  if not ok or type(encoded) ~= "string" then
    return protocol.MAX_FRAME + 1, protocol.MAX_FRAME + 5
  end
  return #encoded, #encoded + 4
end

---@param self Neoagent.RpcConnection
---@param message table
local function send_detached(self, message)
  local lease = assert(self._lease, "RPC channel is not attached")
  local encoded, bytes = pcall(protocol.encode, message)
  if not encoded then
    fail(self, protocol_error(bytes))
    return
  end
  local completed, written, write_err = pcall(lease.write, lease, bytes)
  if not completed or not written then
    fail(self, completed and (write_err or protocol_error("Could not write to RPC peer"))
      or protocol_error(written))
  end
end

---@param self Neoagent.RpcConnection
local function settle_cancel(self)
  self._queue = {}
  self._queued_bytes = 0
  self._active = nil
  self._state = "open"
  close_cancel_timer(self)
  local waiters = self._cancel_waiters
  self._cancel_waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter.resolve(true)
  end
end

---@param self Neoagent.RpcConnection
---@param request_id? integer
local function begin_cancel(self, request_id)
  if self._state == "closed" or self._state == "failed" or self._state == "cancelling" then
    return
  end
  local active = self._active
  if request_id and (not active or active.id ~= request_id) then
    return
  end
  if not active then
    if self._state == "open" then
      return
    end
    fail(self, util.error("cancelled", "RPC request cancelled"))
    return
  end
  if active.terminal_received then
    settle_cancel(self)
    return
  end
  self._state = "cancelling"
  self._cancel_timer = assert(vim.uv.new_timer())
  self._cancel_timer:start(CANCEL_GRACE_MS, 0, function()
    close_cancel_timer(self)
    if self._state == "cancelling" then
      fail(self, util.error("cancelled", "RPC request cancellation timed out"))
    end
  end)
  send_detached(self, {
    type = "cancel",
    call_id = self._call_id,
    request_id = active.id,
  })
end

---@param self Neoagent.RpcConnection
---@param message table
---@return boolean
local function accept_detached_cancel(self, message)
  if self._state ~= "cancelling" then
    return false
  end
  local active = self._active
  if not active or message.call_id ~= self._call_id or message.request_id ~= active.id then
    fail(self, protocol_error("RPC peer sent a stale cancellation event"))
    return true
  end
  if message.type == "event" then
    return true
  end
  if message.type ~= "cancelled" and message.type ~= "response" and message.type ~= "request_error" then
    fail(self, protocol_error("RPC peer sent an invalid cancellation event"))
    return true
  end
  settle_cancel(self)
  return true
end

---@param self Neoagent.RpcConnection
---@param message table
---@return boolean
local function accept_connection_event(self, message)
  if message.type ~= "event" or message.request_id ~= nil then
    return false
  end
  if message.call_id ~= self._call_id
      or self._state ~= "open" and self._state ~= "request" and self._state ~= "cancelling" then
    fail(self, protocol_error("RPC peer sent a connection event in an invalid state"))
    return true
  end
  if message.sequence ~= self._event_sequence + 1 then
    fail(self, protocol_error("RPC connection event sequence is invalid"))
    return true
  end
  self._event_sequence = message.sequence
  if not self._on_event then
    fail(self, protocol_error("RPC connection received an unhandled event"))
    return true
  end
  local accepted, accept_err = pcall(self._on_event, message)
  if not accepted then
    fail(self, protocol_error("RPC connection event handler failed: " .. util.safe_message(accept_err)))
  end
  return true
end

---@param self Neoagent.RpcConnection
---@param message table
local function enqueue(self, message)
  if self._state == "closed" or self._state == "failed" then
    return
  end
  if accept_connection_event(self, message) then
    return
  end
  if accept_detached_cancel(self, message) then
    return
  end
  local state = self._state
  local active = self._active
  local accepted = false
  if state == "new" or state == "waiting_ready" then
    accepted = message.type == "ready" and not self._ready_received
    if accepted then
      self._ready_received = true
    end
  elseif state == "opening" then
    accepted = message.type == "opened" and not self._opened_received
    if accepted then
      self._opened_received = true
    end
  elseif state == "request" then
    accepted = active ~= nil
      and not active.terminal_received
      and (message.type == "event"
        or message.type == "response"
        or message.type == "request_error"
        or message.type == "cancelled")
  elseif state == "closing" then
    accepted = message.type == "closed" and not self._close_received
    if accepted then
      self._close_received = true
    end
  end
  if not accepted then
    fail(self, protocol_error("RPC peer sent a message in an invalid state"))
    return
  end
  local payload_bytes, queued_bytes = message_sizes(message)
  if payload_bytes > protocol.MAX_FRAME
      or self._queued_bytes + queued_bytes > protocol.MAX_QUEUED_BYTES then
    fail(self, protocol_error("RPC peer output exceeded the protocol queue limit"))
    return
  end
  if active
      and message.call_id == self._call_id
      and message.request_id == active.id
      and (message.type == "response" or message.type == "request_error" or message.type == "cancelled") then
    active.terminal_received = true
  end
  local waiter = self._waiter
  if waiter then
    self._waiter = nil
    waiter.resolve(message)
    return
  end
  self._queue[#self._queue + 1] = message
  self._queued_bytes = self._queued_bytes + queued_bytes
end

---@param self Neoagent.RpcConnection
---@return table
---@async
local function next_message(self)
  if #self._queue > 0 then
    local message = table.remove(self._queue, 1)
    local _, queued_bytes = message_sizes(message)
    self._queued_bytes = math.max(0, self._queued_bytes - queued_bytes)
    return message
  end
  if self._failure then
    raise_failure(self)
  end
  return async.await(function(done)
    assert(not self._waiter, "RPC connection has multiple message waiters")
    self._waiter = done
    return function()
      if self._waiter == done then
        self._waiter = nil
      end
      begin_cancel(self)
    end
  end)
end

---@param timer uv.uv_timer_t
local function close_timer(timer)
  if not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@param self Neoagent.RpcConnection
---@param milliseconds integer
---@param kind string
---@param message string
---@return table
---@async
local function next_message_bounded(self, milliseconds, kind, message)
  local timer = assert(vim.uv.new_timer())
  timer:start(milliseconds, 0, function()
    close_timer(timer)
    fail(self, util.error(kind, message))
  end)
  local completed, value = pcall(next_message, self)
  close_timer(timer)
  if not completed then
    error(value, 0)
  end
  return value
end

---@param self Neoagent.RpcConnection
---@param message table
---@async
local function send(self, message)
  local lease = assert(self._lease, "RPC channel is not attached")
  local encoded, bytes = pcall(protocol.encode, message)
  if not encoded then
    fail(self, protocol_error(bytes))
    raise_failure(self)
  end
  local written, write_err = lease:write(bytes)
  if not written then
    fail(self, write_err or protocol_error("Could not write to RPC peer"))
    raise_failure(self)
  end
end

---@param self Neoagent.RpcConnection
---@param active Neoagent.RpcRequest
---@param method string
---@param payload Neoagent.JsonObject
---@async
local function send_request(self, active, method, payload)
  local message = {
    type = "request",
    call_id = self._call_id,
    request_id = active.id,
    method = method,
    payload = payload,
  }
  if message_sizes(message) <= protocol.MAX_FRAME then
    send(self, message)
    return
  end
  local encoded, bytes = pcall(vim.mpack.encode, payload)
  if not encoded or type(bytes) ~= "string" or bytes == "" then
    fail(self, protocol_error("RPC request could not be encoded"))
    raise_failure(self)
  end
  if #bytes > protocol.MAX_REQUEST then
    fail(self, protocol_error("RPC request exceeded the aggregate protocol limit"))
    raise_failure(self)
  end
  send(self, {
    type = "request_begin",
    call_id = self._call_id,
    request_id = active.id,
    method = method,
    bytes = #bytes,
  })
  for offset = 1, #bytes, protocol.MAX_REQUEST_CHUNK do
    send(self, {
      type = "request_chunk",
      call_id = self._call_id,
      request_id = active.id,
      data = bytes:sub(offset, offset + protocol.MAX_REQUEST_CHUNK - 1),
    })
  end
  send(self, {
    type = "request_end",
    call_id = self._call_id,
    request_id = active.id,
  })
end

---@param self Neoagent.RpcConnection
---@param active Neoagent.RpcRequest
---@param payload Neoagent.JsonObject
---@return unknown
---@async
local function request(self, active, payload)
  self._active = active
  self._state = "request"
  send_request(self, active, active.method, payload)
  local owner = async.current()
  local remove_cancel = owner and owner:on_cancel(function()
    begin_cancel(self, active.id)
  end) or nil
  ---@async
  ---@return unknown
  local function await_result()
    while true do
      local message = next_message(self)
      if self._failure then
        raise_failure(self)
      end
      if message.call_id ~= self._call_id or message.request_id ~= active.id then
        fail(self, protocol_error("RPC peer sent a message for another request"))
        raise_failure(self)
      end
      if message.type == "event" then
        if message.sequence ~= active.sequence + 1 then
          fail(self, protocol_error("RPC request event sequence is invalid"))
          raise_failure(self)
        end
        active.sequence = message.sequence
        if not active.on_event then
          fail(self, protocol_error("RPC request received an unhandled event"))
          raise_failure(self)
        end
        local accepted, accept_err = pcall(active.on_event, message)
        if not accepted then
          local err = util.normalize_error(accept_err, "protocol")
          if err.kind == "cancelled" then
            error(err, 0)
          end
          fail(self, err.kind == "protocol"
            and protocol_error("RPC event handler failed: " .. err.message)
            or err)
          raise_failure(self)
        end
      elseif message.type == "response" then
        self._active = nil
        self._state = "open"
        return message.value
      elseif message.type == "request_error" then
        self._active = nil
        self._state = "open"
        local wire = protocol.error(message.error)
        local err = util.error(wire.kind, wire.message, wire.detail)
        if wire.code then
          rawset(err, "code", wire.code)
        end
        error(err, 0)
      elseif message.type == "cancelled" then
        self._active = nil
        self._state = "open"
        error(util.error("cancelled", "RPC peer cancelled the request"), 0)
      end
    end
  end
  local completed, value = pcall(await_result)
  if remove_cancel then
    remove_cancel()
  end
  if not completed then
    error(value, 0)
  end
  return value
end

---@param lease Neoagent.WorkerLease
function RpcConnection:attach(lease)
  assert(self._lease == nil and type(lease) == "table", "RPC channel is already attached")
  assert(type(lease.write) == "function", "RPC channel must provide write")
  assert(type(lease.close_stdin) == "function", "RPC channel must provide close_stdin")
  self._lease = lease
end

---@param chunk string
function RpcConnection:feed(chunk)
  if self._state == "closed" or self._state == "failed" then
    return
  end
  local ok, err = pcall(self._decoder.feed, self._decoder, chunk)
  if not ok then
    fail(self, protocol_error(err))
  end
end

---@param result Neoagent.WorkerResult
function RpcConnection:eof(result)
  if self._exit then
    return
  end
  self._exit = util.copy(result)
  close_cancel_timer(self)
  if self._state == "closed" or self._state == "failed" then
    return
  end
  local state = self._state
  local starting = state == "new" or state == "waiting_ready" or state == "opening"
  local terminal_received = state == "request" and self._active and self._active.terminal_received == true
  if terminal_received then
    return
  end
  if state == "closing" and self._close_received and not result.error and result.code == 0 then
    return
  end
  local function reject(err)
    fail(self, err)
  end
  if result.error then
    local cause = util.normalize_error(result.error, "protocol")
    if state == "cancelling" then
      reject(util.error("cancelled", "RPC request cancelled"))
    elseif starting then
      reject(cause)
    else
      reject(util.error("protocol", cause.message, cause.detail))
    end
    return
  end
  local kind = starting and "worker_start"
    or state == "cancelling" and "cancelled"
    or "protocol"
  local message = result.code == 0 and "RPC peer exited before completing the protocol"
    or "RPC peer exited with status " .. tostring(result.code)
  local detail = result.stderr ~= "" and util.safe_message(result.stderr, {
    max_characters = protocol.MAX_ERROR_BYTES,
    max_source_bytes = protocol.MAX_ERROR_BYTES,
  }) or nil
  reject(util.error(kind, message, detail))
end

---@param context Neoagent.JsonObject
---@async
function RpcConnection:open(context)
  if self._state ~= "new" or not self._lease then
    if self._failure then
      raise_failure(self)
    end
    error("RPC connection cannot be opened in its current state", 0)
  end
  assert(type(context) == "table", "RPC connection context must be an object")
  self._wire_context = util.copy(context)
  self._state = "waiting_ready"
  local ready = next_message_bounded(
    self,
    self._start_grace_ms,
    "worker_start",
    "RPC peer did not announce readiness"
  )
  if self._failure then
    raise_failure(self)
  end
  if ready.type ~= "ready" or ready.marker ~= protocol.MARKER then
    fail(self, protocol_error("RPC peer source or protocol marker does not match"))
    raise_failure(self)
  end
  self._state = "opening"
  send(self, {
    type = "open",
    call_id = self._call_id,
    context = self._wire_context,
  })
  local opened = next_message_bounded(
    self,
    self._start_grace_ms,
    "worker_start",
    "RPC peer did not acknowledge the connection"
  )
  if self._failure then
    raise_failure(self)
  end
  if opened.type ~= "opened" or opened.call_id ~= self._call_id then
    fail(self, protocol_error("RPC peer did not acknowledge the connection"))
    raise_failure(self)
  end
  self._state = "open"
end

---@return true
---@async
function RpcConnection:close()
  if self._state == "closed" then
    return true
  end
  if self._state ~= "open" then
    if self._failure then
      raise_failure(self)
    end
    error("RPC connection cannot close with an active request", 0)
  end
  self._state = "closing"
  send(self, { type = "close", call_id = self._call_id })
  local closed = next_message_bounded(
    self,
    self._shutdown_grace_ms,
    "protocol",
    "RPC peer did not acknowledge shutdown"
  )
  if self._failure then
    raise_failure(self)
  end
  if closed.type ~= "closed" or closed.call_id ~= self._call_id then
    fail(self, protocol_error("RPC peer did not acknowledge shutdown"))
    raise_failure(self)
  end
  self._state = "closed"
  local lease = assert(self._lease)
  if not self._exit then
    local stdin_closed, close_err = lease:close_stdin()
    if not stdin_closed then
      fail(self, close_err or protocol_error("Could not close RPC channel input"))
      raise_failure(self)
    end
  end
  local exited = self._exit
  if exited and exited.error then
    fail(self, util.normalize_error(exited.error, "protocol"))
    raise_failure(self)
  end
  if exited and exited.code ~= 0 then
    fail(self, util.error("protocol", "RPC peer failed during shutdown", exited.stderr))
    raise_failure(self)
  end
  local finished, finish_err = self._decoder:finish()
  if not finished then
    fail(self, protocol_error(finish_err))
    raise_failure(self)
  end
  return true
end

function RpcConnection:abort()
  fail(self, self._failure or util.error("protocol", "RPC connection was aborted"))
end

function RpcConnection:cancel()
  begin_cancel(self)
end

---@return true
---@async
function RpcConnection:wait_cancelled()
  if self._state == "open" and not self._active then
    return true
  end
  if self._failure then
    raise_failure(self)
  end
  if self._state ~= "cancelling" then
    error("RPC connection has no cancelling request", 0)
  end
  return async.await(function(done)
    self._cancel_waiters[#self._cancel_waiters + 1] = done
    return function()
      for index, waiter in ipairs(self._cancel_waiters) do
        if waiter == done then
          table.remove(self._cancel_waiters, index)
          break
        end
      end
    end
  end)
end

---@class Neoagent.RpcRequestHandlers
---@field on_event? async fun(message: table)

---@class Neoagent.RpcCall
---@field _connection Neoagent.RpcConnection
---@field _run Neoagent.Run<{value: unknown}, unknown>
---@field _request_id integer
local RpcCall = {}
RpcCall.__index = RpcCall

---@return unknown
---@async
function RpcCall:result()
  local value = self._run:await()
  if value.ok == false then
    error(value.error, 0)
  end
  return value.value
end

---@param _reason? string
function RpcCall:cancel(_reason)
  if self._run:is_done() then
    return
  end
  self._run:cancel()
  begin_cancel(self._connection, self._request_id)
end

---@param method string
---@param payload Neoagent.JsonObject
---@param handlers? Neoagent.RpcRequestHandlers
---@return Neoagent.RpcCall
function RpcConnection:start_request(method, payload, handlers)
  if self._state ~= "open" then
    if self._failure then
      raise_failure(self)
    end
    error("RPC connection is not ready for a request", 0)
  end
  self._request_id = self._request_id + 1
  ---@type Neoagent.RpcRequest
  local active = {
    id = self._request_id,
    method = method,
    sequence = 0,
    on_event = handlers and handlers.on_event or nil,
    terminal_received = false,
  }
  local connection = self
  local run = async.run(function()
    return { value = request(connection, active, payload) }
  end, { error_kind = "protocol" })
  return setmetatable({
    _connection = self,
    _run = run,
    _request_id = active.id,
  }, RpcCall)
end

---@param method string
---@param payload Neoagent.JsonObject
---@param handlers? Neoagent.RpcRequestHandlers
---@return unknown
---@async
function RpcConnection:request(method, payload, handlers)
  return self:start_request(method, payload, handlers):result()
end

---@class Neoagent.RpcConnectionOptions
---@field start_grace_ms? integer
---@field shutdown_grace_ms? integer
---@field on_event? fun(message: table)
---@field on_failure? fun(error: Neoagent.Error)

---@param opts? Neoagent.RpcConnectionOptions
---@return Neoagent.RpcConnection
function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "RPC connection options must be an object")
  assert(opts.on_event == nil or type(opts.on_event) == "function", "RPC event callback must be a function")
  assert(opts.on_failure == nil or type(opts.on_failure) == "function", "RPC failure callback must be a function")
  assert(
    opts.start_grace_ms == nil
      or type(opts.start_grace_ms) == "number" and opts.start_grace_ms > 0 and opts.start_grace_ms % 1 == 0,
    "RPC connection start grace must be a positive integer"
  )
  assert(
    opts.shutdown_grace_ms == nil
      or type(opts.shutdown_grace_ms) == "number" and opts.shutdown_grace_ms > 0 and opts.shutdown_grace_ms % 1 == 0,
    "RPC connection shutdown grace must be a positive integer"
  )
  next_call_id = next_call_id + 1
  ---@type Neoagent.RpcConnection
  local client = setmetatable({
    _queue = {},
    _queued_bytes = 0,
    _cancel_waiters = {},
    _state = "new",
    _call_id = "call-" .. tostring(next_call_id),
    _request_id = 0,
    _event_sequence = 0,
    _on_event = opts.on_event,
    _on_failure = opts.on_failure,
    _start_grace_ms = opts.start_grace_ms or START_GRACE_MS,
    _shutdown_grace_ms = opts.shutdown_grace_ms or SHUTDOWN_GRACE_MS,
  }, RpcConnection)
  client._decoder = protocol.decoder(function(message)
    enqueue(client, message)
  end)
  return client
end

return M
