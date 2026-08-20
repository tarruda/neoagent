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

  it("builds the Codex Responses Lite request profile", function()
    local model = codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://chatgpt.com/backend-api",
      reasoning = true,
      reasoning_effort = "high",
      reasoning_summary = "none",
      responses_lite = true,
    })
    local request = model:_request({
      system_prompt = "Use Codex channels.",
      messages = { { role = "user", content = "Hello" } },
      tools = { {
        name = "read",
        description = "Read",
        input_schema = { type = "object", properties = {}, additionalProperties = false },
      } },
    })

    assert.are.equal("true", request.headers["x-openai-internal-codex-responses-lite"])
    assert.is_nil(request.body.instructions)
    assert.is_nil(request.body.tools)
    assert.is_false(request.body.parallel_tool_calls)
    assert.are.equal("additional_tools", request.body.input[1].type)
    assert.are.equal("developer", request.body.input[1].role)
    assert.are.equal("read", request.body.input[1].tools[1].name)
    assert.are.equal("message", request.body.input[2].type)
    assert.are.equal("developer", request.body.input[2].role)
    assert.are.equal("Use Codex channels.", request.body.input[2].content[1].text)
    assert.are.equal("user", request.body.input[3].role)
    assert.are.same({ effort = "high", context = "all_turns" }, request.body.reasoning)

    local layered = codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://chatgpt.com/backend-api",
      responses_lite = true,
    }):_request({
      messages = {},
      tools = {},
      request_opts = { body = { reasoning = { effort = "medium" } } },
    })
    assert.are.same({ effort = "medium", context = "all_turns" }, layered.body.reasoning)
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
        ["X-Codex-Secondary-Reset-At"] = "1787870220",
        ["X-Codex-Credits-Has-Credits"] = "true",
        ["X-Codex-Credits-Unlimited"] = "false",
        ["X-Codex-Credits-Balance"] = "12.50",
        ["X-Codex-Sonic-Primary-Used-Percent"] = "20",
        ["X-Codex-Sonic-Primary-Window-Minutes"] = "43200",
        ["X-Codex-Sonic-Limit-Name"] = "Sonic",
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
    local status = emitted[#emitted]
    assert.are.equal("provider_status", status.type)
    assert.are.equal("5h 87.5% left · weekly 60% left", status.text)
    assert.are.equal("codex", status.details.limits[1].id)
    assert.are.equal(12.5,
      status.details.limits[1].primary.used_percent)
    assert.are.equal(1787870220,
      status.details.limits[1].secondary.resets_at)
    assert.are.same({
      has_credits = true, unlimited = false, balance = "12.50",
    }, status.details.credits)
    assert.are.equal("codex-sonic", status.details.limits[2].id)
    assert.are.equal("Sonic", status.details.limits[2].name)
    assert.are.equal(43200,
      status.details.limits[2].primary.window_minutes)
  end)

  it("orders additional quota headers and rejects unsafe metadata", function()
    local output = { {
      type = "message", id = "msg", role = "assistant", status = "completed",
      content = {},
    } }
    local transport = fake_transport.new({ {
      chunks = { event({
        type = "response.done",
        response = { id = "response", status = "completed", output = output },
      }) },
      headers = {
        ["X-Codex-Primary-Used-Percent"] = "30",
        ["X-Codex-Primary-Window-Minutes"] = "300",
        ["X-Alpha-Primary-Used-Percent"] = "10",
        ["X-Alpha-Primary-Window-Minutes"] = "60",
        ["X-Alpha-Limit-Name"] = "\n",
        ["X-Beta-Primary-Used-Percent"] = "20",
        ["X-Beta-Primary-Window-Minutes"] = "60",
        ["X-Codex-Credits-Has-Credits"] = "maybe",
        ["X-Codex-Credits-Unlimited"] = "true",
      },
    } })
    local emitted = {}
    local result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = transport,
    }):stream({
      messages = {},
      on_event = function(value) emitted[#emitted + 1] = value end,
    }))

    assert.is_true(result.ok)
    local status = emitted[#emitted]
    assert.are.equal("5h 70% left", status.text)
    assert.are.same({ "codex", "alpha", "beta" },
      vim.tbl_map(function(limit) return limit.id end, status.details.limits))
    assert.is_nil(status.details.limits[2].name)
    assert.is_nil(status.details.credits)
  end)

  it("normalizes malformed Codex tool arguments for agent recovery", function()
    local call = {
      type = "function_call", id = "fc", call_id = "call", name = "edit",
      arguments = "{",
    }
    local result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = fake_transport.new({ { chunks = { event({
        type = "response.done",
        response = { id = "response", status = "completed", output = { call } },
      }) } } }),
    }):stream({ messages = {} }))

    assert.is_true(result.ok)
    assert.are.equal("toolUse", result.message.stopReason)
    assert.are.same({}, result.message.content[1].arguments)
    assert.are.equal("Tool arguments are not valid JSON",
      result.message.content[1].argumentsError)
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
    local statuses = {}
    local result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = transport,
      request_max_retries = 1,
      sleep = function(delay) delays[#delays + 1] = delay end,
    }):stream({
      messages = {},
      on_event = function(value)
        if value.type == "provider_status" then
          statuses[#statuses + 1] = value
        end
      end,
    }))

    assert.is_true(result.ok)
    assert.are.equal("recovered", result.text)
    assert.are.equal(2, #transport.requests)
    assert.are.same({ 200 }, delays)
    assert.are.same({
      {
        type = "provider_status",
        text = "Reconnecting… 1/1",
        reconnecting = true,
      },
      { type = "provider_status", reconnecting = false },
    }, statuses)
  end)

  it("honors provider retry delays with the default cancellable timer", function()
    local output = { {
      type = "message", id = "msg", role = "assistant", status = "completed",
      content = { { type = "output_text", text = "recovered", annotations = {} } },
    } }
    local transport = fake_transport.new({
      { error = {
        kind = "transport",
        message = "HTTP 429: slow down",
        response = { status = 429, headers = { ["retry-after-ms"] = "1" } },
      } },
      { chunks = { event({
        type = "response.done",
        response = { id = "response", status = "completed", output = output },
      }) } },
    })
    local result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = transport,
      request_max_retries = 1,
    }):stream({ messages = {} }))

    assert.is_true(result.ok)
    assert.are.equal("recovered", result.text)
    assert.are.equal(2, #transport.requests)
  end)

  it("clears reconnect state when request retries are exhausted", function()
    local failure = {
      kind = "transport",
      message = "HTTP 503: overloaded",
      response = { status = 503, headers = {} },
    }
    local statuses = {}
    local result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = fake_transport.new({
        { error = vim.deepcopy(failure) },
        { error = vim.deepcopy(failure) },
      }),
      request_max_retries = 1,
      sleep = function() end,
    }):stream({
      messages = {},
      on_event = function(value)
        if value.type == "provider_status" then
          statuses[#statuses + 1] = value
        end
      end,
    }))

    assert.is_false(result.ok)
    assert.is_true(statuses[1].reconnecting)
    assert.is_false(statuses[#statuses].reconnecting)
  end)

  it("cancels a Codex request during retry backoff", function()
    local retrying = false
    local statuses = {}
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
    }):stream({
      messages = {},
      on_event = function(value)
        if value.type == "provider_status" then
          statuses[#statuses + 1] = value
        end
      end,
    })
    assert(vim.wait(1000, function() return retrying end))
    run:cancel()
    local result = wait(run)

    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.are.equal(1, #transport.requests)
    assert.is_true(statuses[1].reconnecting)
    assert.is_false(statuses[#statuses].reconnecting)
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
    assert.are.equal("provider_status", emitted[#emitted].type)
    assert.are.equal("weekly 79% left", emitted[#emitted].text)
    assert.are.equal(0.79,
      emitted[#emitted].details.limits[1].primary.remaining)
  end)

  it("derives provider status from rate-limit error headers", function()
    local transport = fake_transport.new({ {
      error = {
        kind = "transport",
        message = "HTTP 429: The usage limit has been reached",
        response = {
          status = 429,
          headers = {
            ["X-Codex-Primary-Used-Percent"] = "100",
            ["X-Codex-Primary-Window-Minutes"] = "10080",
          },
        },
      },
    } })
    local result = wait(codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport,
    }):stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("weekly 0% left", result.error.provider_status)
    assert.are.equal(0,
      result.error.provider_status_details.limits[1].primary.remaining)
  end)
end)
