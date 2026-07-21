local fake_transport = require("tests.helpers.fake_transport")
local responses = require("neoagent.api.openai_responses")
local util = require("neoagent.util")

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end

local function event(value)
  return "data: " .. vim.json.encode(value) .. "\n\n"
end

local function model(fake, extra)
  local options = {
    provider = "local",
    model = "test",
    base_url = "http://localhost/v1",
    transport = fake,
  }
  for key, value in pairs(extra or {}) do options[key] = value end
  return responses.new(options)
end

describe("neoagent.api.openai_responses", function()
  it("streams normalized reasoning, text, tools, and usage", function()
    local reasoning = {
      type = "reasoning", id = "rs_1", summary = { { type = "summary_text", text = "think" } },
      encrypted_content = "encrypted",
    }
    local message = {
      type = "message", id = "msg_1", role = "assistant", status = "completed",
      content = { { type = "output_text", text = "Hello", annotations = util.list() } },
    }
    local call = {
      type = "function_call", id = "fc_1", call_id = "call_1", name = "echo",
      arguments = "{\"text\":\"ok\"}",
    }
    local chunks = {
      event({ type = "response.created", response = { id = "resp_1" } }),
      event({ type = "response.output_item.added", output_index = 0,
        item = { type = "reasoning", id = "rs_1", summary = util.list() } }),
      event({ type = "response.reasoning_summary_text.delta", output_index = 0, delta = "thi" }),
      event({ type = "response.reasoning_text.delta", output_index = 0, delta = "nk" }),
      event({ type = "response.reasoning_summary_part.done", output_index = 0 }),
      event({ type = "response.output_item.done", output_index = 0, item = reasoning }),
      event({ type = "response.output_item.added", output_index = 1,
        item = { type = "message", id = "msg_1", content = util.list() } }),
      event({ type = "response.output_text.delta", output_index = 1, delta = "Hel" }),
      event({ type = "response.refusal.delta", output_index = 1, delta = "lo" }),
      event({ type = "response.output_item.done", output_index = 1, item = message }),
      event({ type = "response.output_item.added", output_index = 2,
        item = { type = "function_call", id = "fc_1", call_id = "call_1", name = "echo", arguments = "" } }),
      event({ type = "response.function_call_arguments.delta", output_index = 2, delta = "{\"text\":" }),
      event({ type = "response.function_call_arguments.done", output_index = 2,
        arguments = "{\"text\":\"ok\"}" }),
      event({ type = "response.output_item.done", output_index = 2, item = call }),
      event({
        type = "response.completed",
        response = {
          id = "resp_1", status = "completed", output = { reasoning, message, call },
          usage = {
            input_tokens = 10, output_tokens = 4, total_tokens = 14,
            input_tokens_details = { cached_tokens = 2, cache_write_tokens = 1 },
            output_tokens_details = { reasoning_tokens = 3 },
          },
        },
      }),
      "data: [DONE]\n\n",
    }
    local fake = fake_transport.new({ { chunks = chunks } })
    local emitted = {}
    local result = wait(model(fake):stream({
      messages = { { role = "user", content = "Hello" } },
      tools = { { name = "echo", description = "Echo", input_schema = { type = "object" } } },
      on_event = function(value) emitted[#emitted + 1] = value end,
    }))

    assert.is_true(result.ok)
    assert.are.equal("Hello", result.text)
    assert.are.equal("toolUse", result.message.stopReason)
    assert.are.equal("resp_1", result.message.responseId)
    assert.are.equal("think", result.message.content[1].thinking)
    assert.are.equal("encrypted", vim.json.decode(result.message.content[1].thinkingSignature).encrypted_content)
    assert.are.equal("msg_1", result.message.content[2].textSignature)
    assert.are.equal("call_1|fc_1", result.message.content[3].id)
    assert.are.same({ text = "ok" }, result.message.content[3].arguments)
    assert.are.equal(7, result.message.usage.input)
    assert.are.equal(3, result.message.usage.reasoning)
    assert.are.equal("usage", emitted[#emitted].type)
    local request = vim.json.decode(fake.requests[1].body)
    assert.is_false(request.store)
    assert.are.equal("echo", request.tools[1].name)
    assert.is_false(request.tools[1].strict)
  end)

  it("encodes stateless multimodal history and merges request options", function()
    local key_calls = 0
    local provider_opts = {
      headers = { ["X-Test"] = "provider" },
      body = { metadata = { provider = true }, temperature = 1 },
    }
    local instance = model(fake_transport.new(), {
      base_url = "http://localhost/v1/",
      api_key = function() key_calls = key_calls + 1 return "dynamic" end,
      max_output_tokens = 1,
      reasoning = true,
      reasoning_effort = "high",
      reasoning_summary = "detailed",
      request_opts_layers = { provider_opts },
    })
    local request = instance:_request({
      system_prompt = "Be precise",
      messages = {
        { role = "user", content = {
          { type = "text", text = "inspect" },
          { type = "image", mimeType = "image/png", data = "AAAA" },
        } },
        { role = "assistant", content = {
          { type = "thinking", thinking = "secret", thinkingSignature = vim.json.encode({
            type = "reasoning", id = "rs_saved", encrypted_content = "cipher", summary = util.list(),
          }) },
          { type = "text", text = "checking", textSignature = '{"id":"msg_saved"}' },
          { type = "toolCall", id = "call_saved|fc_saved", name = "inspect", arguments = { path = "x.lua" } },
        } },
        { role = "toolResult", toolCallId = "call_saved|fc_saved", content = {
          { type = "text", text = "image" },
          { type = "image", mimeType = "image/jpeg", data = "BBBB" },
        } },
        { role = "toolResult", toolCallId = "empty", content = {} },
        { role = "assistant", content = {
          { type = "toolCall", id = "legacy", name = "legacy_tool", arguments = {} },
        } },
      },
      tools = { { name = "inspect", description = "Inspect", input_schema = { type = "object" } } },
      request_opts = function(context)
        assert.is_true(context.request.body.metadata.provider)
        return {
          url = "http://override/responses",
          headers = { ["x-test"] = "call" },
          body = { metadata = { call = true }, temperature = 0 },
        }
      end,
    })

    assert.are.equal(1, key_calls)
    assert.are.equal("http://override/responses", request.url)
    assert.are.equal("Bearer dynamic", request.headers.Authorization)
    assert.are.equal("call", request.headers["X-Test"])
    assert.are.same({ provider = true, call = true }, request.body.metadata)
    assert.are.equal(0, request.body.temperature)
    assert.are.equal(16, request.body.max_output_tokens)
    assert.are.same({ effort = "high", summary = "detailed" }, request.body.reasoning)
    assert.are.same({ "reasoning.encrypted_content" }, request.body.include)
    assert.are.equal("system", request.body.input[1].role)
    assert.are.equal("data:image/png;base64,AAAA", request.body.input[2].content[2].image_url)
    assert.are.equal("reasoning", request.body.input[3].type)
    assert.are.equal("msg_saved", request.body.input[4].id)
    assert.are.equal("fc_saved", request.body.input[5].id)
    assert.are.equal("data:image/jpeg;base64,BBBB", request.body.input[6].output[2].image_url)
    assert.are.equal("(no tool output)", request.body.input[7].output)
    assert.is_nil(request.body.input[8].id)
    assert.are.same({ provider = true }, provider_opts.body.metadata)
  end)

  it("accepts terminal-only incomplete output and generated text ids", function()
    local output = { {
      type = "message", id = "msg_final", role = "assistant", status = "completed",
      content = { { type = "output_text", text = "final", annotations = util.list() } },
    } }
    local fake = fake_transport.new({ { chunks = { event({
      type = "response.incomplete",
      response = { id = "resp_final", status = "incomplete", output = output },
    }) } } })
    local deltas = {}
    local result = wait(model(fake):stream({
      messages = { { role = "assistant", content = { { type = "text", text = "old" } } } },
      on_event = function(value) if value.type == "text_delta" then deltas[#deltas + 1] = value.text end end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("length", result.message.stopReason)
    assert.are.equal("final", result.text)
    assert.are.same({ "final" }, deltas)
    local body = vim.json.decode(fake.requests[1].body)
    assert.are.equal("msg_neoagent_1_1", body.input[1].id)
  end)

  it("normalizes item-id streams that omit output indexes", function()
    local reasoning = {
      type = "reasoning", id = "rs_local", summary = util.list(),
      content = { { type = "reasoning_text", text = "think" } }, encrypted_content = "",
    }
    local message = {
      type = "message", id = "msg_local", role = "assistant", status = "completed",
      content = { { type = "output_text", text = "OK", annotations = util.list() } },
    }
    local chunks = {
      event({ type = "response.output_item.added", item = {
        type = "reasoning", id = "rs_local", summary = util.list(), content = util.list(),
      } }),
      event({ type = "response.output_item.added", item = {
        type = "message", id = "msg_local", role = "assistant", content = util.list(),
      } }),
      event({ type = "response.output_text.delta", item_id = "msg_local", delta = "OK" }),
      event({ type = "response.output_item.done", item = reasoning }),
      event({ type = "response.output_item.done", item = message }),
      event({ type = "response.completed", response = {
        id = "resp_local", status = "completed", output = { reasoning, message },
      } }),
    }
    local result = wait(model(fake_transport.new({ { chunks = chunks } })):stream({ messages = {} }))
    assert.is_true(result.ok)
    assert.are.equal("think", result.message.content[1].thinking)
    assert.are.equal("OK", result.text)
  end)

  it("replays function calls and outputs through the stateless agent loop", function()
    local call = {
      type = "function_call", id = "fc_loop", call_id = "call_loop", name = "echo", arguments = "{}",
    }
    local answer = {
      type = "message", id = "msg_loop", role = "assistant", status = "completed",
      content = { { type = "output_text", text = "done", annotations = util.list() } },
    }
    local fake = fake_transport.new({
      { chunks = {
        event({ type = "response.output_item.done", output_index = 0, item = call }),
        event({ type = "response.completed", response = { status = "completed", output = { call } } }),
      } },
      { chunks = {
        event({ type = "response.output_item.done", output_index = 0, item = answer }),
        event({ type = "response.completed", response = { status = "completed", output = { answer } } }),
      } },
    })
    local result = wait(require("neoagent.agent").run({
      model = model(fake),
      messages = { { role = "user", content = "echo" } },
      tools = { {
        name = "echo", description = "Echo", input_schema = { type = "object" },
        execute = function() return { content = { { type = "text", text = "tool output" } } } end,
      } },
    }))
    assert.is_true(result.ok)
    assert.are.equal("done", result.text)
    local second = vim.json.decode(fake.requests[2].body)
    assert.are.equal("function_call", second.input[2].type)
    assert.are.equal("fc_loop", second.input[2].id)
    assert.are.equal("function_call_output", second.input[3].type)
    assert.are.equal("call_loop", second.input[3].call_id)
    assert.are.equal("tool output", second.input[3].output)
  end)

  it("surfaces provider, protocol, history, and tool failures", function()
    local cases = {
      { chunks = { "data: not-json\n\n" }, kind = "protocol", message = "Invalid JSON" },
      { chunks = { event({ error = { message = "overloaded" } }) }, kind = "model", message = "overloaded" },
      { chunks = { event({ type = "error", message = "bad event" }) }, kind = "model", message = "bad event" },
      { chunks = { event({ type = "response.failed", response = { error = { message = "failed" } } }) },
        kind = "model", message = "failed" },
      { chunks = { event({ type = "response.completed", response = { status = "cancelled" } }) },
        kind = "model", message = "status" },
      { chunks = { event({ type = "response.output_item.added", output_index = 0,
        item = { type = "message", id = "m", content = util.list() } }),
        event({ type = "response.output_text.delta", output_index = 0, delta = "partial" }) },
        kind = "protocol", message = "terminal", partial = true },
      { chunks = { event({ type = "response.output_item.added", output_index = 0,
        item = { type = "function_call", id = "fc", call_id = "call", name = "bad", arguments = "" } }),
        event({ type = "response.output_item.done", output_index = 0,
          item = { type = "function_call", id = "fc", call_id = "call", name = "bad", arguments = "{" } }) },
        kind = "protocol", message = "JSON object", partial = true },
    }
    for _, case in ipairs(cases) do
      local result = wait(model(fake_transport.new({ { chunks = case.chunks } })):stream({ messages = {} }))
      assert.is_false(result.ok)
      assert.are.equal(case.kind, result.error.kind)
      assert.matches(case.message, result.error.message)
      assert.are.equal(case.partial == true, result.message ~= nil)
    end

    local invalid_history = {
      { messages = { { role = "system", content = "bad" } }, message = "Unsupported" },
      { messages = { { role = "assistant", content = { {
        type = "thinking", thinking = "x", thinkingSignature = "bad",
      } } } }, message = "reasoning signature" },
    }
    for _, case in ipairs(invalid_history) do
      local fake = fake_transport.new()
      local result = wait(model(fake):stream({ messages = case.messages }))
      assert.is_false(result.ok)
      assert.matches(case.message, result.error.message)
      assert.are.equal(0, #fake.requests)
    end
  end)

  it("requires final function calls to have ids and names", function()
    local cases = {
      { item = { type = "function_call", name = "echo", arguments = "{}" }, message = "id" },
      { item = { type = "function_call", id = "fc", call_id = "call", arguments = "{}" }, message = "name" },
    }
    for _, case in ipairs(cases) do
      local chunks = { event({ type = "response.output_item.done", output_index = 0, item = case.item }) }
      local result = wait(model(fake_transport.new({ { chunks = chunks } })):stream({ messages = {} }))
      assert.is_false(result.ok)
      assert.are.equal("protocol", result.error.kind)
      assert.matches(case.message, result.error.message)
    end
  end)
end)
