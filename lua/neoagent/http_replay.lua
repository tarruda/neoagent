local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

---@class Neoagent.RecordedBody
---@field body? Neoagent.JsonValue
---@field body_encoding? string
---@field body_format? string
---@field redacted? boolean

---@class Neoagent.RecordedRequest: Neoagent.RecordedBody
---@field method string
---@field url string
---@field headers? table<string, string>

---@class Neoagent.RecordedExchange
---@field type 'exchange'
---@field schema string
---@field version integer
---@field request Neoagent.RecordedRequest
---@field context? Neoagent.JsonValue
---@field at_us? integer

---@class Neoagent.RecordedChunk
---@field type 'response_chunk'
---@field at_us integer
---@field index integer
---@field bytes integer

---@class Neoagent.RecordedResponseBody: Neoagent.RecordedBody
---@field type 'response_body'
---@field at_us integer
---@field bytes integer

---@class Neoagent.RecordedResponse: Neoagent.HttpMetadata
---@field type 'response'
---@field at_us integer

---@class Neoagent.RecordedCompletion
---@field type 'complete'
---@field at_us integer
---@field ok boolean
---@field error? Neoagent.HttpError

---@alias Neoagent.RecordedEvent Neoagent.RecordedExchange|Neoagent.RecordedChunk|Neoagent.RecordedResponseBody|Neoagent.RecordedResponse|Neoagent.RecordedCompletion

---@class Neoagent.ReplayChunk
---@field bytes integer
---@field at_us integer
---@field data string

---@class Neoagent.ReplayExchange
---@field request Neoagent.HttpRequest
---@field chunks Neoagent.ReplayChunk[]
---@field context? Neoagent.JsonValue
---@field structural boolean
---@field response Neoagent.HttpMetadata
---@field body string
---@field terminal Neoagent.RecordedCompletion

---@class Neoagent.ReplayEntryOptions
---@field path? string
---@field exchange? Neoagent.ReplayExchange
---@field id? string
---@field headers_subset? boolean
---@field body_subset? boolean
---@field body_exact? boolean
---@field after? string[]
---@field gates? table<string, string[]>
---@field finish_after? string[]
---@field open? boolean

---@class Neoagent.ReplayEntry: Neoagent.ReplayEntryOptions
---@field id string
---@field exchange Neoagent.ReplayExchange
---@field used? boolean

---@class Neoagent.ReplayOptions
---@field exchanges? (string|Neoagent.ReplayEntryOptions)[]
---@field timeout_ms? integer
---@field timing? boolean

---@class Neoagent.ReplayCall<T>
---@field request Neoagent.HttpRequest
---@field on_chunk? fun(chunk: string)
---@field on_done? fun(result: T|Neoagent.AsyncFailure)

local M = {}

---@param record Neoagent.RecordedBody
---@param structured? boolean
---@return string
---@return boolean? structural
local function bytes(record, structured)
  assert(not record.redacted, "Recording body is masked; supply a synthetic adaptation")
  if record.body_encoding == "base64" then
    assert(type(record.body) == "string", "Invalid recording body")
    return vim.base64.decode(record.body)
  end
  assert(record.body_encoding == nil, "Unsupported recording body encoding")
  if structured and record.body_format == "json" or type(record.body) == "table" then
    return util.json_encode(record.body), true
  end
  assert(record.body == nil or type(record.body) == "string", "Invalid recording body")
  return record.body or ""
end

---@param value unknown
local function validate_headers(value)
  assert(value == nil or type(value) == "table", "Invalid recording headers")
  for key, item in pairs(value or {}) do
    assert(type(key) == "string" and type(item) == "string", "Invalid recording headers")
  end
end

