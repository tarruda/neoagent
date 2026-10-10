local async = require("neoagent.async")
local util = require("neoagent.util")
local waiting = require("neoagent.files.wait")
local transport_failure = require("neoagent.transport.failure")
local M = {}

local metadata_retry = {
  proxy_dns = true,
  dns = true,
  connection = true,
  http2 = true,
  incomplete_response = true,
  timeout = true,
  empty_response = true,
  send = true,
  receive = true,
}

---@param value unknown
---@param minimum integer
---@param maximum integer
---@return integer?
local function bounded_code(value, minimum, maximum)
  if type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0 then
    return math.floor(value)
  end
end

---@param result Neoagent.HttpResult
---@return integer?
function M.status(result)
  if result.ok then
    return bounded_code(result.status, 100, 599)
  end
  local response = rawget(result.error, "response")
  return bounded_code(type(response) == "table" and rawget(response, "status") or nil, 100, 599)
end

---@class Neoagent.FileHttpError: Neoagent.Error
---@field status? integer
---@field exit_code? integer

---@param result Neoagent.HttpResult
---@param label string
---@return Neoagent.JsonValue?
function M.checked(result, label)
  local status = M.status(result)
  if result.ok and status and status >= 200 and status < 300 then
    return result.body
  end
  if result.ok == false and result.error.kind == "cancelled" then
    error(util.copy(async.cancelled_error), 0)
  end
  ---@type Neoagent.FileHttpError
  local err = util.error("files", label .. " request failed" .. (status and " (HTTP " .. status .. ")" or ""))
  err.status = status
  if result.ok == false and (not status or status < 400) then
    -- File preparation owns transport retries. Inference recovery must not
    -- repeat an upload or restart an exhausted metadata-read budget. HTTP
    -- rejections retain the existing request-level recovery policy.
    err.retryable = false
    local failure = transport_failure.classify(result.error)
    if failure then
      err.code = failure.code
      err.exit_code = failure.exit_code
      err.message = err.message .. ": " .. failure.message
    elseif result.error.kind == "protocol" then
      err.code = "protocol"
      err.message = err.message .. ": Invalid HTTP response"
    end
  end
  error(err, 0)
end

---@param message string
---@return Neoagent.Error
local function terminal_error(message)
  local err = util.error("files", message)
  err.retryable = false
  return err
end

---@async
---@param delay integer
local function pause(delay)
  async.await(function(done)
    local timer = vim.uv.new_timer()
    if not timer then
      error(terminal_error("Could not create file retry timer"), 0)
    end
    local function close()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    vim.uv.update_time()
    local ok, started = pcall(timer.start, timer, delay, 0, function()
      close()
      done.resolve(true)
    end)
    if not ok or not started then
      close()
      error(terminal_error("Could not start file retry timer"), 0)
    end
    return close
  end)
end

-- Only metadata GETs retry. Every attempt and backoff shares one deadline;
-- uploads, HTTP rejections and malformed responses keep their own outcomes.
---@async
---@param client Neoagent.HttpClient
---@param request Neoagent.HttpRequest
---@param timeout_ms integer
---@return Neoagent.HttpResult
function M.get(client, request, timeout_ms)
  assert(request.method == "GET", "file retries require a metadata GET")
  local deadline = waiting.now() + timeout_ms
  request = util.copy(request)
  local attempt = 0
  ---@type Neoagent.HttpResult?
  local result
  while true do
    local remaining = math.floor(deadline - waiting.now())
    if remaining <= 0 then
      if result then
        return result
      end
      error(terminal_error("Image preparation timed out"), 0)
    end
    request.timeout_ms = remaining
    result = client.fetch({ request = request }):await()
    attempt = attempt + 1
    if result.ok then
      return result
    end
    local err = result.error
    local failure = transport_failure.classify(err)
    local status = M.status(result)
    if
      not failure
      or not metadata_retry[failure.code]
      or err.retryable == false
      or status and status >= 400
      or attempt >= 3
    then
      return result
    end
    local delay = 250 * attempt
    if waiting.now() + delay >= deadline then
      return result
    end
    pause(delay)
  end
end

return M
