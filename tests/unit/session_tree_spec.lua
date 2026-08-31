local tree = require("neoagent.session_tree")

local function base(entry_type, values)
  return vim.tbl_extend("force", {
    type = entry_type,
    id = entry_type,
    parentId = vim.NIL,
    timestamp = "2026-01-01T00:00:00.000Z",
  }, values or {})
end

describe("neoagent.session_tree", function()
  it("validates every current entry shape", function()
    local invalid = {
      base("message", { parentId = {}, message = { role = "user", content = "x" } }),
      base("message", { message = { role = "user" } }),
      base("model_change", { provider = "", modelId = "x" }),
      base("thinking_level_change", { thinkingLevel = "" }),
      base("compaction", { summary = "", firstKeptEntryId = "x", tokensBefore = 1 }),
      base("leaf", { targetId = 1 }),
    }
    for _, entry in ipairs(invalid) do
      local ok, err = tree.validate_entry(entry)
      assert.is_false(ok)
      assert.is_truthy(err)
    end

    local ok, err = tree.validate_entry(base("message", { message = { role = "user", content = "x" } }))
    assert.is_true(ok)
    assert.is_nil(err)
    ok, err = tree.validate_entry(base("custom", { customType = "" }))
    assert.is_false(ok)
    assert.matches("unsupported entry type", err)
  end)

  it("rejects malformed tree relationships", function()
    local message = base("message", { message = { role = "user", content = "one" } })
    local duplicate = vim.deepcopy(message)
    duplicate.parentId = message.id
    local validated, err, index = tree.validate_entries({ message, duplicate })
    assert.is_nil(validated)
    assert.matches("duplicate", err)
    assert.are.equal(2, index)

    duplicate.id = "child"
    duplicate.parentId = "missing"
    validated, err = tree.validate_entries({ message, duplicate })
    assert.is_nil(validated)
    assert.matches("does not precede", err)

    local leaf = base("leaf", { id = "leaf", parentId = message.id, targetId = "missing" })
    validated, err = tree.validate_entries({ message, leaf })
    assert.is_nil(validated)
    assert.matches("leaf target", err)

    local compaction = base("compaction", {
      id = "compaction", parentId = message.id,
      firstKeptEntryId = "missing", summary = "bad", tokensBefore = 1,
    })
    validated, err = tree.validate_entries({ message, compaction })
    assert.is_nil(validated)
    assert.matches("first kept", err)

    local left = base("message", {
      id = "left", parentId = message.id,
      message = { role = "assistant", content = {} },
    })
    local right = base("message", {
      id = "right", parentId = message.id,
      message = { role = "assistant", content = {} },
    })
    compaction.parentId = right.id
    compaction.firstKeptEntryId = left.id
    validated, err = tree.validate_entries({ message, left, right, compaction })
    assert.is_nil(validated)
    assert.matches("active path", err)

    local path
    path, err = tree.path({ message }, "missing")
    assert.is_nil(path)
    assert.matches("entry not found", err)
  end)

  it("builds copied paths from validated entries and maintained indexes", function()
    local first = base("message", {
      id = "first", message = { role = "user", content = "one" },
    })
    local second = base("message", {
      id = "second", parentId = first.id, message = { role = "assistant", content = {} },
    })
    local validated = assert(tree.validate_entries({ first, second }))

    local path = assert(tree.path({ first, second }))
    local indexed = assert(tree.indexed_path(validated.by_id, second.id))
    assert.are.same({ "first", "second" }, vim.tbl_map(function(entry) return entry.id end, path))
    assert.are.same(path, indexed)
    indexed[1].message.content = "changed"
    assert.are.equal("one", first.message.content)
    assert.are.same({}, assert(tree.indexed_path(validated.by_id, vim.NIL)))
    local missing, err = tree.indexed_path(validated.by_id, "missing")
    assert.is_nil(missing)
    assert.matches("entry not found", err)
  end)

  it("orders compacted model context and transcripts identically", function()
    local prefix = base("message", {
      id = "prefix", message = { role = "user", content = "old" },
    })
    local kept = base("message", {
      id = "kept", parentId = prefix.id,
      message = { role = "assistant", content = {} },
    })
    local compaction = base("compaction", {
      id = "compaction", parentId = kept.id, firstKeptEntryId = kept.id,
      summary = "summary", tokensBefore = 100,
    })
    local after = base("message", {
      id = "after", parentId = compaction.id,
      message = { role = "assistant", content = {} },
    })
    local path = { prefix, kept, compaction, after }
    local ids = function(entries)
      return vim.tbl_map(function(entry) return entry.id end, entries)
    end

    assert.are.same({ "compaction", "kept", "after" },
      ids(tree.context_entries(path)))
    assert.are.same({ "compaction", "kept", "after" },
      ids(tree.transcript_entries(path)))
  end)

  it("projects compaction summaries into LLM context", function()
    local context = tree.to_llm({
      { role = "compactionSummary", summary = "old work", timestamp = 5 },
    })
    assert.are.equal(1, #context)
    assert.matches("old work", context[1].content[1].text)
  end)
end)
