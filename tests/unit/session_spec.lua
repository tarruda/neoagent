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

  it("validates injected stores and initial message collections", function()
    local session, err = Session.new({ store = {} })
    assert.is_nil(session)
    assert.matches("storage contract", err.message)

    session, err = Session.new({ store = {
      load = function() return nil, "unreadable" end,
      append = function() return true end,
    } })
    assert.is_nil(session)
    assert.are.equal("storage", err.kind)
    assert.matches("unreadable", err.message)

    session, err = Session.new({ messages = "not an array" })
    assert.is_nil(session)
    assert.matches("array", err.message)

    local initial = { { role = "user", content = "hello" } }
    session = assert(Session.new({ messages = initial }))
    initial[1].content = "changed"
    assert.are.equal("hello", session:messages()[1].content)
  end)

  it("branches in memory and projects Pi context entries", function()
    local session = assert(Session.new())
    local ok, _, first = session:append({ role = "user", content = "one" })
    assert(ok)
    local _, _, left = session:append({ role = "assistant", content = { { type = "text", text = "left" } } })
    assert(session:move_to(first.id))
    local _, _, right = session:append({ role = "assistant", content = { { type = "text", text = "right" } } })
    assert.are.equal(first.id, right.parentId)
    assert.are.same({ "one", "right" }, vim.tbl_map(function(message)
      return type(message.content) == "string" and message.content or message.content[1].text
    end, session:messages()))
    assert(session:move_to(left.id, { summary = "Work from the other branch" }))
    assert.are.equal("left", session:messages()[2].content[1].text)
    assert.are.equal("branchSummary", session:messages()[3].role)

    assert(session:append_entry("custom_message", {
      customType = "notice", content = "remember", display = true,
    }))
    local context = assert(session:context_messages())
    assert.matches("other branch", context[3].content[1].text)
    assert.are.equal("remember", context[4].content[1].text)
    assert.are.equal(7, #session:entries())
  end)

  it("owns labels, names, state, and compaction entries in memory", function()
    local session = assert(Session.new())
    local _, _, first = session:append({ role = "user", content = "one" })
    assert.are.equal(first.id, session:leaf_id())
    assert(session:append_entry("model_change", { provider = "openai", modelId = "gpt" }))
    assert(session:append_entry("thinking_level_change", { thinkingLevel = "high" }))
    assert(session:append_entry("active_tools_change", { activeToolNames = { "read_file" } }))
    assert(session:append_entry("label", { targetId = first.id, label = "Start" }))
    assert(session:append_entry("session_info", { name = "  Example  " }))
    assert.are.equal("Start", session:label(first.id))
    assert.are.equal("Example", session:name())
    assert.are.same({
      model = { provider = "openai", model = "gpt" },
      thinking_level = "high",
      active_tools = { "read_file" },
    }, session:state())
    assert(session:append_entry("compaction", {
      summary = "earlier", firstKeptEntryId = first.id, tokensBefore = 20,
    }))
    assert.matches("earlier", session:context_messages()[1].content[1].text)

    local ok, err = session:move_to("missing")
    assert.is_nil(ok)
    assert.matches("Entry not found", err.message)
    ok, err = session:append_entry("label", { targetId = "missing", label = "bad" })
    assert.is_nil(ok)
    assert.matches("Invalid label", err.message)
  end)

  it("delegates the optional tree API to a capable store", function()
    local calls = {}
    local store = {
      load = function() return { { role = "user", content = "stored" } } end,
      append = function() return true end,
      context_messages = function() return { { role = "user", content = "context" } } end,
      entries = function() return { { id = "one" } } end,
      entry = function(_, id) return id == "one" and { id = id } or nil end,
      leaf_id = function() return "one" end,
      path = function(_, id) return { { id = id or "one" } } end,
      state = function() return { thinking_level = "low" } end,
      label = function() return "label" end,
      name = function() return "name" end,
      append_entry = function(_, kind, values)
        calls.entry = { kind, values }
        return true, nil, { id = "two" }
      end,
      set_leaf = function(_, id) calls.leaf = id return true end,
      metadata = function() return { id = "stored" } end,
    }
    local session = assert(Session.new({ store = store }))
    assert.are.equal("context", session:context_messages()[1].content)
    assert.are.equal("one", session:entries()[1].id)
    assert.are.equal("one", session:entry("one").id)
    assert.are.equal("one", session:leaf_id())
    assert.are.equal("one", session:path()[1].id)
    assert.are.equal("low", session:state().thinking_level)
    assert.are.equal("label", session:label("one"))
    assert.are.equal("name", session:name())
    assert(session:append_entry("custom", { customType = "x" }))
    assert.are.same({ "custom", { customType = "x" } }, calls.entry)
    assert(session:move_to("one"))
    assert.are.equal("one", calls.leaf)
  end)

  it("reports optional store failures without mutating cached messages", function()
    local loads = 0
    local store = {
      load = function()
        loads = loads + 1
        if loads == 1 then return {} end
        return nil, { kind = "storage", message = "reload failed" }
      end,
      append = function() return true end,
      context_messages = function() return nil, { kind = "storage", message = "context failed" } end,
    }
    local session = assert(Session.new({ store = store }))
    local messages, err = session:context_messages()
    assert.is_nil(messages)
    assert.are.equal("context failed", err.message)
    local ok
    ok, err = session:append({ role = "user", content = "lost" })
    assert.is_nil(ok)
    assert.are.equal("reload failed", err.message)

    session = assert(Session.new({ store = { load = function() return {} end, append = function() return true end } }))
    ok, err = session:append_entry("custom", { customType = "x" })
    assert.is_nil(ok)
    assert.matches("does not support session entries", err.message)
    ok, err = session:move_to(nil)
    assert.is_nil(ok)
    assert.matches("does not support branching", err.message)
  end)
end)
