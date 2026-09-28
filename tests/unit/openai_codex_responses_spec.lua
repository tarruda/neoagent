local it = require("tests.helpers.async_test")
local images = require("neoagent.api.images")
local attachments = require("tests.helpers.attachments").new()
local assert = require("luassert")
local codex = require("neoagent.api.openai_codex_responses")
local fake_transport = require("tests.helpers.fake_transport")

---@param value Neoagent.JsonObject
---@return string
local function event(value)
  return "data: " .. vim.json.encode(value) .. "\n\n"
end

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe("neoagent.api.openai_codex_responses", function()
  for _, operation in ipairs({ "stream", "compact" }) do
    for _, credential_source in ipairs({ "callable key", "Authentication" }) do
      it("requires fresh " .. operation .. " preparation after " .. credential_source .. " changes content", function()
        local key = "synthetic-before"
        local delays, reconnects = {}, {}
        local chunks = { event({ type = "response.completed", response = {
          id = "prepared", status = "completed", output = operation == "compact"
            and { { type = "compaction", encrypted_content = "synthetic-checkpoint" } }
            or { { type = "message", id = "reply", role = "assistant", status = "completed",
              content = { { type = "output_text", text = "Prepared answer", annotations = {} } } } },
        } }) }
        if operation == "compact" then
          table.insert(chunks, 1, event({ type = "response.output_item.done", item = {
            type = "compaction", encrypted_content = "synthetic-checkpoint",
          } }))
        end
        local transport = fake_transport.new({ { chunks = chunks } })
        ---@type Neoagent.Model
        local model = codex.new({ provider = "codex", model = "gpt-test", base_url = "https://example.test",
          transport = transport, sleep = function(delay) delays[#delays + 1] = delay end,
          api_key = credential_source == "callable key" and function() return key end or nil,
          request_opts = credential_source == "callable key" and function()
            return { messages = { { role = "user", content = key == "synthetic-before" and "Short"
              or string.rep("Changed context. ", 100) } } }
          end or nil,
        })
        local rotate = function() key = "synthetic-after" end
        if credential_source == "Authentication" then
          local store = require("tests.helpers.auth_manager").store({ key = { type = "api_key", key = key } })
          local manager = require("neoagent.auth").new({ store = store,
            methods = { key = require("neoagent.auth.api_key").new({ name = "Synthetic key",
              request_opts = function(credential)
                return { headers = { Authorization = "Bearer " .. credential.key },
                  messages = { { role = "user", content = credential.key == "synthetic-before" and "Short"
                    or string.rep("Changed context. ", 100) } } }
              end,
            }) },
          })
          model = manager:wrap(model, "key")
          rotate = function() assert(store:write("key", { type = "api_key", key = "synthetic-after" })) end
        end
        local call = { messages = { { role = "user", content = "Original" } },
          _preparation = require("neoagent.api.request_preparation").new(),
          on_event = function(value)
            if value.type == "provider_status" and value.reconnecting then reconnects[#reconnects + 1] = value end
          end,
        }
        local before = assert(model.estimate_request)(model, call, operation == "compact" and "compact" or nil)
        rotate()
        ---@async
        local function execute()
          if operation == "compact" then return assert(model.compact)(model, call):await() end
          return model:stream(call):await()
        end
        local result = execute()
        assert.is_false(result.ok)
        assert.are.equal("stale_request_preparation", assert(result.error).code)
        assert.are.equal(0, #transport.requests)
        assert.are.same({}, delays)
        assert.are.same({}, reconnects)
        assert.is_false(assert(result.error).retryable)
        assert.is_nil(assert(result.error).retry_exhausted)
        local after = assert(model.estimate_request)(model, call, operation == "compact" and "compact" or nil)
        assert.is_true(after > before)
        assert.is_true(execute().ok)
        assert.are.equal(1, #transport.requests)
      end)
    end
  end

  it("retries structured rate limits whose message resembles a context overflow", function()
    local transport = fake_transport.new({
      { error = { kind = "transport", message = "HTTP 429", response = { status = 429 },
        detail = [[{"error":{"code":"rate_limit_exceeded","message":"Request too large for the token-per-minute budget"}}]],
      } },
      { chunks = { event({ type = "response.completed", response = { id = "retried", status = "completed",
        output = { { type = "message", id = "reply", role = "assistant", status = "completed",
          content = { { type = "output_text", text = "Recovered", annotations = {} } } } },
      } }) } },
    })
    local delays = {}
    local model = codex.new({ provider = "codex", model = "gpt-test", base_url = "https://example.test",
      transport = transport, sleep = function(delay) delays[#delays + 1] = delay end })
    local result = wait(model:stream({ messages = {} }))
    assert.is_true(result.ok)
    assert.are.equal("Recovered", result.text)
    assert.are.equal(2, #transport.requests)
    assert.are.same({ 200 }, delays)
  end)

  it("compacts through Codex Responses and replays only compatible encrypted context", function()
    local encrypted = "synthetic-encrypted-checkpoint"
    local transport = fake_transport.new({
      { chunks = {
        event({ type = "response.output_item.done", item = { type = "message", role = "assistant" } }),
        event({ type = "response.output_item.done", item = {
          type = "compaction", encrypted_content = encrypted,
        } }),
        event({ type = "response.completed", response = {
          id = "compacted-1", usage = { input_tokens = 30, output_tokens = 5, total_tokens = 35 },
        } }),
      } },
      { chunks = { event({ type = "response.done", response = {
        id = "reply-1", status = "completed", output = { {
          type = "message", id = "message-1", role = "assistant", status = "completed",
          content = { { type = "output_text", text = "continued", annotations = {} } },
        } },
      } }) } },
    })
    local model = codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport,
    })
    local compact = assert(model.compact)
    local result = wait(compact(model, { messages = { { role = "user", content = "original" } } }))
    assert(result.ok)
    assert.are.equal(encrypted, result.item.encrypted_content)
    assert.are.equal(35, assert(result.usage).totalTokens)
    local first = vim.json.decode((assert(assert(transport.requests[1]).body)))
    assert.are.equal("compaction_trigger", first.input[#first.input].type)
    assert.is_true(first.parallel_tool_calls)

    local reply = wait(model:stream({ messages = {
      result.item, { role = "user", content = "continue" },
    } }))
    assert(reply.ok)
    assert.are.equal("continued", reply.text)
    local second = vim.json.decode((assert(assert(transport.requests[2]).body)))
    assert.are.equal("compaction", second.input[1].type)
    assert.are.equal(encrypted, second.input[1].encrypted_content)
    assert.is_nil(second.input[1].id)
    assert.are.equal("continue", second.input[2].content[1].text)

    local incompatible = codex.new({
      provider = "other", model = "gpt-test", base_url = "https://example.test/codex",
    })
    local rejected = wait(incompatible:stream({ messages = { result.item } }))
    assert.is_false(rejected.ok)
    assert.matches("Encrypted context requires its original API, provider, and Model", assert(rejected.error).message)
  end)

  it("omits a small output cap for native compaction but keeps it for inference", function()
    local transport = fake_transport.new({
      { chunks = {
        event({ type = "response.output_item.done", item = {
          type = "compaction", encrypted_content = "opaque",
        } }),
        event({ type = "response.completed", response = { id = "compacted" } }),
      } },
      { chunks = { event({ type = "response.done", response = {
        id = "reply", status = "completed", output = { {
          type = "message", role = "assistant", status = "completed",
          content = { { type = "output_text", text = "continued" } },
        } },
      } }) } },
    })
    local model = codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport, max_output_tokens = 4096,
    })
    local compacted = wait(assert(model.compact)(model, { messages = { { role = "user", content = "original" } } }))
    assert.is_true(compacted.ok)
    local compact_body = vim.json.decode((assert(assert(transport.requests[1]).body)))
    assert.are.equal("compaction_trigger", compact_body.input[#compact_body.input].type)
    assert.is_nil(compact_body.max_output_tokens)

    assert.is_true(wait(model:stream({ messages = { { role = "user", content = "continue" } } })).ok)
    local inference_body = vim.json.decode((assert(assert(transport.requests[2]).body)))
    assert.are.equal(4096, inference_body.max_output_tokens)
  end)

  it("uses an explicit native output budget and rejects an unsupported small one", function()
    local transport = fake_transport.new({ { chunks = {
      event({ type = "response.output_item.done", item = {
        type = "compaction", encrypted_content = "opaque",
      } }),
      event({ type = "response.completed", response = { id = "compacted" } }),
    } } })
    local model = codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport, max_output_tokens = 4096,
      request_opts_layers = { { body = { max_output_tokens = 32000 } } },
    })
    local invalid = wait(assert(model.compact)(model, { messages = {}, compaction_output_tokens = 16000 }))
    assert.is_false(invalid.ok)
    assert.matches("at least 20000", assert(invalid.error).message)
    assert.are.equal(0, #transport.requests)

    local valid = wait(assert(model.compact)(model, { messages = {}, compaction_output_tokens = 24000 }))
    assert.is_true(valid.ok)
    local body = vim.json.decode((assert(assert(transport.requests[1]).body)))
    assert.are.equal(24000, body.max_output_tokens)
  end)

  it("rejects inference output caps and undersized shaped native budgets before sending", function()
    local transport = fake_transport.new()
    local model = codex.new({ provider = "codex", model = "gpt-test", base_url = "https://example.test",
      transport = transport, request_max_retries = 0 })
    local invalid_options = { messages = {} }
    rawset(invalid_options, "max_output_tokens", 24000)
    local invalid = wait(assert(model.compact)(model, invalid_options))
    assert.is_false(invalid.ok)
    assert.matches("uses compaction_output_tokens", assert(invalid.error).message)
    invalid = wait(assert(model.compact)(model, { messages = {},
      request_opts = { body = { max_output_tokens = 1000 } } }))
    assert.is_false(invalid.ok)
    assert.matches("at least 20000", assert(invalid.error).message)
    assert.are.equal(0, #transport.requests)
  end)

  it("accepts a Codex response.done compaction without an item id", function()
    local transport = fake_transport.new({ { chunks = {
      event({ type = "response.output_item.done", item = {
        type = "compaction", encrypted_content = "opaque",
      } }),
      event({ type = "response.done", response = { id = "response", status = "completed" } }),
    } } })
    local model = codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport,
    })
    local result = wait(assert(model.compact)(model, { messages = {} }))
    assert.is_true(result.ok)
    assert.is_nil(assert(result.item).id)
  end)

  it("bounds retries of native Codex compaction failures", function()
    local failure = { error = {
      kind = "transport", message = "HTTP 503: busy",
      response = { status = 503, headers = {} },
    } }
    local transport = fake_transport.new({
      failure,
      { chunks = {
        event({ type = "response.output_item.done", item = {
          type = "compaction", encrypted_content = "opaque",
        } }),
        event({ type = "response.completed", response = { id = "response" } }),
      } },
    })
    local model = codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport, request_max_retries = 1, sleep = function() end,
    })
    assert.is_true(wait(assert(model.compact)(model, { messages = {} })).ok)
    assert.are.equal(2, #transport.requests)

    transport = fake_transport.new({ failure, failure, failure, failure })
    model = codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport, request_max_retries = 3, sleep = function() end,
    })
    local result = wait(assert(model.compact)(model, { messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal(3, #transport.requests)
  end)

  it("classifies incomplete and coded terminal native failures without retrying", function()
    for _, case in ipairs({
      { event = { type = "error", code = "context_length_exceeded", message = "Request failed" },
        code = "context_length_exceeded" },
      { event = { type = "response.incomplete", response = {
        status = "incomplete", incomplete_details = { reason = "max_output_tokens" },
      } }, code = "max_output_tokens" },
      { event = { type = "response.failed", response = {
        status = "failed", error = { code = "context_length_exceeded", message = "Request failed" },
      } }, code = "context_length_exceeded" },
    }) do
      local transport = fake_transport.new({ { chunks = { event(case.event) } } })
      local model = codex.new({
        provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
        transport = transport, request_max_retries = 2, sleep = function() end,
      })
      local result = wait(assert(model.compact)(model, { messages = {} }))
      assert.is_false(result.ok)
      assert.are.equal(case.code, rawget(assert(result.error), "code"))
      assert.is_false(rawget(assert(result.error), "retryable"))
      assert.are.equal(1, #transport.requests)
    end
  end)

  it("cancels native Codex compaction during retry backoff", function()
    local retrying = false
    local statuses = {}
    local transport = fake_transport.new({ { error = {
      kind = "transport", message = "HTTP 503: overloaded",
      response = { status = 503, headers = {} },
    } } })
    local model = codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport, request_max_retries = 1,
      on_diagnostic = function(value)
        if value.type == "request_retry" then
          retrying = true
        end
      end,
    })
    local run = assert(model.compact)(model, {
      messages = {},
      on_event = function(value)
        if value.type == "provider_status" then statuses[#statuses + 1] = value end
      end,
    })
    assert(vim.wait(1000, function() return retrying end))
    run:cancel()
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal(1, #transport.requests)
    assert.is_true(statuses[1].reconnecting)
    assert.is_false(statuses[#statuses].reconnecting)
  end)

  it("rejects incomplete or malformed native compaction responses", function()
    local compact_item = event({ type = "response.output_item.done", item = {
      type = "compaction", encrypted_content = "opaque",
    } })
    local completed = event({ type = "response.completed", response = { id = "response" } })
    for _, case in ipairs({
      { chunks = { completed }, error = "exactly one encrypted output item" },
      { chunks = { event({ type = "response.output_item.done", item = {
        type = "compaction", encrypted_content = "",
      } }), completed }, error = "Invalid encrypted compaction output" },
      { chunks = { compact_item, compact_item, completed }, error = "exactly one encrypted output item" },
      { chunks = { compact_item }, error = "terminal response event" },
      { chunks = { compact_item, event({ type = "response.completed", response = {} }) },
        error = "requires a response id" },
      { chunks = { compact_item, event({ type = "response.done", response = {
        id = "response", status = "incomplete",
      } }) }, error = "Compaction response incomplete" },
      { chunks = { event({ type = "response.failed", response = { error = { message = "unavailable" } } }) },
        error = "unavailable" },
    }) do
      local transport = fake_transport.new({ { chunks = case.chunks } })
      local model = codex.new({
        provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
        transport = transport, request_max_retries = 0,
      })
      local result = wait(assert(model.compact)(model, { messages = {} }))
      assert.is_false(result.ok)
      assert.matches(case.error, assert(result.error).message)
      assert.are.equal(1, #transport.requests)
    end
  end)

  it("builds the Codex SSE request profile on the shared Responses protocol", function()
    local model = codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://chatgpt.com/backend-api",
      reasoning = true,
      reasoning_effort = "high",
      text_verbosity = "medium",
    })
    local plan = model:_request({
      system_prompt = "Be precise.",
      messages = { { role = "user", content = "Hello" } },
      tools = { {
        name = "read",
        description = "Read",
        input_schema = { type = "object", properties = {}, additionalProperties = false },
      } },
    })
    local request = plan.request
    request.body = plan.encode(images.inline(plan.api, attachments.files))
    assert.are.equal("openai-codex-responses", model.api)
    assert.are.equal("https://chatgpt.com/backend-api/codex/responses", request.url)
    local body = assert(request.body)
    assert.are.equal("Be precise.", body.instructions)
    assert.are.equal("user", body.input[1].role)
    assert.are.same({ verbosity = "medium" }, body.text)
    assert.are.equal("auto", body.tool_choice)
    assert.is_true(body.parallel_tool_calls)
    assert.are.equal(vim.NIL, body.tools[1].strict)
    assert.are.equal("{}", vim.json.encode(assert(body.tools[1].parameters).properties))
    assert.are.same({ "reasoning.encrypted_content" }, body.include)

    assert.are.equal("https://example.test/codex/responses", codex.new({
      provider = "p", model = "m", base_url = "https://example.test/codex/responses",
    }):_request({ messages = {}, tools = {} }).request.url)
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
    local plan = model:_request({
      system_prompt = "Use Codex channels.",
      messages = { { role = "user", content = "Hello" } },
      tools = { {
        name = "read",
        description = "Read",
        input_schema = { type = "object", properties = {}, additionalProperties = false },
      } },
    })
    local request = plan.request
    request.body = plan.encode(images.inline(plan.api, attachments.files))

    assert.are.equal("true", rawget(assert(request.headers), "x-openai-internal-codex-responses-lite"))
    local body = assert(request.body)
    assert.is_nil(body.instructions)
    assert.is_nil(body.tools)
    assert.is_false(body.parallel_tool_calls)
    assert.are.equal("additional_tools", body.input[1].type)
    assert.are.equal("developer", body.input[1].role)
    assert.are.equal("read", assert(assert(body.input[1].tools)[1]).name)
    assert.are.equal("message", body.input[2].type)
    assert.are.equal("developer", body.input[2].role)
    assert.are.equal("Use Codex channels.", assert(assert(body.input[2].content)[1]).text)
    assert.are.equal("user", body.input[3].role)
    assert.are.same({ effort = "high", context = "all_turns" }, body.reasoning)

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
    assert.are.same({ effort = "medium", context = "all_turns" }, layered.encode(images.inline(layered.api)).reasoning)
  end)

  it("includes the required Lite reasoning context without optional reasoning settings", function()
    -- The live Luna endpoint rejects this request with HTTP 400 when context
    -- is absent, even when the caller did not select a reasoning effort.
    local plan = codex.new({ provider = "openai-codex", model = "gpt-5.6-luna", base_url = "https://chatgpt.com/backend-api",
      responses_lite = true }):_request({ messages = { { role = "user", content = "Inspect the tile." } } })
    assert.are.same({ context = "all_turns" }, plan.encode(images.inline(plan.api)).reasoning)
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
    ---@type Neoagent.ModelEvent[]
    local emitted = {}
    local result = wait(codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport,
    }):stream({ messages = {}, on_event = function(value) emitted[#emitted + 1] = value end }))
    assert(result.ok)
    assert.are.equal("done", result.text)
    assert.are.equal("openai-codex-responses", result.message.api)
    local status = emitted[#emitted]
    assert.are.equal("provider_status", status.type)
    assert.are.equal("5h 87.5% left · weekly 60% left", status.text)
    assert.are.equal("codex", assert(status.details).limits[1].id)
    assert.are.equal(12.5,
      assert(assert(status.details).limits[1].primary).used_percent)
    assert.are.equal(1787870220,
      assert(assert(status.details).limits[1].secondary).resets_at)
    assert.are.same({
      has_credits = true, unlimited = false, balance = "12.50",
    }, assert(status.details).credits)
    assert.are.equal("codex-sonic", assert(status.details).limits[2].id)
    assert.are.equal("Sonic", assert(status.details).limits[2].name)
    assert.are.equal(43200,
      assert(assert(status.details).limits[2].primary).window_minutes)
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
    ---@type Neoagent.ModelEvent[]
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

    assert(result.ok)
    local status = emitted[#emitted]
    assert.are.equal("5h 70% left", status.text)
    local limits = assert(status.details).limits
    assert(type(limits) == "table")
    assert.are.same({ "codex", "alpha", "beta" },
      vim.tbl_map(function(limit) return limit.id end, limits))
    assert.is_nil(assert(status.details).limits[2].name)
    assert.is_nil(assert(status.details).credits)
  end)

  it("normalizes malformed Codex tool arguments for Agent Loop recovery", function()
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

    assert(result.ok)
    assert.are.equal("toolUse", assert(result.message).stopReason)
    assert.are.same({}, assert(assert(result.message).content[1]).arguments)
    assert.are.equal("Tool arguments are not valid JSON",
      assert(assert(result.message).content[1]).argumentsError)
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
    assert.are.equal("specific provider failure", assert(result.error).message)
    assert.are.equal("invalid_request", rawget(assert(result.error), "code"))
    assert.is_false(rawget(assert(result.error), "retryable"))
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

    assert(result.ok)
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

    assert(result.ok)
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

  it("clears reconnect state after a native compaction retry", function()
    local statuses = {}
    local model = codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = fake_transport.new({
        { error = { kind = "transport", message = "HTTP 503: overloaded",
          response = { status = 503, headers = {} } } },
        { chunks = {
          event({ type = "response.output_item.done", item = {
            type = "compaction", encrypted_content = "synthetic-ciphertext",
          } }),
          event({ type = "response.completed", response = { id = "compacted", status = "completed" } }),
        } },
      }),
      request_max_retries = 1,
      sleep = function() end,
    })
    local compact = assert(model.compact)
    local result = wait(compact(model, {
      messages = { { role = "user", content = "Summarize" } },
      on_event = function(value)
        if value.type == "provider_status" then statuses[#statuses + 1] = value end
      end,
    }))
    assert.is_true(result.ok)
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
    assert.are.equal("cancelled", assert(result.error).kind)
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
      assert.is_true(rawget(assert(result.error), "retryable"))
      assert.are.equal(case.delay, rawget(assert(result.error), "retry_after_ms"))
    end
  end)

  it("marks partial Codex stream failures for turn replay", function()
    local chunks = {
      event({ type = "response.output_item.added", output_index = 0,
        item = { type = "reasoning", id = "reasoning", summary = {} } }),
      event({ type = "response.reasoning_summary_text.delta", output_index = 0, delta = "working" }),
      event({ type = "response.output_item.done", output_index = 0,
        item = { type = "reasoning", id = "reasoning",
          summary = { { text = "working" } } } }),
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
    assert.are.equal("upstream disconnected", assert(result.error).message)
    assert.are.equal("upstream_error", rawget(assert(result.error), "code"))
    assert.is_true(rawget(assert(result.error), "retryable"))
    assert.are.equal(5, rawget(assert(result.error), "stream_max_retries"))
    assert.are.equal("working", assert(assert(result.message).content[1]).thinking)
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
        ["X-Codex-Primary-Reset-At"] = "-1",
        ["X-Codex-Secondary-Used-Percent"] = "0",
        ["X-Codex-Secondary-Window-Minutes"] = "0",
      },
    } })
    ---@type Neoagent.ModelEvent[]
    local emitted = {}
    local result = wait(codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport,
    }):stream({ messages = {}, on_event = function(value) emitted[#emitted + 1] = value end }))
    assert(result.ok)
    assert.are.equal("provider_status", emitted[#emitted].type)
    assert.are.equal("weekly 79% left", emitted[#emitted].text)
    assert.are.equal(0.79,
      assert(assert(emitted[#emitted].details).limits[1].primary).remaining)
  end)

  it("reports a secondary quota when the primary window is absent", function()
    local text, details = codex.rate_limit_status({
      ["X-Codex-Secondary-Used-Percent"] = "25",
      ["X-Codex-Secondary-Window-Minutes"] = "10080",
    })
    assert.are.equal("weekly 75% left", text)
    assert.is_nil(assert(assert(details).limits[1]).primary)
    assert.are.equal(0.75, assert(assert(assert(details).limits[1]).secondary).remaining)
  end)

  it("derives provider status from rate-limit error headers", function()
    local transport = fake_transport.new({ {
      status = 429,
      chunks = { ' {"error":{"message":"The usage limit has been reached"}}' },
      headers = {
        ["X-Codex-Primary-Used-Percent"] = "100",
        ["X-Codex-Primary-Window-Minutes"] = "10080",
      },
    } })
    local result = wait(codex.new({
      provider = "openai-codex", model = "gpt-test", base_url = "https://example.test/codex",
      transport = transport,
    }):stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("weekly 0% left", rawget(assert(result.error), "provider_status"))
    assert.are.equal(0,
      rawget(assert(result.error), "provider_status_details").limits[1].primary.remaining)
  end)

  it("normalizes structured retry hints and cancellation failures", function()
    local result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = fake_transport.new({ { error = {
        kind = "transport",
        message = "request failed",
        detail = { error = { code = "server_error", message = "try later" } },
        response = { status = 503, headers = { ["retry-after"] = "2" } },
      } } }),
      request_max_retries = 0,
    }):stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("server_error", rawget(assert(result.error), "code"))
    assert.are.equal(2000, rawget(assert(result.error), "retry_after_ms"))

    result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = fake_transport.new({ { chunks = { event({
        type = "response.failed",
        response = { error = {
          code = "rate_limit_exceeded",
          message = "Please try again later.",
        } },
      }) } } }),
      request_max_retries = 0,
    }):stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.is_true(rawget(assert(result.error), "retryable"))
    assert.is_nil(rawget(assert(result.error), "retry_after_ms"))

    result = wait(codex.new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "https://example.test/codex",
      transport = fake_transport.new({ { error = {
        kind = "cancelled", message = "request cancelled",
      } } }),
      request_max_retries = 1,
    }):stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
  end)
end)
