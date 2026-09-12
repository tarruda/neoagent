local attachments = require("tests.helpers.attachments").new()
local assert = require("luassert")
local core_agent_loop = require("neoagent.agent_loop")
local fake_model = require("tests.helpers.fake_model")
local util = require("neoagent.util")

---@class Neoagent.TestAgentLoopOptions: Neoagent.AgentLoopOptions<unknown>
---@field commit_message? Neoagent.MessageCommit

local agent_loop = { prepare = core_agent_loop.prepare }
---@param opts Neoagent.TestAgentLoopOptions
---@return Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>
function agent_loop.run(opts)
  local call = vim.tbl_extend("force", {}, opts)
  call.commit_message = call.commit_message or function() return true end
  return core_agent_loop.run(call --[[@as Neoagent.AgentLoopOptions<unknown>]])
end

---@param run Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>
---@return Neoagent.AgentLoopResult
local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@param result Neoagent.AgentLoopResult
---@param index integer
---@return Neoagent.Message
local function result_message(result, index)
  return (assert(assert(result.new_messages)[index]))
end

describe("neoagent.agent_loop", function()
  it("requires an authoritative message command", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "unused" } }),
    } })
    assert.has_error(function()
      local invalid = { model = model, messages = {} }
      core_agent_loop.run(invalid --[[@as Neoagent.AgentLoopOptions<unknown>]])
    end, "commit_message must be a function")
  end)

  it("prepares one owned immutable turn value", function()
    local messages = { { role = "user", content = "hello", timestamp = 1 } }
    local options = { nested = { value = true } }
    local tool = {
      name = "echo",
      description = "Echo text",
      input_schema = { type = "object", properties = {
        text = { type = "string" },
      } },
      execute = function() error("unexpected tool execution") end,
    }
    local prepared = agent_loop.prepare({
      model = fake_model.new({}),
      messages = messages,
      tools = { tool },
      model_options = options,
      commit_message = function() return true end,
    })

    messages[1].content = "changed"
    tool.input_schema.properties.text.type = "number"
    options.nested.value = false

    assert.are.equal("hello", assert(prepared.messages[1]).content)
    assert.are.equal("string",
      assert(assert(prepared.tool_schemas[1]).input_schema.properties).text.type)
    assert.is_true(rawget(rawget(prepared.model_options, "nested"), "value"))
    assert.are.equal(prepared.tools[1], prepared.tool_lookup.echo)
  end)

  it("runs a tool-free model without mutating messages", function()
    local messages = { { role = "user", content = "hello", timestamp = 1 } }
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "hi" } }) } })
    local result = wait(agent_loop.run({ model = model, messages = messages }))
    assert(result.ok == true)
    assert.are.equal("hi", result.text)
    assert.are.equal(1, #messages)
    assert.are.equal(1, #result.new_messages)
  end)

  it("commits owned copies to an ordinary in-memory message owner", function()
    local source = fake_model.assistant({ { type = "text", text = "answer" } })
    local model = fake_model.new({ { result = source } })
    ---@type Neoagent.Message[]
    local owner = {}
    local result = wait(core_agent_loop.run({
      model = model,
      messages = {},
      commit_message = function(message)
        owner[#owner + 1] = message
        assert(message.content[1]).text = "owner mutation"
        return true
      end,
    }))

    assert(result.ok == true)
    assert.are.equal("owner mutation", assert(assert(owner[1]).content[1]).text)
    assert.are.equal("answer", assert(assert(result.message).content[1]).text)
    assert.are.equal("answer", assert(source.message.content[1]).text)
  end)

  it("contains thrown commits and malformed committed observations", function()
    ---@param commit_message Neoagent.MessageCommit
    ---@return Neoagent.AgentLoopResult
    local function run(commit_message)
      return wait(core_agent_loop.run({
        model = fake_model.new({ {
          result = fake_model.assistant({ { type = "text", text = "answer" } }),
        } }),
        messages = {},
        commit_message = commit_message,
      }))
    end

    local result = run(function() error("commit crashed") end)
    assert.is_false(result.ok)
    assert.matches("commit crashed", assert(result.error).message)
    assert.are.equal("answer", assert(assert(result.message).content[1]).text)
    assert.are.same({}, result.new_messages)

    for _, observation in ipairs({
      "invalid",
      { role = "assistant", content = { { type = "text", text = "other" } } },
      { role = "assistant", content = { { type = "text", text = "answer" } },
        _neoagent_entry_id = "bad\nentry" },
    }) do
      result = run(function() return true, nil, observation --[[@as Neoagent.ObservedMessage]] end)
      assert.is_false(result.ok)
      assert.matches("commit_message observation", assert(result.error).message)
      assert.are.equal(1, #result.new_messages)
      assert.is_nil(result.message)
    end

    result = run(function(message)
      rawset(message, "_neoagent_entry_id", "bad\nentry")
      return true, nil, message
    end)
    assert.is_false(result.ok)
    assert.matches("entry id is invalid", assert(result.error).message)
    assert.are.equal(1, #result.new_messages)
  end)

  it("rejects invalid Model roles and duplicate calls before effects", function()
    local duplicate = fake_model.assistant({ {
      type = "toolCall", id = "call-1", name = "echo", arguments = {},
    } }, "toolUse")
    local model = fake_model.new({ { result = duplicate } })
    local executed = false
    local result = wait(agent_loop.run({
      model = model,
      messages = {
        { role = "assistant", content = { {
          type = "toolCall", id = "call-1", name = "echo", arguments = {},
        } } },
        { role = "toolResult", toolCallId = "call-1", toolName = "echo",
          content = {} },
      },
      tools = { {
        name = "echo", description = "Echo", input_schema = {},
        execute = function() executed = true; return { content = {} } end,
      } },
    }))
    assert.is_false(result.ok)
    assert.are.equal("model", assert(result.error).kind)
    assert.matches("duplicate conversation toolCall", assert(result.error).message)
    assert.is_false(executed)

    model = fake_model.new({ {
      result = { ok = true,
        message = { role = "user", content = "invalid" } --[[@as Neoagent.AssistantMessage]] },
    } })
    result = wait(agent_loop.run({ model = model, messages = {} }))
    assert.is_false(result.ok)
    assert.matches("assistant message is required", assert(result.error).message)

    model = fake_model.new({ {
      result = fake_model.assistant({ {
        type = "thinking", thinking = "I should inspect.",
      } }, "toolUse"),
    } })
    result = wait(agent_loop.run({ model = model, messages = {} }))
    assert.is_false(result.ok)
    assert.matches("declared tool use without supplying a tool call",
      assert(result.error).message)

    model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "first" } }),
    } })
    result = wait(agent_loop.run({
      model = model,
      messages = {},
      get_steering_messages = function()
        return { {
          role = "assistant",
          content = { { type = "text", text = "wrong role" } },
        } --[[@as Neoagent.UserMessage]] }
      end,
    }))
    assert.is_false(result.ok)
    assert.matches("user message is required", assert(result.error).message)
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
          return { content = { { type = "text", text = assert(arguments.text) --[[@as string]] } } }
        end,
      } },
      on_event = function(event) events[#events + 1] = event.type end,
    }))
    assert(result.ok == true)
    assert.are.same({ "one", "two" }, executions)
    assert.are.equal(4, #result.new_messages)
    assert.are.equal(3, #assert(model.requests[2]).messages)
    assert(vim.wait(1000, function() return #events == 10 end))
    assert.are.same({
      "message_end",
      "tool_start", "tool_update", "tool_end", "message_end",
      "tool_start", "tool_update", "tool_end", "message_end",
      "message_end",
    }, events)
  end)

  it("stops dependent work at every failed message commit", function()
    local storage_error = { kind = "storage", message = "journal failed" }
    local executed = false
    local model = fake_model.new({ { result = fake_model.assistant({ {
      type = "toolCall", id = "call", name = "effect", arguments = {},
    } }, "toolUse") } })
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "effect", description = "effect", input_schema = {},
        execute = function() executed = true; return { content = {} } end,
      } },
      commit_message = function() return nil, storage_error end,
    }))
    assert.is_false(result.ok)
    assert.are.equal("journal failed", assert(result.error).message)
    assert.is_false(executed)
    assert.are.equal(1, #model.requests)

    executed = false
    local commits = 0
    model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "call", name = "effect", arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "late" } }) },
    })
    result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "effect", description = "effect", input_schema = {},
        execute = function()
          executed = true
          return { content = { { type = "text", text = "changed" } } }
        end,
      } },
      commit_message = function()
        commits = commits + 1
        if commits == 2 then return nil, storage_error end
        return true
      end,
    }))
    assert.is_false(result.ok)
    assert.is_true(executed)
    assert.are.equal(1, #result.new_messages)
    assert.are.equal("toolResult", assert(result.message).role)
    assert.are.equal(1, #model.requests)

    commits = 0
    local steering = { { role = "user", content = "redirect" } }
    local acknowledgement
    model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "first" } }) },
      { result = fake_model.assistant({ { type = "text", text = "late" } }) },
    })
    result = wait(agent_loop.run({
      model = model,
      messages = {},
      get_steering_messages = function()
        local messages = steering
        steering = {}
        return messages, function(committed)
          acknowledgement = committed
        end
      end,
      commit_message = function()
        commits = commits + 1
        if commits == 2 then return nil, storage_error end
        return true
      end,
    }))
    assert.is_false(result.ok)
    assert.is_false(acknowledgement)
    assert.are.equal("user", assert(result.message).role)
    assert.are.equal(1, #model.requests)
  end)

  it("publishes committed observations in authoritative order", function()
    local order = {}
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "call", name = "echo", arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local next_id = 0
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "echo", description = "Echo", input_schema = {},
        execute = function()
          order[#order + 1] = "execute"
          return { content = { { type = "text", text = "echoed" } } }
        end,
      } },
      commit_message = function(message)
        next_id = next_id + 1
        order[#order + 1] = "commit:" .. message.role
        local observed = vim.deepcopy(message) --[[@as Neoagent.ObservedMessage]]
        observed._neoagent_entry_id = "entry-" .. next_id
        return true, nil, observed
      end,
      on_event = function(event)
        if event.type == "tool_end" or event.type == "message_end" then
          order[#order + 1] = event.type .. ":"
            .. assert(event.message)._neoagent_entry_id
        end
      end,
    }))
    assert(result.ok == true)
    assert(vim.wait(1000, function() return #order == 8 end))
    assert.are.same({
      "commit:assistant", "execute", "commit:toolResult",
      "message_end:entry-1", "tool_end:entry-2", "message_end:entry-2",
      "commit:assistant", "message_end:entry-3",
    }, order)
  end)

  it("stops observation and effects when cancellation follows commit", function()
    local commits, observations, executed = 0, 0, false
    local model = fake_model.new({ { result = fake_model.assistant({ {
      type = "toolCall", id = "call", name = "effect", arguments = {},
    } }, "toolUse") } })
    local run = agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "effect", description = "Effect", input_schema = {},
        execute = function() executed = true; return { content = {} } end,
      } },
      commit_message = function()
        commits = commits + 1
        require("neoagent.async").current():cancel()
        return true
      end,
      on_event = function(event)
        if event.type == "message_end" then observations = observations + 1 end
      end,
    })
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal(1, commits)
    assert.are.equal(0, observations)
    assert.is_false(executed)
    assert.are.equal(1, #model.requests)
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
    assert(result.ok == true)
    assert.are.same({ "assistant", "user", "assistant" },
      vim.tbl_map(function(message) return message.role end, (assert(result.new_messages))))
    assert.are.equal("change direction", assert(assert(model.requests[2]).messages[3]).content)
  end)

  it("acknowledges steering immediately after its durable commit", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "first" } }) },
      { result = fake_model.assistant({ { type = "text", text = "second" } }) },
    })
    local acknowledgement
    local commits = 0
    local result = wait(agent_loop.run({
      model = model,
      messages = { { role = "user", content = "begin", timestamp = 1 } },
      get_steering_messages = function()
        if acknowledgement ~= nil then return {} end
        return { {
          role = "user", content = "redirect", timestamp = 2,
        } }, function(committed, observation)
          acknowledgement = {
            committed = committed,
            observed = observation and observation._neoagent_entry_id,
            commits = commits,
          }
        end
      end,
      commit_message = function(message)
        commits = commits + 1
        local observed = vim.deepcopy(message) --[[@as Neoagent.ObservedMessage]]
        observed._neoagent_entry_id = "entry-" .. commits
        return true, nil, observed
      end,
    }))

    assert(result.ok == true)
    assert.are.same({
      committed = true,
      observed = "entry-2",
      commits = 2,
    }, acknowledgement)
  end)

  it("keeps steering acknowledged when cancellation follows commit", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "first" } }) },
      { result = fake_model.assistant({ { type = "text", text = "unused" } }) },
    })
    ---@type Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>?
    local run
    local acknowledged
    local offered = false
    run = agent_loop.run({
      model = model,
      messages = { { role = "user", content = "begin", timestamp = 1 } },
      get_steering_messages = function()
        if offered then return {} end
        offered = true
        return { {
          role = "user", content = "redirect", timestamp = 2,
        } }, function(committed)
          acknowledged = committed
        end
      end,
      commit_message = function(message)
        if message.role == "user" then assert(run):cancel() end
        return true
      end,
    })
    local result = wait(run)

    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.is_true(acknowledged)
    assert.are.equal(1, #model.requests)
  end)

  it("turns unknown tools into error results", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "missing", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local result = wait(agent_loop.run({ model = model, messages = {} }))
    assert(result.ok == true)
    assert.is_true(result_message(result, 2).isError)
    assert.matches("Unknown tool", util.text_content(result_message(result, 2).content))
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

    assert(result.ok == true)
    assert.is_true(result_message(result, 2).isError)
    assert.matches("valid UTF%-8", util.text_content(result_message(result, 2).content))
    assert.is_true(result_message(result, 3).isError)
    assert.matches("must be a string", util.text_content(result_message(result, 3).content))
    assert.is_true(util.is_valid_utf8(util.text_content(
      assert(assert(model.requests[2]).messages[2]).content)))
    assert.are.equal("recovered", result.text)
  end)

  it("normalizes empty argument lists and unsafe executor details", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "empty", name = "empty", arguments = {} },
        { type = "toolCall", id = "detail", name = "detail", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "empty", description = "empty", input_schema = { type = "object" },
        execute = function(arguments)
      assert.is_false(util.is_list(arguments))
          return { content = { { type = "text", text = "empty object" } } }
        end,
      }, {
        name = "detail", description = "detail", input_schema = { type = "object" },
        execute = function()
          error(util.error("tool", "safe message", "bad\255detail"), 0)
        end,
      } },
    }))

    assert(result.ok == true)
    assert.are.equal("empty object", util.text_content(result_message(result, 2).content))
    assert.is_true(result_message(result, 3).isError)
    assert.are.equal("safe message", util.text_content(result_message(result, 3).content))
    assert.are.same({ detail = "bad\\xFFdetail" },
      result_message(result, 3).details)
  end)

  it("contains steering acknowledgement failures after durable commit", function()
    local offered = false
    local result = wait(agent_loop.run({
      model = fake_model.new({ {
        result = fake_model.assistant({ { type = "text", text = "first" } }),
      } }),
      messages = {},
      get_steering_messages = function()
        if offered then return {} end
        offered = true
        return { { role = "user", content = "redirect" } }, function()
          error("acknowledgement failed")
        end
      end,
    }))

    assert.is_false(result.ok)
    assert.matches("acknowledgement failed", assert(result.error).message)
    assert.are.equal(1, #result.new_messages)
  end)

  it("contains commit failure for a partial failed Model response", function()
    local result = wait(core_agent_loop.run({
      model = fake_model.new({ {
        result = {
          ok = false,
          error = { kind = "transport", message = "stream failed" },
          message = {
            role = "assistant",
            content = { { type = "text", text = "partial" } },
          },
        },
      } }),
      messages = {},
      commit_message = function()
        return nil, { kind = "storage", message = "partial commit failed" }
      end,
    }))

    assert.is_false(result.ok)
    assert.matches("partial commit failed", assert(result.error).message)
    assert.are.equal("partial", assert(assert(result.message).content[1]).text)
  end)

  it("sanitizes executor failures before persisting an error result", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "c1", name = "broken", arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local detail = {}
    detail.self = detail
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      tools = { {
        name = "broken",
        description = "Broken executor",
        input_schema = {},
        execute = function()
          error({ kind = "tool", message = "bad\255message", detail = detail }, 0)
        end,
      } },
    }))

    assert(result.ok == true)
    assert.is_true(result_message(result, 2).isError)
    assert.matches("bad\\xFFmessage", util.text_content(result_message(result, 2).content))
    assert.is_nil(result_message(result, 2).details)
    assert.are.equal("recovered", result.text)
  end)

  it("validates stable image identities in results and transient updates", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "preview", arguments = {} },
        { type = "toolCall", id = "c2", name = "bad_final", arguments = {} },
        { type = "toolCall", id = "c3", name = "missing_mime", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local events = {}
    ---@type Neoagent.ImageBlock?
    local final_image
    ---@param fields table<string, unknown>
    ---@return table<string, unknown>
    local function image(fields)
      return vim.tbl_extend("force", attachments.image("image"), fields or {})
    end
    local result = wait(agent_loop.run({
      model = model,
      messages = {},
      model_options = { files = attachments.files },
      tools = { {
        name = "preview",
        description = "preview",
        input_schema = { type = "object" },
        execute = function(_, ctx)
          local invalid = {
            image({ revision = 1 }),
            image({ id = "preview" }),
            image({ id = "preview", revision = 1, file_id = false }),
            image({ id = "preview", revision = 1, mime_type = false }),
            { type = "image", file_id = string.rep("a", 64), bytes = 3,
              id = "untyped", revision = 1 },
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
            image({ id = "preview", revision = "frame-1",
              mime_type = "IMAGE/PNG" }),
          } })
          final_image = attachments.image("immutable-image", "IMAGE/PNG")
          return { content = { final_image } }
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
      }, {
        name = "missing_mime",
        description = "missing image MIME type",
        input_schema = { type = "object" },
        execute = function()
          return { content = { {
            type = "image", file_id = string.rep("a", 64), bytes = 3,
          } } }
        end,
      } },
      on_event = function(event) events[#events + 1] = event end,
    }))

    assert(result.ok == true)
    assert.is_false(result_message(result, 2).isError)
    assert.are.same(attachments.image("immutable-image"), result_message(result, 2).content[1])
    assert.are.equal("IMAGE/PNG", assert(final_image).mime_type)
    assert.is_true(result_message(result, 3).isError)
    assert.matches("finite", util.text_content(result_message(result, 3).content))
    assert.is_true(result_message(result, 4).isError)
    assert.matches("mime_type", util.text_content(result_message(result, 4).content))
    assert(vim.wait(1000, function()
      local count = 0
      for _, event in ipairs(events) do
        if event.type == "tool_update" then count = count + 1 end
      end
      return count == 1
    end))
    ---@type Neoagent.InputBlock?
    local update
    for _, event in ipairs(events) do
      if event.type == "tool_update" then update = event.result.content[1] end
    end
    assert.are.equal("preview", assert(update).id)
    assert.are.equal("frame-1", assert(update).revision)
    assert.are.equal("image/png", assert(update).mime_type)
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
    assert.are.equal("disconnected", assert(result.error).message)
    assert.are.equal("partial", util.text_content(result_message(result, 1).content))
    assert(vim.wait(1000, function() return #events == 2 end))
    assert.are.same({ "text_delta", "message_end" }, { events[1].type, events[2].type })
  end)

  it("turns invalid calls and executor failures into rich tool results", function()
    ---@type (fun(update: Neoagent.ToolResult))?
    local late_update
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "a", name = "invalid_args",
          arguments = vim.empty_dict(),
          argumentsError = "Tool arguments are not a JSON object" },
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
    assert(result.ok == true)
    for index = 2, 5 do assert.is_true(result_message(result, index).isError) end
    assert.matches("JSON object", util.text_content(result_message(result, 2).content))
    assert.matches("result with content", util.text_content(result_message(result, 3).content))
    assert.matches("unsupported content", util.text_content(result_message(result, 4).content))
    assert.matches("executor exploded", util.text_content(result_message(result, 5).content))
    assert.are.same({ diff = "+changed" }, result_message(result, 6).details)
    assert.are.same({ output = 3 }, result_message(result, 6).usage)
    local count = #events
    assert(late_update)({ content = { { type = "text", text = "too late" } } })
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
        execute = function() executed = true; return { content = {} } end,
      } },
    }))

    assert(result.ok == true)
    assert.is_false(executed)
    assert.is_true(result_message(result, 2).isError)
    assert.are.equal("Tool arguments are not valid JSON",
      util.text_content(result_message(result, 2).content))
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

    assert(result.ok == true)
    assert.is_false(executed)
    assert.is_true(result_message(result, 2).isError)
    assert.are.equal(table.concat({
      "Tool call arguments do not match the declared schema:",
      "- plan[2].status is required",
      "- plan[3].status is required",
    }, "\n"), util.text_content(result_message(result, 2).content))
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
        called = tool.name == "echo" and arguments.value == true and ctx.model == model
          and ctx.call.id == "c1" and ctx.call.name == "echo"
        return { content = { { type = "text", text = "approved" } } }
      end,
    }))
    assert(result.ok == true)
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
      ---@async
      execute_tool = function()
        return require("neoagent.async").await(function(done)
          vim.schedule(function()
            done.resolve({ content = { { type = "text", text = "approved asynchronously" } } })
          end)
        end)
      end,
    }))
    assert(result.ok == true)
    assert.are.equal("approved asynchronously", util.text_content(result_message(result, 2).content))
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
        ---@async
        execute = function()
          return require("neoagent.async").await(function()
            return function() cleaned = true end
          end)
        end,
      } },
    })
    vim.defer_fn(function() run:cancel() end, 10)
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(assert(run:result()).ok)
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
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
    ---@type (fun(update: Neoagent.ToolResult))?, boolean
    local late_update, cleaned = nil, false
    local revisions, completions = {}, 0
    local run = agent_loop.run({
      model = model,
      messages = {},
      model_options = { files = attachments.files },
      tools = { {
        name = "animate",
        description = "animate",
        input_schema = { type = "object" },
        ---@async
        execute = function(_, ctx)
          late_update = ctx.on_update
          ctx.on_update({ content = { attachments.image(vim.base64.decode("ZnJhbWUtb25l"), "image/png", { id = "preview", revision = 1 }) } })
          return require("neoagent.async").await(function()
            return function() cleaned = true end
          end)
        end,
      } },
      on_event = function(event)
        if event.type == "tool_update" then
          revisions[#revisions + 1] = assert(assert(event.result).content[1]).revision
        end
      end,
      on_done = function() completions = completions + 1 end,
    })
    assert(vim.wait(1000, function()
      return late_update ~= nil and #revisions == 1
    end))
    run:cancel()
    assert(vim.wait(1000, function() return run:is_done() end))
    assert(late_update)({ content = { attachments.image(vim.base64.decode("ZnJhbWUtdHdv"), "image/png", { id = "preview", revision = 2 }) } })
    vim.wait(20)

    assert.are.same({ 1 }, revisions)
    assert.are.equal(1, completions)
    assert.is_true(cleaned)
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
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
    assert.is_false(assert(run:result()).ok)
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
    assert.are.equal(1, #model.requests)
  end)

  it("continues tool calls until the model stops", function()
    ---@type Neoagent.TestModelResponse[]
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
    assert(result.ok == true)
    assert.are.equal("done", result.text)
    assert.are.equal(13, executions)
    assert.are.equal(14, #model.requests)
  end)
end)
