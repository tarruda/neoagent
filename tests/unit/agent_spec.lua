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
