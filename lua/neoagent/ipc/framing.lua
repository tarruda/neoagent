local M = {}

local DEFAULT_MAX_FRAME = 1024 * 1024

---@class Neoagent.FrameDecoder
---@field _header string
---@field _length? integer
---@field _payload string[]
---@field _received integer
---@field _max_frame integer
---@field _on_value fun(value: unknown, frame_bytes: integer)
---@field _failed? string
local Decoder = {}
Decoder.__index = Decoder

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

---@param value string
---@return integer
local function decode_length(value)
  local a, b, c, d = assert(value:byte(1, 4))
  return ((a * 256 + b) * 256 + c) * 256 + d
end

---@param value unknown
---@param max_frame? integer
---@return string
function M.encode(value, max_frame)
  local payload = vim.mpack.encode(value)
  local maximum = max_frame or DEFAULT_MAX_FRAME
  assert(#payload > 0 and #payload <= maximum, "IPC frame is outside the configured bound")
  return u32(#payload) .. payload
end

---@param message string
local function fail(self, message)
  self._failed = message
  error(message, 0)
end

---@param chunk string
function Decoder:feed(chunk)
  assert(type(chunk) == "string", "IPC chunk must be a string")
  if self._failed then
    error(self._failed, 0)
  end
  local offset = 1
  while offset <= #chunk do
    if not self._length then
      local needed = 4 - #self._header
      local count = math.min(needed, #chunk - offset + 1)
      self._header = self._header .. chunk:sub(offset, offset + count - 1)
      offset = offset + count
      if #self._header == 4 then
        local length = decode_length(self._header)
        self._header = ""
        if length <= 0 or length > self._max_frame then
          fail(self, "invalid IPC frame length")
        end
        self._length = length
      end
    else
      local needed = self._length - self._received
      local count = math.min(needed, #chunk - offset + 1)
      self._payload[#self._payload + 1] = chunk:sub(offset, offset + count - 1)
      self._received = self._received + count
      offset = offset + count
      if self._received == self._length then
        local payload = table.concat(self._payload)
        self._payload = {}
        self._received = 0
        self._length = nil
        local ok, value = pcall(vim.mpack.decode, payload)
        if not ok then
          fail(self, "invalid IPC MessagePack payload")
        end
        self._on_value(value, #payload + 4)
      end
    end
  end
end

---@return true?, string?
function Decoder:finish()
  if self._failed then
    return nil, self._failed
  end
  if self._header ~= "" or self._length ~= nil or self._received ~= 0 then
    return nil, "truncated IPC frame"
  end
  return true
end

---@param opts? {max_frame?: integer, on_value?: fun(value: unknown, frame_bytes: integer)}
---@return Neoagent.FrameDecoder
function M.new(opts)
  opts = opts or {}
  local maximum = opts.max_frame or DEFAULT_MAX_FRAME
  assert(type(maximum) == "number" and maximum > 0 and maximum % 1 == 0, "maximum frame must be positive")
  return setmetatable({
    _header = "",
    _payload = {},
    _received = 0,
    _max_frame = maximum,
    _on_value = opts.on_value or function() end,
  }, Decoder)
end

M.MAX_FRAME = DEFAULT_MAX_FRAME
return M
