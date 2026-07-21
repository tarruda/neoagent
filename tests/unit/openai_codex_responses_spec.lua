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
