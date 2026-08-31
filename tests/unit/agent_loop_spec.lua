local agent_loop = require("neoagent.agent_loop")
local fake_model = require("tests.helpers.fake_model")

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end

describe("neoagent.agent_loop", function()
  it("runs a tool-free model without mutating messages", function()
    local messages = { { role = "user", content = "hello", timestamp = 1 } }
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "hi" } }) } })
    local result = wait(agent_loop.run({ model = model, messages = messages }))
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
    local result = wait(agent_loop.run({
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
    local result = wait(agent_loop.run({
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
    local result = wait(agent_loop.run({ model = model, messages = {} }))
    assert.is_true(result.ok)
    assert.is_true(result.new_messages[2].isError)
    assert.matches("Unknown tool", result.new_messages[2].content[1].text)
  end)

  it("turns invalid UTF-8 tool text into an error before the next model turn", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "binary", arguments = {} },
        { type = "toolCall", id = "c2", name = "invalid_value", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "binary",
        description = "binary",
        input_schema = { type = "object" },
        execute = function() return { content = { { type = "text", text = "bad\255text" } } } end,
      }, {
        name = "invalid_value",
        description = "invalid value",
        input_schema = { type = "object" },
        execute = function() return { content = { { type = "text", text = 42 } } } end,
      } },
    }))

    assert.is_true(result.ok)
    assert.is_true(result.new_messages[2].isError)
    assert.matches("valid UTF%-8", result.new_messages[2].content[1].text)
    assert.is_true(result.new_messages[3].isError)
    assert.matches("string value", result.new_messages[3].content[1].text)
    assert.is_true(require("neoagent.util").is_valid_utf8(
      model.requests[2].messages[2].content[1].text))
    assert.are.equal("recovered", result.text)
  end)

  it("validates stable image identities in results and transient updates", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "preview", arguments = {} },
        { type = "toolCall", id = "c2", name = "bad_final", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local events = {}
    local function image(fields)
      return vim.tbl_extend("force", {
        type = "image",
        data = "encoded-png",
        mimeType = "image/png",
      }, fields or {})
    end
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "preview",
        description = "preview",
        input_schema = { type = "object" },
        execute = function(_, ctx)
          local invalid = {
            image({ revision = 1 }),
            image({ id = "preview" }),
            image({ id = "preview", revision = 1, data = false }),
            image({ id = "preview", revision = 1, mimeType = false }),
            image({ id = false, revision = 1 }),
            image({ id = "", revision = 1 }),
            image({ id = "bad\nidentity", revision = 1 }),
            image({ id = "bad\255identity", revision = 1 }),
            image({ id = string.rep("i", 513), revision = 1 }),
            image({ id = "preview", revision = {} }),
            image({ id = "preview", revision = math.huge }),
            image({ id = "preview", revision = -math.huge }),
            image({ id = "preview", revision = 0 / 0 }),
            image({ id = "preview", revision = "" }),
            image({ id = "preview", revision = "bad\255revision" }),
            image({ id = "preview", revision = "bad\nrevision" }),
            image({ id = "preview", revision = string.rep("r", 129) }),
          }
          for _, block in ipairs(invalid) do
            ctx.on_update({ content = { block } })
          end
          ctx.on_update({ content = {
            image({ id = "duplicate", revision = 1 }),
            image({ id = "duplicate", revision = 2 }),
          } })
          ctx.on_update({ content = {
            image({ id = "preview", revision = "frame-1" }),
          } })
          return { content = { { type = "image", data = "immutable-image" } } }
        end,
      }, {
        name = "bad_final",
        description = "bad final image",
        input_schema = { type = "object" },
        execute = function()
          return { content = {
            image({ id = "final", revision = math.huge }),
          } }
        end,
      } },
      on_event = function(event) events[#events + 1] = event end,
    }))

    assert.is_true(result.ok)
    assert.is_false(result.new_messages[2].isError)
    assert.are.same({ type = "image", data = "immutable-image" },
      result.new_messages[2].content[1])
    assert.is_true(result.new_messages[3].isError)
    assert.matches("finite", result.new_messages[3].content[1].text)
    assert(vim.wait(1000, function()
      local count = 0
      for _, event in ipairs(events) do
        if event.type == "tool_update" then count = count + 1 end
      end
      return count == 1
    end))
    local update
    for _, event in ipairs(events) do
      if event.type == "tool_update" then update = event.result.content[1] end
    end
    assert.are.equal("preview", update.id)
    assert.are.equal("frame-1", update.revision)
  end)

  it("forwards model events and preserves partial failed responses", function()
    local partial = fake_model.assistant({ { type = "text", text = "partial" } }).message
    local model = fake_model.new({ {
      events = { { type = "text_delta", text = "partial" } },
      result = { ok = false, message = partial, error = { kind = "transport", message = "disconnected" } },
    } })
    local events = {}
    local result = wait(agent_loop.run({
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
    local result = wait(agent_loop.run({
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

  it("returns argument normalization errors without executing tools", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall",
        id = "c1",
        name = "edit",
        arguments = {},
        argumentsError = "Tool arguments are not valid JSON",
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local executed = false
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "edit",
        description = "Edit",
        input_schema = { type = "object" },
        execute = function() executed = true end,
      } },
    }))

    assert.is_true(result.ok)
    assert.is_false(executed)
    assert.is_true(result.new_messages[2].isError)
    assert.are.equal("Tool arguments are not valid JSON",
      result.new_messages[2].content[1].text)
    assert.are.equal("recovered", result.text)
  end)

  it("reports every nested tool schema mismatch before execution", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall",
        id = "c1",
        name = "update_plan",
        arguments = {
          plan = {
            { step = "Inspect the failure", status = "completed" },
            { step = "Implement the fix" },
            { step = "Verify the result" },
          },
        },
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local tool = require("neoagent.tools.update_plan").new()
    local executed = false
    tool.execute = function()
      executed = true
      return { content = { { type = "text", text = "must not execute" } } }
    end

    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { tool },
    }))

    assert.is_true(result.ok)
    assert.is_false(executed)
    assert.is_true(result.new_messages[2].isError)
    assert.are.equal(table.concat({
      "Tool call arguments do not match the declared schema:",
      "- plan[2].status is required",
      "- plan[3].status is required",
    }, "\n"), result.new_messages[2].content[1].text)
    assert.are.equal("recovered", result.text)
  end)

  it("uses the custom execution boundary", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "echo", arguments = { value = true } },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local called = false
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { { name = "echo", description = "", input_schema = {}, execute = function() error("unused") end } },
      execute_tool = function(tool, arguments, ctx)
        called = tool.name == "echo" and arguments.value and ctx.model == model
          and ctx.call.id == "c1" and ctx.call.name == "echo"
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
    local result = wait(agent_loop.run({
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

  it("propagates cancellation from an active tool without another model turn", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "wait", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "must not run" } }) },
    })
    local cleaned = false
    local run = agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "wait",
        description = "",
        input_schema = { type = "object" },
        execute = function()
          return require("neoagent.async").await(function()
            return function() cleaned = true end
          end)
        end,
      } },
    })
    vim.defer_fn(function() run:cancel() end, 10)
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(run:result().ok)
    assert.are.equal("cancelled", run:result().error.kind)
    assert.is_true(cleaned)
    assert.are.equal(1, #model.requests)
  end)

  it("suppresses late image frames after active tool cancellation", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall",
        id = "animated",
        name = "animate",
        arguments = {},
      } }, "toolUse") },
    })
    local late_update, cleaned = nil, false
    local revisions, completions = {}, 0
    local run = agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "animate",
        description = "animate",
        input_schema = { type = "object" },
        execute = function(_, ctx)
          late_update = ctx.on_update
          ctx.on_update({ content = { {
            type = "image",
            mimeType = "image/png",
            data = "frame-one",
            id = "preview",
            revision = 1,
          } } })
          return require("neoagent.async").await(function()
            return function() cleaned = true end
          end)
        end,
      } },
      on_event = function(event)
        if event.type == "tool_update" then
          revisions[#revisions + 1] = event.result.content[1].revision
        end
      end,
      on_done = function() completions = completions + 1 end,
    })
    assert(vim.wait(1000, function()
      return late_update ~= nil and #revisions == 1
    end))
    run:cancel()
    assert(vim.wait(1000, function() return run:is_done() end))
    late_update({ content = { {
      type = "image",
      mimeType = "image/png",
      data = "frame-two",
      id = "preview",
      revision = 2,
    } } })
    vim.wait(20)

    assert.are.same({ 1 }, revisions)
    assert.are.equal(1, completions)
    assert.is_true(cleaned)
    assert.are.equal("cancelled", run:result().error.kind)
  end)

  it("propagates cancellation raised by an executor decorator", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "cancel", arguments = {} },
      }, "toolUse") },
    })
    local run = agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "cancel",
        description = "",
        input_schema = { type = "object" },
        execute = function() error("unused") end,
      } },
      execute_tool = function()
        error(require("neoagent.async").cancelled_error, 0)
      end,
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(run:result().ok)
    assert.are.equal("cancelled", run:result().error.kind)
    assert.are.equal(1, #model.requests)
  end)

  it("continues tool calls until the model stops", function()
    local responses = {}
    for round = 1, 13 do
      responses[#responses + 1] = { result = fake_model.assistant({
        { type = "toolCall", id = "c" .. round, name = "echo", arguments = {} },
      }, "toolUse") }
    end
    responses[#responses + 1] = {
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    }
    local model = fake_model.new(responses)
    local executions = 0
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "echo", description = "", input_schema = {},
        execute = function()
          executions = executions + 1
          return { content = { { type = "text", text = "ok" } } }
        end,
      } },
    }))
    assert.is_true(result.ok)
    assert.are.equal("done", result.text)
    assert.are.equal(13, executions)
    assert.are.equal(14, #model.requests)
  end)
end)
