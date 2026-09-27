local assert = require("luassert")
local tree = require("neoagent.session_tree")

---@param entry_type string
---@param values table<string, unknown>
---@return Neoagent.JournalEntryInput
local function base(entry_type, values)
  return vim.tbl_extend("force", {
    type = entry_type,
    id = entry_type,
    parent_id = vim.NIL,
    created_at = 1767225600000,
  }, values)
end

---@param entry_type string
---@param values table<string, unknown>
---@return Neoagent.JournalEntry
local function valid_entry(entry_type, values)
  local value = base(entry_type, values)
  assert(tree.validate_entry(value))
  return value --[[@as Neoagent.JournalEntry]]
end

describe("neoagent.session_tree", function()
  it("projects independent checkpoint candidates from one unchanged source snapshot", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Earlier request" }))
    assert(session:append({ role = "assistant", content = { { type = "text", text = "Earlier answer" } } }))
    local _, _, retained = session:append({ role = "user", content = "Continue" })
    local before = session:entries()
    local path = assert(session:path())
    local project = tree.compaction_projector(path)
    assert(assert(path[3]).message).content = "Changed after snapshot"
    local invalid, err = project({ summary = "", tokens_before = 100 })
    assert.is_nil(invalid)
    assert.are.equal("Invalid compaction", assert(err).message)
    local payload = { summary = "Checkpoint", tokens_before = 100, first_kept_entry_id = assert(retained).id }
    local first = assert(project(payload))
    assert.are.equal("Continue", assert(first[2]).content)
    assert(first[2]).content = "Changed projection"
    assert.are.equal("Continue", assert(assert(project(payload))[2]).content)
    local whole = assert(project({ summary = "Whole context", tokens_before = 100 }))
    assert.are.equal(1, #whole)
    assert.matches("Whole context", require("neoagent.util").text_content(assert(whole[1]).content))
    assert.are.same(before, session:entries())
  end)

  it("validates native checkpoint metadata before projecting or previewing context", function()
    local native = { role = "nativeCompaction", api = "openai-codex-responses", provider = "codex",
      model = "gpt-test", encrypted_content = "synthetic-ciphertext" }
    for _, values in ipairs({
      { native = native, retained_users = {}, tokens_before = -1 },
      { native = { role = "nativeCompaction" }, retained_users = {}, tokens_before = 1 },
      { native = native, first_kept_entry_id = "user", tokens_before = 1 },
    }) do
      local valid, err = tree.validate_entry(base("compaction", values))
      assert.is_false(valid)
      assert.is_string(err)
    end
    for _, values in ipairs({ { tokens_before = -1, created_at = 1 },
      { tokens_before = 1, created_at = -1 } }) do
      local projected, err = tree.normalize_projection({ vim.tbl_extend("force", values,
        { role = "compactionCheckpoint" }) })
      assert.is_nil(projected)
      assert.is_string(err)
    end
    local array = setmetatable({ "array" }, { __index = { role = "compactionCheckpoint" } })
    assert.is_nil((tree.normalize_projection_message(array)))
    local reads = 0
    local changing = setmetatable({ tokens_before = 1, created_at = 1 }, { __index = function(_, key)
      if key ~= "role" then return nil end
      reads = reads + 1
      return reads <= 2 and "compactionCheckpoint" or nil
    end })
    assert.is_nil((tree.normalize_projection_message(changing)))
    assert.has_error(function()
      tree.to_llm({ { role = "compactionCheckpoint", tokens_before = 1, created_at = 1 } })
    end, "Native compaction checkpoint requires its opaque request item")

    local user = valid_entry("message", { id = "compaction-preview", message = { role = "user", content = "History" } })
    local path = { user }
    local projected = assert(tree.preview_compaction(path, { native = native, retained_users = {}, tokens_before = 1 }))
    assert.are.same({ native }, projected)
    assert.are.same({ user }, path)
    local invalid, err = tree.preview_compaction(path, { summary = "", tokens_before = 1 })
    assert.is_nil(invalid)
    assert.are.equal("Invalid compaction", assert(err).message)
    local orphan = valid_entry("message", { id = "orphan", message = { role = "toolResult",
      toolCallId = "missing", content = {} } })
    invalid, err = tree.preview_compaction({ user, orphan }, {
      summary = "Summary", first_kept_entry_id = "orphan", tokens_before = 1,
    })
    assert.is_nil(invalid)
    assert.are.equal("Invalid compacted context", assert(err).message)
  end)

  it("assembles entries without exposing journal-owned fields", function()
    for _, entry_type in ipairs({ "message", "compaction", "leaf" }) do
      for _, field in ipairs({ "type", "id", "parent_id", "created_at" }) do
        local payload = { [field] = "forged" }
        local entry, err = tree.prepare_entry({
          type = entry_type,
          id = "owned-id",
          parent_id = vim.NIL,
          created_at = 1767225600000,
          payload = payload,
          by_id = {},
        })
        assert.is_nil(entry)
        assert.matches("protected field " .. field, (assert(err)))
      end
    end

    local payload = { message = { role = "user", content = "owned" } }
    local entry = assert(tree.prepare_entry({
      type = "message",
      id = "owned-id",
      parent_id = vim.NIL,
      created_at = 1767225600000,
      payload = payload,
      by_id = {},
    }))
    payload.message.content = "changed"
    assert.are.equal("owned-id", entry.id)
    assert.are.equal("owned", assert(entry.message).content)
  end)

  it("requires finite UTC milliseconds and preserves them in model context", function()
    for _, created_at in ipairs({ "2026-01-01T00:00:00Z", -1, 0.5, math.huge, false, {} }) do
      local entry = base("compaction", {
        created_at = created_at, summary = "Earlier work", tokens_before = 12,
        first_kept_entry_id = "user",
      })
      local valid, err = tree.validate_entry(entry)
      assert.is_false(valid)
      assert.matches("created_at", (assert(err)))
    end
    for _, created_at in ipairs({ 0, 951782400123, 1767225600123 }) do
      local entry = valid_entry("compaction", {
        created_at = created_at, summary = "Earlier work", tokens_before = 12,
        first_kept_entry_id = "user",
      })
      local messages = tree.to_llm(tree.entry_messages(entry))
      assert.are.equal(created_at, assert(messages[1]).timestamp)
      assert.same(messages, assert(require("neoagent.semantic_message").normalize_list(messages)))
    end
  end)

  it("validates every current entry shape", function()
    local scalar_ok, scalar_err = tree.validate_entry(false)
    assert.is_false(scalar_ok)
    assert.matches("entry must be an object", assert(scalar_err))
    local missing_id = base("message", { message = { role = "user", content = "x" } })
    missing_id.id = ""
    scalar_ok, scalar_err = tree.validate_entry(missing_id)
    assert.is_false(scalar_ok)
    assert.matches("entry id is required", assert(scalar_err))
    local invalid = {
      base("message", { parent_id = {}, message = { role = "user", content = "x" } }),
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
        request = { thinking_level = "" },
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
      base("thinking_level_change", { thinking_level = "high" }),
      base("compaction", { summary = "", first_kept_entry_id = "x", tokens_before = 1 }),
      base("leaf", { target_id = 1 }),
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
    assert.matches("unsupported entry type", (assert(err)))
  end)

  it("rejects malformed tree relationships", function()
    local message = base("message", { message = { role = "user", content = "one" } })
    local duplicate = vim.deepcopy(message)
    duplicate.parent_id = message.id
    local validated, err, index = tree.validate_entries({ message, duplicate })
    assert.is_nil(validated)
    assert.matches("duplicate", (assert(err)))
    assert.are.equal(2, index)

    duplicate.id = "child"
    duplicate.parent_id = "missing"
    validated, err = tree.validate_entries({ message, duplicate })
    assert.is_nil(validated)
    assert.matches("does not precede", (assert(err)))

    local leaf = base("leaf", { id = "leaf", parent_id = message.id, target_id = "missing" })
    validated, err = tree.validate_entries({ message, leaf })
    assert.is_nil(validated)
    assert.matches("leaf target", (assert(err)))

    local compaction = base("compaction", {
      id = "compaction", parent_id = message.id,
      first_kept_entry_id = "missing", summary = "bad", tokens_before = 1,
    })
    validated, err = tree.validate_entries({ message, compaction })
    assert.is_nil(validated)
    assert.matches("first kept", (assert(err)))

    local left = base("message", {
      id = "left", parent_id = message.id,
      message = { role = "assistant", content = {} },
    })
    local right = base("message", {
      id = "right", parent_id = message.id,
      message = { role = "assistant", content = {} },
    })
    compaction.parent_id = right.id
    compaction.first_kept_entry_id = left.id
    validated, err = tree.validate_entries({ message, left, right, compaction })
    assert.is_nil(validated)
    assert.matches("active path", (assert(err)))

    local path
    path, err = tree.path({ message --[[@as Neoagent.JournalEntry]] }, "missing")
    assert.is_nil(path)
    assert.matches("entry not found", (assert(err)))
  end)

  it("validates Tool linkage on each journal branch", function()
    local call = base("message", {
      id = "call", message = { role = "assistant", content = { {
        type = "toolCall", id = "tool-1", name = "read", arguments = {},
      } }, timestamp = 1 },
    })
    local result = base("message", {
      id = "result", parent_id = call.id,
      message = { role = "toolResult", toolCallId = "tool-1",
        toolName = "read", content = {}, timestamp = 2 },
    })
    assert(tree.validate_entries({ call, result }))

    local mismatched = vim.deepcopy(result)
    assert(type(mismatched.message) == "table")
    mismatched.message.toolName = "write"
    local validated, err = tree.validate_entries({ call, mismatched })
    assert.is_nil(validated)
    assert.matches("does not match", (assert(err)))

    local duplicate = base("message", {
      id = "duplicate", parent_id = result.id,
      message = { role = "assistant", content = { {
        type = "toolCall", id = "tool-1", name = "read", arguments = {},
      } }, timestamp = 3 },
    })
    validated, err = tree.validate_entries({ call, result, duplicate })
    assert.is_nil(validated)
    assert.matches("duplicate conversation toolCall", (assert(err)))
  end)

  it("builds copied paths from validated entries and maintained indexes", function()
    local first = valid_entry("message", {
      id = "first", message = { role = "user", content = "one" },
    })
    local second = valid_entry("message", {
      id = "second", parent_id = first.id, message = { role = "assistant", content = {} },
    })
    local validated = assert(tree.validate_entries({ first, second }))

    local path = assert(tree.path({ first, second }))
    local indexed = assert(tree.indexed_path(validated.by_id, second.id))
    assert.are.same({ "first", "second" }, vim.tbl_map(function(entry) return entry.id end, path))
    assert.are.same(path, indexed)
    assert(assert(indexed[1]).message).content = "changed"
    assert.are.equal("one", assert(first.message).content)
    assert.are.same({}, assert(tree.indexed_path(validated.by_id, vim.NIL)))
    assert.are.same({}, assert(tree.indexed_path(validated.by_id, nil)))
    local missing, err = tree.indexed_path(validated.by_id, "missing")
    assert.is_nil(missing)
    assert.matches("entry not found", (assert(err)))
  end)

  it("orders compacted model context and transcripts identically", function()
    local prefix = valid_entry("message", {
      id = "prefix", message = { role = "user", content = "old" },
    })
    local kept = valid_entry("message", {
      id = "kept", parent_id = prefix.id,
      message = { role = "assistant", content = {} },
    })
    local compaction = valid_entry("compaction", {
      id = "compaction", parent_id = kept.id, first_kept_entry_id = kept.id,
      summary = "summary", tokens_before = 100,
    })
    local after = valid_entry("message", {
      id = "after", parent_id = compaction.id,
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

  it("keeps native checkpoint history visible without retaining it in requests", function()
    local user = valid_entry("message", { id = "user", message = { role = "user", content = "question" } })
    local answer = valid_entry("message", { id = "answer", parent_id = user.id,
      message = { role = "assistant", content = { { type = "text", text = "completed answer" } } } })
    local checkpoint = valid_entry("compaction", { id = "checkpoint", parent_id = answer.id,
      native = { role = "nativeCompaction", api = "openai-codex-responses", provider = "codex",
        model = "test", encrypted_content = "opaque" },
      retained_users = { { entry_id = user.id, text_chars = 3 } }, tokens_before = 100 })
    local path = { user, answer, checkpoint }
    local ids = function(entries)
      return vim.tbl_map(function(entry) return entry.id end, entries)
    end
    assert.are.same({ "user", "checkpoint" }, ids(tree.context_entries(path)))
    assert.are.same({ "user", "answer", "checkpoint" }, ids(tree.transcript_entries(path)))
    assert.are.equal("question", assert(assert(tree.transcript_entries(path)[1]).message).content)
  end)

  it("projects compaction summaries into LLM context", function()
    local context = tree.to_llm({
      { role = "compactionSummary", summary = "old work", tokens_before = 0, created_at = 5 },
    })
    assert.are.equal(1, #context)
    assert.matches("old work", (assert(assert(assert(context[1]).content[1]).text)))
  end)

  it("normalizes internal compaction projections separately", function()
    local source = {
      { role = "user", content = "before", timestamp = 1 },
      { role = "compactionSummary", summary = "checkpoint",
        tokens_before = 20, created_at = 2 },
      { role = "compactionCheckpoint", tokens_before = 30, created_at = 3 },
      { role = "user", content = "after", timestamp = 3 },
    }
    local projected = assert(tree.normalize_projection(source))
    assert.are.equal("compactionSummary", assert(projected[2]).role)
    assert.are.equal("compactionCheckpoint", assert(projected[3]).role)
    assert(projected[2]).summary = "changed"
    assert.are.equal("checkpoint", source[2].summary)

    local invalid, err = tree.normalize_projection({ {
      role = "compactionSummary", summary = "checkpoint",
      tokens_before = math.huge, created_at = 2,
    } })
    assert.is_nil(invalid)
    assert.matches("tokens_before", (assert(err)))
    invalid, err = tree.normalize_projection({ {
      role = "compactionCheckpoint", summary = "fabricated", tokens_before = 30, created_at = 3,
    } })
    assert.is_nil(invalid)
    assert.matches("unsupported field", assert(err))
  end)

  it("rejects malformed request, projection, and preparation boundaries", function()
    local invalid_state, state_err = tree.normalize_request_state({ "array" })
    assert.is_nil(invalid_state)
    assert.matches("state must be an object", (assert(state_err)))

    local invalid_projection, projection_err = tree.normalize_projection({ value = true })
    assert.is_nil(invalid_projection)
    assert.matches("messages must be a list", (assert(projection_err)))
    invalid_projection, projection_err = tree.normalize_projection({
      { role = "user" },
      { role = "compactionSummary", summary = "checkpoint",
        tokens_before = 1, created_at = 1 },
    })
    assert.is_nil(invalid_projection)
    assert.matches("message content is required", assert(projection_err))

    local array_summary = setmetatable({ "array" }, {
      __index = { role = "compactionSummary" },
    })
    local role_reads = 0
    local changing_summary = setmetatable({
      summary = "valid",
      tokens_before = 1,
      created_at = 1,
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
      { role = "compactionSummary", summary = "valid", tokens_before = 1,
        created_at = 1, unknown = true },
      { role = "user", summary = "valid", tokens_before = 1, timestamp = 1 },
      { role = "compactionSummary", summary = "", tokens_before = 1,
        created_at = 1 },
      { role = "compactionSummary", summary = "valid", tokens_before = 1,
        created_at = -1 },
    }
    for _, summary in ipairs(summaries) do
      local normalized, err = tree.normalize_projection_message(summary)
      assert.is_nil(normalized)
      assert.is_string(err)
    end

    local prepared, prepare_err = tree.prepare_entry(false --[[@as Neoagent.EntryPreparation]])
    assert.is_nil(prepared)
    assert.matches("options must be an object", (assert(prepare_err)))
    prepared, prepare_err = tree.prepare_entry({
      type = "leaf", id = "leaf", parent_id = vim.NIL,
      created_at = 1767225600000, payload = { "array" },
    })
    assert.is_nil(prepared)
    assert.matches("payload must be an object", (assert(prepare_err)))
    prepared, prepare_err = tree.prepare_entry({
      type = "leaf", id = "leaf", parent_id = vim.NIL,
      created_at = 1767225600000,
    })
    assert(prepared, prepare_err)
    prepared, prepare_err = tree.prepare_entry(({
      type = "leaf", id = "leaf", parent_id = vim.NIL,
      created_at = 1767225600000, payload = {}, by_id = false,
    }) --[[@as Neoagent.EntryPreparation]])
    assert.is_nil(prepared)
    assert.matches("entry index must be a table", assert(prepare_err))
    local invalid_path, path_err, path_index = tree.path({ false --[[@as Neoagent.JournalEntry]] })
    assert.is_nil(invalid_path)
    assert.matches("entry must be an object", assert(path_err))
    assert.are.equal(1, path_index)
    assert.are.same({}, tree.entry_messages(valid_entry("leaf", { target_id = vim.NIL })))
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
    assert.matches("unknown toolCall", (assert(err)))
  end)
end)
