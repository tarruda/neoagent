local async = require("neoagent.async")
local protocol = require("neoagent.rpc.protocol")
local util = require("neoagent.util")

---@class Neoagent.RpcServerOptions
---@field send fun(message: table)
---@field dependencies? Neoagent.ToolDependencyOverrides

---@class Neoagent.RpcServerRequest
---@field id integer
---@field method string
---@field run? Neoagent.Run<table, unknown>
---@field cancelling boolean
---@field sequence integer

---@class Neoagent.RpcServerIncomingRequest
---@field id integer
---@field method string
---@field bytes integer
---@field received integer
---@field chunks string[]

---@class Neoagent.RpcServer
---@field _send fun(message: table)
---@field _domain Neoagent.RpcServerDomain
---@field _state "waiting_open"|"open"|"closed"|"failed"
---@field _call_id? string
---@field _deferred_events {name: string, value: table}[]
---@field _event_sequence integer
---@field _last_request integer
---@field _completed_request? integer
---@field _active? Neoagent.RpcServerRequest
---@field _incoming? Neoagent.RpcServerIncomingRequest
---@field _failure? string
local Server = {}
Server.__index = Server

---@class Neoagent.RpcServerOperation
---@field execute async fun(): table
---@field finish async fun(result: table): table

---@class Neoagent.RpcServerDomain
---@field error_kind string
---@field max_pending_events integer Maximum connection notifications queued during a request.
---@field open fun(context: unknown)
---@field events fun(send: fun(name: string, value: table))
---@field request fun(method: string, payload: unknown, emit: fun(name: string, value: table), cancelled: fun(): boolean): Neoagent.RpcServerOperation
---@field close fun(reason: string)
---@field is_quiescent fun(): boolean

local M = {}

---@param self Neoagent.RpcServer
---@param message table
local function send(self, message)
  self._send(message)
end

---@param self Neoagent.RpcServer
---@param active Neoagent.RpcServerRequest
---@param name string
---@param value table
local function send_event(self, active, name, value)
  if self._active ~= active or active.cancelling then
    error(async.cancelled_error, 0)
  end
  active.sequence = active.sequence + 1
  send(self, {
    type = "event",
    call_id = assert(self._call_id),
    request_id = active.id,
    sequence = active.sequence,
    name = name,
    value = value,
  })
end

---@param self Neoagent.RpcServer
---@param reason string
local function stop(self, reason)
  self._state = "failed"
  self._failure = util.safe_message(reason, {
    fallback = "Tool RPC server failed",
    max_characters = protocol.MAX_ERROR_BYTES,
    max_source_bytes = protocol.MAX_ERROR_BYTES,
  })
  if self._active then
    local run = self._active.run
    if run then
      run:cancel()
    end
  end
  self._incoming = nil
  self._domain.close("RPC worker stopped")
end

---@param self Neoagent.RpcServer
---@param reason string
---@return never
local function fail(self, reason)
  stop(self, reason)
  error(reason, 0)
end

---@param self Neoagent.RpcServer
---@param message table
local function start_request(self, message)
  if self._active or self._incoming or message.request_id ~= self._last_request + 1 then
    fail(self, "Tool RPC request order is invalid")
  end
  self._last_request = message.request_id
  local active = { id = message.request_id, method = message.method, cancelling = false, sequence = 0 }
  self._active = active
  local operation = self._domain.request(message.method, message.payload, function(name, value)
    send_event(self, active, name, value)
  end, function()
    return self._active ~= active or active.cancelling or self._state == "failed"
  end)
  active.run = async.run(operation.execute, {
    error_kind = self._domain.error_kind,
    on_done = function(result)
      if self._active ~= active then
        return
      end
      -- Request cleanup belongs to the domain and survives cancellation of
      -- the request Run. The wire acknowledgement follows that cleanup.
      async.run(function()
        return { value = operation.finish(result) }
      end, {
        on_done = function(finished)
          if finished.ok == false then
            self._active = nil
            stop(self, finished.error.message)
            return
          end
          if self._state == "failed" then
            self._active = nil
            return
          end
          local value = finished.value
          local completed, completion_err = pcall(function()
            self._active = nil
            self._completed_request = active.id
            if value.ok == false then
              local err = value.error
              if active.cancelling or err.kind == "cancelled" then
                send(self, { type = "cancelled", call_id = assert(self._call_id), request_id = active.id })
                return
              end
              local wire_error = {
                kind = self._domain.error_kind,
                message = util.safe_message(err.message, {
                  fallback = "RPC operation failed",
                  max_characters = protocol.MAX_ERROR_BYTES,
                  max_source_bytes = protocol.MAX_ERROR_BYTES,
                }),
                detail = err.detail ~= nil and util.safe_message(err.detail, {
                  fallback = "RPC operation detail was unavailable",
                  max_characters = protocol.MAX_ERROR_BYTES,
                  max_source_bytes = protocol.MAX_ERROR_BYTES,
                }) or nil,
              }
              local code = rawget(err, "code")
              if type(code) == "string" and code:match("^[A-Za-z0-9_.:-]+$") and #code <= 128 then
                wire_error.code = code
              end
              send(
                self,
                { type = "request_error", call_id = assert(self._call_id), request_id = active.id, error = wire_error }
              )
            else
              send(self, { type = "response", call_id = assert(self._call_id), request_id = active.id, value = value })
            end
          end)
          if not completed then
            stop(self, completion_err)
          else
            local events = self._deferred_events
            self._deferred_events = {}
            for _, event in ipairs(events) do
              self._event_sequence = self._event_sequence + 1
              local sent, err = pcall(send, self, {
                type = "event",
                call_id = assert(self._call_id),
                sequence = self._event_sequence,
                name = event.name,
                value = event.value,
              })
              if not sent then
                stop(self, err)
                break
              end
            end
          end
        end,
      })
    end,
  })
