local M = {}

local Parser = {}
Parser.__index = Parser

local function dispatch(self)
  if #self.data == 0 then
    return true
  end
  local value = table.concat(self.data, "\n")
  self.data = {}
  self.data_bytes = 0
  self.on_event(value)
  return true
end

local function consume_line(self, line)
  if line == "" then
    return dispatch(self)
  end
  if line:sub(1, 1) == ":" then
    return true
  end
  local field, value = line:match("^([^:]+):?(.*)$")
  if field == "data" then
    if value:sub(1, 1) == " " then
      value = value:sub(2)
    end
    local next_bytes = self.data_bytes + #value
      + (#self.data > 0 and 1 or 0)
    if next_bytes > self.max_event_bytes then
      self.error = "SSE event exceeded " .. self.max_event_bytes .. " bytes"
      return nil, self.error
    end
    self.data[#self.data + 1] = value
    self.data_bytes = next_bytes
  end
  return true
end

function Parser:feed(chunk)
  if self.closed then
    return nil, "SSE parser is closed"
  end
  if self.error then return nil, self.error end
  self.pending = self.pending .. (chunk or "")
  if #self.pending > self.max_buffer then
    self.error = "SSE pending buffer exceeded " .. self.max_buffer .. " bytes"
    return nil, self.error
  end
  while true do
    local start_pos, end_pos = self.pending:find("\r?\n")
    if not start_pos then
      break
    end
    local line = self.pending:sub(1, start_pos - 1)
    self.pending = self.pending:sub(end_pos + 1)
    local consumed, err = consume_line(self, line)
    if not consumed then return nil, err end
  end
  return true
end

function Parser:finish()
  if self.closed then
    if self.error then return nil, self.error end
    return true
  end
  self.closed = true
  if self.error then return nil, self.error end
  if self.pending ~= "" then
    local consumed, err = consume_line(self, self.pending)
    self.pending = ""
    if not consumed then return nil, err end
  end
  return dispatch(self)
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.on_event) == "function", "SSE parser requires on_event")
  local max_buffer = opts.max_buffer or 1024 * 1024
  local max_event_bytes = opts.max_event_bytes or max_buffer
  assert(type(max_buffer) == "number" and max_buffer > 0
    and max_buffer % 1 == 0, "SSE max_buffer must be a positive integer")
  assert(type(max_event_bytes) == "number" and max_event_bytes > 0
    and max_event_bytes % 1 == 0,
    "SSE max_event_bytes must be a positive integer")
  return setmetatable({
    on_event = opts.on_event,
    max_buffer = max_buffer,
    max_event_bytes = max_event_bytes,
    pending = "",
    data = {},
    data_bytes = 0,
    closed = false,
  }, Parser)
end

return M
