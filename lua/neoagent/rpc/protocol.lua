local framing = require("neoagent.ipc.framing")
local limits = require("neoagent.rpc.limits")
local util = require("neoagent.util")

local M = {}

M.MARKER = "neoagent-rpc/7/2026-09-19"
M.MAX_FRAME = 1024 * 1024
M.MAX_REQUEST_CHUNK = 256 * 1024
M.MAX_REQUEST = limits.MAX_REQUEST_BYTES
M.MAX_ERROR_BYTES = 4096
M.MAX_QUEUED_BYTES = limits.MAX_QUEUED_BYTES

---@param value unknown
---@return boolean
local function object(value)
  return type(value) == "table" and (next(value) == nil or not util.is_list(value))
end

---@param value table
---@param allowed table<string, boolean>
---@param label string
local function exact(value, allowed, label)
  for key in pairs(value) do
    if type(key) ~= "string" or allowed[key] == nil then
      error(label .. " has an unknown field", 0)
    end
  end
  for key, required in pairs(allowed) do
    if required and rawget(value, key) == nil then
      error(label .. " is missing " .. key, 0)
    end
  end
end

---@param value unknown
---@param label string
---@param maximum? integer
---@return string
local function text(value, label, maximum)
  maximum = maximum or 256
  if type(value) ~= "string" or value == "" or #value > maximum or not util.is_valid_utf8(value) then
    error(label .. " must be bounded UTF-8 text", 0)
  end
  return value
end

---@param value unknown
---@param label string
---@return integer
local function positive_id(value, label)
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 or value > 9007199254740991 then
    error(label .. " must be a positive integer", 0)
  end
  ---@cast value integer
  return value
end

---@param value unknown
---@param label string
---@param maximum? integer
---@return string
local function identifier(value, label, maximum)
  local selected = text(value, label, maximum or 128)
  if selected:find("[^A-Za-z0-9_.:-]") then
    error(label .. " is invalid", 0)
  end
  return selected
end

---@param value unknown
---@param label string
---@return Neoagent.JsonObject
local function payload(value, label)
  if not object(value) then
    error(label .. " must be an object", 0)
  end
  return util.copy(value) --[[@as Neoagent.JsonObject]]
end

---@param value unknown
---@return {kind: string, code?: string, message: string, detail?: string}
function M.error(value)
  if not object(value) then
    error("RPC error must be an object", 0)
  end
  ---@cast value table
  exact(value, { kind = true, code = false, message = true, detail = false }, "RPC error")
  local result = {
    kind = identifier(value.kind, "RPC error kind", 64),
    message = text(value.message, "RPC error message", M.MAX_ERROR_BYTES),
  }
  if value.code ~= nil then
    result.code = identifier(value.code, "RPC error code", 128)
  end
  if value.detail ~= nil then
    result.detail = text(value.detail, "RPC error detail", M.MAX_ERROR_BYTES)
  end
  return result
end

local allowed = {
  ready = { type = true, marker = true },
  open = { type = true, call_id = true, context = true },
  opened = { type = true, call_id = true },
  request = { type = true, call_id = true, request_id = true, method = true, payload = true },
  request_begin = { type = true, call_id = true, request_id = true, method = true, bytes = true },
  request_chunk = { type = true, call_id = true, request_id = true, data = true },
  request_end = { type = true, call_id = true, request_id = true },
  event = {
    type = true,
    call_id = true,
    request_id = false,
    sequence = true,
    name = true,
    value = true,
  },
  response = { type = true, call_id = true, request_id = true, value = true },
  request_error = { type = true, call_id = true, request_id = true, error = true },
  cancel = { type = true, call_id = true, request_id = true },
  cancelled = { type = true, call_id = true, request_id = true },
  close = { type = true, call_id = true },
  closed = { type = true, call_id = true },
}

---@param value unknown
---@return table
function M.validate(value)
  if not object(value) or type(value.type) ~= "string" or not allowed[value.type] then
    error("invalid RPC message", 0)
  end
  ---@cast value table
  local kind = value.type
  local fields = assert(allowed[kind])
  exact(value, fields, "RPC " .. kind)
  if kind == "ready" then
    text(value.marker, "RPC marker", 256)
  else
    value.call_id = identifier(value.call_id, "RPC call ID")
  end
  if kind == "request" or kind:find("^request_") or kind == "response"
      or kind == "request_error" or kind == "cancel" or kind == "cancelled" then
    value.request_id = positive_id(value.request_id, "RPC request ID")
  end
  if kind == "open" then
    payload(value.context, "RPC context")
  elseif kind == "request" then
    value.method = identifier(value.method, "RPC method")
    payload(value.payload, "RPC payload")
  elseif kind == "request_begin" then
    value.method = identifier(value.method, "RPC method")
    local bytes = positive_id(value.bytes, "RPC request size")
    if bytes > M.MAX_REQUEST then
      error("RPC request exceeds the byte limit", 0)
    end
  elseif kind == "request_chunk" then
    if type(value.data) ~= "string" or value.data == "" or #value.data > M.MAX_REQUEST_CHUNK then
      error("RPC request chunk is invalid", 0)
    end
  elseif kind == "event" then
    if value.request_id ~= nil then
      value.request_id = positive_id(value.request_id, "RPC request ID")
    end
    value.sequence = positive_id(value.sequence, "RPC event sequence")
    value.name = identifier(value.name, "RPC event name")
    payload(value.value, "RPC event value")
  elseif kind == "response" then
    payload(value.value, "RPC response value")
  elseif kind == "request_error" then
    M.error(value.error)
  end
  return util.copy(value)
end

---@param value table
---@return string
function M.encode(value)
  return framing.encode(M.validate(value), M.MAX_FRAME)
end

---@param on_message fun(message: table)
---@return Neoagent.FrameDecoder
function M.decoder(on_message)
  return framing.new({
    max_frame = M.MAX_FRAME,
    on_value = function(value)
      on_message(M.validate(value))
    end,
  })
end

return M
