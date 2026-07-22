local mock_server = require("tests.helpers.mock_server")
local codex = require("neoagent.api.openai_codex_responses")
local openai = require("neoagent.api.openai_completions")
local responses = require("neoagent.api.openai_responses")

local function model(server, key)
  return openai.new({
    provider = "mock",
    model = "test-model",
    base_url = "http://127.0.0.1:" .. server.port .. "/v1",
    api_key = key,
  })
end

local function responses_model(server, key)
  return responses.new({
    provider = "mock",
    model = "test-model",
    base_url = "http://127.0.0.1:" .. server.port .. "/v1",
    api_key = key,
  })
end

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

describe("OpenAI-compatible HTTP integration", function()
  local servers = {}
  after_each(function()
    for _, server in ipairs(servers) do server:stop() end
    servers = {}
  end)

  it("streams real curl response chunks", function()
    local server = mock_server.start("tests/fixtures/openai/stream.json")
    servers[#servers + 1] = server
    local deltas = {}
    local result = wait(model(server, "test-key"):stream({
      messages = { { role = "user", content = "Hello" } },
      on_event = function(event) if event.type == "text_delta" then deltas[#deltas + 1] = event.text end end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("Hello", result.text)
    assert(vim.wait(1000, function() return #deltas == 2 end))
    assert.are.same({ "Hel", "lo" }, deltas)
    assert(vim.wait(1000, function() return #server.records >= 2 end))
    assert.are.equal("request", server.records[2].type)
  end)

  it("streams DeepSeek reasoning and replays it through a tool turn", function()
    local server = mock_server.start("tests/fixtures/deepseek/stream.json")
    servers[#servers + 1] = server
    local deepseek = openai.new({
      provider = "deepseek",
      model = "deepseek-v4-flash",
      base_url = "http://127.0.0.1:" .. server.port,
      api_key = "deepseek-key",
      max_output_tokens = 384000,
      request_opts = { body = { stream_options = { include_usage = true } } },
    })
    local tools = { {
      name = "inspect",
      description = "Inspect a path",
      input_schema = { type = "object", properties = { path = { type = "string" } } },
    } }
    local request_opts = {
      body = { thinking = { type = "enabled" }, reasoning_effort = "high" },
    }
    local user = { role = "user", content = "Inspect it" }
    local first = wait(deepseek:stream({
      messages = { user },
      tools = tools,
      request_opts = request_opts,
    }))

    assert.is_true(first.ok)
    assert.are.equal("toolUse", first.message.stopReason)
    assert.are.equal("reasoning_content", first.message.content[1].thinkingSignature)
    assert.are.equal(4, first.message.usage.cacheRead)
    assert.are.same({ path = "x.lua" }, first.message.content[2].arguments)

    local second = wait(deepseek:stream({
      messages = {
        user,
        first.message,
        { role = "toolResult", toolCallId = "call-1", content = {
          { type = "text", text = "return true" },
        } },
      },
      tools = tools,
      request_opts = request_opts,
    }))
    assert.is_true(second.ok)
    assert.are.equal("Looks good.", second.text)
    assert.are.equal("reasoning_content", second.message.content[2].thinkingSignature)
  end)

  it("streams Z.AI reasoning and streamed tools through its API profile", function()
    local server = mock_server.start("tests/fixtures/zai/stream.json")
    servers[#servers + 1] = server
    local zai = openai.new({
      provider = "zai",
      model = "glm-5.2",
      base_url = "http://127.0.0.1:" .. server.port,
      api_key = "zai-key",
      max_output_tokens = 131072,
      request_opts_layers = {
        { body = { stream_options = { include_usage = true } } },
        function(context)
          return #context.tools > 0 and { body = { tool_stream = true } } or {}
        end,
      },
    })
    local tools = { {
      name = "inspect",
      description = "Inspect a path",
      input_schema = { type = "object", properties = { path = { type = "string" } } },
    } }
    local request_opts = { body = {
      thinking = { type = "enabled", clear_thinking = false },
      reasoning_effort = "max",
    } }
    local user = { role = "user", content = "Inspect it" }
    local first = wait(zai:stream({
      messages = { user },
      tools = tools,
      request_opts = request_opts,
    }))

    assert.is_true(first.ok)
    assert.are.equal("toolUse", first.message.stopReason)
    assert.are.equal("reasoning_content", first.message.content[1].thinkingSignature)
    assert.are.equal(4, first.message.usage.cacheRead)
    assert.are.same({ path = "x.lua" }, first.message.content[2].arguments)

    local second = wait(zai:stream({
      messages = {
        user,
        first.message,
        { role = "toolResult", toolCallId = "call-1", content = {
          { type = "text", text = "return true" },
        } },
      },
      tools = tools,
      request_opts = request_opts,
    }))
    assert.is_true(second.ok)
    assert.are.equal("Looks good.", second.text)
    assert.are.equal("reasoning_content", second.message.content[2].thinkingSignature)
  end)

  it("surfaces non-2xx bodies as transport errors", function()
    local server = mock_server.start("tests/fixtures/openai/error.json")
    servers[#servers + 1] = server
    local result = wait(model(server):stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("transport", result.error.kind)
    assert.are.equal("HTTP 400: bad request", result.error.message)
    assert.matches("bad request", result.error.detail)
    assert.are.equal(22, result.error.exit_code)
    assert.matches("returned error: 400", result.error.stderr)
    assert.are.equal(400, result.error.response.status)
    assert.are.equal("req-error", result.error.response.headers["x-request-id"])
    assert.are.equal("ray-error", result.error.response.headers["cf-ray"])
  end)

  it("cancels curl and preserves partial assistant output", function()
    local server = mock_server.start("tests/fixtures/openai/cancel.json")
    servers[#servers + 1] = server
    local saw_partial = false
    local run
    run = model(server):stream({
      messages = {},
      on_event = function(event)
        if event.type == "text_delta" then
          saw_partial = true
          run:cancel()
        end
      end,
    })
    local result = wait(run)
    assert.is_true(saw_partial)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.are.equal("partial", result.message.content[1].text)
    assert.are.equal("aborted", result.message.stopReason)
  end)

  it("streams stateless Responses API requests through real curl", function()
    local server = mock_server.start("tests/fixtures/openai/responses_stream.json")
    servers[#servers + 1] = server
    local deltas = {}
    local result = wait(responses_model(server, "test-key"):stream({
      messages = { { role = "user", content = "Hello" } },
      on_event = function(event) if event.type == "text_delta" then deltas[#deltas + 1] = event.text end end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("Hello", result.text)
    assert.are.same({ "Hel", "lo" }, deltas)
    assert(vim.wait(1000, function() return #server.records >= 2 end))
    assert.are.equal("/v1/responses", server.records[2].path)
  end)

  it("preserves stream protocol errors behind successful HTTP responses", function()
    local server = mock_server.start("tests/fixtures/openai/responses_protocol_error.json")
    servers[#servers + 1] = server
    local result = wait(responses_model(server):stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)
    assert.are.equal("Invalid JSON in SSE response", result.error.message)
  end)

  it("retries Codex HTTP 500 responses with request diagnostics", function()
    local server = mock_server.start("tests/fixtures/openai/codex_retry.json")
    servers[#servers + 1] = server
    local diagnostics = {}
    local result = wait(codex.new({
      provider = "mock-codex",
      model = "gpt-test",
      base_url = "http://127.0.0.1:" .. server.port .. "/v1",
      request_max_retries = 1,
      sleep = function() end,
      on_diagnostic = function(value) diagnostics[#diagnostics + 1] = value end,
    }):stream({ messages = {} }))

    assert.is_true(result.ok)
    assert.are.equal("recovered", result.text)
    assert(vim.wait(1000, function() return #server.records >= 3 end))
    assert.are.equal(2, vim.tbl_count(vim.tbl_filter(function(record)
      return record.type == "request"
    end, server.records)))
    assert.are.equal("request_retry", diagnostics[1].type)
    assert.are.equal(500, diagnostics[1].status)
    assert.are.equal("req-codex-retry", diagnostics[1].request_id)
    assert.are.equal("ray-codex-retry", diagnostics[1].cf_ray)
  end)

  it("cancels Responses API curl and preserves partial output", function()
    local server = mock_server.start("tests/fixtures/openai/responses_cancel.json")
    servers[#servers + 1] = server
    local run
    run = responses_model(server):stream({
      messages = {},
      on_event = function(event) if event.type == "text_delta" then run:cancel() end end,
    })
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.are.equal("partial", result.message.content[1].text)
    assert.are.equal("aborted", result.message.stopReason)
  end)
end)
