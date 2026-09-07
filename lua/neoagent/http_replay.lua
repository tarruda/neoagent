local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}

local function bytes(record, structured)
  assert(not record.redacted, "Recording body is masked; supply a synthetic adaptation")
  if record.body_encoding == "base64" then return vim.base64.decode(record.body) end
  assert(record.body_encoding == nil, "Unsupported recording body encoding")
  if structured and record.body_format == "json" or type(record.body) == "table" then
    return util.json_encode(record.body), true
  end
  assert(record.body == nil or type(record.body) == "string", "Invalid recording body")
  return record.body or ""
end

local function validate_headers(value)
  assert(value == nil or type(value) == "table", "Invalid recording headers")
  for key, item in pairs(value or {}) do
    assert(type(key) == "string" and type(item) == "string", "Invalid recording headers")
  end
end

function M.read(path)
  local content = assert(fs.read(path))
  local yaml = path:match("%.ya?ml$") ~= nil
  if yaml then
    local result = vim.system({ "yq", "-o=json", "-I=0", ".", path }, { text = true }):wait(10000)
    assert(result.code == 0, "Cannot import YAML recording; check it with yq v4")
    content = result.stdout
  end
  local events = {}
  for line in content:gmatch("[^\n]+") do
    local ok, event = pcall(vim.json.decode, line)
    assert(ok and type(event) == "table", "Invalid recording JSON")
    events[#events + 1] = event
  end
  local first = events[1]
  assert(first and first.schema == "neoagent-http-recording" and first.version == 1
    and first.type == "exchange", "Unsupported HTTP recording")
  assert(type(first.request) == "table" and type(first.request.method) == "string"
    and type(first.request.url) == "string", "Recording request is missing method or URL")
  validate_headers(first.request.headers)
  local exchange = { request = util.copy(first.request), chunks = {}, context = first.context }
  local body, structural, terminal, response
  local previous = 0
  for index = 2, #events do
    local event = events[index]
    assert(type(event.at_us) == "number" and event.at_us >= previous
      and event.at_us < math.huge and event.at_us % 1 == 0,
      "Recording timestamps must be ordered")
    previous = event.at_us
    if event.type == "response_chunk" then
      assert(not body and event.index == #exchange.chunks + 1
        and type(event.bytes) == "number" and event.bytes >= 0 and event.bytes % 1 == 0,
        "Invalid recording chunk sequence")
      exchange.chunks[#exchange.chunks + 1] = { bytes = event.bytes, at_us = event.at_us }
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
  for _, chunk in ipairs(exchange.chunks) do
    chunk.data = body:sub(offset, offset + chunk.bytes - 1)
    offset = offset + chunk.bytes
  end
  if structural then
    -- YAML preserves JSON values, not their original serialization or cuts.
    exchange.chunks = { { data = body, bytes = #body, at_us = terminal.at_us } }
  else
    assert(offset - 1 == #body, "Recording chunk lengths do not match the body")
  end
  exchange.request.body = first.request.body ~= nil and bytes(first.request, yaml) or nil
  exchange.structural = structural == true
  exchange.response, exchange.body, exchange.terminal = response, body, terminal
  return exchange
end

local function headers(value)
  local result = {}
  for key, item in pairs(value or {}) do result[key:lower()] = item end
  return result
end

local function form(value)
  local result = {}
  for pair in (value or ""):gmatch("[^&]+") do
    local key, item = pair:match("^([^=]+)=(.*)$")
    if not key then return nil end
    local function decode(text) return vim.uri_decode((text:gsub("+", " "))) end
    key, item = decode(key), decode(item)
    if result[key] ~= nil then return nil end
    result[key] = item
  end
  return result
end

local function body_value(request)
  local content_type = headers(request.headers)["content-type"] or ""
  if content_type:find("application/x-www-form-urlencoded", 1, true) then
    return form(request.body) or request.body
  end
  if request.body == nil then return nil end
  local ok, value = pcall(vim.json.decode, request.body)
  if ok then return value end
  return request.body
end

local function normalized_url(url)
  return (url:gsub("%%(%x%x)", function(hex) return "%" .. hex:upper() end))
end

local function equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  -- vim.deep_equal treats empty JSON objects and arrays as equal.
  if vim.islist(left) ~= vim.islist(right) then return false end
  for key, value in pairs(left) do
    if not equal(value, right[key]) then return false end
  end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

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

local function tick(milliseconds)
  return async.await(function(done)
    local active = true
    local function ready() if active then done.resolve(true) end end
    local timer
    if milliseconds and milliseconds > 0 then
      timer = vim.uv.new_timer()
      timer:start(milliseconds, 0, function()
        timer:stop(); timer:close(); timer = nil
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

function M.new(opts)
  opts = opts or {}
  local entries, signals, waiters, runs, failures = {}, {}, {}, {}, {}
  local timeout_ms = opts.timeout_ms or 5000
  assert(type(timeout_ms) == "number" and timeout_ms > 0 and timeout_ms < math.huge,
    "Replay timeout must be positive and finite")
  local ids = {}
  local replay = { requests = {} }
  for index, value in ipairs(assert(opts.exchanges, "Replay exchanges are required")) do
    local entry = type(value) == "string" and { path = value } or util.copy(value)
    entry.id = entry.id or tostring(index)
    assert(type(entry.id) == "string" and not ids[entry.id], "Replay exchange IDs must be unique strings")
    ids[entry.id] = true
    entry.exchange = entry.exchange or M.read(entry.path)
    entries[#entries + 1] = entry
  end

  function replay.release(signal)
    signals[signal] = true
    for wake in pairs(waiters) do wake() end
  end

  local function barrier(required)
    if not required then return end
    async.await(function(done)
      local timer = vim.uv.new_timer()
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
      timer:start(timeout_ms, 0, function()
        cleanup()
        failures[#failures + 1] = "Replay dependency timed out"
        done.reject(util.error("replay", "Replay dependency timed out"))
      end)
      waiters[wake] = true
      wake()
      return cleanup
    end)
  end

  local function perform(operation, call)
    local entry, differences = nil, {}
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
          if operation == "request" and call.on_chunk then call.on_chunk(chunk.data) end
          replay.release(entry.id .. ":chunk:" .. index)
        end
        barrier(entry.finish_after)
        if entry.open then barrier({ entry.id .. ":close" }) end
        tick(opts.timing and math.max(0, (exchange.terminal.at_us - previous) / 1000) or nil)
      end)
      replay.release(entry.id .. ":complete")
      if not ok then
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
      if operation == "fetch" then
        return { ok = true, body = exchange.body, status = exchange.response.status,
          headers = util.copy(exchange.response.headers) }
      end
      return { ok = true, response = util.copy(exchange.response) }
    end, { on_done = call.on_done, error_kind = "replay" })
    runs[#runs + 1] = run
    return run
  end

  replay.request = function(call) return perform("request", call) end
  replay.fetch = function(call) return perform("fetch", call) end
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
