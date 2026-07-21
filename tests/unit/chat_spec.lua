local chat = require("neoagent.chat")
local Session = require("neoagent.session")
local fake_model = require("tests.helpers.fake_model")

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end

describe("neoagent.chat", function()
  it("sends one model response and persists both messages", function()
    local session = assert(Session.new())
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "hi" } }) } })
    local result = wait(chat.send(session, "hello", { model = model }))
    assert.is_true(result.ok)
    assert.are.equal(session, result.session)
    assert.are.equal(2, #session:messages())
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

  it("continues projected Session context without appending another user message", function()
    local session = assert(Session.new({ messages = { { role = "user", content = "existing" } } }))
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "continued" } }) } })
    local result = wait(chat.continue(session, { model = model }))
    assert.is_true(result.ok)
    assert.are.equal(2, #session:messages())
    assert.are.equal("existing", model.requests[1].messages[1].content)
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
