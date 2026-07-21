local Session = require("neoagent.session")

describe("neoagent.session", function()
  it("is a no-argument tool-free in-memory message sequence", function()
    local session = assert(Session.new())
    assert.is_nil(session:metadata())
    assert(session:append({ role = "user", content = "hello" }))
    local messages = session:messages()
    messages[1].content = "changed"
    assert.are.equal("hello", session:messages()[1].content)
  end)

  it("loads and appends through an injected store", function()
    local appended
    local store = {
      load = function() return { { role = "user", content = "old" } } end,
      append = function(_, message) appended = message return true end,
      metadata = function() return { id = "store" } end,
    }
    local session = assert(Session.new({ store = store }))
    assert.are.equal("old", session:messages()[1].content)
    assert(session:append({ role = "assistant", content = {} }))
    assert.are.equal("assistant", appended.role)
    assert.are.same({ id = "store" }, session:metadata())
  end)

  it("does not add a message when storage rejects it", function()
    local session = assert(Session.new({ store = {
      load = function() return {} end,
      append = function() return nil, { kind = "storage", message = "full" } end,
      metadata = function() return {} end,
    } }))
    local ok, err = session:append({ role = "user", content = "lost" })
    assert.is_nil(ok)
    assert.are.equal("storage", err.kind)
    assert.are.equal(0, #session:messages())
  end)

  it("rejects initial messages combined with a store", function()
    local session, err = Session.new({ messages = {}, store = {} })
    assert.is_nil(session)
    assert.are.equal("session", err.kind)
  end)
end)
