local artifacts = require("neoagent.rpc.artifacts")
local async = require("neoagent.async")
local codec = require("neoagent.rpc.codec")
local limits = require("neoagent.rpc.tool_limits")
local methods = require("neoagent.rpc.methods")
local protocol = require("neoagent.rpc.protocol")
local common = require("neoagent.tools.common")
local util = require("neoagent.util")

---@class Neoagent.RpcServerOptions
---@field send fun(message: table)
---@field dependencies? Neoagent.ToolDependencyOverrides

---@class Neoagent.RpcServerRequest
---@field id integer
---@field method string
---@field run? Neoagent.Run<Neoagent.ToolResult, unknown>
---@field cancelling boolean
---@field sequence integer
---@field update_count integer
---@field update_bytes integer
---@field policy? Neoagent.ToolRpcPolicyEvidence

---@class Neoagent.RpcServerIncomingRequest
---@field id integer
---@field method string
---@field bytes integer
---@field received integer
---@field chunks string[]

---@class Neoagent.RpcServer
---@field _send fun(message: table)
---@field _dependencies Neoagent.ToolDependencyOverrides
---@field _processes Neoagent.ProcessScope
---@field _state "waiting_open"|"open"|"closed"|"failed"
---@field _call_id? string
---@field _context? {workspace: Neoagent.ToolWorkspace, denial_keywords: string[]}
---@field _last_request integer
---@field _completed_request? integer
---@field _active? Neoagent.RpcServerRequest
---@field _incoming? Neoagent.RpcServerIncomingRequest
---@field _failure? string
---@field _dispatch async fun(name: string, payload: unknown, call: Neoagent.ToolOperationCall, options: Neoagent.ToolDependencyOverrides): Neoagent.ToolResult
local Server = {}
Server.__index = Server

local M = {}

-- Leave half the acknowledgement window for relays and scheduled delivery.
local PROCESS_CLEANUP_MS = math.floor(protocol.CANCEL_GRACE_MS / 2)

---@param name string
---@param payload unknown
---@param call Neoagent.ToolOperationCall
---@param options Neoagent.ToolDependencyOverrides
---@return Neoagent.ToolResult
---@async
local function dispatch(name, payload, call, options)
  local descriptor = methods.by_name[name]
  assert(descriptor, "unknown Tool RPC method")
  return descriptor.execute(payload, call, options)
end

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
  self._processes:close()
end

---@param self Neoagent.RpcServer
---@param reason string
---@return never
local function fail(self, reason)
  stop(self, reason)
  error(reason, 0)
end