---@param path string
---@return Neoagent.ReplayExchange
function M.read(path)
  local content = assert(fs.read(path))
  local yaml = path:match("%.ya?ml$") ~= nil
  if yaml then
    local result = vim.system({ "yq", "-o=json", "-I=0", ".", path }, { text = true }):wait(10000)
    assert(result.code == 0, "Cannot import YAML recording; check it with yq v4")
    content = assert(result.stdout)
  end
  ---@type Neoagent.RecordedEvent[]
  local events = {}
  for line in content:gmatch("[^\n]+") do
    local ok, event = pcall(vim.json.decode, line)
    assert(ok and type(event) == "table", "Invalid recording JSON")
    -- The checks below validate the protocol fields before they are consumed.
    events[#events + 1] = event --[[@as Neoagent.RecordedEvent]]
  end
  local first = events[1]
  assert(first and first.type == "exchange"
    and first.schema == "neoagent-http-recording" and first.version == 1, "Unsupported HTTP recording")
  assert(type(first.request) == "table" and type(first.request.method) == "string"
    and type(first.request.url) == "string", "Recording request is missing method or URL")
  validate_headers(first.request.headers)
  ---@type {bytes: integer, at_us: integer}[]
  local cuts = {}
  ---@type string?
  local body
  ---@type boolean?
  local structural
  ---@type Neoagent.RecordedCompletion?
  local terminal
  ---@type Neoagent.HttpMetadata?
  local response
  local previous = 0
  for index = 2, #events do
    local event = assert(events[index])
    assert(type(event.at_us) == "number" and event.at_us >= previous
      and event.at_us < math.huge and event.at_us % 1 == 0,
      "Recording timestamps must be ordered")
    previous = event.at_us
    if event.type == "response_chunk" then
      assert(not body and event.index == #cuts + 1
        and type(event.bytes) == "number" and event.bytes >= 0 and event.bytes % 1 == 0,
        "Invalid recording chunk sequence")
      cuts[#cuts + 1] = { bytes = event.bytes, at_us = event.at_us }
    elseif event.type == "response_body" then
      assert(not body, "Duplicate recording body")
      body, structural = bytes(event, yaml)
      assert(structural or event.bytes == #body, "Recording body length mismatch")
    elseif event.type == "response" then
      assert(not response, "Duplicate recording response")
      assert(event.status == nil or type(event.status) == "number"
        and event.status >= 0 and event.status <= 599 and event.status % 1 == 0,
        "Invalid recording status")
      validate_headers(event.headers)
      response = { status = event.status, headers = event.headers or {} }
    elseif event.type == "complete" then
      assert(index == #events and type(event.ok) == "boolean", "Invalid recording completion")
      assert(event.ok or type(event.error) == "table" and type(event.error.kind) == "string",
        "Failed recording requires an error")
      terminal = event
    else
      error("Unknown recording event")
    end
  end
  assert(body and response and terminal, "Incomplete recording; body, response and completion are required")
  assert(not terminal.ok or response.status and response.status >= 100, "Successful recording requires HTTP status")
  local offset = 1
  ---@type Neoagent.ReplayChunk[]
  local chunks = {}
  for _, chunk in ipairs(cuts) do
    chunks[#chunks + 1] = { bytes = chunk.bytes, at_us = chunk.at_us,
      data = body:sub(offset, offset + chunk.bytes - 1) }
    offset = offset + chunk.bytes
  end
  if structural then
    -- YAML preserves JSON values, not their original serialization or cuts.
    chunks = { { data = body, bytes = #body, at_us = terminal.at_us } }
  else
    assert(offset - 1 == #body, "Recording chunk lengths do not match the body")
  end
  local request = util.copy(first.request)
  request.body = first.request.body ~= nil and bytes(first.request, yaml) or nil
  return {
    request = request --[[@as Neoagent.HttpRequest]],
    chunks = chunks, context = util.copy(first.context), structural = structural == true,
    response = response, body = body, terminal = terminal,
  }
end

---@param value? table<string, unknown>
---@return table<string, unknown>
local function headers(value)
  local result = {}
  for key, item in pairs(value or {}) do result[key:lower()] = item end
  return result
end

---@param value? string
---@return table<string, string>?
local function form(value)
  local result = {}
  for pair in (value or ""):gmatch("[^&]+") do
    local key, item = pair:match("^([^=]+)=(.*)$")
    if not key then return nil end
    ---@param text string
    ---@return string
    local function decode(text) return vim.uri_decode((text:gsub("+", " "))) end
    key, item = decode(key), decode(assert(item))
    if result[key] ~= nil then return nil end
    result[key] = item
  end
  return result
end

---@param request Neoagent.HttpRequest
---@return unknown
local function body_value(request)
  local content_type = rawget(headers(request.headers), "content-type") or ""
  if type(content_type) == "string" and content_type:find("application/x-www-form-urlencoded", 1, true) then
    return form(request.body) or request.body
  end
  if request.body == nil then return nil end
  local ok, value = pcall(vim.json.decode, request.body)
  if ok then return value end
  return request.body
end

---@param url string
---@return string
local function normalized_url(url)
  return (url:gsub("%%(%x%x)", function(hex) return "%" .. hex:upper() end))
end

---@param left unknown
---@param right unknown
---@return boolean
local function equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" or type(right) ~= "table" then return left == right end
  -- vim.deep_equal treats empty JSON objects and arrays as equal.
  if vim.islist(left) ~= vim.islist(right) then return false end
  for key, value in pairs(left) do
    if not equal(value, right[key]) then return false end
  end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

---@param entry Neoagent.ReplayEntry
---@param request Neoagent.HttpRequest
---@return string?
local function mismatch(entry, request)
  local expected = entry.exchange.request
  if (request.method or "POST") ~= expected.method then return "method" end
  if normalized_url(request.url) ~= normalized_url(expected.url) then return "URL" end
  local actual_headers, wanted_headers = headers(request.headers), headers(expected.headers)
  if entry.headers_subset then
    for key, value in pairs(wanted_headers) do
      if actual_headers[key] ~= value then return "headers" end
    end
  elseif not equal(actual_headers, wanted_headers) then
    return "headers"
  end
  if entry.body_exact then
    if request.body ~= expected.body then return "body" end
    return
  end
  local actual, wanted = body_value(request), body_value(expected)
  if entry.body_subset and wanted ~= nil then
    if type(actual) ~= "table" or type(wanted) ~= "table" then return "body" end
    for key, value in pairs(wanted) do
      if not equal(value, actual[key]) then return "body" end
    end
  elseif not equal(wanted, actual) then
    return "body"
  end
end

---@async
---@param milliseconds? number
local function tick(milliseconds)
  return async.await(
  ---@param done Neoagent.AwaitCallbacks<boolean>
  function(done)
    local active = true
    local function ready() if active then done.resolve(true) end end
    ---@type uv.uv_timer_t?
    local timer
    if milliseconds and milliseconds > 0 then
      timer = assert(vim.uv.new_timer())
      timer:start(math.floor(milliseconds), 0, function()
        assert(timer):stop(); assert(timer):close(); timer = nil
        vim.schedule(ready)
      end)
    else
      vim.schedule(ready)
    end
    return function()
      active = false
      if timer then timer:stop(); timer:close(); timer = nil end
    end
  end)
end

---@param opts? Neoagent.ReplayOptions
---@return Neoagent.HttpReplay
function M.new(opts)
  opts = opts or {}
  ---@type Neoagent.ReplayEntry[]
  local entries = {}
  ---@type table<string, boolean>
  local signals = {}
  ---@type table<fun(), boolean>
  local waiters = {}
  ---@type Neoagent.Run<unknown, unknown>[]
  local runs = {}
  ---@type string[]
  local failures = {}
  local timeout_ms = opts.timeout_ms or 5000
  assert(type(timeout_ms) == "number" and timeout_ms > 0 and timeout_ms < math.huge,
    "Replay timeout must be positive and finite")
  local ids = {}
  ---@class Neoagent.HttpReplay: Neoagent.ByteBackend
  ---@field requests Neoagent.HttpRequest[]
  ---@field request fun(call: Neoagent.ByteStreamOptions): Neoagent.Run<Neoagent.ByteStreamResult, nil>
  ---@field fetch fun(call: Neoagent.ByteFetchOptions): Neoagent.Run<Neoagent.ByteFetchResult, nil>
  local replay = { requests = {} }
  for index, value in ipairs(assert(opts.exchanges, "Replay exchanges are required")) do
    local entry = type(value) == "string" and { path = value } or util.copy(value)
    entry.id = entry.id or tostring(index)
    assert(type(entry.id) == "string" and not ids[entry.id], "Replay exchange IDs must be unique strings")
    ids[entry.id] = true
    entry.exchange = entry.exchange or M.read(assert(entry.path))
    entries[#entries + 1] = entry --[[@as Neoagent.ReplayEntry]]
  end

  ---@param signal string
  function replay.release(signal)
    signals[signal] = true
    for wake in pairs(waiters) do wake() end
  end

  ---@async
  ---@param required? string[]
  local function barrier(required)
    if not required then return end
    async.await(
    ---@param done Neoagent.AwaitCallbacks<boolean>
    function(done)
      ---@type uv.uv_timer_t?
      local timer = assert(vim.uv.new_timer())
      ---@type fun()
      local wake
      local function cleanup()
        waiters[wake] = nil
        if timer then timer:stop(); timer:close(); timer = nil end
      end
      wake = function()
        for _, signal in ipairs(required) do if not signals[signal] then return end end
        cleanup()
        done.resolve(true)
      end
      assert(timer):start(timeout_ms, 0, function()
        cleanup()
        failures[#failures + 1] = "Replay dependency timed out"
        done.reject(util.error("replay", "Replay dependency timed out"))
      end)
      waiters[wake] = true
      wake()
      return cleanup
    end)
  end

  ---@generic T
  ---@param call Neoagent.ReplayCall<T>
  ---@param complete fun(exchange: Neoagent.ReplayExchange): T
  ---@return Neoagent.Run<T, nil>
  local function perform(call, complete)
    ---@type Neoagent.ReplayEntry?
    local entry
    local differences = {}
    for _, candidate in ipairs(entries) do
      if not candidate.used then
        local field = mismatch(candidate, call.request)
        if not field then entry = candidate; break end
        differences[#differences + 1] = candidate.id .. ": " .. field
      end
    end
    if not entry then
      -- Do not include request bodies, URLs, or credentials in failure reports.
      failures[#failures + 1] = "Unexpected HTTP request #" .. (#replay.requests + 1)
        .. (#differences > 0 and " (" .. table.concat(differences, "; ") .. ")" or " (all exchanges consumed)")
      return async.run(function() error(util.error("replay", failures[#failures]), 0) end,
        { on_done = call.on_done, error_kind = "replay" })
    end
    entry.used = true -- Reserve before yielding so concurrent requests cannot reuse it.
    replay.requests[#replay.requests + 1] = util.copy(call.request)
    replay.release(entry.id .. ":request")
    local run = async.run(function()
      barrier(entry.after)
      local exchange, previous = entry.exchange, 0
      local ok, failure = pcall(function()
        for index, chunk in ipairs(exchange.chunks) do
          barrier(entry.gates and entry.gates[tostring(index)])
          tick(opts.timing and math.max(0, (chunk.at_us - previous) / 1000) or nil)
          previous = chunk.at_us
          if call.on_chunk then call.on_chunk(chunk.data) end
          replay.release(entry.id .. ":chunk:" .. index)
        end
        barrier(entry.finish_after)
        if entry.open then barrier({ entry.id .. ":close" }) end
        tick(opts.timing and math.max(0, (exchange.terminal.at_us - previous) / 1000) or nil)
      end)
      replay.release(entry.id .. ":complete")
      if not ok then
        ---@type Neoagent.HttpError
        local err = util.normalize_error(failure, "protocol")
        err.response = util.copy(exchange.response)
        return { ok = false, error = err }
      end
      local error_info = exchange.terminal.error
      if error_info and error_info.kind == "transport" and error_info.exit_code ~= 22 then
        local err = util.copy(error_info)
        err.response = util.copy(exchange.response)
        return { ok = false, error = err }
      end
      if error_info and error_info.kind == "cancelled" then
        local message = "Cancelled recording requires an explicit open stream and caller cancellation"
        failures[#failures + 1] = message
        error(util.error("replay", message), 0)
      end
      return complete(exchange)
    end, { on_done = call.on_done, error_kind = "replay" })
    runs[#runs + 1] = run
    return run
  end

  replay.request = function(call)
    return perform({ request = call.request, on_chunk = call.on_chunk, on_done = call.on_done },
    ---@param exchange Neoagent.ReplayExchange
    ---@return Neoagent.ByteStreamResult
    function(exchange)
      return { ok = true, response = util.copy(exchange.response) }
    end)
  end
  replay.fetch = function(call)
    return perform({ request = call.request, on_done = call.on_done },
    ---@param exchange Neoagent.ReplayExchange
    ---@return Neoagent.ByteFetchResult
    function(exchange)
      return { ok = true, body = exchange.body, status = exchange.response.status,
        headers = util.copy(exchange.response.headers) }
    end)
  end
  function replay.assert_consumed()
    assert(#failures == 0, table.concat(failures, "; "))
    for _, entry in ipairs(entries) do assert(entry.used, "Unused HTTP exchange: " .. entry.id) end
  end
  function replay.close()
    for _, run in ipairs(runs) do run:cancel() end
  end
  return replay
end

return M
