local assert = require("luassert")
local recovery = require("neoagent.providers.opencode_go.model")
local fake = require("tests.helpers.fake_model")
local util = require("neoagent.util")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return (assert(run:result()))
end
---@class Neoagent.TestMissingToolResult: Neoagent.ModelFailure
---@field message Neoagent.AssistantMessage
---@field error Neoagent.Error

---@param text? string
---@return Neoagent.TestMissingToolResult
local function missing(text)
  local message = fake.assistant({ { type = "thinking", thinking = text or "First thought." } }, "error").message
  message.errorMessage = "A changed diagnostic."
  message.usage = { input = 3, output = 2, totalTokens = 5, cost = { input = 1, total = 1 } }
  return { ok = false, message = message,
    error = { kind = "protocol", code = "missing_tool_call", message = message.errorMessage } }
end
---@param responses Neoagent.TestModelResponse[]
---@return Neoagent.TestModel
local function model(responses)
  local value = fake.new(responses)
  value.id, value.provider, value.api = "qwen3.8-flash", "opencode-go", "anthropic-messages"
  return value
end

describe("OpenCode Go Model recovery policy", function()
  it("leaves other models and APIs untouched", function()
    for _, fields in ipairs({ { id = "qwen3.8-max" }, { api = "openai-completions" } }) do
      local value = model({ { result = missing() } })
      if fields.id then value.id = fields.id end
      if fields.api then value.api = fields.api end
      local wrapped = recovery.wrap(value)
      assert.are.equal(value, wrapped)
      assert.is_false(wait(wrapped:stream({ messages = {} })).ok)
      assert.are.equal(1, #value.requests)
    end
  end)

  it("does not continue successful responses or unrelated failures", function()
    ---@type Neoagent.ModelFailure
    local absent = missing(); absent.message = nil
    local unrelated = missing(); rawset(unrelated.error, "code", "invalid_assistant_message")
    local provider_error = missing(); provider_error.error.kind = "model"
    for _, result in ipairs({ fake.assistant({}), unrelated, provider_error, absent }) do
      local value = model({ { result = result } })
      local wrapped = recovery.wrap(value)
      assert.are.same(result, wait(wrapped:stream({ messages = {} })))
      assert.are.equal(1, #value.requests)
    end
  end)

  it("returns a recovery proposal without issuing another Model request", function()
    local first = missing()
    local value = model({ { result = first } })
    local result = wait(recovery.wrap(value):stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.same(first.message, result.message)
    assert.matches("no tool call", util.text_content(assert(result.recovery).message.content))
    assert.are.equal(1, #value.requests)
  end)

  it("commits recovery history and gates the follow-up with separate usage", function()
    local first = missing()
    first.message.content[#first.message.content + 1] = { type = "text", text = "Before." }
    local second = fake.assistant({ { type = "text", text = "After." } })
    second.message.usage = { input = 4, output = 3, totalTokens = 7, cost = { output = 2, total = 2 } }
    local value = model({ { result = first }, { result = second, events = {
      { type = "text_delta", text = "After." }, { type = "usage", usage = second.message.usage },
    } } })
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Start" }))
    local gates, events = 0, {}
    local result = wait(require("neoagent.agent_loop").run({
      model = recovery.wrap(value), messages = assert(session:context_messages()), tools = {},
      commit_message = function(message) local ok, err = session:append(message) return ok, err end,
      prepare_request_messages = function(messages)
        gates = gates + 1
        assert.are.same(assert(session:context_messages()), messages)
        if gates == 2 then
          assert.are.equal(3, #messages)
          assert.are.equal("Before.", util.text_content(assert(messages[2]).content))
          assert.matches("no tool call", util.text_content(assert(messages[3]).content))
        end
        return messages
      end,
      on_event = function(event) events[#events + 1] = event end,
    }))
    assert(result.ok)
    assert.are.equal("After.", result.text)
    assert.are.equal(2, gates)
    assert.are.equal(4, #session:messages())
    assert.are.same(first.message.usage, assert(session:messages()[2]).usage)
    assert.are.same(second.message.usage, result.message.usage)
    assert.are.equal(7, require("neoagent.context_estimate").estimate_context(assert(session:context_messages())).tokens)
    local usages = vim.tbl_filter(function(event) return event.type == "usage" end, events)
    assert.are.same(second.message.usage, usages[1].usage)
  end)

  it("retains partial history when the follow-up fails before producing output", function()
    local value = model({ { result = missing() }, { result = {
      ok = false, error = { kind = "auth", message = "Credentials unavailable" },
    } } })
    local committed = {}
    local result = wait(require("neoagent.agent_loop").run({
      model = recovery.wrap(value), messages = {}, tools = {},
      commit_message = function(message) committed[#committed + 1] = message return true end,
    }))
    assert.is_false(result.ok)
    assert.are.equal("Credentials unavailable", assert(result.error).message)
    assert.are.equal("First thought.", committed[1].content[1].thinking)
    assert.are.equal(5, committed[1].usage.totalTokens)
    assert.are.equal(2, #committed)
    assert.are.equal(2, #value.requests)
  end)

  it("fails a recovery that returns no visible answer or Tool call", function()
    for _, content in ipairs({ {}, { { type = "thinking", thinking = "Still thinking" } } }) do
      local value = model({ { result = missing() }, { result = fake.assistant(content) } })
      local committed = {}
      local result = wait(require("neoagent.agent_loop").run({
        model = recovery.wrap(value), messages = {}, tools = {},
        commit_message = function(message) committed[#committed + 1] = message return true end,
      }))
      assert.is_false(result.ok)
      assert.matches("no visible answer or tool call", assert(result.error).message)
      assert.are.equal(2, #value.requests)
      assert.are.equal(3, #committed)
    end
  end)

  it("blocks the follow-up when committing its prompt or preparing its context fails", function()
    for _, phase in ipairs({ "commit", "prepare" }) do
      local value = model({ { result = missing() } })
      local gates, committed = 0, {}
      local result = wait(require("neoagent.agent_loop").run({
        model = recovery.wrap(value), messages = {}, tools = {},
        commit_message = function(message)
          if message.role == "user" and phase == "commit" then
            return nil, { kind = "session", message = "Recovery commit rejected" }
          end
          committed[#committed + 1] = message
          return true
        end,
        prepare_request_messages = function(messages)
          gates = gates + 1
          if gates == 2 then return nil, { kind = "context", message = "Recovery budget rejected" } end
          return messages
        end,
      }))
      assert.is_false(result.ok)
      assert.matches("Recovery", assert(result.error).message)
      assert.are.equal(phase == "commit" and 1 or 2, #committed)
      assert.are.equal(1, #value.requests)
    end
  end)

  it("keeps concurrent continuations independent on one wrapped Model", function()
    local value = model({ { result = missing("A") }, { result = missing("B") },
      { result = fake.assistant({ { type = "text", text = "answer A" } }) },
      { result = fake.assistant({ { type = "text", text = "answer B" } }) },
    })
    local wrapped = recovery.wrap(value)
    local function start(prompt)
      return require("neoagent.agent_loop").run({ model = wrapped,
        messages = { { role = "user", content = prompt } }, tools = {},
        commit_message = function() return true end,
      })
    end
    local a, b = start("A"), start("B")
    assert.are.equal("answer A", wait(a).text)
    assert.are.equal("answer B", wait(b).text)
    assert.are.equal("A", assert(assert(value.requests[3]).messages[1]).content)
    assert.are.equal("B", assert(assert(value.requests[4]).messages[1]).content)
  end)
end)
