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
  it("validates every Pi v3 entry shape", function()
    local invalid = {
      base("active_tools_change", { activeToolNames = { 1 } }),
      base("compaction", { summary = "", firstKeptEntryId = "x", tokensBefore = 1 }),
      base("compaction", { summary = "x", firstKeptEntryId = "x", tokensBefore = 1, fromHook = "yes" }),
      base("branch_summary", { fromId = "", summary = "x" }),
      base("branch_summary", { fromId = "x", summary = "x", fromHook = 1 }),
      base("custom_message", { customType = "x", content = "x", display = "yes" }),
      base("label", { targetId = "x", label = 1 }),
      base("session_info", { name = 1 }),
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
    assert.matches("customType", err)
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
    local path
    path, err = tree.path({ message }, "missing")
    assert.is_nil(path)
    assert.matches("entry not found", err)
  end)

  it("projects Pi execution and summary messages into LLM context", function()
    local context = tree.to_llm({
      { role = "bashExecution", command = "pwd", output = "", exitCode = 2, timestamp = 1 },
      { role = "bashExecution", command = "sleep 1", output = "stopped", cancelled = true, timestamp = 2 },
      { role = "bashExecution", command = "secret", output = "hidden", excludeFromContext = true },
      { role = "custom", content = "remember", timestamp = 3 },
      { role = "branchSummary", summary = "branch work", timestamp = 4 },
      { role = "compactionSummary", summary = "old work", timestamp = 5 },
    })
    assert.are.equal(5, #context)
    assert.matches("no output", context[1].content[1].text)
    assert.matches("code 2", context[1].content[1].text)
    assert.matches("cancelled", context[2].content[1].text)
    assert.are.equal("remember", context[3].content[1].text)
    assert.matches("branch work", context[4].content[1].text)
    assert.matches("old work", context[5].content[1].text)
  end)
end)
