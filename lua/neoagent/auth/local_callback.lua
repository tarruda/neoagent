local async = require("neoagent.async")

local M = {}

---@class Neoagent.CallbackRequest
---@field method string
---@field target string
---@field headers table<string, string>
---@field body string

---@class Neoagent.CallbackResponse<T>
---@field status integer
---@field body? string
---@field headers? table<string, unknown>
---@field done? boolean
---@field value? T

---@class Neoagent.CallbackOptions<T>
---@field host? string
---@field port? integer
---@field max_request_bytes? integer
---@field timeout_ms? number
---@field handler fun(request: Neoagent.CallbackRequest): Neoagent.CallbackResponse<T>

---@class Neoagent.CallbackListener<T>
---@field port integer
---@field wait async fun(): T?
---@field close fun(): boolean

---@class Neoagent.CallbackCompleted<T>
---@field ok true
---@field value? T

---@alias Neoagent.CallbackPending<T> Neoagent.CallbackCompleted<T>|Neoagent.AsyncFailure

local reasons = {
  [200] = "OK",
  [204] = "No Content",
  [400] = "Bad Request",
  [404] = "Not Found",
  [413] = "Payload Too Large",
  [500] = "Internal Server Error",
}

---@param handle? uv.uv_handle_t
local function close_handle(handle)
  if handle and not handle:is_closing() then handle:close() end
end

---@param value? table<string, unknown>
---@return table<string, string>
local function safe_headers(value)
  local result = {}
  for name, item in pairs(value or {}) do
    if type(name) == "string" and name:match("^[%w-]+$")
        and type(item) == "string"
        and not item:find("[\r\n]") then
      result[name] = item
    end
  end
  return result
end

