local util = require("neoagent.util")
local framing = require("neoagent.ipc.framing")
local validation = require("neoagent.validation")

local M = {}
M.MAX_INPUT_CHUNK = 64 * 1024
---@class Neoagent.SandboxProtocolInput
---@field v? unknown
---@field type? unknown
---@field stream? unknown
---@field seq? unknown
---@field data? unknown
---@field code? unknown
---@field signal? unknown
---@field timed_out? unknown
---@field stage? unknown
---@field errno? unknown
---@field cleanup? unknown

---@class Neoagent.SandboxNativeFailure
---@field stage string
---@field errno integer

---@class Neoagent.SandboxCleanupObservation
---@field released boolean
---@field error? Neoagent.SandboxNativeFailure

---@class Neoagent.SandboxProtocolBase: Neoagent.SandboxProtocolInput
---@field v 1

---@class Neoagent.SandboxReadyEvent: Neoagent.SandboxProtocolBase
---@field type "ready"

---@class Neoagent.SandboxOutputEvent: Neoagent.SandboxProtocolBase
---@field type "output"
---@field stream "stdout"|"stderr"
---@field seq integer
---@field data string

---@class Neoagent.SandboxExitEvent: Neoagent.SandboxProtocolBase
---@field type "exit"
---@field code integer
---@field signal integer
---@field timed_out? boolean
---@field cleanup? Neoagent.SandboxCleanupObservation Native sandbox resources, independent of target exit.

---@class Neoagent.SandboxErrorEvent: Neoagent.SandboxProtocolBase
---@field type "error"
---@field stage string
---@field errno integer
---@field cleanup? Neoagent.SandboxCleanupObservation

---@alias Neoagent.SandboxTerminalEvent Neoagent.SandboxExitEvent|Neoagent.SandboxErrorEvent
---@alias Neoagent.SandboxProtocolEvent Neoagent.SandboxReadyEvent|Neoagent.SandboxOutputEvent|Neoagent.SandboxTerminalEvent

---@class Neoagent.SandboxProtocolDecoder
---@field sequence integer
---@field ready boolean
---@field terminal? Neoagent.SandboxTerminalEvent
---@field failed? string
---@field on_event fun(event: Neoagent.SandboxProtocolEvent)
---@field framing Neoagent.FrameDecoder
local Decoder = {}
Decoder.__index = Decoder

local MAX_FRAME = 1024 * 1024

---@param message unknown
---@return string
local function framing_error(message)
  local value = tostring(message)
  value = value:gsub("invalid IPC frame length", "invalid sandbox protocol frame length")
  value = value:gsub("invalid IPC MessagePack payload", "invalid sandbox protocol MessagePack payload")
  value = value:gsub("truncated IPC frame", "truncated sandbox protocol frame")
  return value
end

---@param value unknown
---@return string
function M.encode(value)
  return framing.encode(value, MAX_FRAME)
end

---@param on_data fun(data: string)
---@param on_end fun()
---@return Neoagent.FrameDecoder
function M.input_decoder(on_data, on_end)
  local ended = false
  return framing.new({
    max_frame = MAX_FRAME,
    on_value = function(value)
      assert(validation.object(value), "invalid sandbox input message")
      ---@cast value table
      validation.exact(value, { v = true, type = true, data = false }, "sandbox input")
      assert(not ended and value.v == 1, "invalid sandbox input state")
      if value.type == "stdin" then
        assert(
          type(value.data) == "string" and value.data ~= "" and #value.data <= M.MAX_INPUT_CHUNK,
          "invalid sandbox input bytes"
        )
        on_data(value.data)
      else
        assert(value.type == "stdin-end" and value.data == nil, "invalid sandbox input end")
        ended = true
        on_end()
      end
    end,
  })
end

