local assert = require("luassert")
local async = require("neoagent.async")
local chat = require("neoagent.chat")
local Session = require("neoagent.session")
local fake_model = require("tests.helpers.fake_model")

---@param value integer
---@return string
local function uint32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256)
end

---@param size integer
---@return string
local function png(size)
  return "\137PNG\r\n\26\n\0\0\0\rIHDR"
    .. uint32(size) .. uint32(size)
end

---@param run Neoagent.ChatRun
---@return Neoagent.ChatResult
local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe("neoagent.chat", function()
  ---@type string[]
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
    assert(result.ok)
    assert.are.equal(session, result.session)
    assert.are.equal(2, #session:messages())
  end)

  for _, method in ipairs({ "send", "run", "continue" }) do
    it("completes " .. method .. " turns with a projection-only Session store", function()
      ---@type Neoagent.Message[]
      local committed = {}
      ---@type Neoagent.SessionStorage
      local store = {
        load = function() return vim.deepcopy(committed) end,
        append = function(_, message)
          committed[#committed + 1] = vim.deepcopy(message)
          return true, nil, nil, { type = "append", messages = { vim.deepcopy(message) } }
        end,
      }
      local session = assert(Session.new({ store = store }))
      local model = fake_model.new()
      if method ~= "send" then
        model.responses[#model.responses + 1] = {
          result = fake_model.assistant({ { type = "toolCall", id = "c", name = "echo", arguments = {} } }, "toolUse"),
        }
      end
      model.responses[#model.responses + 1] = { result = fake_model.assistant({ { type = "text", text = "done" } }) }
      model.responses[#model.responses + 1] = { result = fake_model.assistant({ { type = "text", text = "later" } }) }
      local accepted_count = 0
      ---@type Neoagent.Message[]
      local steering = {}
      ---@type Neoagent.ObservedMessage[]
      local observed = {}
      ---@type Neoagent.ChatOptions<unknown>
      local opts = {
        model = model,
        tools = { {
          name = "echo", description = "", input_schema = {},
          execute = function()
            assert.are.equal("assistant", assert(committed[#committed]).role)
            steering = { { role = "user", content = "Follow up after the echo." } }
            return { content = { { type = "text", text = "echoed" } } }
          end,
        } },
        get_steering_messages = function()
          local pending = steering
          steering = {}
          return pending
        end,
        on_accept = function(entry)
          accepted_count = accepted_count + 1
          assert.is_nil(entry)
          assert.are.equal("hello", assert(committed[1]).content)
        end,
        on_event = function(event)
          if event.type == "message_end" then
            observed[#observed + 1] = vim.deepcopy(event.message)
            assert.is_nil(event.message._neoagent_entry_id)
            event.message.content = {}
          end
        end,
      }
      local run
      if method == "continue" then
        assert(session:append({ role = "user", content = "hello" }))
        run = chat.continue(session, opts)
      else
        run = chat[method](session, "hello", opts)
      end
      local result = wait(run)
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.equal(method == "continue" and 0 or 1, accepted_count)
      local expected_roles = method == "send" and { "user", "assistant" }
        or { "user", "assistant", "toolResult", "user", "assistant" }
      assert.are.same(expected_roles, vim.tbl_map(function(message) return message.role end, committed))
      assert.are.same(committed, session:messages())
      assert.are.same(vim.list_slice(committed, 2), observed)
      assert.are.equal("hello", assert(assert(model.requests[1]).messages[1]).content)
      if method ~= "send" then
        assert.are.equal("echoed", assert(assert(assert(model.requests[2]).messages[3]).content[1]).text)
        assert.are.equal("Follow up after the echo.", assert(assert(model.requests[2]).messages[4]).content)
      end

      assert.is_true(wait(chat.send(session, "next", { model = model })).ok)
      assert.are.equal(#expected_roles + 2, #committed)
      assert.are.same(committed, session:messages())
      assert.are.equal(method == "send" and 2 or 3, #model.requests)
    end)
  end

  for _, method in ipairs({ "send", "run", "continue" }) do
    it("releases the " .. method .. " reservation when Run construction throws", function()
      local session = assert(Session.new())
      local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "recovered" } }) } })
      local original = async.run
      async.run = function() error("Run construction failed") end
      local ok, err = pcall(function()
        if method == "continue" then return chat.continue(session, { model = model }) end
        return chat[method](session, "accepted", { model = model })
      end)
      async.run = original
      assert.is_false(ok)
      assert.matches("Run construction failed", tostring(err))
      assert.are.equal(method == "continue" and 0 or 1, #session:messages())
      assert.are.equal(0, #model.requests)
      local restarted, run = pcall(chat.send, session, "retry", { model = model })
      assert(restarted, vim.inspect(run))
      assert.is_true(wait(run).ok)
    end)
  end

  for _, method in ipairs({ "send", "run" }) do
    it("keeps accepted " .. method .. " prompts when cancelled before provider preparation", function()
      local session = assert(Session.new())
      local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "unused" } }) } })
      local run = chat[method](session, "accepted prompt", { model = model })
      assert.are.equal("accepted prompt", assert(session:messages()[1]).content)
      run:cancel()
      assert.is_false(wait(run).ok)
      assert.are.equal(0, #model.requests, "provider preparation ran before cancellation could be handled")
      assert.are.equal(1, #session:messages())
    end)
  end

  it("publishes acceptance after journaling the request model", function()
    local session = assert(Session.new())
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "hi" } }),
    } })
    ---@type {entry?: Neoagent.JournalEntry, state?: Neoagent.SelectionState}?
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

    assert(result.ok)
    assert.are.equal("message", assert(assert(accepted).entry).type)
    assert.are.same({ provider = "local", model = "coder" },
      assert(assert(accepted).state).model)
    assert.are.equal("high", assert(assert(accepted).state).thinking_level)
  end)

  it("rejects every reentrant Session mutation while accepting", function()
    for _, method in ipairs({ "send", "run", "continue" }) do
      local session = assert(Session.new())
      local model = fake_model.new({
        { result = fake_model.assistant({ { type = "text", text = "inner" } }) },
        { result = fake_model.assistant({ { type = "text", text = "outer" } }) },
      })
      ---@type boolean?, unknown
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

      assert(result.ok)
      assert.is_false(nested_ok, method)
      assert(type(nested_err) == "table")
      assert.are.equal("session", rawget(nested_err, "kind"))
      assert.are.equal(2, #session:messages())
    end
  end)

  it("reports acceptance callback failures and continues the turn", function()
    local session = assert(Session.new())
    ---@type {message: string, level: integer}[]
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

    assert(result.ok)
    assert.are.equal(2, #session:messages())
    assert.are.equal(1, #reports)
    assert.matches("acceptance observer failed", assert(reports[1]).message)
    assert.are.equal(vim.log.levels.ERROR, assert(reports[1]).level)
  end)

  it("reports callback diagnostics from an awaited Model Run", function()
    local session = assert(Session.new())
    local response = fake_model.assistant({ { type = "text", text = "hi" } })
    local model = fake_model.new()
    function model:stream()
      return async.run(function() return response end, {
        on_done = function() error("nested callback exploded") end,
      })
    end
    ---@type {message: string, level: integer}[]
    local reports = {}
    local result = wait(chat.run(session, "hello", {
      model = model,
      report = function(message, level)
        reports[#reports + 1] = { message = message, level = level }
      end,
    }))

    assert(result.ok)
    assert(vim.wait(1000, function() return #reports == 1 end))
    assert.matches("nested callback exploded", assert(reports[1]).message)
    assert.are.equal(vim.log.levels.ERROR, assert(reports[1]).level)
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
    assert(result.ok)
    assert.are.equal(4, #session:messages())
  end)

  it("rejects an invalid Tool before accepting the user message", function()
    local invalid_tools = {
      { {
        name = "unsafe\nname",
        description = "cannot identify safely",
        input_schema = {},
        execute = function() end,
      } },
      { {
        name = "missing_execute",
        description = "cannot run",
        input_schema = {},
      } },
      { {
        name = "invalid_schema",
        description = "cannot describe arguments",
        input_schema = "invalid",
        execute = function() end,
      } },
      { {
        name = "invalid_description",
        description = "invalid\255description",
        input_schema = {},
        execute = function() end,
      } },
      { {
        name = "invalid_message_hook",
        description = "cannot observe messages",
        input_schema = {},
        execute = function() end,
        on_messages = true,
      } },
      { {
        name = "invalid_current_hook",
        description = "cannot expose current state",
        input_schema = {},
        execute = function() end,
        current = true,
      } },
      { {
        name = "invalid_capability",
        description = "cannot declare capabilities",
        input_schema = {},
        execute = function() end,
        capabilities = { read_files = "yes" },
      } },
      { {
        name = "invalid_renderer",
        description = "cannot render",
        input_schema = {},
        execute = function() end,
        render = {},
      } },
      { {
        name = "unsupported_field",
        description = "cannot add implicit contracts",
        input_schema = {},
        execute = function() end,
        extension = true,
      } },
      {
        {
          name = "duplicate",
          description = "first",
          input_schema = {},
          execute = function() end,
        },
        {
          name = "duplicate",
          description = "second",
          input_schema = {},
          execute = function() end,
        },
      },
    }

    for _, tools in ipairs(invalid_tools) do
      local session = assert(Session.new())
      local model = fake_model.new({ {
        result = fake_model.assistant({ { type = "text", text = "unused" } }),
      } })
      local ok = pcall(chat.run, session, "must not be accepted", {
        model = model,
        tools = tools --[[@as Neoagent.Tool<unknown>[] ]],
      })

      assert.is_false(ok)
      assert.are.same({}, session:messages())
    end
  end)

  it("prepares the complete agent request before acceptance", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "unused" } }),
    } })
    local invalid_options = {
      { model = {} },
      { model = model, model_options = "invalid" },
      { model = model, system_prompt = {} },
      { model = model, execute_tool = true },
      { model = model, get_steering_messages = true },
      { model = model, on_event = true },
      { model = model, on_done = true },
    }

    for _, options in ipairs(invalid_options) do
      local session = assert(Session.new())
      assert.is_false(pcall(chat.run, session, "must not be accepted", options --[[@as Neoagent.ChatOptions<unknown>]]))
      assert.are.same({}, session:messages())
    end

    local session = assert(Session.new())
    assert.is_false(pcall(chat.run, session, false --[[@as string]], { model = model }))
    assert.are.same({}, session:messages())
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
    local attachments = require("tests.helpers.attachments").new(session:files())
    ---@type Neoagent.ImageBlock[]
    local frames = {}
    for revision = 1, 3 do
      frames[revision] = attachments.image(png(8 + revision), "image/png", { id = "preview", revision = revision })
    end
    local updates = {}
    local result = wait(chat.run(session, "animate", {
      model = model,
      tools = { {
        name = "animate",
        description = "emit deterministic PNG frames",
        input_schema = { type = "object" },
        execute = function(_, ctx)
          for revision = 1, 3 do ctx.on_update({ content = { frames[revision] } }) end
          return { content = { frames[3] } }
        end,
      } },
      on_event = function(event)
        if event.type == "tool_update" then
          updates[#updates + 1] = assert(assert(event.result).content[1]).revision
        end
      end,
    }))

    assert(result.ok)
    assert.are.same({ 1, 2, 3 }, updates)
    local messages = session:messages()
    assert.are.equal(4, #messages)
    assert.are.equal("toolResult", assert(messages[3]).role)
    assert.is_nil(assert(assert(assert(messages[3]).content)[1]).revision)
    assert.are.equal(assert(frames[3]).file_id, assert(assert(assert(messages[3]).content)[1]).file_id)
    assert.are.equal(png(11), attachments.read(assert(assert(assert(messages[3]).content)[1])))
    assert.are.equal(assert(frames[3]).file_id,
      assert(assert(assert(model.requests[2]).messages[3]).content[1]).file_id)

    local path = store:metadata().path
    local journal = table.concat(vim.fn.readfile(path), "\n")
    assert.is_nil((journal:find((assert(frames[1]).file_id), 1, true)))
    assert.is_nil((journal:find((assert(frames[2]).file_id), 1, true)))
    assert.is_not_nil((journal:find((assert(frames[3]).file_id), 1, true)))
    local resumed = assert(storage.open(path, store:workspace_storage())):load()
    assert.is_nil(assert(assert(assert(resumed[3]).content)[1]).revision)
    assert.are.equal(assert(frames[3]).file_id, assert(assert(assert(resumed[3]).content)[1]).file_id)
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
    local tool_identity
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
          identities[#identities + 1] = assert(event.message)._neoagent_entry_id
        elseif event.type == "tool_end" then
          tool_identity = assert(event.message)._neoagent_entry_id
        end
      end,
    }))

    assert(result.ok)
    assert.are.equal(3, #identities)
    local seen = {}
    for _, identity in ipairs(identities) do
      assert.is_string(identity)
      seen[identity] = true
    end
    assert.are.equal(3, vim.tbl_count(seen))
    assert.is_string(tool_identity)
    assert.is_true(seen[tool_identity])
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
    assert(result.ok)
    assert.are.same({ "user", "assistant", "user", "assistant" },
      vim.tbl_map(function(message) return message.role end, session:messages()))
    assert.are.equal("steer", assert(session:messages()[3]).content)
  end)

  it("continues projected Session context without appending another user message", function()
    local session = assert(Session.new({ messages = { { role = "user", content = "existing" } } }))
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "continued" } }) } })
    local result = wait(chat.continue(session, { model = model }))
    assert(result.ok)
    assert.are.equal(2, #session:messages())
    assert.are.equal("existing", assert(assert(model.requests[1]).messages[1]).content)
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
    assert(result.ok)
    projected[1].content = "changed"
    assert.are.equal("projected", assert(assert(model.requests[1]).messages[1]).content)

    result = wait(chat.continue(session, {
      model = model,
      context_messages = { { role = "user", content = "fixed" } },
    }))
    assert(result.ok)
    assert.are.equal("fixed", assert(assert(model.requests[2]).messages[1]).content)
  end)

  it("reports failed context projections and publishes completed sends", function()
    local session = assert(Session.new())
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local completed
    local result = wait(chat.send(session, "hello", {
      model = model,
      on_done = function(value) completed = value end,
    }))
    assert.is_true(result.ok)
    assert.are.equal(result, completed)

    result = wait(chat.continue(session, {
      model = model,
      context_messages = function()
        return nil, { kind = "storage", message = "context unavailable" }
      end,
    }))
    assert.is_false(result.ok)
    assert.are.equal("storage", assert(result.error).kind)
    assert.matches("context unavailable", assert(result.error).message)
  end)

  it("clears active state after synchronous startup failures", function()
    local session = assert(Session.new())
    local throwing = fake_model.new()
    function throwing:stream() error("stream startup failed") end
    local sent = chat.send(session, "first", { model = throwing })
    assert.matches("stream startup failed", assert(wait(sent).error).message)

    local invalid_options = { model = {} }
    local invalid_ok, invalid_err = pcall(
      chat.run, session, "second", invalid_options --[[@as Neoagent.ChatOptions<unknown>]])
    assert.is_false(invalid_ok)
    assert(not invalid_ok)
    assert.matches("model is required", tostring(invalid_err))
    assert.are.equal(1, #session:messages())

    local recovered = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    assert.is_true(wait(chat.send(session, "third", { model = recovered })).ok)
  end)

  it("clears acceptance reservations after append and preparation failures", function()
    local session = assert(Session.new())
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "unused" } }),
    } })
    local append = session.append
    session.append = function()
      session.append = append
      error("append crashed")
    end
    local ok, err = pcall(chat.run, session, "not accepted", { model = model })
    assert.is_false(ok)
    assert.matches("append crashed", tostring(err))

    ok, err = pcall(chat.run, session, "not prepared", { model = false --[[@as Neoagent.Model]] })
    assert.is_false(ok)
    assert.matches("model is required", tostring(err))
    assert.are.same({}, session:messages())

    local recovered = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "recovered" } }),
    } })
    local result = wait(chat.run(session, "retry", { model = recovered }))
    assert(result.ok)
  end)

  it("rejects a second active mutation", function()
    local session = assert(Session.new())
    local model = fake_model.new()
    function model:stream()
      return async.run(function()
        return async.await(function() return function() end end)
      end)
    end
    local first = chat.send(session, "one", { model = model })
    local ok, err = pcall(chat.send, session, "two", { model = model })
    assert.is_false(ok)
    assert(type(err) == "table")
    assert.are.equal("session", rawget(err, "kind"))
    first:cancel()
    assert(vim.wait(1000, function() return first:is_done() end))
    local replacement = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "recovered" } }) } })
    local result = wait(chat.send(session, "three", { model = replacement }))
    assert(result.ok)
  end)

  it("surfaces user and assistant persistence failures", function()
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "unused" } }) } })
    local rejecting = assert(Session.new())
    rejecting.append = function() return nil, { kind = "storage", message = "read only" } end
    local ok, err = pcall(chat.send, rejecting, "hello", { model = model })
    assert.is_false(ok)
    assert(type(err) == "table")
    assert.are.equal("storage", rawget(err, "kind"))

    local writes = 0
    local flaky = assert(Session.new())
    local append = flaky.append
    function flaky:append(message, state)
      writes = writes + 1
      if writes == 2 then return nil, { kind = "storage", message = "disk full" } end
      return append(self, message, state)
    end
    model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "lost" } }) },
      { result = fake_model.assistant({ { type = "text", text = "saved" } }) },
    })
    local result = wait(chat.send(flaky, "one", { model = model }))
    assert.is_false(result.ok)
    assert.are.equal("disk full", assert(result.error).message)
    result = wait(chat.send(flaky, "two", { model = model }))
    assert(result.ok)
  end)

  it("stops persisting an agent run after the first storage failure", function()
    local writes = 0
    local session = assert(Session.new())
    local append = session.append
    function session:append(message, state)
      writes = writes + 1
      if writes == 2 then return nil, { kind = "storage", message = "unavailable" } end
      return append(self, message, state)
    end
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "answer" } }) } })
    local result = wait(chat.run(session, "question", { model = model }))
    assert.is_false(result.ok)
    assert.are.equal("unavailable", assert(result.error).message)
    assert.are.equal(2, writes)
  end)

  it("commits a tool call before allowing its effect", function()
    local writes = 0
    local session = assert(Session.new())
    local append = session.append
    function session:append(message, state)
      writes = writes + 1
      if writes == 2 then
        return nil, { kind = "storage", message = "journal unavailable" }
      end
      return append(self, message, state)
    end
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "effect", name = "mutate", arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local executed = false
    local result = wait(chat.run(session, "change it", {
      model = model,
      tools = { {
        name = "mutate",
        description = "perform an effect",
        input_schema = { type = "object" },
        execute = function()
          executed = true
          return { content = { { type = "text", text = "changed" } } }
        end,
      } },
    }))

    assert.is_false(result.ok)
    assert.are.equal("journal unavailable", assert(result.error).message)
    assert.is_false(executed)
    assert.are.equal(1, #model.requests)
    assert.are.equal(2, writes)
  end)
end)
