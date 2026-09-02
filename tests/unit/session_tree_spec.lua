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
  it("assembles entries without exposing journal-owned fields", function()
    for _, entry_type in ipairs({ "message", "compaction", "leaf" }) do
      for _, field in ipairs({ "type", "id", "parentId", "timestamp" }) do
        local payload = { [field] = "forged" }
        local entry, err = tree.prepare_entry({
          type = entry_type,
          id = "owned-id",
          parent_id = vim.NIL,
          timestamp = "2026-01-01T00:00:00.000Z",
          payload = payload,
          by_id = {},
        })
        assert.is_nil(entry)
        assert.matches("protected field " .. field, err)
      end
    end

    local payload = { message = { role = "user", content = "owned" } }
    local entry = assert(tree.prepare_entry({
      type = "message",
      id = "owned-id",
      parent_id = vim.NIL,
      timestamp = "2026-01-01T00:00:00.000Z",
      payload = payload,
      by_id = {},
    }))
    payload.message.content = "changed"
    assert.are.equal("owned-id", entry.id)
    assert.are.equal("owned", entry.message.content)
  end)

  it("validates every current entry shape", function()
    local invalid = {
      base("message", { parentId = {}, message = { role = "user", content = "x" } }),
      base("message", { message = { role = "system", content = "x" } }),
      base("message", { message = { role = "user" } }),
      base("message", { message = { role = "assistant", content = "x" } }),
      base("message", { message = { role = "user", content = { {
        type = "image", data = "aW1hZ2U=",
      } } } }),
      base("message", {
        message = { role = "user", content = "x" },
        request = { model = { provider = "", model = "x" } },
      }),
      base("message", {
        message = { role = "user", content = "x" },
        request = { thinkingLevel = "" },
      }),
      base("message", {
        message = { role = "user", content = "x" },
        request = { "array" },
      }),
      base("message", {
        message = { role = "user", content = "x" },
        request = { unknown = true },
      }),
      base("message", {
        message = { role = "user", content = "x" },
        request = { model = {
          provider = "provider", model = "model", unknown = true,
        } },
      }),
      base("message", {
        message = { role = "user", content = "x" },
        unknown = true,
      }),
      base("model_change", { provider = "p", modelId = "x" }),
      base("thinking_level_change", { thinkingLevel = "high" }),
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

  it("validates Tool linkage on each journal branch", function()
    local call = base("message", {
      id = "call", message = { role = "assistant", content = { {
        type = "toolCall", id = "tool-1", name = "read", arguments = {},
      } }, timestamp = 1 },
    })
    local result = base("message", {
      id = "result", parentId = call.id,
      message = { role = "toolResult", toolCallId = "tool-1",
        toolName = "read", content = {}, timestamp = 2 },
    })
    assert(tree.validate_entries({ call, result }))

    local mismatched = vim.deepcopy(result)
    mismatched.message.toolName = "write"
    local validated, err = tree.validate_entries({ call, mismatched })
    assert.is_nil(validated)
    assert.matches("does not match", err)

    local duplicate = base("message", {
      id = "duplicate", parentId = result.id,
      message = { role = "assistant", content = { {
        type = "toolCall", id = "tool-1", name = "read", arguments = {},
      } }, timestamp = 3 },
    })
    validated, err = tree.validate_entries({ call, result, duplicate })
    assert.is_nil(validated)
    assert.matches("duplicate conversation toolCall", err)
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

  it("normalizes internal compaction projections separately", function()
    local source = {
      { role = "user", content = "before", timestamp = 1 },
      { role = "compactionSummary", summary = "checkpoint",
        tokensBefore = 20, timestamp = 2 },
      { role = "user", content = "after", timestamp = 3 },
    }
    local projected = assert(tree.normalize_projection(source))
    assert.are.equal("compactionSummary", projected[2].role)
    projected[2].summary = "changed"
    assert.are.equal("checkpoint", source[2].summary)

    local invalid, err = tree.normalize_projection({ {
      role = "compactionSummary", summary = "checkpoint",
      tokensBefore = math.huge, timestamp = 2,
    } })
    assert.is_nil(invalid)
    assert.matches("tokensBefore", err)
  end)

  it("rejects malformed request, projection, and preparation boundaries", function()
    local invalid_state, state_err = tree.normalize_request_state({ "array" })
    assert.is_nil(invalid_state)
    assert.matches("state must be an object", state_err)

    local invalid_projection, projection_err = tree.normalize_projection({ value = true })
    assert.is_nil(invalid_projection)
    assert.matches("messages must be a list", projection_err)

    local array_summary = setmetatable({ "array" }, {
      __index = { role = "compactionSummary" },
    })
    local role_reads = 0
    local changing_summary = setmetatable({
      summary = "valid",
      tokensBefore = 1,
      timestamp = 1,
    }, {
      __index = function(_, key)
        if key ~= "role" then return nil end
        role_reads = role_reads + 1
        return role_reads == 1 and "compactionSummary" or nil
      end,
    })
    local summaries = {
      array_summary,
      changing_summary,
      { "array" },
      { role = "compactionSummary", summary = "valid", tokensBefore = 1,
        timestamp = 1, unknown = true },
      { role = "user", summary = "valid", tokensBefore = 1, timestamp = 1 },
      { role = "compactionSummary", summary = "", tokensBefore = 1,
        timestamp = 1 },
      { role = "compactionSummary", summary = "valid", tokensBefore = 1,
        timestamp = -1 },
    }
    for _, summary in ipairs(summaries) do
      local normalized, err = tree.normalize_projection_message(summary)
      assert.is_nil(normalized)
      assert.is_string(err)
    end

    local prepared, prepare_err = tree.prepare_entry(false)
    assert.is_nil(prepared)
    assert.matches("options must be an object", prepare_err)
    prepared, prepare_err = tree.prepare_entry({
      type = "leaf", id = "leaf", parent_id = vim.NIL,
      timestamp = "2026-01-01T00:00:00.000Z", payload = { "array" },
    })
    assert.is_nil(prepared)
    assert.matches("payload must be an object", prepare_err)
    assert.are.same({}, tree.entry_messages(base("leaf", { targetId = vim.NIL })))
  end)

  it("rejects Tool results without an ancestor call", function()
    local result = base("message", {
      message = {
        role = "toolResult", toolCallId = "missing", toolName = "read",
        content = {}, timestamp = 1,
      },
    })
    local validated, err = tree.validate_entries({ result })
    assert.is_nil(validated)
    assert.matches("unknown toolCall", err)
  end)
end)
