local assert = require("luassert")
local recovery = require("neoagent.providers.opencode_go.model")
local fake = require("tests.helpers.fake_model")
local util = require("neoagent.util")

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end
local function missing(text)
  local result = fake.assistant({ { type = "thinking", thinking = text or "First thought." } }, "error")
  result.ok = false
  result.error = { kind = "protocol", code = "missing_tool_call", message = "A changed diagnostic." }
  result.message.errorMessage = result.error.message
  result.message.usage = { input = 3, output = 2, totalTokens = 5, cost = { input = 1, total = 1 } }
  return result
end
local function model(responses)
  local value = fake.new(responses)
  value.id, value.provider, value.api = "qwen3.8-flash", "opencode-go", "anthropic-messages"
  return value
end

describe("OpenCode Go Model recovery policy", function()
  it("leaves other models and APIs untouched", function()
    for _, fields in ipairs({ { id = "qwen3.8-max" }, { api = "openai-completions" } }) do
      local value = vim.tbl_extend("force", model({ { result = missing() } }), fields)
      local wrapped = recovery.wrap(value)
      assert.are.equal(value, wrapped)
      assert.is_false(wait(wrapped:stream({ messages = {} })).ok)
      assert.are.equal(1, #value.requests)
    end
  end)

  it("does not continue successful responses or unrelated failures", function()
    local absent = missing(); absent.message = nil
    local unrelated = missing(); unrelated.error.code = "invalid_assistant_message"
    local provider_error = missing(); provider_error.error.kind = "model"
    for _, result in ipairs({ fake.assistant({}), unrelated, provider_error, absent }) do
      local value = model({ { result = result } })
      assert.are.same(result, wait(recovery.wrap(value):stream({ messages = {} })))
      assert.are.equal(1, #value.requests)
    end
  end)

  it("recognizes structured failures and combines final text, costs and live usage", function()
    local first = missing()
    first.message.content[#first.message.content + 1] = { type = "text", text = "Before." }
    local second = fake.assistant({ { type = "text", text = "After." } })
    second.message.usage = { input = 4, output = 3, totalTokens = 7, cost = { output = 2, total = 2 } }
    local value = model({ { result = first }, { result = second, events = {
      { type = "text_delta", text = "After." }, { type = "usage", usage = second.message.usage },
    } } })
    local events = {}
    local result = wait(recovery.wrap(value):stream({ messages = {}, on_event = function(event)
      events[#events + 1] = event
    end }))
    assert.is_true(result.ok)
    assert.are.equal("Before.After.", result.text)
    assert.are.equal("stop", result.message.stopReason)
    assert.is_nil(result.message.errorMessage)
    assert.are.same({ input = 1, output = 2, total = 3 }, result.message.usage.cost)
    assert.are.equal(12, result.message.usage.totalTokens)
    assert.are.equal("warning", events[1].type)
    assert.are.equal(1, events[2].index)
    assert.are.same(result.message.usage, events[3].usage)
    assert.are.same({ { type = "text", text = "After." } }, second.message.content)
  end)

  it("retains the first response when the follow-up fails before producing output", function()
    for _, throws in ipairs({ false, true }) do
      local value = model({ { result = missing() }, { result = {
        ok = false, error = { kind = "auth", message = "Credentials unavailable" },
      } } })
      if throws then
        local stream = value.stream
        function value:stream(opts)
          if #self.requests == 1 then error(util.error("auth", "Credentials unavailable"), 0) end
          return stream(self, opts)
        end
      end
      local result = wait(recovery.wrap(value):stream({ messages = {} }))
      assert.is_false(result.ok)
      assert.are.equal("Credentials unavailable", result.error.message)
      assert.are.equal("First thought.", result.message.content[1].thinking)
      assert.are.equal("error", result.message.stopReason)
      assert.are.equal(5, result.message.usage.totalTokens)
    end
  end)

  it("keeps concurrent continuations independent on one wrapped Model", function()
    local value = model({ { result = missing("A") }, { result = missing("B") },
      { result = fake.assistant({ { type = "text", text = "answer A" } }) },
      { result = fake.assistant({ { type = "text", text = "answer B" } }) },
    })
    local wrapped = recovery.wrap(value)
    local a = wrapped:stream({ messages = { { role = "user", content = "A" } } })
    local b = wrapped:stream({ messages = { { role = "user", content = "B" } } })
    assert.are.equal("A", wait(a).message.content[1].thinking)
    assert.are.equal("B", wait(b).message.content[1].thinking)
    assert.are.equal("A", value.requests[3].messages[1].content)
    assert.are.equal("B", value.requests[4].messages[1].content)
  end)
end)
