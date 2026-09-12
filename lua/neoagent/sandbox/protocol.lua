local util = require("neoagent.util")

local M = {}
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

---@class Neoagent.SandboxErrorEvent: Neoagent.SandboxProtocolBase
---@field type "error"
---@field stage string
---@field errno integer

---@alias Neoagent.SandboxTerminalEvent Neoagent.SandboxExitEvent|Neoagent.SandboxErrorEvent
---@alias Neoagent.SandboxProtocolEvent Neoagent.SandboxReadyEvent|Neoagent.SandboxOutputEvent|Neoagent.SandboxTerminalEvent

---@class Neoagent.SandboxProtocolDecoder
---@field buffer string
---@field length? integer
---@field sequence integer
---@field ready boolean
---@field terminal? Neoagent.SandboxTerminalEvent
---@field max_frame integer
---@field on_event fun(event: Neoagent.SandboxProtocolEvent)
local Decoder = {}
Decoder.__index = Decoder

local MAX_FRAME = 1024 * 1024

---@param value integer
---@return string
local function u32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

---@param buffer string
---@return integer
local function decode_length(buffer)
  local a, b, c, d = buffer:byte(1, 4)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

---@param value unknown
---@return string
function M.encode(value)
  local payload = vim.mpack.encode(value)
  assert(#payload <= MAX_FRAME, "sandbox protocol frame is too large")
  return u32(#payload) .. payload
end

---@param value unknown
---@param state Neoagent.SandboxProtocolDecoder
---@return Neoagent.SandboxProtocolEvent
local function validate(value, state)
  if type(value) ~= "table" or value.v ~= 1 or type(value.type) ~= "string" then
    error("invalid sandbox protocol event")
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
  self.buffer = self.buffer .. chunk
  while true do
    if not self.length then
      if #self.buffer < 4 then
        return
      end
      self.length = decode_length(self.buffer)
      self.buffer = self.buffer:sub(5)
      if self.length <= 0 or self.length > self.max_frame then
        error("invalid sandbox protocol frame length")
      end
    end
    if #self.buffer < self.length then
      return
    end
    local payload = self.buffer:sub(1, self.length)
    self.buffer = self.buffer:sub(self.length + 1)
    self.length = nil
    local ok, value = pcall(vim.mpack.decode, payload)
    if not ok then
      error("invalid sandbox MessagePack payload: " .. tostring(value))
    end
    local event = validate(value, self)
    self.on_event(util.copy(event))
  end
end

---@return Neoagent.SandboxTerminalEvent?, string?
---@return_overload Neoagent.SandboxTerminalEvent
---@return_overload nil, string
function Decoder:finish()
  if self.length or self.buffer ~= "" then
    return nil, "truncated sandbox protocol stream"
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
  return setmetatable({
    buffer = "",
    length = nil,
    sequence = 0,
    ready = false,
    terminal = nil,
    max_frame = opts.max_frame or MAX_FRAME,
    on_event = opts.on_event or function() end,
  }, Decoder)
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
