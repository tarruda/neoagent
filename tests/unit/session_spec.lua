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

  it("validates Tool-result linkage before append", function()
    local session = assert(Session.new())
    local ok, err = session:append({
      role = "toolResult",
      toolCallId = "missing",
      content = {},
    })
    assert.is_nil(ok)
    assert.matches("unknown toolCall", err.detail)
    assert.are.same({}, session:messages())

    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "call-1", name = "read", arguments = {},
    } } }))
    assert(session:append({
      role = "toolResult", toolCallId = "call-1", toolName = "read",
      content = {},
    }))
    ok, err = session:append({ role = "assistant", content = { {
      type = "toolCall", id = "call-1", name = "read", arguments = {},
    } } })
    assert.is_nil(ok)
    assert.matches("duplicate conversation toolCall", err.detail)
    assert.are.equal(2, #session:messages())
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
    assert.are.same({
      model = { provider = "local", model = "coder" },
      thinkingLevel = "high",
    }, session:entries()[1].request)
    assert.are.same({ "message" },
      vim.tbl_map(function(entry) return entry.type end, session:entries()))

    assert(session:append({ role = "user", content = "second" }, {
      model = { provider = "local", model = "coder" },
      thinking_level = "high",
    }))
    assert.are.equal(2, #session:entries())
    assert.are.same(session:entries()[1].request,
      session:entries()[2].request)

    local ok, err = session:append({ role = "user", content = "invalid" }, {
      unknown = true,
    })
    assert.is_nil(ok)
    assert.matches("unsupported message state field", err.detail)
    assert.are.equal(2, #session:entries())
  end)

  it("clears thinking state only through an explicit tombstone", function()
    local session = assert(Session.new())
    local _, _, thinking = session:append({
      role = "user", content = "thinking",
    }, {
      model = { provider = "local", model = "reasoning" },
      thinking_level = "high",
    })
    assert(thinking)
    assert(session:append({ role = "assistant", content = { {
      type = "text", text = "done",
    } } }))
    assert(session:append({ role = "user", content = "preserve" }, {
      model = { provider = "local", model = "reasoning" },
    }))
    assert.are.equal("high", session:state().thinking_level)
    local _, _, cleared = session:append({
      role = "user", content = "clear",
    }, {
      model = { provider = "local", model = "plain" },
      thinking_level = vim.NIL,
    })
    assert(cleared)

    assert.is_nil(session:state().thinking_level)
    assert.are.equal(vim.NIL,
      session:entries()[4].request.thinkingLevel)
    assert(session:move_to(thinking.id))
    assert.are.equal("high", session:state().thinking_level)
    assert(session:move_to(cleared.id))
    assert.is_nil(session:state().thinking_level)
  end)

  it("keeps long in-memory append projection bounded", function()
    local session = assert(Session.new())
    local started = vim.uv.hrtime()
    for index = 1, 2000 do
      assert(session:append({ role = "user", content = "message " .. index, timestamp = index }))
    end
    local elapsed_ms = (vim.uv.hrtime() - started) / 1000000
    local maximum_ms = vim.env.NEOAGENT_COVERAGE == "1" and 4000 or 2000

    assert.is_true(elapsed_ms < maximum_ms,
      string.format("linear appends took %.0f ms", elapsed_ms))
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
      messages = { { role = "assistant", content = {
        { type = "text", text = "accepted" },
      } } },
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
    local ok, _, entry = session:append({ role = "assistant", content = {
      { type = "text", text = "requested" },
    } })

    assert(ok)
    assert.are.equal("entry", entry.id)
    assert.are.equal(1, loads)
    projection.messages[1].content[1].text = "changed"
    assert.are.equal("accepted", session:messages()[1].content[1].text)
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
          messages = { { role = "assistant", content = {
            { type = "text", text = "projection" },
          } } },
        }
      end,
    }
    local session = assert(Session.new({ store = store }))

    local ok, err = session:append({ role = "assistant", content = {
      { type = "text", text = "requested" },
    } })
    assert.is_nil(ok)
    assert.matches("unknown projection", err.message)
    assert.are.equal(1, loads)
    assert.are.same({}, session:messages())
  end)

  it("rejects malformed Store message projections at every boundary", function()
    local session, err = Session.new({ store = {
      load = function() return { { role = "user" } } end,
      append = function() return true end,
    } })
    assert.is_nil(session)
    assert.matches("Store returned invalid messages", err.message)

    local function loaded_store(projection)
      return {
        load = function() return {} end,
        append = function() return true, nil, nil, projection end,
      }
    end
    session = assert(Session.new({ store = loaded_store({
      type = "append", messages = { { role = "user" } },
    }) }))
    local ok
    ok, err = session:append({ role = "user", content = "request" })
    assert.is_nil(ok)
    assert.matches("Store returned invalid messages", err.message)

    session = assert(Session.new({ store = loaded_store({
      type = "append", messages = { {
        role = "toolResult", toolCallId = "missing", toolName = "read",
        content = {}, timestamp = 1,
      } },
    }) }))
    ok, err = session:append({ role = "user", content = "request" })
    assert.is_nil(ok)
    assert.matches("unknown toolCall", err.detail)

    session = assert(Session.new({ store = loaded_store({
      type = "replace", messages = { { role = "assistant" } },
    }) }))
    ok, err = session:append({ role = "user", content = "request" })
    assert.is_nil(ok)
    assert.matches("Store returned invalid messages", err.message)

    session = assert(Session.new({ store = {
      load = function() return {} end,
      append = function() return true end,
      context_messages = function() return { { role = "user" } } end,
    } }))
    local context
    context, err = session:context_messages()
    assert.is_nil(context)
    assert.matches("Store returned invalid context", err.message)
  end)

  it("contains invalid indexed and projected entry dependencies", function()
    local tree = require("neoagent.session_tree")
    local entry = {
      type = "message", id = "entry", parentId = vim.NIL,
      timestamp = "2026-01-01T00:00:00.000Z",
      message = { role = "user", content = "valid" },
    }
    local indexed_path = tree.indexed_path
    tree.indexed_path = function() return nil, "path dependency failed" end
    local session, err = Session.new({ entries = { entry } })
    tree.indexed_path = indexed_path
    assert.is_nil(session)
    assert.matches("path dependency failed", err.detail)

    local normalize_projection = tree.normalize_projection
    tree.normalize_projection = function()
      return nil, "projection dependency failed"
    end
    session, err = Session.new({ entries = { entry } })
    tree.normalize_projection = normalize_projection
    assert.is_nil(session)
    assert.matches("projection dependency failed", err.detail)
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

    for _, invalid in ipairs({
      {
        messages = { { role = "system", content = "unsupported" } },
        detail = "message 1: unsupported message role: system",
      },
      {
        messages = { { role = "user" } },
        detail = "message 1: message content is required",
      },
      {
        messages = { { role = "assistant", content = "invalid" } },
        detail = "message 1: assistant content must be a block list",
      },
      {
        messages = { { role = "user", content = {
          { type = "video", data = "invalid" },
        } } },
        detail = "message 1: content block 1: unsupported content block: video",
      },
      {
        messages = { { role = "user", content = {
          { type = "image", data = "aW1hZ2U=" },
        } } },
        detail = "message 1: content block 1: image mimeType is required",
      },
      {
        messages = { { role = "assistant", content = {
          { type = "toolCall", name = "missing_id", arguments = {} },
        } } },
        detail = "message 1: content block 1: toolCall id is required",
      },
      {
        messages = { { role = "toolResult", content = {} } },
        detail = "message 1: toolResult toolCallId is required",
      },
      { messages = {
        { role = "user", content = "valid prefix" },
        { role = "assistant" },
      }, detail = "message 2: message content is required" },
    }) do
      session, err = Session.new({ messages = invalid.messages })
      assert.is_nil(session)
      assert.matches("Invalid Session messages", err.message)
      assert.are.equal(invalid.detail, err.detail)
    end

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

  it("rejects protected compaction fields identically with a Store", function()
    for _, field in ipairs({ "type", "id", "parentId", "timestamp" }) do
      local directory = vim.fn.tempname()
      local memory = assert(Session.new())
      local stored = assert(Session.new({
        store = require("neoagent.storage").new({
          directory = directory,
          cwd = directory,
        }),
      }))
      local _, _, memory_first = memory:append({
        role = "user", content = "first",
      })
      local _, _, stored_first = stored:append({
        role = "user", content = "first",
      })
      local memory_values = {
        summary = "summary",
        firstKeptEntryId = memory_first.id,
        tokensBefore = 1,
        [field] = "forged",
      }
      local stored_values = {
        summary = "summary",
        firstKeptEntryId = stored_first.id,
        tokensBefore = 1,
        [field] = "forged",
      }
      local memory_ok, memory_err = memory:append_compaction(memory_values)
      local stored_ok, stored_err = stored:append_compaction(stored_values)
      assert.is_nil(memory_ok)
      assert.is_nil(stored_ok)
      assert.are.equal(memory_err.detail, stored_err.detail)
      assert.matches("protected field " .. field, memory_err.detail)
      vim.fn.delete(directory, "rf")
    end
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
