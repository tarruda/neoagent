local openai = require("neoagent.api.openai_completions")
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
      tools = { { name = "echo", description = "Echo", input_schema = { type = "object" } } },
      on_event = function(event) events[#events + 1] = event end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("Hi", result.text)
    assert.are.equal("toolUse", result.message.stopReason)
    assert.are.equal("echo", result.message.content[3].name)
    assert.are.same({ text = "ok" }, result.message.content[3].arguments)
    assert.are.equal(5, result.message.usage.totalTokens)
    assert.are.equal(5, #events)
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
          { type = "toolCall", id = "call-1", name = "inspect", arguments = { path = "x.lua" } },
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
    assert.are.same({ path = "x.lua" }, vim.json.decode(request.body.messages[3].tool_calls[1]["function"].arguments))
    assert.are.equal("(see attached image)", request.body.messages[4].content)
    assert.are.equal("data:image/jpeg;base64,BBBB", request.body.messages[5].content[2].image_url.url)
    assert.are.equal("(no tool output)", request.body.messages[6].content)
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

  it("returns malformed tool arguments as a protocol failure with partial output", function()
    local fake = fake_transport.new({ { chunks = {
      "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"bad\",\"arguments\":\"{\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
    } } })
    local model = openai.new({ provider = "p", model = "m", base_url = "http://x", transport = fake })
    local result = wait(model:stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)
    assert.are.equal("error", result.message.stopReason)
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
      { opts = { messages = { { role = "system", content = "unexpected" } } }, message = "Unsupported message role" },
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

    local fake = fake_transport.new({ { chunks = {
      "data: {\"choices\":[{\"delta\":{\"content\":\"cut off\"},\"finish_reason\":\"length\"}]}\n\n",
    } } })
    local model = openai.new({ provider = "p", model = "m", base_url = "http://x", transport = fake })
    local result = wait(model:stream({ messages = {} }))
    assert.is_true(result.ok)
    assert.are.equal("length", result.message.stopReason)
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
