local async = require("neoagent.async")
local chat = require("neoagent.chat")
local Session = require("neoagent.session")
local fake_model = require("tests.helpers.fake_model")

local function uint32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256)
end

local function png(size)
  return "\137PNG\r\n\26\n\0\0\0\rIHDR"
    .. uint32(size) .. uint32(size)
end

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end

describe("neoagent.chat", function()
  local directories = {}

  after_each(function()
    for _, directory in ipairs(directories) do
      vim.fn.delete(directory, "rf")
    end
    directories = {}
  end)

  it("sends one model response and persists both messages", function()
    local session = assert(Session.new())
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "hi" } }) } })
    local result = wait(chat.send(session, "hello", { model = model }))
    assert.is_true(result.ok)
    assert.are.equal(session, result.session)
    assert.are.equal(2, #session:messages())
  end)

  it("publishes acceptance after journaling the request model", function()
    local session = assert(Session.new())
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "hi" } }),
    } })
    local accepted
    local result = wait(chat.send(session, "hello", {
      model = model,
      session_state = {
        model = { provider = "local", model = "coder" },
        thinking_level = "high",
      },
      on_accept = function(entry)
        accepted = { entry = entry, state = session:state() }
      end,
    }))

    assert.is_true(result.ok)
    assert.are.equal("message", accepted.entry.type)
    assert.are.same({ provider = "local", model = "coder" },
      accepted.state.model)
    assert.are.equal("high", accepted.state.thinking_level)
  end)

  it("rejects every reentrant Session mutation while accepting", function()
    for _, method in ipairs({ "send", "run", "continue" }) do
      local session = assert(Session.new())
      local model = fake_model.new({
        { result = fake_model.assistant({ { type = "text", text = "inner" } }) },
        { result = fake_model.assistant({ { type = "text", text = "outer" } }) },
      })
      local nested_ok, nested_err
      local result = wait(chat.run(session, "outer", {
        model = model,
        on_accept = function()
          nested_ok, nested_err = pcall(function()
            if method == "continue" then
              return chat.continue(session, { model = model })
            end
            return chat[method](session, "inner", { model = model })
          end)
        end,
      }))

      assert.is_true(result.ok)
      assert.is_false(nested_ok, method)
      assert.are.equal("session", nested_err.kind)
      assert.are.equal(2, #session:messages())
    end
  end)

  it("reports acceptance callback failures and continues the turn", function()
    local session = assert(Session.new())
    local reports = {}
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "hi" } }),
    } })
    local run = chat.run(session, "hello", {
      model = model,
      on_accept = function() error("acceptance observer failed") end,
      report = function(message, level)
        reports[#reports + 1] = { message = message, level = level }
      end,
    })
    local result = wait(run)

    assert.is_true(result.ok)
    assert.are.equal(2, #session:messages())
    assert.are.equal(1, #reports)
    assert.matches("acceptance observer failed", reports[1].message)
    assert.are.equal(vim.log.levels.ERROR, reports[1].level)
  end)

  it("reports callback diagnostics from an awaited Model Run", function()
    local session = assert(Session.new())
    local response = fake_model.assistant({ { type = "text", text = "hi" } })
    local model = {
      stream = function()
        return async.run(function() return response end, {
          on_done = function() error("nested callback exploded") end,
        })
      end,
    }
    local reports = {}
    local result = wait(chat.run(session, "hello", {
      model = model,
      report = function(message, level)
        reports[#reports + 1] = { message = message, level = level }
      end,
    }))

    assert.is_true(result.ok)
    assert(vim.wait(1000, function() return #reports == 1 end))
    assert.matches("nested callback exploded", reports[1].message)
    assert.are.equal(vim.log.levels.ERROR, reports[1].level)
  end)

  it("runs an agent and persists every generated message", function()
    local session = assert(Session.new())
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "toolCall", id = "c", name = "echo", arguments = {} } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local result = wait(chat.run(session, "go", {
      model = model,
      tools = { {
        name = "echo", description = "", input_schema = {},
        execute = function() return { content = { { type = "text", text = "ok" } } } end,
      } },
    }))
    assert.is_true(result.ok)
    assert.are.equal(4, #session:messages())
  end)

  it("persists only the final frame from transient tool animation", function()
    local directory = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    directories[#directories + 1] = directory
    local storage = require("neoagent.storage")
    local store = storage.new({ directory = directory, cwd = directory })
    local session = assert(Session.new({ store = store }))
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall",
        id = "animated",
        name = "animate",
        arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local frames = {}
    for revision = 1, 3 do
      frames[revision] = vim.base64.encode(png(8 + revision))
    end
    local updates = {}
    local result = wait(chat.run(session, "animate", {
      model = model,
      tools = { {
        name = "animate",
        description = "emit deterministic PNG frames",
        input_schema = { type = "object" },
        execute = function(_, ctx)
          for revision = 1, 3 do
            ctx.on_update({ content = { {
              type = "image",
              mimeType = "image/png",
              data = frames[revision],
              id = "preview",
              revision = revision,
            } } })
          end
          return { content = { {
            type = "image",
            mimeType = "image/png",
            data = frames[3],
            id = "preview",
            revision = 3,
          } } }
        end,
      } },
      on_event = function(event)
        if event.type == "tool_update" then
          updates[#updates + 1] = event.result.content[1].revision
        end
      end,
    }))

    assert.is_true(result.ok)
    assert.are.same({ 1, 2, 3 }, updates)
    local messages = session:messages()
    assert.are.equal(4, #messages)
    assert.are.equal("toolResult", messages[3].role)
    assert.are.equal(3, messages[3].content[1].revision)
    assert.are.equal(frames[3], messages[3].content[1].data)
    assert.are.equal(frames[3],
      model.requests[2].messages[3].content[1].data)

    local path = store:metadata().path
    local journal = table.concat(vim.fn.readfile(path), "\n")
    assert.is_nil(journal:find(frames[1], 1, true))
    assert.is_nil(journal:find(frames[2], 1, true))
    assert.is_not_nil(journal:find(frames[3], 1, true))
    local resumed = assert(storage.open(path)):load()
    assert.are.equal(3, resumed[3].content[1].revision)
  end)

  it("publishes persisted message identities with agent events", function()
    local session = assert(Session.new())
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "c", name = "echo", arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ {
        type = "text", text = "done",
      } }) },
    })
    local identities = {}
    local result = wait(chat.run(session, "go", {
      model = model,
      tools = { {
        name = "echo", description = "", input_schema = {},
        execute = function()
          return { content = { { type = "text", text = "ok" } } }
        end,
      } },
      on_event = function(event)
        if event.type == "message_end" then
          identities[#identities + 1] = event.message._neoagent_entry_id
        end
      end,
    }))

    assert.is_true(result.ok)
    assert.are.equal(3, #identities)
    local seen = {}
    for _, identity in ipairs(identities) do
      assert.is_string(identity)
      seen[identity] = true
    end
    assert.are.equal(3, vim.tbl_count(seen))
  end)

  it("persists steering messages when the Agent Loop accepts them", function()
    local session = assert(Session.new())
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "first" } }) },
      { result = fake_model.assistant({ { type = "text", text = "redirected" } }) },
    })
    local pending = { { role = "user", content = "steer", timestamp = 2 } }
    local result = wait(chat.run(session, "begin", {
      model = model,
      get_steering_messages = function()
        local messages = pending
        pending = {}
        return messages
      end,
    }))
    assert.is_true(result.ok)
    assert.are.same({ "user", "assistant", "user", "assistant" },
      vim.tbl_map(function(message) return message.role end, session:messages()))
    assert.are.equal("steer", session:messages()[3].content)
  end)

  it("continues projected Session context without appending another user message", function()
    local session = assert(Session.new({ messages = { { role = "user", content = "existing" } } }))
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "continued" } }) } })
    local result = wait(chat.continue(session, { model = model }))
    assert.is_true(result.ok)
    assert.are.equal(2, #session:messages())
    assert.are.equal("existing", model.requests[1].messages[1].content)
  end)

  it("accepts explicit context projections without exposing mutable input", function()
    local session = assert(Session.new({ messages = { { role = "user", content = "stored" } } }))
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "function" } }) },
      { result = fake_model.assistant({ { type = "text", text = "table" } }) },
    })
    local projected = { { role = "user", content = "projected" } }
    local result = wait(chat.continue(session, {
      model = model,
      context_messages = function(selected)
        assert.are.equal(session, selected)
        return projected
      end,
    }))
    assert.is_true(result.ok)
    projected[1].content = "changed"
    assert.are.equal("projected", model.requests[1].messages[1].content)

    result = wait(chat.continue(session, {
      model = model,
      context_messages = { { role = "user", content = "fixed" } },
    }))
    assert.is_true(result.ok)
    assert.are.equal("fixed", model.requests[2].messages[1].content)
  end)

  it("clears active state after synchronous startup failures", function()
    local session = assert(Session.new())
    local throwing = { stream = function() error("stream startup failed") end }
    local sent = chat.send(session, "first", { model = throwing })
    assert.is_true(sent:is_done())
    assert.matches("stream startup failed", sent:result().error.message)

    local invalid = chat.run(session, "second", { model = {} })
    assert.is_true(invalid:is_done())
    assert.matches("model is required", invalid:result().error.message)

    local recovered = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    assert.is_true(wait(chat.send(session, "third", { model = recovered })).ok)
  end)

  it("clears acceptance reservations after append and preparation failures", function()
    local session = assert(Session.new())
    local append = session.append
    session.append = function()
      session.append = append
      error("append crashed")
    end
    local ok, err = pcall(chat.run, session, "not accepted", { model = {} })
    assert.is_false(ok)
    assert.matches("append crashed", err)

    ok, err = pcall(chat.run, session, "accepted", { model = false })
    assert.is_false(ok)
    assert.matches("model is required", err)

    local recovered = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "recovered" } }),
    } })
    local result = wait(chat.run(session, "retry", { model = recovered }))
    assert.is_true(result.ok)
  end)

  it("rejects a second active mutation", function()
    local session = assert(Session.new())
    local model = {
      stream = function()
        return require("neoagent.async").run(function()
          require("neoagent.async").await(function() return function() end end)
        end)
      end,
    }
    local first = chat.send(session, "one", { model = model })
    local ok, err = pcall(chat.send, session, "two", { model = model })
    assert.is_false(ok)
    assert.are.equal("session", err.kind)
    first:cancel()
    assert(vim.wait(1000, function() return first:is_done() end))
    local replacement = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "recovered" } }) } })
    local result = wait(chat.send(session, "three", { model = replacement }))
    assert.is_true(result.ok)
  end)

  it("surfaces user and assistant persistence failures", function()
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "unused" } }) } })
    local rejecting = {
      append = function() return nil, { kind = "storage", message = "read only" } end,
      messages = function() return {} end,
    }
    local ok, err = pcall(chat.send, rejecting, "hello", { model = model })
    assert.is_false(ok)
    assert.are.equal("storage", err.kind)

    local messages = {}
    local writes = 0
    local flaky = {
      append = function(_, message)
        writes = writes + 1
        if writes == 2 then return nil, { kind = "storage", message = "disk full" } end
        messages[#messages + 1] = message
        return true
      end,
      messages = function() return vim.deepcopy(messages) end,
    }
    model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "lost" } }) },
      { result = fake_model.assistant({ { type = "text", text = "saved" } }) },
    })
    local result = wait(chat.send(flaky, "one", { model = model }))
    assert.is_false(result.ok)
    assert.are.equal("disk full", result.error.message)
    result = wait(chat.send(flaky, "two", { model = model }))
    assert.is_true(result.ok)
  end)

  it("stops persisting an agent run after the first storage failure", function()
    local messages = {}
    local writes = 0
    local session = {
      append = function(_, message)
        writes = writes + 1
        if writes == 2 then return nil, { kind = "storage", message = "unavailable" } end
        messages[#messages + 1] = message
        return true
      end,
      messages = function() return vim.deepcopy(messages) end,
    }
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "answer" } }) } })
    local result = wait(chat.run(session, "question", { model = model }))
    assert.is_false(result.ok)
    assert.are.equal("unavailable", result.error.message)
    assert.are.equal(2, writes)
  end)
end)
