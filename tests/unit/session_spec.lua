local Session = require("neoagent.session")

describe("neoagent.session", function()
  it("rejects branches and compactions targeting unknown entries", function()
    local session = assert(Session.new())
    local ok, err = session:move_to("missing")
    assert.is_nil(ok)
    assert.matches("Entry not found", err.message)
    ok, err = session:append_compaction({
      firstKeptEntryId = "missing",
      summary = "compacted",
      tokensBefore = 1,
    })
    assert.is_nil(ok)
    assert.matches("Invalid compaction", err.message)
  end)

  it("rejects colliding in-memory entry ids", function()
    local random = vim.uv.random
    vim.uv.random = function() return string.rep("x", 8) end
    local call_ok, append_ok, append_err = pcall(function()
      local session = assert(Session.new())
      assert(session:append({ role = "user", content = "first" }))
      return session:append({ role = "user", content = "second" })
    end)
    vim.uv.random = random

    assert(call_ok, append_ok)
    assert.is_nil(append_ok)
    assert.matches("duplicate entry id", append_err.detail)
  end)

  it("is a no-argument tool-free in-memory message sequence", function()
    local session = assert(Session.new())
    assert.is_nil(session:metadata())
    assert(session:append({ role = "user", content = "hello" }))
    local messages = session:messages()
    messages[1].content = "changed"
    assert.are.equal("hello", session:messages()[1].content)
  end)

  it("associates model state with an accepted in-memory message", function()
    local session = assert(Session.new())
    assert(session:append({ role = "user", content = "first" }, {
      model = { provider = "local", model = "coder" },
      thinking_level = "high",
    }))
    assert.are.same({ provider = "local", model = "coder" },
      session:state().model)
    assert.are.equal("high", session:state().thinking_level)
    assert.are.same({ "model_change", "thinking_level_change", "message" },
      vim.tbl_map(function(entry) return entry.type end, session:entries()))

    assert(session:append({ role = "user", content = "second" }, {
      model = { provider = "local", model = "coder" },
      thinking_level = "high",
    }))
    assert.are.equal(4, #session:entries())
  end)

  it("keeps long in-memory append projection bounded", function()
    local session = assert(Session.new())
    local started = vim.uv.hrtime()
    for index = 1, 2000 do
      assert(session:append({ role = "user", content = "message " .. index, timestamp = index }))
    end
    local elapsed_ms = (vim.uv.hrtime() - started) / 1000000

    assert.is_true(elapsed_ms < 2000, string.format("linear appends took %.0f ms", elapsed_ms))
    assert.are.equal(2000, #session:messages())
  end)

  it("loads and appends through an injected store", function()
    local appended
    local store = {
      load = function() return { { role = "user", content = "old" } } end,
      append = function(_, message)
        appended = message
        return true, nil, nil, {
          type = "append", messages = { vim.deepcopy(message) },
        }
      end,
      metadata = function() return { id = "store" } end,
    }
    local session = assert(Session.new({ store = store }))
    assert.are.equal("old", session:messages()[1].content)
    assert(session:append({ role = "assistant", content = {} }))
    assert.are.equal("assistant", appended.role)
    assert.are.same({ id = "store" }, session:metadata())
  end)

  it("applies copied projection updates from an injected store", function()
    local loads = 0
    local projection = {
      type = "append",
      messages = { { role = "assistant", content = "accepted" } },
    }
    local store = {
      load = function()
        loads = loads + 1
        return {}
      end,
      append = function()
        return true, nil, { id = "entry" }, projection
      end,
    }
    local session = assert(Session.new({ store = store }))
    local ok, _, entry = session:append({ role = "assistant", content = "requested" })

    assert(ok)
    assert.are.equal("entry", entry.id)
    assert.are.equal(1, loads)
    projection.messages[1].content = "changed"
    assert.are.equal("accepted", session:messages()[1].content)
  end)

  it("rejects stores that return an unknown incremental projection", function()
    local loads = 0
    local store = {
      load = function()
        loads = loads + 1
        return {}
      end,
      append = function()
        return true, nil, { id = "entry" }, {
          type = "future",
          messages = { { role = "assistant", content = "projection" } },
        }
      end,
    }
    local session = assert(Session.new({ store = store }))

    local ok, err = session:append({ role = "assistant", content = "requested" })
    assert.is_nil(ok)
    assert.matches("unknown projection", err.message)
    assert.are.equal(1, loads)
    assert.are.same({}, session:messages())
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

  it("branches in memory and projects the selected path", function()
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
    assert(session:move_to(left.id))
    assert.are.equal("left", session:messages()[2].content[1].text)
    local context = assert(session:context_messages())
    assert.are.equal("one", context[1].content)
    assert.are.equal("left", context[2].content[1].text)
    assert.are.equal(5, #session:entries())
  end)

  it("owns state and compaction entries in memory", function()
    local session = assert(Session.new())
    local _, _, first = session:append({ role = "user", content = "one" }, {
      model = { provider = "openai", model = "gpt" },
      thinking_level = "high",
    })
    assert.are.equal(first.id, session:leaf_id())
    assert.are.same({
      model = { provider = "openai", model = "gpt" },
      thinking_level = "high",
    }, session:state())
    assert(session:append_compaction({
      summary = "earlier", firstKeptEntryId = first.id, tokensBefore = 20,
    }))
    assert.matches("earlier", session:context_messages()[1].content[1].text)

    local ok, err = session:move_to("missing")
    assert.is_nil(ok)
    assert.matches("Entry not found", err.message)
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
      append_compaction = function(_, values)
        calls.compaction = values
        return true, nil, { id = "two" }, {
          type = "append", messages = {},
        }
      end,
      set_leaf = function(_, id)
        calls.leaf = id
        return true, nil, nil, { type = "replace", messages = {} }
      end,
      metadata = function() return { id = "stored" } end,
    }
    local session = assert(Session.new({ store = store }))
    assert.are.equal("context", session:context_messages()[1].content)
    assert.are.equal("one", session:entries()[1].id)
    assert.are.equal("one", session:entry("one").id)
    assert.are.equal("one", session:leaf_id())
    assert.are.equal("one", session:path()[1].id)
    assert.are.equal("low", session:state().thinking_level)
    assert(session:append_compaction({ summary = "done" }))
    assert.are.same({ summary = "done" }, calls.compaction)
    assert(session:move_to("one"))
    assert.are.equal("one", calls.leaf)
  end)

  it("reports optional store failures without mutating cached messages", function()
    local store = {
      load = function() return {} end,
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
    assert.matches("invalid projection", err.message)

    session = assert(Session.new({ store = { load = function() return {} end, append = function() return true end } }))
    ok, err = session:append_compaction({ summary = "x" })
    assert.is_nil(ok)
    assert.matches("does not support compaction", err.message)
    ok, err = session:move_to(nil)
    assert.is_nil(ok)
    assert.matches("does not support branching", err.message)
  end)

  it("rejects missing projections after optional tree store mutations", function()
    local session = assert(Session.new({ store = {
      load = function() return {} end,
      append = function() return true end,
      append_compaction = function()
        return true, nil, { id = "entry" }
      end,
    } }))
    local ok, err = session:append_compaction({ summary = "x" })
    assert.is_nil(ok)
    assert.are.equal("storage", err.kind)
    assert.matches("invalid projection", err.message)
    assert.are.same({}, session:messages())

    session = assert(Session.new({ store = {
      load = function() return {} end,
      append = function() return true end,
      set_leaf = function()
        return true
      end,
    } }))
    ok, err = session:move_to(nil)
    assert.is_nil(ok)
    assert.are.equal("storage", err.kind)
    assert.matches("invalid projection", err.message)
    assert.are.same({}, session:messages())
  end)

  it("rolls back atomic in-memory state journals", function()
    local original_random = vim.uv.random
    local function rejected_on(duplicate_call)
      local session = assert(Session.new())
      local calls = 0
      vim.uv.random = function(bytes)
        calls = calls + 1
        local value = calls == duplicate_call and 1 or calls
        return string.rep(string.char(value), bytes)
      end
      local ok, err = session:append({ role = "user", content = "atomic" }, {
        model = { provider = "fake", model = "test" },
        thinking_level = "high",
      })
      vim.uv.random = original_random
      assert.is_nil(ok)
      assert.matches("duplicate entry id", err.detail)
      assert.are.same({}, session:entries())
      assert.are.same({}, session:messages())
    end
    local ok, err = pcall(function()
      rejected_on(2)
      rejected_on(3)
    end)
    vim.uv.random = original_random
    assert(ok, err)
  end)

  it("validates explicit journals, snapshots, stores, and identities", function()
    local session, err = Session.new({ entries = false })
    assert.is_nil(session)
    assert.matches("entries must be an array", err.message)
    session, err = Session.new({ entries = { { type = "invalid" } } })
    assert.is_nil(session)
    assert.matches("Invalid Session entries", err.message)
    session, err = Session.new({ entries = {}, leaf_id = "missing" })
    assert.is_nil(session)
    assert.matches("active leaf", err.detail)
    session, err = Session.new({ id = false })
    assert.is_nil(session)
    assert.matches("id must be", err.message)

    local invalid_store = {
      load = function() return {} end,
      append = function() return true end,
      entries = function() return false end,
      leaf_id = function() return nil end,
    }
    session = assert(Session.new({ store = invalid_store }))
    assert.are.equal(invalid_store, session:store())
    local snapshot
    snapshot, err = session:snapshot()
    assert.is_nil(snapshot)
    assert.matches("Invalid Session snapshot", err.message)

    local mismatched_store = {
      load = function() return {} end,
      append = function() return true end,
      entries = function() return {} end,
      leaf_id = function() return "missing" end,
    }
    session = assert(Session.new({ store = mismatched_store }))
    snapshot, err = session:snapshot()
    assert.is_nil(snapshot)
    assert.matches("active leaf", err.detail)
  end)
end)
