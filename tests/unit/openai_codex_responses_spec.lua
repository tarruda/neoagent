local codex = require("neoagent.api.openai_codex_responses")
local fake_transport = require("tests.helpers.fake_transport")

local function event(value)
  return "data: " .. vim.json.encode(value) .. "\n\n"
end

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end

describe("neoagent.api.openai_codex_responses", function()
  it("builds the Codex SSE request profile on the shared Responses protocol", function()
    local model = codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://chatgpt.com/backend-api",
      reasoning = true,
      reasoning_effort = "high",
      text_verbosity = "medium",
    })
    local request = model:_request({
      system_prompt = "Be precise.",
      messages = { { role = "user", content = "Hello" } },
      tools = { {
        name = "read",
        description = "Read",
        input_schema = { type = "object", properties = {}, additionalProperties = false },
      } },
    })
    assert.are.equal("openai-codex-responses", model.api)
    assert.are.equal("https://chatgpt.com/backend-api/codex/responses", request.url)
    assert.are.equal("Be precise.", request.body.instructions)
    assert.are.equal("user", request.body.input[1].role)
    assert.are.same({ verbosity = "medium" }, request.body.text)
    assert.are.equal("auto", request.body.tool_choice)
    assert.is_true(request.body.parallel_tool_calls)
    assert.are.equal(vim.NIL, request.body.tools[1].strict)
    assert.are.equal("{}", vim.json.encode(request.body.tools[1].parameters.properties))
    assert.are.same({ "reasoning.encrypted_content" }, request.body.include)

    assert.are.equal("https://example.test/codex/responses", codex.new({
      provider = "p", model = "m", base_url = "https://example.test/codex/responses",
    }):_request({ messages = {}, tools = {} }).url)
  end)

  it("accepts the Codex response.done terminal event", function()
    local output = { {
      type = "message", id = "msg", role = "assistant", status = "completed",
      content = { { type = "output_text", text = "done", annotations = {} } },
    } }
    local transport = fake_transport.new({ {
      chunks = { event({
        type = "response.done",
        response = { id = "response", status = "completed", output = output },
      }) },
      headers = {
        ["X-Codex-Primary-Used-Percent"] = "12.5",
        ["X-Codex-Primary-Window-Minutes"] = "300",
        ["X-Codex-Secondary-Used-Percent"] = "40",
        ["X-Codex-Secondary-Window-Minutes"] = "10080",
      },
    } })
    local emitted = {}
    local result = wait(codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport,
    }):stream({ messages = {}, on_event = function(value) emitted[#emitted + 1] = value end }))
    assert.is_true(result.ok)
    assert.are.equal("done", result.text)
    assert.are.equal("openai-codex-responses", result.message.api)
    assert.are.same({
      type = "provider_status",
      text = "5h 87.5% left · weekly 60% left",
    }, emitted[#emitted])
  end)

  it("extracts nested Codex errors and reports safe diagnostics", function()
    local diagnostics = {}
    local result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = fake_transport.new({ { chunks = { event({
        type = "error",
        error = { code = "invalid_request", message = "specific provider failure" },
      }) } } }),
      request_max_retries = 0,
      on_diagnostic = function(value) diagnostics[#diagnostics + 1] = value end,
    }):stream({ messages = {} }))

    assert.is_false(result.ok)
    assert.are.equal("specific provider failure", result.error.message)
    assert.are.equal("invalid_request", result.error.code)
    assert.is_false(result.error.retryable)
    assert.are.equal(1, #diagnostics)
    assert.are.equal("request_failed", diagnostics[1].type)
    assert.are.equal("invalid_request", diagnostics[1].code)
    assert.is_nil(diagnostics[1].detail)
  end)

  it("retries transient HTTP failures before output", function()
    local output = { {
      type = "message", id = "msg", role = "assistant", status = "completed",
      content = { { type = "output_text", text = "recovered", annotations = {} } },
    } }
    local transport = fake_transport.new({
      { error = {
        kind = "transport",
        message = "HTTP 500: internal server error",
        detail = [[{"error":{"message":"internal server error"}}]],
        exit_code = 22,
        response = { status = 500, headers = {
          ["x-request-id"] = "req-retry",
          ["cf-ray"] = "ray-retry",
        } },
      } },
      { chunks = { event({
        type = "response.done",
        response = { id = "response", status = "completed", output = output },
      }) } },
    })
    local delays = {}
    local result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = transport,
      request_max_retries = 1,
      sleep = function(delay) delays[#delays + 1] = delay end,
    }):stream({ messages = {} }))

    assert.is_true(result.ok)
    assert.are.equal("recovered", result.text)
    assert.are.equal(2, #transport.requests)
    assert.are.same({ 200 }, delays)
  end)

  it("cancels a Codex request during retry backoff", function()
    local retrying = false
    local transport = fake_transport.new({ { error = {
      kind = "transport",
      message = "HTTP 503: overloaded",
      response = { status = 503, headers = {} },
    } } })
    local run = codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = transport,
      request_max_retries = 1,
      on_diagnostic = function(value)
        if value.type == "request_retry" then retrying = true end
      end,
    }):stream({ messages = {} })
    assert(vim.wait(1000, function() return retrying end))
    run:cancel()
    local result = wait(run)

    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.are.equal(1, #transport.requests)
  end)

  it("extracts Codex rate-limit retry delays", function()
    for _, case in ipairs({
      { message = "Rate limit reached. Please try again in 28ms.", delay = 28 },
      { message = "Rate limit exceeded. Try again in 35 seconds.", delay = 35000 },
    }) do
      local result = wait(codex.new({
        provider = "openai-codex",
        model = "gpt-test",
        base_url = "https://example.test/codex",
        transport = fake_transport.new({ { chunks = { event({
          type = "response.failed",
          response = { error = {
            code = "rate_limit_exceeded",
            message = case.message,
          } },
        }) } } }),
        request_max_retries = 0,
      }):stream({ messages = {} }))

      assert.is_false(result.ok)
      assert.is_true(result.error.retryable)
      assert.are.equal(case.delay, result.error.retry_after_ms)
    end
  end)

  it("marks partial Codex stream failures for turn replay", function()
    local chunks = {
      event({ type = "response.output_item.added", output_index = 0,
        item = { type = "reasoning", id = "reasoning", summary = {} } }),
      event({ type = "response.reasoning_summary_text.delta", output_index = 0, delta = "working" }),
      event({ type = "response.failed", response = {
        error = { code = "upstream_error", message = "upstream disconnected" },
      } }),
    }
    local result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = fake_transport.new({ { chunks = chunks } }),
    }):stream({ messages = {} }))

    assert.is_false(result.ok)
    assert.are.equal("upstream disconnected", result.error.message)
    assert.are.equal("upstream_error", result.error.code)
    assert.is_true(result.error.retryable)
    assert.are.equal(5, result.error.stream_max_retries)
    assert.are.equal("working", result.message.content[1].thinking)
  end)

  it("omits disabled rate-limit windows from provider status", function()
    local output = { {
      type = "message", id = "msg", role = "assistant", status = "completed", content = {},
    } }
    local transport = fake_transport.new({ {
      chunks = { event({
        type = "response.done",
        response = { id = "response", status = "completed", output = output },
      }) },
      headers = {
        ["X-Codex-Primary-Used-Percent"] = "21",
        ["X-Codex-Primary-Window-Minutes"] = "10080",
        ["X-Codex-Secondary-Used-Percent"] = "0",
        ["X-Codex-Secondary-Window-Minutes"] = "0",
      },
    } })
    local emitted = {}
    local result = wait(codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport,
    }):stream({ messages = {}, on_event = function(value) emitted[#emitted + 1] = value end }))
    assert.is_true(result.ok)
    assert.are.same({ type = "provider_status", text = "weekly 79% left" }, emitted[#emitted])
  end)
end)