---@param active Neoagent.RpcServerRequest
---@param keywords string[]
---@return fun(output: string, is_stderr: boolean)?
local function policy_output_observer(active, keywords)
  if #keywords == 0 then
    return nil
  end
  local lowered = {}
  local overlap_bytes = 0
  for index, keyword in ipairs(keywords) do
    lowered[index] = keyword:lower()
    overlap_bytes = math.max(overlap_bytes, #keyword - 1)
  end
  local overlaps = { [false] = "", [true] = "" }
  return function(output, is_stderr)
    if active.policy and active.policy.denial_output or output == "" then
      return
    end
    local text = (overlaps[is_stderr] .. output):lower()
    for index, keyword in ipairs(lowered) do
      if text:find(keyword, 1, true) then
        active.policy = active.policy or {}
        active.policy.denial_output = assert(keywords[index])
        return
      end
    end
    overlaps[is_stderr] = overlap_bytes > 0 and text:sub(-overlap_bytes) or ""
  end
end

---@param self Neoagent.RpcServer
---@param message table
local function start_request(self, message)
  if self._active or self._incoming or message.request_id ~= self._last_request + 1 then
    fail(self, "Tool RPC request order is invalid")
  end
  self._last_request = message.request_id
  local processes = require("neoagent.process").scope()
  self._processes = processes
  ---@type Neoagent.RpcServerRequest
  local active = {
    id = message.request_id,
    method = message.method,
    cancelling = false,
    sequence = 0,
    update_count = 0,
    update_bytes = 0,
  }
  self._active = active
  local publisher = artifacts.publisher(function(event)
    local value = util.copy(event)
    value.type = nil
    local name = event.type == "artifact_begin" and codec.events.artifact_begin
      or event.type == "artifact_chunk" and codec.events.artifact_chunk
      or codec.events.artifact_end
    send_event(self, active, name, value)
  end)
  local context = assert(self._context)
  ---@type Neoagent.ToolOperationCall
  local call = {
    workspace = util.copy(context.workspace),
    on_update = function(value)
      if self._active ~= active or active.cancelling then
        return
      end
      local valid = common.update(value)
      local encoded, bytes = pcall(vim.mpack.encode, valid)
      if not encoded or type(bytes) ~= "string" then
        error("Tool update could not be encoded", 0)
      end
      if
        active.update_count + 1 > limits.MAX_UPDATE_COUNT
        or active.update_bytes + #bytes > limits.MAX_UPDATE_BYTES
      then
        -- Updates are transient progress. Once their bounded transport budget
        -- is exhausted, preserve the authoritative final Tool result.
        return
      end
      active.update_count = active.update_count + 1
      active.update_bytes = active.update_bytes + #bytes
      send_event(self, active, codec.events.update, valid)
    end,
  }
  local dependency_options = util.copy(self._dependencies)
  local process = dependency_options.process
  if not process then
    ---@async
    process = function(command, options)
      return processes:run(command, options)
    end
  end
  local observe = policy_output_observer(active, context.denial_keywords)
  dependency_options.process = function(command, options)
    local selected = util.copy(options or {})
    local on_output = selected.on_output
    selected.on_output = function(data, is_stderr, stdout, stderr, output)
      -- Search stdout contains matched file content and names, not diagnostics.
      -- Shell commands may report failures on either stream.
      if observe and (is_stderr or active.method == "shell") then
        observe(data, is_stderr)
      end
      if on_output then
        on_output(data, is_stderr, stdout, stderr, output)
      end
    end
    local result = process(command, selected)
    -- Preserve native status before the Tool turns a failure into text.
    -- The parent decides whether these observations establish a denial.
    if result.code ~= 0 then
      active.policy = active.policy or {}
      active.policy.process_exit = { code = result.code, signal = result.signal }
    end
    return result
  end
  dependency_options.artifact_publisher = function()
    return publisher
  end
  local run = async.run(function()
    return self._dispatch(active.method, message.payload, call, dependency_options)
  end, {
    error_kind = "tool",
    on_done = function(result)
      if self._active ~= active then
        return
      end
      processes:close()
      async.run(function()
        processes:wait(PROCESS_CLEANUP_MS)
      end, {
        on_done = function(cleaned)
          if cleaned.ok == false then
            self._active = nil
            stop(self, cleaned.error.message)
            return
          end
          if self._state == "failed" then
            self._active = nil
            return
          end
          local completed, completion_err = pcall(function()
            if
              not active.cancelling
              and active.policy
              and (result.ok == false and result.error.kind ~= "cancelled" or result.isError)
            then
              send_event(self, active, codec.events.policy, active.policy)
            end
            self._active = nil
            self._completed_request = active.id
            if result.ok == false then
              local err = result.error
              if active.cancelling or err.kind == "cancelled" then
                send(self, {
                  type = "cancelled",
                  call_id = assert(self._call_id),
                  request_id = active.id,
                })
                return
              end
              local wire_error = {
                kind = "tool",
                message = util.safe_message(err.message, {
                  fallback = "Tool operation failed",
                  max_characters = protocol.MAX_ERROR_BYTES,
                  max_source_bytes = protocol.MAX_ERROR_BYTES,
                }),
                detail = err.detail ~= nil and util.safe_message(err.detail, {
                  fallback = "Tool operation detail was unavailable",
                  max_characters = protocol.MAX_ERROR_BYTES,
                  max_source_bytes = protocol.MAX_ERROR_BYTES,
                }) or nil,
              }
              local code = rawget(err, "code")
              if type(code) == "string" and code ~= "" and #code <= 128 and util.is_valid_utf8(code) then
                wire_error.code = code
              end
              send(self, {
                type = "request_error",
                call_id = assert(self._call_id),
                request_id = active.id,
                error = wire_error,
              })
              return
            end
            local response = {
              type = "response",
              call_id = assert(self._call_id),
              request_id = active.id,
              value = codec.result(result),
            }
            send(self, response)
          end)
          if not completed then
            stop(self, completion_err)
          end
        end,
      })
    end,
  })
  active.run = run
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
    self._context = codec.decode_context(message.context)
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
    self._processes:close()
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
  return self._active == nil and self._incoming == nil and self._processes:is_settled()
end

---@return string?
function Server:failure()
  return self._failure
end

---@param opts Neoagent.RpcServerOptions
---@param selected_dispatch? async fun(name: string, payload: unknown, call: Neoagent.ToolOperationCall, options: Neoagent.ToolDependencyOverrides): Neoagent.ToolResult
---@return Neoagent.RpcServer
local function new(opts, selected_dispatch)
  assert(type(opts) == "table" and type(opts.send) == "function", "Tool RPC server send function is required")
  local server = setmetatable({
    _send = opts.send,
    _dependencies = util.copy(opts.dependencies or {}),
    _processes = require("neoagent.process").scope(),
    _dispatch = selected_dispatch or dispatch,
    _state = "waiting_open",
    _last_request = 0,
  }, Server)
  send(server, { type = "ready", marker = protocol.MARKER })
  return server
end

---@param opts Neoagent.RpcServerOptions
---@return Neoagent.RpcServer
function M.new(opts)
  return new(opts)
end

-- Internal dependency injection for behavioral tests. Production construction
-- always uses the fixed dispatcher above.
---@param opts Neoagent.RpcServerOptions
---@param selected_dispatch async fun(name: string, payload: unknown, call: Neoagent.ToolOperationCall, options: Neoagent.ToolDependencyOverrides): Neoagent.ToolResult
---@return Neoagent.RpcServer
function M._new(opts, selected_dispatch)
  assert(type(selected_dispatch) == "function", "Tool RPC test dispatcher must be a function")
  return new(opts, selected_dispatch)
end

return M