end

---@param self Neoagent.RpcServer
---@param message table
local function begin_streamed_request(self, message)
  if self._active or self._incoming or message.request_id ~= self._last_request + 1 then
    fail(self, "Tool RPC request order is invalid")
  end
  self._incoming = {
    id = message.request_id,
    method = message.method,
    bytes = message.bytes,
    received = 0,
    chunks = {},
  }
end

---@param self Neoagent.RpcServer
---@param message table
local function append_streamed_request(self, message)
  local incoming = self._incoming
  if not incoming or incoming.id ~= message.request_id or incoming.received + #message.data > incoming.bytes then
    fail(self, "Tool RPC request stream is invalid")
  end
  incoming.chunks[#incoming.chunks + 1] = message.data
  incoming.received = incoming.received + #message.data
end

---@param self Neoagent.RpcServer
---@param message table
local function finish_streamed_request(self, message)
  local incoming = self._incoming
  if not incoming or incoming.id ~= message.request_id or incoming.received ~= incoming.bytes then
    fail(self, "Tool RPC request stream is incomplete")
  end
  local decoded, payload = pcall(vim.mpack.decode, table.concat(incoming.chunks))
  if not decoded then
    fail(self, "Tool RPC request stream payload is invalid")
  end
  self._incoming = nil
  start_request(self, {
    request_id = incoming.id,
    method = incoming.method,
    payload = payload,
  })
end

---@param message unknown
function Server:receive(message)
  message = protocol.validate(message)
  if self._state == "waiting_open" then
    if message.type ~= "open" then
      fail(self, "Tool RPC expected an open message")
    end
    self._call_id = message.call_id
    self._domain.open(message.context)
    self._state = "open"
    send(self, { type = "opened", call_id = self._call_id })
    return
  end
  if self._state ~= "open" or message.call_id ~= self._call_id then
    fail(self, "Tool RPC call state is invalid")
  end
  if message.type == "request" then
    start_request(self, message)
  elseif message.type == "request_begin" then
    begin_streamed_request(self, message)
  elseif message.type == "request_chunk" then
    append_streamed_request(self, message)
  elseif message.type == "request_end" then
    finish_streamed_request(self, message)
  elseif message.type == "cancel" then
    local active = self._active
    if not active and self._completed_request == message.request_id then
      return
    end
    if not active or active.id ~= message.request_id or active.cancelling then
      fail(self, "Tool RPC cancellation is invalid")
    end
    active.cancelling = true
    local run = active.run
    if run then
      run:cancel()
    end
  elseif message.type == "close" then
    if self._active or self._incoming then
      fail(self, "Tool RPC cannot close with an active request")
    end
    self._state = "closed"
    self._domain.close("RPC connection closed")
    send(self, { type = "closed", call_id = assert(self._call_id) })
  else
    fail(self, "Tool RPC message is invalid in the worker")
  end
end

function Server:eof()
  if self._state ~= "closed" then
    stop(self, "Tool RPC input ended before orderly shutdown")
  end
end

---@return boolean
function Server:is_terminal()
  return self._state == "closed" or self._state == "failed"
end

---@return boolean
function Server:is_quiescent()
  return self._active == nil and self._incoming == nil and self._domain.is_quiescent()
end

---@return string?
function Server:failure()
  return self._failure
end

---@param opts Neoagent.RpcServerOptions
---@param domain Neoagent.RpcServerDomain
---@return Neoagent.RpcServer
local function new(opts, domain)
  assert(type(opts) == "table" and type(opts.send) == "function", "Tool RPC server send function is required")
  local server = setmetatable({
    _send = opts.send,
    _domain = domain,
    _state = "waiting_open",
    _last_request = 0,
    _event_sequence = 0,
    _deferred_events = {},
  }, Server)
  domain.events(function(name, value)
    assert(server._state == "open", "RPC connection event requires an open connection")
    if server._active then
      assert(#server._deferred_events < domain.max_pending_events, "RPC connection event queue exceeded its bound")
      server._deferred_events[#server._deferred_events + 1] = { name = name, value = value }
      return
    end
    server._event_sequence = server._event_sequence + 1
    send(server, {
      type = "event",
      call_id = assert(server._call_id),
      sequence = server._event_sequence,
      name = name,
      value = value,
    })
  end)
  send(server, { type = "ready", marker = protocol.MARKER })
  return server
end

---@param opts Neoagent.RpcServerOptions
---@return Neoagent.RpcServer
function M.new(opts)
  return new(opts, require("neoagent.rpc.tool_server").new(util.copy(opts.dependencies or {})))
end

-- Internal dependency injection for behavioral tests. Production construction
-- always uses the fixed dispatcher above.
---@param opts Neoagent.RpcServerOptions
---@param selected_dispatch async fun(name: string, payload: unknown, call: Neoagent.ToolOperationCall, options: Neoagent.ToolDependencyOverrides): Neoagent.ToolResult
---@return Neoagent.RpcServer
function M._new(opts, selected_dispatch)
  assert(type(selected_dispatch) == "function", "Tool RPC test dispatcher must be a function")
  return new(opts, require("neoagent.rpc.tool_server").new(util.copy(opts.dependencies or {}), selected_dispatch))
end

-- Retained execution has its own connection lifetime; Tool request scopes
-- keep their existing ownership in the separate Tool domain.
---@param opts Neoagent.RpcServerOptions
---@return Neoagent.RpcServer
function M.process(opts)
  return new(opts, require("neoagent.rpc.process_server").new())
end

return M