---@generic T
---@param response Neoagent.CallbackResponse<T>
---@return string
local function response_text(response)
  local selected = type(response) == "table" and response or {}
  local status = reasons[selected.status] and selected.status or 500
  local body = type(selected.body) == "string" and selected.body or ""
  local headers = safe_headers(selected.headers)
  headers["Content-Length"] = tostring(#body)
  headers.Connection = "close"
  if body ~= "" and headers["Content-Type"] == nil then
    headers["Content-Type"] = "text/plain; charset=utf-8"
  end
  local names = vim.tbl_keys(headers)
  table.sort(names, function(left, right)
    return left:lower() < right:lower()
  end)
  local lines = {
    "HTTP/1.1 " .. tostring(status) .. " " .. reasons[status],
  }
  for _, name in ipairs(names) do
    lines[#lines + 1] = name .. ": " .. headers[name]
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  return table.concat(lines, "\r\n")
end

---@param buffer string
---@param maximum integer
---@return Neoagent.CallbackRequest|false|nil, "large"|"malformed"?
local function parsed_request(buffer, maximum)
  if #buffer > maximum then return nil, "large" end
  local header_end = buffer:find("\r\n\r\n", 1, true)
  local separator = 4
  if not header_end then
    header_end = buffer:find("\n\n", 1, true)
    separator = 2
  end
  if not header_end then return false end
  local head = buffer:sub(1, header_end - 1):gsub("\r\n", "\n")
  local first, rest = head:match("^([^\n]+)\n?(.*)$")
  local method, target
  if first then
    method, target = first:match(
      "^([A-Z]+)%s+(%S+)%s+HTTP/%d+%.%d+$")
  end
  if not method or not target or #target > 8192 then return nil, "malformed" end
  local headers = {}
  for line in (rest or ""):gmatch("[^\n]+") do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    name = name and name:lower() or nil
    if not name or not name:match("^[%w-]+$")
        or headers[name] ~= nil then
      return nil, "malformed"
    end
    headers[name] = value
  end
  if headers["transfer-encoding"] ~= nil then
    return nil, "malformed"
  end
  local length_text = headers["content-length"] or "0"
  if not length_text:match("^%d+$") then return nil, "malformed" end
  local length = tonumber(length_text)
  if not length or length > maximum
      or header_end - 1 + separator + length > maximum then
    return nil, "large"
  end
  ---@cast length integer
  local body_start = header_end + separator
  if #buffer < body_start - 1 + length then return false end
  return {
    method = method,
    target = target,
    headers = headers,
    body = buffer:sub(body_start, body_start + length - 1),
  }
end

---@generic T
---@param opts Neoagent.CallbackOptions<T>
---@param new_connection fun(): uv.uv_tcp_t
---@return Neoagent.CallbackListener<T>?, string?
function M._listen(opts, new_connection)
  opts = opts or {}
  assert(type(opts.handler) == "function",
    "local callback handler is required")
  local host = opts.host or "127.0.0.1"
  local port = opts.port or 0
  local maximum = opts.max_request_bytes or 65536
  local timeout_ms = opts.timeout_ms
  assert(type(host) == "string" and host ~= "",
    "local callback host is required")
  assert(type(port) == "number" and port >= 0 and port <= 65535
      and port % 1 == 0, "local callback port is invalid")
  assert(type(maximum) == "number" and maximum >= 1024
      and maximum % 1 == 0,
    "local callback max_request_bytes must be an integer of at least 1024")
  assert(timeout_ms == nil or type(timeout_ms) == "number"
      and timeout_ms > 0 and timeout_ms < math.huge,
    "local callback timeout_ms must be positive and finite")

  local listener = new_connection()
  local bound, bind_err = listener:bind(host, port)
  if not bound then close_handle(listener) return nil, bind_err end
  local address, address_err = listener:getsockname()
  if not address then close_handle(listener) return nil, address_err end

  ---@type table<uv.uv_tcp_t, true>
  local clients = {}
  ---@type Neoagent.CallbackPending<T>?
  local pending
  ---@type Neoagent.AwaitCallbacks<T?>?
  local waiter
  ---@type uv.uv_timer_t?
  local timer
  local closed = false

  ---@param close_clients boolean
  ---@return boolean
  local function close(close_clients)
    local changed = not closed
    if changed then
      closed = true
      if timer then
        timer:stop()
        close_handle(timer)
        timer = nil
      end
      close_handle(listener)
    end
    if close_clients then
      for client in pairs(clients) do close_handle(client) end
    end
    return changed
  end

  ---@param result Neoagent.CallbackPending<T>
  local function complete(result)
    if pending then return end
    pending = result
    close(false)
    if waiter then
      if result.ok then waiter.resolve(result.value)
      else waiter.reject(result.error) end
    end
  end

  local listened, listen_err = listener:listen(16, function(accept_err)
    if accept_err or closed then return end
    local client = new_connection()
    if not listener:accept(client) then close_handle(client) return end
    clients[client] = true
    local buffer = ""
    local handled = false
    ---@param response Neoagent.CallbackResponse<T>
    local function finish_client(response)
      if handled then return end
      handled = true
      client:read_stop()
      client:write(response_text(response), function()
        clients[client] = nil
        close_handle(client)
        if response.done then complete({ ok = true, value = response.value }) end
      end)
    end
    client:read_start(function(read_err, chunk)
      if handled then return end
      if read_err then
        clients[client] = nil
        close_handle(client)
        return
      end
      if chunk then buffer = buffer .. chunk end
      local request, parse_err = parsed_request(buffer, maximum)
      if request == false and chunk ~= nil then return end
      if not request then
        finish_client({
          status = parse_err == "large" and 413 or 400,
          body = parse_err == "large" and "request too large\n"
            or "malformed request\n",
        })
        return
      end
      local ok, response = pcall(opts.handler, request)
      if not ok or type(response) ~= "table" then
        finish_client({ status = 500, body = "callback failed\n" })
        return
      end
      ---@cast response Neoagent.CallbackResponse<T>
      finish_client(response)
    end)
  end)
  if not listened then close_handle(listener) return nil, listen_err end

  if timeout_ms then
    timer = assert(vim.uv.new_timer())
    timer:start(math.floor(timeout_ms), 0, function()
      complete({ ok = false, error = {
        kind = "auth",
        message = "Browser authentication timed out",
      } })
    end)
  end

  return {
    port = address.port,
    ---@async
    wait = function()
      return async.await(function(done)
        waiter = done
        if pending then
          if pending.ok then done.resolve(pending.value)
          else done.reject(pending.error) end
        end
        return function() close(true) end
      end)
    end,
    close = function() return close(true) end,
  }
end

---@generic T
---@param opts Neoagent.CallbackOptions<T>
---@return Neoagent.CallbackListener<T>?, string?
function M.listen(opts)
  return M._listen(opts, function() return (assert(vim.uv.new_tcp())) end)
end

return M