---@param value unknown
---@param state Neoagent.SandboxProtocolDecoder
---@return Neoagent.SandboxProtocolEvent
local function validate(value, state)
  if type(value) ~= "table" or value.v ~= 1 or type(value.type) ~= "string" then
    error("invalid sandbox protocol event")
  end
  if value.cleanup ~= nil then
    local cleanup = value.cleanup
    assert(value.type == "exit" or value.type == "error", "sandbox cleanup precedes completion")
    assert(validation.object(cleanup), "invalid sandbox cleanup observation")
    validation.exact(cleanup, { released = true, error = false }, "sandbox cleanup")
    assert(type(cleanup.released) == "boolean", "invalid sandbox cleanup release")
    if cleanup.error ~= nil then
      local failure = cleanup.error
      assert(not cleanup.released and validation.object(failure), "invalid sandbox cleanup failure")
      validation.exact(failure, { stage = true, errno = true }, "sandbox cleanup failure")
      assert(type(failure.stage) == "string" and failure.stage ~= "", "invalid sandbox cleanup stage")
      assert(
        type(failure.errno) == "number" and failure.errno % 1 == 0 and failure.errno >= 0,
        "invalid sandbox cleanup errno"
      )
    end
  end
  if value.type == "output" then
    if not state.ready then
      error("sandbox output precedes ready event")
    end
    if state.terminal then
      error("sandbox output follows terminal event")
    end
    if value.stream ~= "stdout" and value.stream ~= "stderr" then
      error("invalid sandbox output stream")
    end
    if
      type(value.seq) ~= "number"
      or value.seq % 1 ~= 0
      or value.seq ~= state.sequence + 1
      or type(value.data) ~= "string"
    then
      error("invalid sandbox output event")
    end
    state.sequence = value.seq
  elseif value.type == "ready" then
    if state.ready or state.terminal then
      error("duplicate sandbox ready event")
    end
    state.ready = true
  elseif value.type == "exit" then
    if
      not state.ready
      or state.terminal
      or type(value.code) ~= "number"
      or value.code % 1 ~= 0
      or value.code < 0
      or type(value.signal) ~= "number"
      or value.signal % 1 ~= 0
      or value.signal < 0
      or value.timed_out ~= nil and type(value.timed_out) ~= "boolean"
    then
      error("invalid sandbox exit event")
    end
    ---@cast value Neoagent.SandboxExitEvent
    state.terminal = util.copy(value)
  elseif value.type == "error" then
    if
      state.terminal
      or type(value.stage) ~= "string"
      or value.stage == ""
      or type(value.errno) ~= "number"
      or value.errno % 1 ~= 0
      or value.errno < 0
    then
      error("invalid sandbox error event")
    end
    ---@cast value Neoagent.SandboxErrorEvent
    state.terminal = util.copy(value)
  else
    error("unknown sandbox protocol event: " .. value.type)
  end
  ---@cast value Neoagent.SandboxProtocolEvent
  return value
end

---@param chunk string
function Decoder:feed(chunk)
  assert(type(chunk) == "string", "sandbox protocol chunk must be a string")
  if self.failed then
    error(self.failed, 0)
  end
  local ok, err = pcall(self.framing.feed, self.framing, chunk)
  if not ok then
    self.failed = framing_error(err)
    error(self.failed, 0)
  end
end

---@return Neoagent.SandboxTerminalEvent?, string?
---@return_overload Neoagent.SandboxTerminalEvent
---@return_overload nil, string
function Decoder:finish()
  if self.failed then
    return nil, self.failed
  end
  local complete, framing_err = self.framing:finish()
  if not complete then
    return nil, framing_error(framing_err)
  end
  if not self.terminal then
    return nil, "sandbox protocol has no terminal event"
  end
  return util.copy(self.terminal)
end

---@param opts? {max_frame?: integer, on_event?: fun(event: Neoagent.SandboxProtocolEvent)}
---@return Neoagent.SandboxProtocolDecoder
function M.new(opts)
  opts = opts or {}
  ---@type Neoagent.SandboxProtocolDecoder
  local decoder = setmetatable({
    sequence = 0,
    ready = false,
    terminal = nil,
    on_event = opts.on_event or function() end,
  }, Decoder)
  decoder.framing = framing.new({
    max_frame = opts.max_frame or MAX_FRAME,
    on_value = function(value)
      local event = validate(value, decoder)
      decoder.on_event(util.copy(event))
    end,
  })
  return decoder
end

---@param data string
---@return Neoagent.SandboxProtocolEvent[]?, Neoagent.SandboxTerminalEvent|string
---@return_overload Neoagent.SandboxProtocolEvent[], Neoagent.SandboxTerminalEvent
---@return_overload nil, string
function M.decode_all(data)
  ---@type Neoagent.SandboxProtocolEvent[]
  local events = {}
  local decoder = M.new({
    on_event = function(value)
      events[#events + 1] = value
    end,
  })
  local ok, err = pcall(decoder.feed, decoder, data)
  if not ok then
    return nil, tostring(err)
  end
  local terminal, finish_err = decoder:finish()
  if not terminal then
    return nil, finish_err
  end
  return events, terminal
end

return M
