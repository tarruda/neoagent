local anthropic = require("neoagent.api.anthropic_messages")
local fake_transport = require("tests.helpers.fake_transport")

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end

local function event(value)
  return "event: " .. value.type .. "\ndata: " .. vim.json.encode(value) .. "\n\n"
end

local function message_start(usage)
  return event({
    type = "message_start",
    message = {
      id = "msg_1",
      type = "message",
      role = "assistant",
      content = {},
      model = "test",
      stop_reason = vim.NIL,
      usage = usage or { input_tokens = 2, output_tokens = 0 },
    },
  })
end

describe("neoagent.api.anthropic_messages", function()
  it("streams normalized thinking, text, tools, and usage", function()
    local fake = fake_transport.new({ { chunks = {
      message_start({
        input_tokens = 10,
        output_tokens = 0,
        cache_read_input_tokens = 2,
        cache_creation_input_tokens = 1,
      }),
      event({
        type = "content_block_start",
        index = 0,
        content_block = { type = "thinking", thinking = "" },
      }),
      event({
        type = "content_block_delta",
        index = 0,
        delta = { type = "thinking_delta", thinking = "consider" },
      }),
      event({
        type = "content_block_start",
        index = 1,
        content_block = { type = "text", text = "" },
      }),
      event({
        type = "content_block_delta",
        index = 1,
        delta = { type = "text_delta", text = "Checking." },
      }),
      event({
        type = "content_block_start",
        index = 2,
        content_block = { type = "tool_use", id = "call_1", name = "inspect", input = {} },
      }),
      event({
        type = "content_block_delta",
        index = 2,
        delta = { type = "input_json_delta", partial_json = "{\"path\":" },
      }),
      event({
        type = "content_block_delta",
        index = 2,
        delta = { type = "input_json_delta", partial_json = "\"x.lua\"}" },
      }),
      event({
        type = "content_block_delta",
        index = 0,
        delta = { type = "signature_delta", signature = "sig_1" },
      }),
      event({ type = "content_block_stop", index = 0 }),
      event({ type = "content_block_stop", index = 1 }),
      event({ type = "content_block_stop", index = 2 }),
      event({
        type = "message_delta",
        delta = { stop_reason = "tool_use", stop_sequence = vim.NIL },
        usage = { output_tokens = 3 },
      }),
      event({ type = "message_stop" }),
    } } })
    local events = {}
    local model = anthropic.new({
      provider = "local",
      model = "test",
      base_url = "http://localhost/v1",
      transport = fake,
    })
    local result = wait(model:stream({
      messages = { { role = "user", content = "Inspect it" } },
      on_event = function(value) events[#events + 1] = value end,
    }))

    assert.is_true(result.ok)
    assert.are.equal("Checking.", result.text)
    assert.are.equal("toolUse", result.message.stopReason)
    assert.are.equal("msg_1", result.message.responseId)
    assert.are.equal("consider", result.message.content[1].thinking)
    assert.are.equal("sig_1", result.message.content[1].thinkingSignature)
    assert.are.equal("inspect", result.message.content[3].name)
    assert.are.same({ path = "x.lua" }, result.message.content[3].arguments)
    assert.are.equal(10, result.message.usage.input)
    assert.are.equal(3, result.message.usage.output)
    assert.are.equal(2, result.message.usage.cacheRead)
    assert.are.equal(1, result.message.usage.cacheWrite)
    assert.are.equal(16, result.message.usage.totalTokens)
    assert.are.equal(6, #events)
  end)

  it("encodes Anthropic history, images, tools, and layered request options", function()
    local key_calls = 0
    local provider_opts = {
      headers = { ["X-Test"] = "provider" },
      body = { metadata = { provider = true } },
    }
    local model = anthropic.new({
      provider = "local",
      model = "test",
      base_url = "http://localhost/v1/",
      api_key = function()
        key_calls = key_calls + 1
        return "secret"
      end,
      max_output_tokens = 256,
      request_opts = provider_opts,
    })
    local request = model:_request({
      system_prompt = "Be precise",
      messages = {
        { role = "user", content = {
          { type = "text", text = "inspect this" },
          { type = "image", mimeType = "image/png", data = "AAAA" },
        } },
        { role = "assistant", content = {
          { type = "thinking", thinking = "signed", thinkingSignature = "sig" },
          { type = "thinking", thinking = "hidden", thinkingSignature = "cipher", redacted = true },
          { type = "text", text = "checking" },
          { type = "toolCall", id = "call:1", name = "inspect", arguments = { path = "x.lua" } },
        } },
        { role = "toolResult", toolCallId = "call:1", isError = true, content = {
          { type = "text", text = "failed" },
          { type = "image", mimeType = "image/jpeg", data = "BBBB" },
        } },
        { role = "toolResult", toolCallId = "call:2", content = {} },
        { role = "toolResult", toolCallId = "call:3", content = {
          { type = "image", mimeType = "image/png", data = "CCCC" },
        } },
        { role = "user", content = "Continue" },
        { role = "assistant", content = {
          { type = "thinking", thinking = "unsigned", thinkingSignature = "" },
        } },
      },
      tools = { {
        name = "inspect",
        description = "Inspect a file",
        input_schema = { type = "object", properties = {} },
      } },
      request_opts = function(context)
        assert.is_true(context.request.body.metadata.provider)
        return {
          headers = { ["x-test"] = "call" },
          body = { metadata = { call = true } },
        }
      end,
    })

    assert.are.equal(1, key_calls)
    assert.are.equal("http://localhost/v1/messages", request.url)
    assert.are.equal("secret", request.headers["x-api-key"])
    assert.are.equal("2023-06-01", request.headers["anthropic-version"])
    assert.are.equal("call", request.headers["X-Test"])
    assert.are.equal("Be precise", request.body.system)
    assert.are.equal(256, request.body.max_tokens)
    assert.are.same({ provider = true, call = true }, request.body.metadata)
    assert.are.equal("base64", request.body.messages[1].content[2].source.type)
    assert.are.equal("image/png", request.body.messages[1].content[2].source.media_type)
    assert.are.equal("thinking", request.body.messages[2].content[1].type)
    assert.are.equal("redacted_thinking", request.body.messages[2].content[2].type)
    assert.are.equal("call_1", request.body.messages[2].content[4].id)
    assert.are.equal(3, #request.body.messages[3].content)
    assert.are.equal("call_1", request.body.messages[3].content[1].tool_use_id)
    assert.is_true(request.body.messages[3].content[1].is_error)
    assert.are.equal("image", request.body.messages[3].content[1].content[2].type)
    assert.are.equal("(no tool output)", request.body.messages[3].content[2].content)
    assert.are.equal("(see attached image)", request.body.messages[3].content[3].content[1].text)
    assert.are.equal("text", request.body.messages[5].content[1].type)
    assert.are.equal("unsigned", request.body.messages[5].content[1].text)
    assert.are.equal("inspect", request.body.tools[1].name)
    assert.are.equal("object", request.body.tools[1].input_schema.type)
    assert.are.same({ provider = true }, provider_opts.body.metadata)
  end)

  it("returns malformed tool input as a protocol failure with partial output", function()
    local fake = fake_transport.new({ { chunks = {
      message_start(),
      event({
        type = "content_block_start",
        index = 0,
        content_block = { type = "tool_use", id = "call_1", name = "broken", input = {} },
      }),
      event({
        type = "content_block_delta",
        index = 0,
        delta = { type = "input_json_delta", partial_json = "{" },
      }),
      event({ type = "content_block_stop", index = 0 }),
    } } })
    local model = anthropic.new({
      provider = "p",
      model = "m",
      base_url = "http://x",
      transport = fake,
    })
    local result = wait(model:stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)
    assert.are.equal("error", result.message.stopReason)
    assert.matches("Tool input", result.error.message)
  end)

  it("reports provider, stop-reason, transport, and stream protocol failures", function()
    local cases = {
      {
        chunks = { "event: message_start\ndata: not-json\n\n" },
        kind = "protocol",
        message = "Invalid JSON",
      },
      {
        chunks = { event({
          type = "error",
          error = { type = "overloaded_error", message = "overloaded" },
        }) },
        kind = "model",
        message = "overloaded",
      },
      {
        chunks = {
          message_start(),
          event({
            type = "content_block_start",
            index = 0,
            content_block = { type = "text", text = "partial" },
          }),
        },
        kind = "protocol",
        message = "message_stop",
        partial = "partial",
      },
      {
        chunks = {
          message_start(),
          event({
            type = "message_delta",
            delta = { stop_reason = "future_reason" },
            usage = { output_tokens = 1 },
          }),
        },
        kind = "model",
        message = "stop_reason",
      },
    }
    for _, case in ipairs(cases) do
      local fake = fake_transport.new({ { chunks = case.chunks } })
      local model = anthropic.new({
        provider = "p",
        model = "m",
        base_url = "http://x",
        transport = fake,
      })
      local result = wait(model:stream({ messages = {} }))
      assert.is_false(result.ok)
      assert.are.equal(case.kind, result.error.kind)
      assert.matches(case.message, result.error.message)
      if case.partial then assert.are.equal(case.partial, result.message.content[1].text) end
    end

    local fake = fake_transport.new({ {
      chunks = {
        message_start(),
        event({
          type = "content_block_start",
          index = 0,
          content_block = { type = "text", text = "cut off" },
        }),
      },
      error = { kind = "transport", message = "connection lost" },
    } })
    local model = anthropic.new({
      provider = "p",
      model = "m",
      base_url = "http://x",
      transport = fake,
    })
    local result = wait(model:stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("transport", result.error.kind)
    assert.are.equal("cut off", result.message.content[1].text)
  end)

  it("accepts redacted thinking, pings, and citation deltas", function()
    local fake = fake_transport.new({ { chunks = {
      message_start(),
      event({ type = "ping" }),
      event({
        type = "content_block_start",
        index = 0,
        content_block = { type = "redacted_thinking", data = "cipher" },
      }),
      event({ type = "content_block_stop", index = 0 }),
      event({
        type = "content_block_start",
        index = 1,
        content_block = { type = "text", text = "answer" },
      }),
      event({
        type = "content_block_delta",
        index = 1,
        delta = { type = "citations_delta", citation = { type = "page_location" } },
      }),
      event({ type = "content_block_stop", index = 1 }),
      event({
        type = "message_delta",
        delta = { stop_reason = "end_turn" },
        usage = { output_tokens = 1 },
      }),
      event({ type = "message_stop" }),
    } } })
    local deltas = {}
    local model = anthropic.new({
      provider = "p",
      model = "m",
      base_url = "http://x",
      transport = fake,
    })
    local result = wait(model:stream({
      messages = {},
      on_event = function(value)
        if value.type == "thinking_delta" then deltas[#deltas + 1] = value.text end
      end,
    }))

    assert.is_true(result.ok)
    assert.are.equal("answer", result.text)
    assert.is_true(result.message.content[1].redacted)
    assert.are.equal("cipher", result.message.content[1].thinkingSignature)
    assert.are.same({ "[Reasoning redacted]" }, deltas)
  end)

  it("rejects refusal and sensitive stop reasons", function()
    for _, case in ipairs({
      { reason = "refusal", details = { explanation = "cannot comply" }, message = "cannot comply" },
      { reason = "sensitive", message = "sensitive" },
    }) do
      local fake = fake_transport.new({ { chunks = {
        message_start(),
        event({
          type = "message_delta",
          delta = { stop_reason = case.reason, stop_details = case.details },
          usage = { output_tokens = 1 },
        }),
      } } })
      local model = anthropic.new({
        provider = "p",
        model = "m",
        base_url = "http://x",
        transport = fake,
      })
      local result = wait(model:stream({ messages = {} }))
      assert.is_false(result.ok)
      assert.are.equal("model", result.error.kind)
      assert.matches(case.message, result.error.message)
    end
  end)

  it("rejects malformed Anthropic event sequences", function()
    local cases = {
      {
        chunks = { message_start(), event({
          type = "content_block_start", index = "bad", content_block = { type = "text" },
        }) },
        message = "content_block_start",
      },
      {
        chunks = {
          message_start(),
          event({ type = "content_block_start", index = 0, content_block = { type = "text" } }),
          event({ type = "content_block_start", index = 0, content_block = { type = "text" } }),
        },
        message = "started twice",
      },
      {
        chunks = { message_start(), event({
          type = "content_block_start", index = 0, content_block = { type = "server_tool_use" },
        }) },
        message = "Unsupported Anthropic content block",
      },
      {
        chunks = { message_start(), event({
          type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "x" },
        }) },
        message = "no active content block",
      },
      {
        chunks = {
          message_start(),
          event({ type = "content_block_start", index = 0, content_block = { type = "text" } }),
          event({ type = "content_block_delta", index = 0, delta = { type = "future_delta" } }),
        },
        message = "Unsupported Anthropic content delta",
      },
      {
        chunks = { message_start(), event({ type = "content_block_stop", index = 0 }) },
        message = "stopped without a start",
      },
      {
        chunks = {
          message_start(),
          event({
            type = "content_block_start", index = 0,
            content_block = { type = "tool_use", name = "inspect", input = {} },
          }),
          event({ type = "content_block_stop", index = 0 }),
        },
        message = "missing an id",
      },
      {
        chunks = {
          message_start(),
          event({
            type = "content_block_start", index = 0,
            content_block = { type = "tool_use", id = "c1", input = {} },
          }),
          event({ type = "content_block_stop", index = 0 }),
        },
        message = "missing a name",
      },
      {
        chunks = {
          message_start(),
          event({
            type = "content_block_start", index = 0,
            content_block = { type = "tool_use", id = "c1", name = "inspect", input = { "bad" } },
          }),
          event({ type = "content_block_stop", index = 0 }),
        },
        message = "not a JSON object",
      },
      {
        chunks = { message_start(), message_start() },
        message = "message_start",
      },
      {
        chunks = { message_start(), event({ type = "future_event" }) },
        message = "Unsupported Anthropic event",
      },
      {
        chunks = {
          event({
            type = "message_delta", delta = { stop_reason = "end_turn" },
            usage = { output_tokens = 1 },
          }),
          event({ type = "message_stop" }),
        },
        message = "message_start",
      },
      {
        chunks = { message_start(), event({ type = "message_stop" }) },
        message = "stop_reason",
      },
      {
        chunks = {
          message_start(),
          event({ type = "content_block_start", index = 0, content_block = { type = "text" } }),
          event({
            type = "message_delta", delta = { stop_reason = "end_turn" },
            usage = { output_tokens = 1 },
          }),
          event({ type = "message_stop" }),
        },
        message = "open content block",
      },
    }

    for _, case in ipairs(cases) do
      local fake = fake_transport.new({ { chunks = case.chunks } })
      local model = anthropic.new({
        provider = "p",
        model = "m",
        base_url = "http://x",
        transport = fake,
      })
      local result = wait(model:stream({ messages = {} }))
      assert.is_false(result.ok)
      assert.are.equal("protocol", result.error.kind)
      assert.matches(case.message, result.error.message)
    end
  end)

  it("maps Anthropic completion stop reasons", function()
    for reason, expected in pairs({
      end_turn = "stop",
      stop_sequence = "stop",
      pause_turn = "stop",
      max_tokens = "length",
      tool_use = "toolUse",
    }) do
      local fake = fake_transport.new({ { chunks = {
        message_start(),
        event({
          type = "message_delta",
          delta = { stop_reason = reason },
          usage = { output_tokens = 1 },
        }),
        event({ type = "message_stop" }),
      } } })
      local model = anthropic.new({
        provider = "p",
        model = "m",
        base_url = "http://x",
        transport = fake,
      })
      local result = wait(model:stream({ messages = {} }))
      assert.is_true(result.ok)
      assert.are.equal(expected, result.message.stopReason)
    end
  end)

  it("rejects invalid request options and unsupported history", function()
    local cases = {
      { opts = { request_opts = { url = "" } }, message = "url" },
      { opts = { request_opts = { headers = "bad" } }, message = "headers" },
      { opts = { request_opts = { body = "bad" } }, message = "body" },
      { opts = { request_opts = function() return nil end }, message = "table" },
      {
        opts = { messages = { { role = "system", content = "unexpected" } } },
        message = "Unsupported message role",
      },
      {
        opts = { messages = { { role = "assistant", content = {
          { type = "toolCall", id = "c1", name = "bad", arguments = "bad" },
        } } } },
        message = "Tool arguments",
      },
    }
    for _, case in ipairs(cases) do
      local fake = fake_transport.new()
      local model = anthropic.new({
        provider = "p",
        model = "m",
        base_url = "http://x",
        transport = fake,
      })
      local opts = case.opts
      opts.messages = opts.messages or {}
      local result = wait(model:stream(opts))
      assert.is_false(result.ok)
      assert.matches(case.message, result.error.message)
      assert.are.equal(0, #fake.requests)
    end
  end)
end)
