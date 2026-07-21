local M = {}

local Parser = {}
Parser.__index = Parser

local function dispatch(self)
  if #self.data == 0 then
    return
  end
  local value = table.concat(self.data, "\n")
  self.data = {}
  self.on_event(value)
end

local function consume_line(self, line)
  if line == "" then
    dispatch(self)
    return
  end
  if line:sub(1, 1) == ":" then
    return
  end
  local field, value = line:match("^([^:]+):?(.*)$")
  if field == "data" then
    if value:sub(1, 1) == " " then
      value = value:sub(2)
    end
    self.data[#self.data + 1] = value
  end
end

function Parser:feed(chunk)
  if self.closed then
    return nil, "SSE parser is closed"
  end
  self.pending = self.pending .. (chunk or "")
  if #self.pending > self.max_buffer then
    return nil, "SSE pending buffer exceeded " .. self.max_buffer .. " bytes"
  end
  while true do
    local start_pos, end_pos = self.pending:find("\r?\n")
    if not start_pos then
      break
    end
    local line = self.pending:sub(1, start_pos - 1)
    self.pending = self.pending:sub(end_pos + 1)
    consume_line(self, line)
  end
  return true
end

function Parser:finish()
  if self.closed then
    return true
  end
  self.closed = true
  if self.pending ~= "" then
    consume_line(self, self.pending)
    self.pending = ""
  end
  dispatch(self)
  return true
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.on_event) == "function", "SSE parser requires on_event")
  return setmetatable({
    on_event = opts.on_event,
    max_buffer = opts.max_buffer or 1024 * 1024,
    pending = "",
    data = {},
    closed = false,
  }, Parser)
end

return M
