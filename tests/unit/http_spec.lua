local assert = require("luassert")
local async = require("neoagent.async")
local http = require("neoagent.transport.http")
local fake = require("tests.helpers.fake_transport")
local util = require("neoagent.util")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@param body unknown
---@param status integer
---@param maximum? integer
---@return Neoagent.RunResult<Neoagent.HttpResult>
local function fetch(body, status, maximum)
  local backend = fake.new()
  backend.fetches = { { body = body --[[@as string]], status = status, headers = { etag = "v1" } } }
  return wait(http.new(backend).fetch({ request = {
    url = "https://example.test", max_response_bytes = maximum,
  } }))
end

describe("decoded HTTP client", function()
  it("reports unsupported backend operations through the returned Run", function()
    local request = { url = "https://example.test" }
    local result = wait(http.new({ request = fake.new().request }).fetch({ request = request }))
    assert.is_false(result.ok)
    assert.are.equal("transport", assert(result.error).kind)
    assert.matches("HTTP backend does not support fetch", assert(result.error).message)
    result = wait(http.new({ fetch = fake.new().fetch }).stream({
      request = request, on_event = function() end,
    }))
    assert.is_false(result.ok)
    assert.are.equal("transport", assert(result.error).kind)
    assert.matches("HTTP backend does not support streaming", assert(result.error).message)
  end)

  it("preserves JSON values, nulls, empty collections and HTTP metadata", function()
    ---@type [string, Neoagent.JsonValue][]
    local cases = {
      { "false", false }, { "true", true }, { "42", 42 },
      { '"hello"', "hello" }, { "null", vim.NIL },
      { "[]", {} }, { "{}", vim.empty_dict() },
      { '{"missing":null,"values":[]}', { missing = vim.NIL, values = {} } },
    }
    for _, case in ipairs(cases) do
      local result = fetch(case[1], 200)
      assert(result.ok)
      assert.are.same(case[2], result.body)
      assert.are.equal(200, result.status)
      assert.are.same({ etag = "v1" }, result.headers)
    end
    local array, object = fetch("[]", 200), fetch("{}", 200)
    assert(array.ok and type(array.body) == "table")
    assert(object.ok and type(object.body) == "table")
    assert.is_true(vim.islist(array.body))
    assert.is_false(vim.islist(object.body))
  end)

  it("preserves empty conditional and no-content responses without inventing JSON", function()
    for _, status in ipairs({ 204, 304 }) do
      local result = fetch("", status)
      assert(result.ok)
      assert.is_nil(result.body)
      assert.are.equal(status, result.status)
    end
  end)

  it("returns non-success HTTP responses for the consumer to classify", function()
    local result = fetch('{"error":"expired"}', 401)
    assert(result.ok)
    assert.are.same({ error = "expired" }, result.body)
    result = fetch("<html>unavailable</html>", 503)
    assert(result.ok)
    assert.is_nil(result.body)
    assert.are.equal(503, result.status)
    assert.matches("unavailable", tostring(result.detail))
  end)

  it("bounds and diagnoses malformed buffered responses with their metadata", function()
    for _, case in ipairs({
      { "{", nil, "invalid JSON" },
      { {}, nil, "body must be text" },
      { string.rep("x", 20), 10, "exceeds 10 bytes" },
    }) do
      local result = fetch(case[1], 200, case[2])
      assert.is_false(result.ok)
      assert.are.equal("protocol", assert(result.error).kind)
      assert.matches(case[3], assert(result.error).message)
      assert.are.equal(200, assert((assert(result.error) --[[@as Neoagent.HttpError]]).response).status)
      assert.are.equal("v1", assert((assert(result.error) --[[@as Neoagent.HttpError]]).response).headers.etag)
    end
  end)

  it("decodes fragmented multiline SSE and retains events after DONE", function()
    local backend = fake.new({ { chunks = {
      ': comment\r', '\nevent: message\r\ndata: {"value":\r',
      '\ndata: null}\r\n\r\ndata: [DONE]\n\n',
      'data: {"usage":1}',
    } } })
    ---@type Neoagent.JsonValue[]
    local events = {}
    local markers = 0
    local result = wait(http.new(backend).stream({
      request = { url = "https://example.test" },
      on_event = function(value) events[#events + 1] = value end,
      on_done_marker = function() markers = markers + 1 end,
    }))
    assert(result.ok)
    assert.are.same({ { value = vim.NIL }, { usage = 1 } }, events)
    assert.are.equal(1, markers)
  end)

  it("rejects invalid or oversized SSE and preserves consumer failures", function()
    for _, case in ipairs({
      { "data: {\n\n", nil, "Invalid JSON" },
      { "data: 123456\n\n", 4, "exceeded 4 bytes" },
      { "data: {}\n\n", nil, "provider failure", true },
    }) do
      local result = wait(http.new(fake.new({ { chunks = { case[1] } } })).stream({
        request = { url = "https://example.test" },
        max_event_bytes = case[2],
        on_event = function()
          if case[4] then error(util.error("model", "provider failure"), 0) end
        end,
      }))
      assert.is_false(result.ok)
      assert.matches(case[3], assert(result.error).message)
      assert.are.equal(case[4] and "model" or "protocol", assert(result.error).kind)
    end
  end)

  it("accepts JSON fallbacks and attaches metadata to HTTP stream errors", function()
    ---@param chunks string[]
    ---@param status integer
    ---@return Neoagent.RunResult<Neoagent.HttpResult>, Neoagent.JsonValue[]
    local function stream(chunks, status)
      local backend = {
      ---@param opts Neoagent.ByteStreamOptions
      ---@return Neoagent.Run<Neoagent.ByteStreamResult, nil>
      request = function(opts)
        return async.run(function()
          for _, chunk in ipairs(chunks) do assert(opts.on_chunk)(chunk) end
          return { ok = true, response = { status = status, headers = { ["x-request-id"] = "r1" } } }
        end)
      end }
      ---@type Neoagent.JsonValue[]
    local events = {}
      local result = wait(http.new(backend).stream({
        request = { url = "https://example.test" },
        on_event = function(event) events[#events + 1] = event end,
      }))
      return result, events
    end
    local result, events = stream({ '  {"value":', '42}' }, 200)
    assert(result.ok)
    assert.are.same({ { value = 42 } }, events)
    assert.are.equal(200, result.status)
    result, events = stream({ '{"error":{"message":"expired"}}' }, 401)
    assert(result.ok)
    assert.are.same({}, events)
    assert.are.equal(401, result.status)
    assert.are.same({ error = { message = "expired" } }, result.body)
    assert.are.equal("r1", assert(result.headers)["x-request-id"])
    result = stream({ "{" }, 200)
    assert.is_false(result.ok)
    assert.matches("invalid JSON", assert(result.error).message)
  end)

  it("cancels the byte operation and ignores callbacks from a settled stream", function()
    ---@type fun(chunk: string)?
    local deliver
    ---@type fun(result: Neoagent.ByteStreamResult)?
    local finish
    local cancelled, completions = 0, 0
    local backend = {
      ---@param opts Neoagent.ByteStreamOptions
      ---@return Neoagent.Run<Neoagent.ByteStreamResult, nil>
      request = function(opts)
      deliver = opts.on_chunk
      return async.run(function()
        return async.await(function(done)
          finish = done.resolve
          return function() cancelled = cancelled + 1 end
        end)
      end)
    end }
    ---@type Neoagent.JsonValue[]
    local events = {}
    local run = http.new(backend).stream({
      request = { url = "https://example.test" },
      on_event = function(event) events[#events + 1] = event end,
      on_done = function() completions = completions + 1 end,
    })
    assert(deliver)('data: {"text":"partial"}\n\n')
    run:cancel()
    assert.are.equal("cancelled", assert(wait(run).error).kind)
    assert(deliver)('data: {"text":"stale"}\n\n')
    assert(finish)({ ok = true, response = { status = 200, headers = {} } })
    assert(vim.wait(1000, function() return completions == 1 end))
    assert.are.same({ { text = "partial" } }, events)
    assert.are.equal(1, cancelled)
  end)

  it("bounds unfinished stream frames and JSON fallback bodies", function()
    for _, case in ipairs({
      { string.rep(" ", 65537), {}, "prefix exceeds limit" },
      { '{"text":"long"}', { max_response_bytes = 4 }, "JSON response exceeds limit" },
      { "data: " .. string.rep("x", 1048576), {}, "pending buffer exceeded" },
    }) do
      local result = wait(http.new(fake.new({ { chunks = { case[1] } } })).stream({
        request = vim.tbl_extend("force", { url = "https://example.test" }, case[2]) --[[@as Neoagent.HttpRequest]],
        on_event = function() error("oversized input was delivered") end,
      }))
      assert.is_false(result.ok)
      assert.matches(case[3], assert(result.error).message)
    end
  end)

  it("reports final-frame failures and ignores delivery after successful completion", function()
    ---@type fun(chunk: string)?
    local deliver
    local backend = {
      ---@param opts Neoagent.ByteStreamOptions
      ---@return Neoagent.Run<Neoagent.ByteStreamResult, nil>
      request = function(opts)
      deliver = opts.on_chunk
      return async.run(function()
        assert(opts.on_chunk)("data: 12345")
        return { ok = true, response = { status = 200, headers = {} } }
      end)
    end }
    local result = wait(http.new(backend).stream({
      request = { url = "https://example.test" }, max_event_bytes = 4,
      on_event = function() error("oversized final event was delivered") end,
    }))
    assert.is_false(result.ok)
    assert.matches("event exceeded", assert(result.error).message)
    assert.are.equal(200, assert((assert(result.error) --[[@as Neoagent.HttpError]]).response).status)
    ---@type Neoagent.JsonValue[]
    local events = {}
    result = wait(http.new(backend).stream({
      request = { url = "https://example.test" },
      on_event = function(value) events[#events + 1] = value end,
    }))
    assert(result.ok)
    assert(deliver)("data: 67890\n\n")
    assert.are.same({ 12345 }, events)
  end)

  it("lets each API validate decoded event objects and classify HTTP error envelopes", function()
    for _, module in ipairs({
      "neoagent.api.openai_completions", "neoagent.api.openai_responses",
      "neoagent.api.anthropic_messages",
    }) do
      for _, case in ipairs({
        { 200, "data: false\n\n", "Expected an object" },
        { 400, '{"message":"request denied"}', "HTTP 400: request denied" },
        { 503, '{"detail":"unavailable"}', "HTTP 503: unavailable" },
      }) do
        local api = require(module) --[[@as { new: fun(opts: Neoagent.ApiModelOptions): Neoagent.Model }]]
        local model = api.new({
          provider = "test", model = "test-model", base_url = "https://example.test",
          transport = fake.new({ { status = case[1], chunks = { case[2] } } }),
        })
        local result = wait(model:stream({ messages = {} }))
        assert.is_false(result.ok)
        assert.matches(case[3], assert(result.error).message)
      end
    end
  end)

  it("binds recording context before decoding and propagates backend failures", function()
    ---@type Neoagent.RequestIdentity?
    local seen
    ---@type Neoagent.ByteBackend
    local backend = { fetch = function()
      return async.run(function() return { ok = false, error = util.error("transport", "offline") } end)
    end }
    backend.with_context = function(context) seen = context return backend end
    local client = http.new(backend).with_context({ session_id = "session-1" })
    local result = wait(client.fetch({ request = { url = "https://example.test" } }))
    assert.are.equal("session-1", rawget(assert(seen), "session_id"))
    assert.is_false(result.ok)
    assert.are.equal("offline", assert(result.error).message)
  end)
end)
