local agent = require("neoagent.agent")
local fake_model = require("tests.helpers.fake_model")

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end

describe("neoagent.agent", function()
  it("runs a tool-free model without mutating messages", function()
    local messages = { { role = "user", content = "hello", timestamp = 1 } }
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "hi" } }) } })
    local result = wait(agent.run({ model = model, messages = messages }))
    assert.is_true(result.ok)
    assert.are.equal("hi", result.text)
    assert.are.equal(1, #messages)
    assert.are.equal(1, #result.new_messages)
  end)

  it("executes requested tools sequentially and emits ordered messages", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "echo", arguments = { text = "one" } },
        { type = "toolCall", id = "c2", name = "echo", arguments = { text = "two" } },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local executions = {}
    local events = {}
    local result = wait(agent.run({
      model = model,
      messages = {},
      tools = { {
        name = "echo",
        description = "echo",
        input_schema = { type = "object" },
        execute = function(arguments, ctx)
          executions[#executions + 1] = arguments.text
          ctx.on_update({ content = { { type = "text", text = "working" } } })
          return { content = { { type = "text", text = arguments.text } } }
        end,
      } },
      on_event = function(event) events[#events + 1] = event.type end,
    }))
    assert.is_true(result.ok)
    assert.are.same({ "one", "two" }, executions)
    assert.are.equal(4, #result.new_messages)
    assert.are.equal(3, #model.requests[2].messages)
    assert(vim.wait(1000, function() return #events == 10 end))
    assert.are.same({
      "message_end",
      "tool_start", "tool_update", "tool_end", "message_end",
      "tool_start", "tool_update", "tool_end", "message_end",
      "message_end",
    }, events)
  end)

  it("injects queued steering messages between assistant turns", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "first" } }) },
      { result = fake_model.assistant({ { type = "text", text = "second" } }) },
    })
    local queued = { {
      role = "user",
      content = "change direction",
      timestamp = 2,
    } }
    local result = wait(agent.run({
      model = model,
      messages = { { role = "user", content = "begin", timestamp = 1 } },
      get_steering_messages = function()
        local messages = queued
        queued = {}
        return messages
      end,
    }))
    assert.is_true(result.ok)
    assert.are.same({ "assistant", "user", "assistant" },
      vim.tbl_map(function(message) return message.role end, result.new_messages))
    assert.are.equal("change direction", model.requests[2].messages[3].content)
  end)

  it("turns unknown tools into error results", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "missing", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local result = wait(agent.run({ model = model, messages = {} }))
    assert.is_true(result.ok)
    assert.is_true(result.new_messages[2].isError)
    assert.matches("Unknown tool", result.new_messages[2].content[1].text)
  end)

  it("forwards model events and preserves partial failed responses", function()
    local partial = fake_model.assistant({ { type = "text", text = "partial" } }).message
    local model = fake_model.new({ {
      events = { { type = "text_delta", text = "partial" } },
      result = { ok = false, message = partial, error = { kind = "transport", message = "disconnected" } },
    } })
    local events = {}
    local result = wait(agent.run({
      model = model,
      messages = {},
      on_event = function(event) events[#events + 1] = event end,
    }))
    assert.is_false(result.ok)
    assert.are.equal("disconnected", result.error.message)
    assert.are.equal("partial", result.new_messages[1].content[1].text)
    assert(vim.wait(1000, function() return #events == 2 end))
    assert.are.same({ "text_delta", "message_end" }, { events[1].type, events[2].type })
  end)

  it("turns invalid calls and executor failures into rich tool results", function()
    local late_update
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "a", name = "invalid_args", arguments = { "not", "an", "object" } },
        { type = "toolCall", id = "b", name = "missing_result", arguments = {} },
        { type = "toolCall", id = "c", name = "bad_block", arguments = {} },
        { type = "toolCall", id = "d", name = "throws", arguments = {} },
        { type = "toolCall", id = "e", name = "rich", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local function tool(name, execute)
      return { name = name, description = name, input_schema = { type = "object" }, execute = execute }
    end
    local events = {}
    local result = wait(agent.run({
      model = model,
      messages = {},
      tools = {
        tool("invalid_args", function() error("must not execute") end),
        tool("missing_result", function() return nil end),
        tool("bad_block", function() return { content = { { type = "audio" } } } end),
        tool("throws", function() error("executor exploded") end),
        tool("rich", function(_, ctx)
          ctx.on_update({ content = { { type = "audio" } } })
          late_update = ctx.on_update
          return {
            content = { { type = "text", text = "edited" } },
            details = { diff = "+changed" },
            usage = { output = 3 },
          }
        end),
      },
      on_event = function(event) events[#events + 1] = event end,
    }))
    assert.is_true(result.ok)
    for index = 2, 5 do assert.is_true(result.new_messages[index].isError) end
    assert.matches("JSON object", result.new_messages[2].content[1].text)
    assert.matches("result with content", result.new_messages[3].content[1].text)
    assert.matches("unsupported content", result.new_messages[4].content[1].text)
    assert.matches("executor exploded", result.new_messages[5].content[1].text)
    assert.are.same({ diff = "+changed" }, result.new_messages[6].details)
    assert.are.same({ output = 3 }, result.new_messages[6].usage)
    local count = #events
    late_update({ content = { { type = "text", text = "too late" } } })
    vim.wait(20)
    assert.are.equal(count, #events)
  end)

  it("uses the custom execution boundary", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "echo", arguments = { value = true } },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local called = false
    local result = wait(agent.run({
      model = model,
      messages = {},
      tools = { { name = "echo", description = "", input_schema = {}, execute = function() error("unused") end } },
      execute_tool = function(tool, arguments, ctx)
        called = tool.name == "echo" and arguments.value and ctx.model == model
        return { content = { { type = "text", text = "approved" } } }
      end,
    }))
    assert.is_true(result.ok)
    assert.is_true(called)
  end)

  it("allows an executor decorator to suspend through async.await", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "echo", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local result = wait(agent.run({
      model = model,
      messages = {},
      tools = { { name = "echo", description = "", input_schema = {}, execute = function() error("unused") end } },
      execute_tool = function()
        return require("neoagent.async").await(function(done)
          vim.schedule(function()
            done.resolve({ content = { { type = "text", text = "approved asynchronously" } } })
          end)
        end)
      end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("approved asynchronously", result.new_messages[2].content[1].text)
  end)

  it("returns a limit error after the configured tool rounds", function()
    local model = fake_model.new({ { result = fake_model.assistant({
      { type = "toolCall", id = "c1", name = "echo", arguments = {} },
    }, "toolUse") } })
    local result = wait(agent.run({
      model = model,
      messages = {},
      max_rounds = 1,
      tools = { {
        name = "echo", description = "", input_schema = {},
        execute = function() return { content = { { type = "text", text = "ok" } } } end,
      } },
    }))
    assert.is_false(result.ok)
    assert.are.equal("limit", result.error.kind)
  end)
end)
