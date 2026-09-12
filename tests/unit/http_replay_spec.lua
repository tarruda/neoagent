local assert = require("luassert")
local replay = require("neoagent.http_replay")
local http = require("neoagent.transport.http")
local util = require("neoagent.util")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@param body? string
local function records(body)
  body = body or 'data: {"text":"héllo"}\r\n\r\ndata: [DONE]\n\n'
  return {
    { schema = "neoagent-http-recording", version = 1, type = "exchange", operation = "request",
      request = { method = "POST", url = "https://api.test/v1", headers = { Authorization = "synthetic" }, body = '{"a":null,"b":[]}' } },
    { type = "response_chunk", index = 1, at_us = 0, bytes = 7 },
    { type = "response_chunk", index = 2, at_us = 10, bytes = #body - 7 },
    { type = "response_body", at_us = 10, bytes = #body, body = body },
    { type = "response", at_us = 10, status = 200, headers = { etag = "v1" } },
    { type = "complete", at_us = 10, ok = true },
  }
end

---@param body string
local function buffered(body)
  local value = records(body)
  value[2].bytes, value[3].bytes = #body, 0
  return value
end

local request = records()[1].request

describe("HTTP recording replay", function()
  ---@type string[]
  local paths = {}
  ---@type Neoagent.HttpReplay[]
  local players = {}
  local system = vim.system
  before_each(function() paths, players, system = {}, {}, vim.system end)
  after_each(function()
    for _, player in ipairs(players) do player.close() end
    for _, path in ipairs(paths) do vim.fn.delete(path) end
    vim.system = system
  end)
  ---@param events unknown[]
  ---@param suffix? string
  ---@return string
  local function write(events, suffix)
    local path = vim.fn.tempname() .. (suffix or ".jsonl")
    assert(paths)[#paths + 1] = path
    local lines = {}
    for _, event in ipairs(events) do lines[#lines + 1] = type(event) == "string" and event or util.json_encode(event) end
    vim.fn.writefile(lines, path)
    return path
  end
  ---@param events unknown[]
  ---@param options? Neoagent.ReplayOptions
  ---@param entry? Neoagent.ReplayEntryOptions
  ---@return Neoagent.HttpReplay
  local function new(events, options, entry)
    options = options or {}
    entry = entry or {}
    entry.path = write(events)
    options.exchanges = { entry }
    local player = replay.new(options)
    assert(players)[#players + 1] = player
    return player
  end

  it("replays exact byte cuts asynchronously through the shared SSE decoder", function()
    local value = records()
    local path = write(value, ".partial.ndjson")
    local exchange = replay.read(path)
    assert.are.equal(value[4].body, assert(exchange.chunks[1]).data .. assert(exchange.chunks[2]).data)
    assert.are.equal(7, #assert(exchange.chunks[1]).data)
    assert.is_false(exchange.structural)
    local player = replay.new({ exchanges = { path } })
    assert(players)[#players + 1] = player
    local events, markers = {}, 0
    local run = http.new(player).stream({ request = request,
      on_event = function(event) events[#events + 1] = event end,
      on_done_marker = function() markers = markers + 1 end,
    })
    assert.are.same({}, events)
    assert.is_false(run:is_done())
    local result = wait(run)
    assert(result.ok)
    assert.are.same({ { text = "héllo" } }, events)
    assert.are.equal(1, markers)
    assert.are.equal("v1", result.headers.etag)
    player.assert_consumed()
    rawset(assert(assert(player.requests[1]).headers), "Authorization", "changed")
    assert.are.equal("synthetic", request.headers.Authorization)
  end)

  it("preserves binary body bytes and structural YAML JSON values", function()
    local body = "\000\255\n"
    local value = buffered(body)
    value[4].body_encoding, value[4].body = "base64", vim.base64.encode(body)
    local player = new(value)
    assert.are.equal(body, wait(player.fetch({ request = request })).body)
    for _, scalar in ipairs({ false, true, 42, vim.NIL, vim.empty_dict(), {} }) do
      local yaml = buffered("original serialization")
      rawset(yaml[4], "body", scalar)
      yaml[4].body_format = "json"
      rawset(yaml[1].request, "body", scalar)
      yaml[1].request.body_format = "json"
      local path = write(yaml, ".yaml")
      vim.system = function(command, opts)
        assert.are.same({ "yq", "-o=json", "-I=0", ".", path }, command)
        assert.is_true(assert(opts).text)
        return { wait = function(_, timeout)
          assert.are.equal(10000, timeout)
          return { code = 0, signal = 0, stdout = table.concat(vim.fn.readfile(path), "\n") }
        end } --[[@as vim.SystemObj]]
      end
      local imported = replay.read(path)
      assert.is_true(imported.structural)
      assert.are.same(scalar, vim.json.decode(imported.body))
      assert.are.same(scalar, vim.json.decode((assert(imported.request.body))))
      assert.are.equal(1, #imported.chunks)
    end
    vim.system = function()
      return { wait = function() return { code = 1, signal = 0, stderr = "private" } end } --[[@as vim.SystemObj]]
    end
    assert.has_error(function() replay.read(write({}, ".yaml")) end,
      "Cannot import YAML recording; check it with yq v4")
  end)

  it("rejects masked, corrupt, unsupported and incomplete recordings before playback", function()
    local cases = {
      { function(v) v[1].request.headers = "invalid" end, "Invalid recording headers" },
      { function(v) v[5].headers = { authorization = 42 } end, "Invalid recording headers" },
      { function(v) v[5].status = "200" end, "Invalid recording status" },
      { function(v) v[5].status = nil end, "Successful recording requires HTTP status" },
      { function(v) v[1].version = 2 end, "Unsupported HTTP recording" },
      { function(v) v[1].request.url = nil end, "Recording request is missing method or URL" },
      { function(v) v[3].at_us = -1 end, "Recording timestamps must be ordered" },
      { function(v) v[3].index = 3 end, "Invalid recording chunk sequence" },
      { function(v) v[4].redacted = true end, "Recording body is masked; supply a synthetic adaptation" },
      { function(v) v[4].body_encoding = "unknown" end, "Unsupported recording body encoding" },
      { function(v) v[4].body = 42 end, "Invalid recording body" },
      { function(v) v[4].bytes = 0 end, "Recording body length mismatch" },
      { function(v) v[2].bytes = 0 end, "Recording chunk lengths do not match the body" },
      { function(v) table.insert(v, 5, vim.deepcopy(v[4])) end, "Duplicate recording body" },
      { function(v) table.insert(v, 6, vim.deepcopy(v[5])) end, "Duplicate recording response" },
      { function(v) v[6].ok = nil end, "Invalid recording completion" },
      { function(v) v[6].ok = false end, "Failed recording requires an error" },
      { function(v) v[6] = nil end, "Incomplete recording; body, response and completion are required" },
      { function(v) v[5].type = "unknown" end, "Unknown recording event" },
    }
    for _, case in ipairs(cases) do
      local value = records()
      case[1](value)
      assert.has_error(function() replay.read(write(value)) end, case[2])
    end
    assert.has_error(function() replay.read(write({ "{" })) end, "Invalid recording JSON")
  end)

  it("matches JSON and form semantics without losing missing, null or array distinctions", function()
    local cases = {
      { '{"a":null,"b":[]}', '{ "b": [], "a": null }', "application/json" },
      { "false", "false", "application/json" },
      { "a=hello+world&b=%2F", "b=%2f&a=hello%20world", "application/x-www-form-urlencoded" },
      { "invalid", "invalid", "application/x-www-form-urlencoded" },
      { "a=1&a=2", "a=1&a=2", "application/x-www-form-urlencoded" },
    }
    for _, case in ipairs(cases) do
      local value = buffered("false")
      value[1].request.body = case[1]
      value[1].request.headers = { ["Content-Type"] = case[3] }
      value[1].request.url = "https://api.test/a%2fb"
      local player = new(value)
      local actual = vim.deepcopy(value[1].request)
      actual.body, actual.url = case[2], "https://api.test/a%2Fb"
      actual.headers = { ["content-type"] = case[3] }
      assert.is_false(wait(http.new(player).fetch({ request = actual })).body)
      player.assert_consumed()
    end
    local value = buffered("{}")
    value[1].request.body = nil
    local player = new(value)
    local actual = vim.deepcopy(request); actual.body = nil
    assert.is_true(wait(player.fetch({ request = actual })).ok)
    player.assert_consumed()
  end)

  it("fails closed on request mismatches and reports only the differing dimension", function()
    local changes = {
      { "method", function(r) r.method = "GET" end },
      { "URL", function(r) r.url = "https://private.test/secret" end },
      { "headers", function(r) r.headers.extra = "private" end },
      { "headers", function(r) r.headers.Authorization = "private" end },
      { "body", function(r) r.body = '{"a":null,"b":{}}' end },
      { "body", function(r) r.body = '{"b":[]}' end },
    }
    for _, case in ipairs(changes) do
      local player = new(records())
      local actual, completed = vim.deepcopy(request), 0
      case[2](actual)
      local result = wait(player.fetch({ request = actual, on_done = function() completed = completed + 1 end }))
      assert.is_false(result.ok)
      assert.are.equal("replay", assert(result.error).kind)
      assert.matches(case[1], assert(result.error).message)
      assert.is_nil((assert(result.error).message:find("private", 1, true)))
      assert(vim.wait(1000, function() return completed == 1 end))
      assert.has_error(player.assert_consumed, assert(result.error).message)
    end
    local player = new(records())
    assert.has_error(player.assert_consumed, "Unused HTTP exchange: 1")
    assert.is_true(wait(player.fetch({ request = request })).ok)
    local result = wait(player.fetch({ request = request }))
    assert.matches("all exchanges consumed", assert(result.error).message)
    assert.has_error(player.assert_consumed, assert(result.error).message)
  end)

  it("requires explicit projections and supports byte-exact request bodies", function()
    local value = buffered("{}")
    value[1].request.headers, value[1].request.body = {}, '{"a":null}'
    local player = new(value, nil, { headers_subset = true, body_subset = true })
    assert.is_true(wait(player.fetch({ request = request })).ok)
    player.assert_consumed()
    for _, body in ipairs({ "false", '{"a":false}' }) do
      player = new(value, nil, { headers_subset = true, body_subset = true })
      local actual = vim.deepcopy(request); actual.body = body
      assert.is_false(wait(player.fetch({ request = actual })).ok)
    end
    player = new(records(), nil, { body_exact = true })
    local actual = vim.deepcopy(request); actual.body = '{ "a": null, "b": [] }'
    assert.is_false(wait(player.fetch({ request = actual })).ok)
    assert.is_true(wait(player.fetch({ request = request })).ok)
  end)

  it("rejects malformed multipart framing before semantic matching", function()
    local boundary = "neoagent-boundary"
    local body = "--" .. boundary .. "\r\npart\r\n--" .. boundary .. "--\r\n"
    local value = buffered("{}")
    value[1].request.body = body
    value[1].request.headers = {
      ["content-type"] = "multipart/form-data; boundary=" .. boundary,
      ["content-length"] = tostring(#body),
    }
    local cases = {
      { name = "empty boundary", corrupt = function(actual)
        actual.headers["content-type"] = "multipart/form-data; boundary=\"\""
      end },
      { name = "incorrect length", corrupt = function(actual)
        actual.headers["content-length"] = tostring(#body + 1)
      end },
      { name = "invalid opener", corrupt = function(actual)
        actual.body = "xx" .. body:sub(3)
      end },
      { name = "missing delimiter", corrupt = function(actual)
        actual.body = "--" .. boundary .. "\r\npart"
        actual.headers["content-length"] = tostring(#actual.body)
      end },
      { name = "invalid suffix", corrupt = function(actual)
        actual.body = "--" .. boundary .. "\r\npart\r\n--" .. boundary .. "xx\r\n"
      end },
    }
    for _, case in ipairs(cases) do
      local player = new(value)
      local actual = vim.deepcopy(value[1].request)
      case.corrupt(actual)
      assert.is_false(wait(player.fetch({ request = actual })).ok, case.name)
    end
  end)

  it("detects unexpected body members and subset headers", function()
    local value = buffered("{}")
    value[1].request.body = "{}"
    value[1].request.headers = {}
    local player = new(value)
    local actual = vim.deepcopy(value[1].request)
    actual.body = '{"extra":1}'
    assert.is_false(wait(player.fetch({ request = actual })).ok)

    value[1].request.body = "{}"
    value[1].request.headers = { required = "value" }
    player = new(value, nil, { headers_subset = true })
    actual = vim.deepcopy(value[1].request)
    actual.headers.required = "different"
    assert.is_false(wait(player.fetch({ request = actual })).ok)
  end)

  it("reserves concurrent exchanges before delivery and orders events using explicit dependencies", function()
    local value = buffered("{}")
    local player = replay.new({ exchanges = {
      { id = "watch", path = write(records()), gates = { ["2"] = { "load:request" } }, finish_after = { "load:complete" } },
      { id = "load", path = write(value), after = { "watch:chunk:1" } },
    } })
    assert(players)[#players + 1] = player
    local chunks = {}
    local stream = player.request({ request = request, on_chunk = function(chunk) chunks[#chunks + 1] = chunk end })
    assert(vim.wait(1000, function() return #chunks == 1 end))
    assert.is_false(stream:is_done())
    local fetch = player.fetch({ request = request })
    assert.is_true(wait(fetch).ok)
    assert.is_true(wait(stream).ok)
    assert.are.equal(2, #chunks)
    assert.are.equal(2, #player.requests)
    player.assert_consumed()
  end)

  it("bounds missing dependencies and cancels blocked and timed playback without stale delivery", function()
    for _, options in ipairs({ { after = { "never" } }, { gates = { ["1"] = { "never" } } } }) do
      local player = new(records(), { timeout_ms = 5 }, options)
      local result = wait(player.request({ request = request }))
      assert.is_false(result.ok)
      assert.matches("dependency timed out", assert(result.error).message)
      assert.has_error(player.assert_consumed, "Replay dependency timed out")
    end
    local value = records()
    value[2].at_us, value[3].at_us, value[4].at_us, value[5].at_us, value[6].at_us = 1000000, 1000001, 1000001, 1000001, 1000001
    for _, entry in ipairs({ {}, { after = { "never" } } }) do
      local player = new(value, { timing = true }, entry)
      local chunks, completions = 0, 0
      local run = player.request({ request = request, on_chunk = function() chunks = chunks + 1 end,
        on_done = function() completions = completions + 1 end })
      player.close()
      assert.are.equal("cancelled", assert(wait(run).error).kind)
      player.release("never")
      assert(vim.wait(1000, function() return completions == 1 end))
      assert.are.equal(0, chunks)
    end
    local player = new(records(), { timing = true })
    assert.is_true(wait(player.request({ request = request })).ok)
    player.assert_consumed()
  end)

  it("lets the current decoder reproduce recorded errors instead of injecting historical decoder failures", function()
    for _, kind in ipairs({ "protocol", "model", "transport" }) do
      local value = buffered('{"error":"expired"}')
      value[5].status = 401
      value[6].ok, value[6].error = false, { kind = kind, exit_code = 22, message = "historical" }
      local player = new(value)
      local result = wait(http.new(player).fetch({ request = request }))
      assert(result.ok)
      assert.are.equal(401, result.status)
      assert.are.same({ error = "expired" }, result.body)
    end
    local player = new(records())
    local result = wait(player.request({ request = request, on_chunk = function() error(util.error("model", "rejected"), 0) end }))
    assert.are.equal("model", assert(result.error).kind)
    local response = assert(rawget(assert(result.error), "response"))
    assert.are.equal(200, rawget(response, "status"))
    local value = buffered("")
    value[6].ok, value[6].error = false, { kind = "transport", message = "connection lost" }
    player = new(value)
    local disconnected = wait(player.fetch({ request = request }))
    assert.are.equal("transport", assert(disconnected.error).kind)
    assert.are.equal("connection lost", assert(disconnected.error).message)
  end)

  it("requires the caller to cancel recordings of persistent subscriptions", function()
    local value = records()
    value[6].ok = false
    rawset(value[6], "error", { kind = "cancelled", message = "cancelled" })
    local player = new(value)
    local result = wait(player.request({ request = request }))
    assert.matches("explicit open stream", assert(result.error).message)
    assert.has_error(player.assert_consumed, assert(result.error).message)
    player = new(value, nil, { open = true })
    local chunks = 0
    local run = player.request({ request = request, on_chunk = function() chunks = chunks + 1 end })
    assert(vim.wait(1000, function() return chunks == 2 end))
    assert.is_false(run:is_done())
    run:cancel()
    assert.are.equal("cancelled", assert(wait(run).error).kind)
    player.assert_consumed()
    assert.has_error(function() replay.new({ timeout_ms = 0, exchanges = {} }) end, "Replay timeout must be positive and finite")
    assert.has_error(function() replay.new({ exchanges = {
      { id = "same", path = write(records()) }, { id = "same", path = write(records()) },
    } }) end, "Replay exchange IDs must be unique strings")
  end)
end)
