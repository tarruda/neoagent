local openai = require("neoagent.api.openai_completions")
local agent_loop = require("neoagent.agent_loop")
local async = require("neoagent.async")
local fake_transport = require("tests.helpers.fake_transport")

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end

describe("neoagent.api.openai_completions", function()
  it("streams normalized text, thinking, usage, and tools", function()
    local fake = fake_transport.new({ {
      chunks = {
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\",\"content\":\"Hi\",\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"ec\",\"arguments\":\"{\\\"text\\\":\"}}]}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"ho\",\"arguments\":\"\\\"ok\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5}}\n\n",
        "data: [DONE]\n\n",
      },
    } })
    local events = {}
    local model = openai.new({ provider = "local", model = "test", base_url = "http://localhost/v1", transport = fake })
    local result = wait(model:stream({
      messages = { { role = "user", content = "Hello" } },
      tools = { { name = "echo", description = "Echo", input_schema = {} } },
      on_event = function(event) events[#events + 1] = event end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("Hi", result.text)
    assert.are.equal("toolUse", result.message.stopReason)
    assert.are.equal("echo", result.message.content[3].name)
    assert.are.same({ text = "ok" }, result.message.content[3].arguments)
    assert.are.equal(5, result.message.usage.totalTokens)
    assert.are.equal(5, #events)
    assert.are.equal(1, fake.requests[1].body:find('{"messages":', 1, true))
    assert.is_truthy(fake.requests[1].body:find(
      '"function":{"description":"Echo","name":"echo","parameters":{}}', 1, true
    ))
  end)

  it("normalizes prompt progress and rolls generation timing over three seconds", function()
    local fake = fake_transport.new({ {
      chunks = {
        'data: {"choices":[{"delta":{"content":null,"role":"assistant"}}],"prompt_progress":{"total":300,"cache":100,"processed":150,"time_ms":1000},"timings":{"prompt_n":50,"prompt_ms":1,"prompt_per_second":1000000,"predicted_n":0,"predicted_ms":0,"predicted_per_second":0}}\n\n',
        'data: {"choices":[{"delta":{"content":null,"role":"assistant"}}],"prompt_progress":{"total":300,"cache":100,"processed":250,"time_ms":2000},"timings":{"prompt_n":150,"prompt_ms":2000,"prompt_per_second":75,"predicted_n":0,"predicted_ms":0,"predicted_per_second":0}}\n\n',
        'data: {"choices":[{"delta":{"content":"a"}}],"timings":{"prompt_n":200,"prompt_ms":2500,"prompt_per_second":80,"predicted_n":1,"predicted_ms":1,"predicted_per_second":7}}\n\n',
        'data: {"choices":[{"delta":{"content":"b"}}],"timings":{"prompt_n":200,"prompt_ms":2500,"prompt_per_second":80,"predicted_n":21,"predicted_ms":1001,"predicted_per_second":7}}\n\n',
        'data: {"choices":[{"delta":{"content":"c"}}],"timings":{"prompt_n":200,"prompt_ms":2500,"prompt_per_second":80,"predicted_n":51,"predicted_ms":2001,"predicted_per_second":7}}\n\n',
        'data: {"choices":[{"delta":{"content":"d"}}],"timings":{"prompt_n":200,"prompt_ms":2500,"prompt_per_second":80,"predicted_n":91,"predicted_ms":3001,"predicted_per_second":7}}\n\n',
        'data: {"choices":[{"delta":{"content":"e"},"finish_reason":"stop"}],"timings":{"prompt_n":200,"prompt_ms":2500,"prompt_per_second":80,"predicted_n":141,"predicted_ms":4001,"predicted_per_second":7}}\n\n',
      },
    } })
    local model = openai.new({
      provider = "compatible",
      model = "test",
      base_url = "http://localhost/v1",
      transport = fake,
    })
    local observed = {}
    local function stream()
      return wait(model:stream({
        messages = {},
        on_event = function(event)
          if event.type == "inference_stats" then
            observed[#observed + 1] = event
          end
        end,
      }))
    end

    assert.is_true(stream().ok)
    assert.are.same({
      {
        type = "inference_stats",
        elapsed_ms = 1000,
        prompt_tokens_per_second = 50,
      },
      {
        type = "inference_stats",
        elapsed_ms = 2000,
        prompt_tokens_per_second = 75,
      },
      {
        type = "inference_stats",
        generation_tokens_per_second = 20,
      },
      {
        type = "inference_stats",
        generation_tokens_per_second = 25,
      },
      {
        type = "inference_stats",
        generation_tokens_per_second = 30,
      },
      {
        type = "inference_stats",
        generation_tokens_per_second = 40,
      },
    }, observed)
  end)

  it("resets and bounds rolling generation samples", function()
    local chunks = {}
    local function sample(tokens, elapsed_ms, content, finish_reason)
      chunks[#chunks + 1] = "data: " .. vim.json.encode({
        choices = { {
          delta = { content = content or "x" },
          finish_reason = finish_reason,
        } },
        timings = {
          predicted_n = tokens,
          predicted_ms = elapsed_ms,
        },
      }) .. "\n\n"
    end
    sample(10, 1000)
    sample(5, 500)
    for index = 1, 170 do
      sample(5 + index, 500 + index * 100)
    end
    sample(176, 17600, "done", "stop")

    local observed = {}
    local model = openai.new({
      provider = "compatible",
      model = "rolling",
      base_url = "http://localhost/v1",
      transport = fake_transport.new({ { chunks = chunks } }),
    })
    local result = wait(model:stream({
      messages = {},
      on_event = function(event)
        if event.type == "inference_stats" then
          observed[#observed + 1] = event
        end
      end,
    }))
    assert.is_true(result.ok)
    assert.is_true(#observed > 0)
    assert.are.equal(10,
      observed[#observed].generation_tokens_per_second)
  end)

  it("requests usage in streamed responses by default", function()
    local model = openai.new({
      provider = "local",
      model = "test",
      base_url = "http://localhost/v1",
    })
    local request = model:_request({ messages = {} })

    assert.is_true(request.body.stream_options.include_usage)
  end)

  it("applies request timeouts from construction and stream options", function()
    local fake = fake_transport.new({
      { chunks = { "data: [DONE]\n\n" } },
      { chunks = { "data: [DONE]\n\n" } },
    })
    local model = openai.new({
      provider = "local",
      model = "test",
      base_url = "http://localhost/v1",
      transport = fake,
      timeout_ms = 30000,
    })
    local result = wait(model:stream({
      messages = {},
      timeout_ms = 45000,
    }))
    assert.is_true(result.ok)
    assert.are.equal(45000, fake.requests[1].timeout_ms)

    result = wait(model:stream({ messages = {} }))
    assert.is_true(result.ok)
    assert.are.equal(30000, fake.requests[2].timeout_ms)

    fake.responses = { { chunks = { "data: [DONE]\n\n" } } }
    result = wait(model:stream({ messages = {}, timeout_ms = false }))
    assert.is_true(result.ok)
    assert.is_false(fake.requests[3].timeout_ms)

    local plain = openai.new({
      provider = "local",
      model = "test",
      base_url = "http://localhost/v1",
      transport = fake_transport.new({ { chunks = { "data: [DONE]\n\n" } } }),
    })
    assert.is_nil(plain.timeout_ms)
    assert.is_nil(plain:_request({ messages = {} }).timeout_ms)
    assert.has_error(function()
      openai.new({
        provider = "local",
        model = "test",
        base_url = "http://localhost/v1",
        timeout_ms = 0,
      })
    end, "timeout_ms must be a positive integer")
  end)

  it("recursively merges request options without mutating inputs", function()
    local provider_opts = {
      headers = { ["X-Test"] = "provider" },
      body = { nested = { provider = true }, temperature = 1 },
    }
    local fake = fake_transport.new({ { chunks = { "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n" } } })
    local model = openai.new({
      provider = "local",
      model = "test",
      base_url = "http://localhost/v1/",
      api_key = "secret",
      request_opts = provider_opts,
      transport = fake,
    })
    local result = wait(model:stream({
      messages = {},
      request_opts = function(ctx)
        assert.are.equal(true, ctx.request.body.nested.provider)
        return {
          headers = { ["x-test"] = "call" },
          body = { nested = { call = true }, temperature = 0 },
        }
      end,
    }))
    assert.is_true(result.ok)
    local request = fake.requests[1]
    assert.are.equal("http://localhost/v1/chat/completions", request.url)
    assert.are.equal("call", request.headers["X-Test"])
    assert.are.equal("Bearer secret", request.headers.Authorization)
    local body = vim.json.decode(request.body)
    assert.are.same({ provider = true, call = true }, body.nested)
    assert.are.equal(0, body.temperature)
    assert.are.same({ provider = true }, provider_opts.body.nested)
  end)

  it("encodes multimodal history, tools, and dynamic model options", function()
    local key_calls = 0
    local model = openai.new({
      provider = "local",
      model = "test",
      base_url = "http://localhost/v1",
      api_key = function()
        key_calls = key_calls + 1
        return "dynamic"
      end,
      max_output_tokens = 256,
    })
    local request = model:_request({
      system_prompt = "Be precise",
      messages = {
        { role = "user", content = {
          { type = "text", text = "inspect this" },
          { type = "image", mimeType = "image/png", data = "AAAA" },
        } },
        { role = "assistant", content = {
          { type = "text", text = "checking" },
          { type = "toolCall", id = "call-1", name = "inspect",
            arguments = { zeta = true, path = "x.lua", alpha = { second = 2, first = 1 } } },
        } },
        { role = "toolResult", toolCallId = "call-1", content = {
          { type = "image", mimeType = "image/jpeg", data = "BBBB" },
        } },
        { role = "toolResult", toolCallId = "call-2", content = {} },
      },
      tools = { { name = "inspect", description = "Inspect a file", input_schema = { type = "object" } } },
      request_opts = { url = "http://override/v1/chat/completions", body = { temperature = 0 } },
    })

    assert.are.equal(1, key_calls)
    assert.are.equal("Bearer dynamic", request.headers.Authorization)
    assert.are.equal("http://override/v1/chat/completions", request.url)
    assert.are.equal(256, request.body.max_completion_tokens)
    assert.are.equal(0, request.body.temperature)
    assert.are.equal("Be precise", request.body.messages[1].content)
    assert.are.equal("data:image/png;base64,AAAA", request.body.messages[2].content[2].image_url.url)
    assert.are.equal("checking", request.body.messages[3].content)
    assert.are.equal([[{"alpha":{"first":1,"second":2},"path":"x.lua","zeta":true}]],
      request.body.messages[3].tool_calls[1]["function"].arguments)
    assert.are.equal("(see attached image)", request.body.messages[4].content)
    assert.are.equal("(no tool output)", request.body.messages[5].content)
    assert.are.equal("data:image/jpeg;base64,BBBB", request.body.messages[6].content[2].image_url.url)
    assert.are.equal("inspect", request.body.tools[1]["function"].name)
  end)

  it("converts tool images into a following user message", function()
    local converted = openai._encode_messages({ {
      role = "toolResult",
      toolCallId = "c1",
      content = {
        { type = "text", text = "image" },
        { type = "image", mimeType = "image/png", data = "AAAA" },
      },
    } })
    assert.are.equal("tool", converted[1].role)
    assert.are.equal("user", converted[2].role)
    assert.are.equal("data:image/png;base64,AAAA", converted[2].content[2].image_url.url)
  end)

  it("keeps parallel tool results contiguous before converted images", function()
    local converted = openai._encode_messages({
      { role = "assistant", content = {
        { type = "toolCall", id = "c1", name = "read_file", arguments = {} },
        { type = "toolCall", id = "c2", name = "read_file", arguments = {} },
      } },
      { role = "toolResult", toolCallId = "c1", content = {
        { type = "text", text = "first" },
        { type = "image", mimeType = "image/png", data = "AAAA" },
      } },
      { role = "toolResult", toolCallId = "c2", content = {
        { type = "text", text = "second" },
        { type = "image", mimeType = "image/png", data = "BBBB" },
      } },
    })

    assert.are.same({ "assistant", "tool", "tool", "user", "user" },
      vim.tbl_map(function(message) return message.role end, converted))
    assert.are.equal("c1", converted[2].tool_call_id)
    assert.are.equal("c2", converted[3].tool_call_id)
    assert.are.equal("data:image/png;base64,AAAA",
      converted[4].content[2].image_url.url)
    assert.are.equal("data:image/png;base64,BBBB",
      converted[5].content[2].image_url.url)
  end)

  it("flushes tool-result images before the following conversation turn", function()
    local converted = openai._encode_messages({
      { role = "toolResult", toolCallId = "c1", content = {
        { type = "image", mimeType = "image/png", data = "AAAA" },
      } },
      { role = "user", content = "continue" },
    })

    assert.are.same({ "tool", "user", "user" },
      vim.tbl_map(function(message) return message.role end, converted))
    assert.are.equal("data:image/png;base64,AAAA",
      converted[2].content[2].image_url.url)
    assert.are.equal("continue", converted[3].content)
  end)

  it("normalizes malformed tool arguments for recovery by the Agent Loop", function()
    local fake = fake_transport.new({ { chunks = {
      "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"bad\",\"arguments\":\"{\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
    } } })
    local model = openai.new({ provider = "p", model = "m", base_url = "http://x", transport = fake })
    local result = wait(model:stream({ messages = {} }))
    assert.is_true(result.ok)
    assert.are.equal("toolUse", result.message.stopReason)
    assert.are.same({}, result.message.content[1].arguments)
    assert.are.equal("Tool arguments are not valid JSON", result.message.content[1].argumentsError)
  end)

  it("returns malformed tool arguments to the model as a tool error", function()
    local fake = fake_transport.new({ {
      chunks = {
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"edit_file\",\"arguments\":\"{\\\"edits\\\":[\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
      },
    }, {
      chunks = {
        "data: {\"choices\":[{\"delta\":{\"content\":\"recovered\"},\"finish_reason\":\"stop\"}]}\n\n",
      },
    } })
    local executed = false
    local model = openai.new({
      provider = "deepseek",
      model = "deepseek-v4-pro",
      base_url = "http://x",
      transport = fake,
    })
    local result = wait(agent_loop.run({
      model = model,
      messages = { { role = "user", content = "Edit the file" } },
      commit_message = function() return true end,
      tools = { {
        name = "edit_file",
        description = "Edit a file",
        input_schema = { type = "object" },
        execute = function()
          executed = true
          return { content = { { type = "text", text = "edited" } } }
        end,
      } },
    }))

    assert.is_true(result.ok)
    assert.is_false(executed)
    assert.are.equal("recovered", result.text)
    assert.is_true(result.new_messages[2].isError)
    assert.matches("valid JSON", result.new_messages[2].content[1].text)
    local retry = vim.json.decode(fake.requests[2].body)
    assert.are.equal("{}", retry.messages[2].tool_calls[1]["function"].arguments)
    assert.matches("valid JSON", retry.messages[3].content)
  end)

  it("normalizes array tool arguments for recovery by the Agent Loop", function()
    local fake = fake_transport.new({ { chunks = {
      "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"edit\",\"arguments\":\"[]\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
    } } })
    local model = openai.new({ provider = "p", model = "m", base_url = "http://x", transport = fake })
    local result = wait(model:stream({ messages = {} }))
    assert.is_true(result.ok)
    assert.are.same({}, result.message.content[1].arguments)
    assert.are.equal("Tool arguments are not a JSON object", result.message.content[1].argumentsError)
  end)

  it("rejects unsupported request option fields", function()
    local model = openai.new({
      provider = "p",
      model = "m",
      base_url = "http://x",
      request_opts = { timeout = 10 },
      transport = fake_transport.new(),
    })
    local result = wait(model:stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("model", result.error.kind)
    assert.matches("Unsupported", result.error.message)
  end)

  it("rejects invalid request overrides and unsupported history", function()
    local cases = {
      { opts = { request_opts = { url = "" } }, message = "url" },
      { opts = { request_opts = { headers = "bad" } }, message = "headers" },
      { opts = { request_opts = { body = "bad" } }, message = "body" },
      { opts = { request_opts = function() return nil end }, message = "table" },
      { opts = { messages = { { role = "system", content = "unexpected" } } }, message = "unsupported message role" },
    }
    for _, case in ipairs(cases) do
      local fake = fake_transport.new()
      local model = openai.new({ provider = "p", model = "m", base_url = "http://x", transport = fake })
      local opts = case.opts
      opts.messages = opts.messages or {}
      local result = wait(model:stream(opts))
      assert.is_false(result.ok)
      assert.matches(case.message, result.error.message)
      assert.are.equal(0, #fake.requests)
    end
  end)

  it("reports provider and stream protocol failures", function()
    local cases = {
      { chunk = "data: not-json\n\n", kind = "protocol", message = "Invalid JSON" },
      { chunk = "data: {\"error\":{\"message\":\"overloaded\"}}\n\n", kind = "model", message = "overloaded" },
      { chunk = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}\n\n", kind = "model", message = "finish_reason" },
      { chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n", kind = "protocol", message = "without finish_reason" },
    }
    for _, case in ipairs(cases) do
      local fake = fake_transport.new({ { chunks = { case.chunk } } })
      local model = openai.new({ provider = "p", model = "m", base_url = "http://x", transport = fake })
      local result = wait(model:stream({ messages = {} }))
      assert.is_false(result.ok)
      assert.are.equal(case.kind, result.error.kind)
      assert.matches(case.message, result.error.message)
    end

    local oversized = fake_transport.new({ { chunks = {
      "data: " .. string.rep("x", 1024 * 1024 + 1),
    } } })
    local oversized_model = openai.new({
      provider = "p", model = "m", base_url = "http://x",
      transport = oversized,
    })
    local oversized_result = wait(oversized_model:stream({ messages = {} }))
    assert.is_false(oversized_result.ok)
    assert.are.equal("protocol", oversized_result.error.kind)
    assert.matches("SSE pending buffer exceeded", oversized_result.error.message)

    local missing_delta = fake_transport.new({ { chunks = {
      'data: {"choices":[{"delta":"invalid","finish_reason":"stop"}]}\n\n',
    } } })
    local missing_delta_model = openai.new({
      provider = "p", model = "m", base_url = "http://x",
      transport = missing_delta,
    })
    local missing_delta_result = wait(missing_delta_model:stream({ messages = {} }))
    assert.is_true(missing_delta_result.ok)
    assert.are.same({}, missing_delta_result.message.content)

    local fake = fake_transport.new({ { chunks = {
      "data: {\"choices\":[{\"delta\":{\"content\":\"cut off\"},\"finish_reason\":\"length\"}]}\n\n",
    } } })
    local model = openai.new({ provider = "p", model = "m", base_url = "http://x", transport = fake })
    local result = wait(model:stream({ messages = {} }))
    assert.is_true(result.ok)
    assert.are.equal("length", result.message.stopReason)

    local thrown_transport = {
      request = function()
        return async.run(function() error("transport exploded") end)
      end,
    }
    local thrown_model = openai.new({
      provider = "p",
      model = "m",
      base_url = "http://x",
      transport = thrown_transport,
    })
    local thrown = wait(thrown_model:stream({ messages = {} }))
    assert.is_false(thrown.ok)
    assert.matches("transport exploded", thrown.error.message)
  end)

  it("requires streamed tool calls to have ids and names", function()
    local cases = {
      { call = "{\"index\":0,\"function\":{\"name\":\"edit\",\"arguments\":\"{}\"}}", message = "missing an id" },
      { call = "{\"index\":0,\"id\":\"c1\",\"function\":{\"arguments\":\"{}\"}}", message = "missing a name" },
    }
    for _, case in ipairs(cases) do
      local chunk = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[" .. case.call .. "]},\"finish_reason\":\"tool_calls\"}]}\n\n"
      local fake = fake_transport.new({ { chunks = { chunk } } })
      local model = openai.new({ provider = "p", model = "m", base_url = "http://x", transport = fake })
      local result = wait(model:stream({ messages = {} }))
      assert.is_false(result.ok)
      assert.are.equal("protocol", result.error.kind)
      assert.matches(case.message, result.error.message)
    end
  end)

  it("accepts natural empty Lua dictionaries in request options", function()
    local fake = fake_transport.new({ { chunks = {
      "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
    } } })
    local model = openai.new({ provider = "p", model = "m", base_url = "http://x", transport = fake })
    local result = wait(model:stream({ messages = {}, request_opts = { headers = {}, body = {} } }))
    assert.is_true(result.ok)
  end)
end)
