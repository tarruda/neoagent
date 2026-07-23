local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local fs = require("neoagent.fs")

local original_mkdirp = fs.mkdirp
local original_write_all = fs.write_all

local function tempdir()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return path
end

describe("neoagent.storage", function()
  local dirs = {}

  after_each(function()
    fs.mkdirp = original_mkdirp
    fs.write_all = original_write_all
    for _, path in ipairs(dirs) do
      vim.fn.delete(path, "rf")
    end
    dirs = {}
  end)

  it("creates no file until the first message", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = store:metadata().path
    local workspace_directory = directory .. "/" .. vim.fn.sha256(vim.uv.fs_realpath(directory))
    assert.are.equal(workspace_directory .. "/sessions", vim.fs.dirname(path))
    assert.is_nil(vim.uv.fs_stat(path))
    local session = assert(Session.new({ store = store }))
    assert.is_nil(vim.uv.fs_stat(path))
    assert(store:append_model_change("openai", "gpt-test"))
    assert(store:append_thinking_level_change("high"))
    assert.are.same({ model = { provider = "openai", model = "gpt-test" }, thinking_level = "high" },
      store:state())
    assert.is_nil(vim.uv.fs_stat(workspace_directory))
    assert(session:append({ role = "user", content = "hello", timestamp = 1 }))
    assert.is_not_nil(vim.uv.fs_stat(path))
    local lines = vim.fn.readfile(path)
    assert.are.equal("model_change", vim.json.decode(lines[2]).type)
    assert.are.equal("thinking_level_change", vim.json.decode(lines[3]).type)
    assert.are.equal("message", vim.json.decode(lines[4]).type)
    local reopened = assert(storage.open(path))
    assert.are.same(store:state(), reopened:state())
    assert.are.equal("hello", reopened:load()[1].content)
  end)

  it("writes and resumes a Pi v3 JSONL session", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local cwd = vim.uv.fs_realpath(directory)
    local store = storage.new({ directory = directory, cwd = cwd })
    assert(store:append({ role = "user", content = "one", timestamp = 1 }))
    assert(store:append({ role = "assistant", content = { { type = "text", text = "two" } }, timestamp = 2 }))
    local data = assert(require("neoagent.fs").read(store:metadata().path))
    local lines = vim.split(data, "\n", { plain = true, trimempty = true })
    local header = vim.json.decode(lines[1])
    local first = vim.json.decode(lines[2])
    local second = vim.json.decode(lines[3])
    assert.are.equal("session", header.type)
    assert.are.equal(3, header.version)
    assert.are.equal(cwd, header.cwd)
    assert.are.equal(vim.NIL, first.parentId)
    assert.are.equal(first.id, second.parentId)

    local reopened = assert(storage.open(store:metadata().path))
    assert.are.equal(2, #reopened:load())
    assert.are.equal(store:metadata().id, reopened:metadata().id)
    assert.are.same({ store:metadata().path }, storage.list(directory, cwd))
  end)

  it("loads Pi branches and follows the persisted active leaf", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local path = directory .. "/tree.jsonl"
    local header = vim.json.encode({ type = "session", version = 3, id = "s", timestamp = "t", cwd = directory })
    local first = vim.json.encode({
      type = "message", id = "one", parentId = vim.NIL, timestamp = "t",
      message = { role = "user", content = "one" },
    })
    local left = vim.json.encode({
      type = "message", id = "left", parentId = "one", timestamp = "t",
      message = { role = "assistant", content = { { type = "text", text = "left" } } },
    })
    local right = vim.json.encode({
      type = "message", id = "right", parentId = "one", timestamp = "t",
      message = { role = "assistant", content = { { type = "text", text = "right" } } },
    })
    local leaf = vim.json.encode({
      type = "leaf", id = "move", parentId = "right", timestamp = "t", targetId = "left",
    })
    vim.fn.writefile({ "", header, first, left, right, leaf, "" }, path, "b")
    local store = assert(storage.open(path))
    assert.are.equal("left", store:leaf_id())
    assert.are.same({ "one", "left" }, vim.tbl_map(function(message)
      return type(message.content) == "string" and message.content or message.content[1].text
    end, store:load()))
    assert(store:set_leaf("right"))
    local ok, _, appended = store:append({ role = "user", content = "continued" })
    assert(ok)
    assert.are.equal("right", appended.parentId)
  end)

  it("rejects invalid messages before creating a session file", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local cases = {
      { value = "text", message = "object" },
      { value = { role = "", content = "x" }, message = "role" },
      { value = { role = "user" }, message = "content" },
    }
    for _, case in ipairs(cases) do
      local ok, err = store:append(case.value)
      assert.is_nil(ok)
      assert.matches(case.message, err.detail)
    end
    local ok, err = store:append_model_change("", "model")
    assert.is_nil(ok)
    assert.matches("provider", err.detail)
    ok, err = store:append_thinking_level_change(42)
    assert.is_nil(ok)
    assert.matches("thinkingLevel", err.detail)
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))
  end)

  it("reports malformed headers, entries, and messages precisely", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    assert.are.same({}, storage.list(directory, directory .. "/missing"))
    local missing, missing_err = storage.open(directory .. "/missing.jsonl")
    assert.is_nil(missing)
    assert.matches("Failed to read", missing_err.message)

    local path = directory .. "/bad.jsonl"
    local header = { type = "session", version = 3, id = "session", timestamp = "time", cwd = directory }
    local cases = {
      { lines = { "42" }, detail = "expected object" },
      { lines = { "{" }, detail = ".+" },
      { lines = { vim.json.encode({ type = "session", version = 2 }) }, detail = "expected pi session" },
      { lines = { vim.json.encode(vim.tbl_extend("force", header, { parentSession = 42 })) },
        detail = "parentSession must be a string" },
      { lines = { vim.json.encode({
        type = "session", version = 3, id = "session", timestamp = "time", cwd = directory, metadata = { 1 },
      }) }, detail = "metadata must be an object" },
      { lines = { vim.json.encode(header), vim.json.encode({ type = "other", id = "one" }) }, detail = "unsupported entry type" },
      { lines = {
        vim.json.encode(header),
        vim.json.encode({ type = "message", id = "one", parentId = vim.NIL, timestamp = "t",
          message = { role = "user", content = "one" } }),
        vim.json.encode({ type = "message", id = "one", parentId = "one", timestamp = "t",
          message = { role = "user", content = "two" } }),
      }, detail = "duplicate entry id" },
      { lines = {
        vim.json.encode(header),
        vim.json.encode({ type = "message", id = "one", parentId = vim.NIL, timestamp = "t",
          message = { role = "user" } }),
      }, detail = "content is required" },
    }
    for _, case in ipairs(cases) do
      vim.fn.writefile(case.lines, path)
      local opened, err = storage.open(path)
      assert.is_nil(opened)
      assert.matches(case.detail, tostring(err.detail))
    end
  end)

  it("preserves in-memory state when session writes fail", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })

    fs.mkdirp = function() return nil, "permission denied" end
    local ok, err = store:append({ role = "user", content = "first" })
    assert.is_nil(ok)
    assert.matches("create session directory", err.message)
    assert.are.equal(0, #store:entries())

    fs.mkdirp = original_mkdirp
    fs.write_all = function() return nil, "disk full" end
    ok, err = store:append({ role = "user", content = "first" })
    assert.is_nil(ok)
    assert.matches("create session file", err.message)
    assert.are.equal(0, #store:entries())

    fs.write_all = original_write_all
    assert(store:append({ role = "user", content = "first" }))
    fs.write_all = function() return nil, "disk full" end
    ok, err = store:append({ role = "assistant", content = {} })
    assert.is_nil(ok)
    assert.matches("append session entry", err.message)
    assert.are.equal(1, #store:entries())
  end)

  it("round-trips every Pi v3 entry type and projects compacted context", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({
      directory = directory,
      cwd = directory,
      parent_session = "/tmp/parent.jsonl",
      metadata = { owner = "test" },
    })
    assert(store:append_model_change("openai", "gpt-test"))
    assert(store:append_thinking_level_change("high"))
    assert(store:append_active_tools_change({ "read_file" }))
    local ok, _, first = store:append({ role = "user", content = "old" })
    assert(ok)
    assert(store:append_entry("custom", { customType = "checkpoint", data = { value = 1 } }))
    assert(store:append_entry("custom_message", {
      customType = "notice", content = "custom context", display = true, details = { value = 2 },
    }))
    assert(store:append_entry("label", { targetId = first.id, label = "start" }))
    assert(store:append_entry("session_info", { name = "Named session" }))
    assert(store:append_entry("branch_summary", {
      fromId = first.id, summary = "Returned branch", usage = { totalTokens = 2 }, fromHook = false,
    }))
    assert(store:append_entry("compaction", {
      summary = "Old work", firstKeptEntryId = first.id, tokensBefore = 100,
      details = { readFiles = { "README.md" } }, usage = { totalTokens = 3 }, fromHook = false,
    }))

    local reopened = assert(storage.open(store:metadata().path))
    assert.are.equal("/tmp/parent.jsonl", reopened:metadata().parent_session)
    assert.are.same({ owner = "test" }, reopened:metadata().data)
    assert.are.equal(10, #reopened:entries())
    assert.are.same({
      model = { provider = "openai", model = "gpt-test" },
      thinking_level = "high",
      active_tools = { "read_file" },
    }, reopened:state())
    local context = assert(reopened:context_messages())
    assert.matches("Old work", context[1].content[1].text)
    assert.are.equal("old", context[2].content)
    assert.are.equal("custom context", context[3].content[1].text)
    assert.matches("Returned branch", context[4].content[1].text)
    assert.are.equal(1, #reopened:find_entries("label"))
    assert.are.equal("start", reopened:label(first.id))
    assert.are.equal("Named session", reopened:name())
    assert.are.same({
      path = reopened:metadata().path,
      id = reopened:metadata().id,
      cwd = directory,
      name = "Named session",
      parent_session = "/tmp/parent.jsonl",
      created_at = reopened:metadata().timestamp,
      modified_at = reopened:info().modified_at,
      message_count = 1,
      first_message = "old",
    }, reopened:info())
    assert(reopened:append_entry("session_info", { name = "" }))
    assert.is_nil(reopened:name())
    assert.is_nil(reopened:info().name)

    vim.fn.writefile({ "invalid" }, vim.fs.dirname(reopened:metadata().path) .. "/invalid.jsonl")
    local listed = storage.list_sessions(directory, directory)
    assert.are.equal(1, #listed)
    assert.are.equal(reopened:metadata().path, listed[1].path)
  end)

  it("validates tree entry references before persistence", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local ok, err = store:set_leaf("missing")
    assert.is_nil(ok)
    assert.matches("entry not found", err.detail)
    ok, err = store:append_entry("leaf", { targetId = "missing" })
    assert.is_nil(ok)
    assert.matches("target does not exist", err.detail)
    ok, err = store:append_entry("label", { targetId = "missing", label = "bad" })
    assert.is_nil(ok)
    assert.matches("target does not exist", err.detail)
    ok, err = store:append_entry("compaction", {
      summary = "bad", firstKeptEntryId = "missing", tokensBefore = 1,
    })
    assert.is_nil(ok)
    assert.matches("first kept entry", err.detail)
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))
    local forked, fork_err = storage.fork(store, { directory = directory })
    assert.is_nil(forked)
    assert.matches("not persisted", fork_err.detail)
  end)

  it("encodes empty Pi header metadata as an object", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory, metadata = {} })
    assert(store:append({ role = "user", content = "metadata" }))
    local header = vim.fn.readfile(store:metadata().path)[1]
    assert.matches('"metadata":{}', header)
    assert.are.same({}, assert(storage.open(store:metadata().path)):metadata().data)
  end)

  it("forks a Pi session at an entry into a linked child file", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local source = storage.new({ directory = directory, cwd = directory })
    local _, _, first = source:append({ role = "user", content = "first" })
    local _, _, answer = source:append({ role = "assistant", content = {} })
    local _, _, second = source:append({ role = "user", content = "second" })
    assert(source:append({ role = "assistant", content = {} }))

    local before = assert(storage.fork(source, {
      directory = directory, entry_id = second.id, position = "before",
    }))
    assert.are.equal(source:metadata().path, before:metadata().parent_session)
    assert.are.same({ "first", "assistant" }, vim.tbl_map(function(message)
      return message.role == "user" and message.content or message.role
    end, before:load()))
    assert.are.equal(answer.id, before:leaf_id())

    local at = assert(storage.fork(source:metadata().path, {
      directory = directory, entry_id = second.id, position = "at",
    }))
    assert.are.equal("second", at:load()[3].content)
    local missing, err = storage.fork(source, { directory = directory, entry_id = "missing" })
    assert.is_nil(missing)
    assert.matches("entry not found", err.detail)
    local invalid
    invalid, err = storage.fork(source, { directory = directory, entry_id = answer.id, position = "before" })
    assert.is_nil(invalid)
    assert.matches("requires a user message", err.detail)
    invalid, err = storage.fork(source, { directory = directory, entry_id = second.id, position = "sideways" })
    assert.is_nil(invalid)
    assert.matches("before or at", err.detail)
    invalid, err = storage.fork({}, { directory = directory })
    assert.is_nil(invalid)
    assert.matches("source store", err.detail)

    local full = assert(storage.fork(source, { directory = directory, metadata = { fork = true } }))
    assert.are.equal(#source:entries(), #full:entries())
    assert.are.same({ fork = true }, full:metadata().data)
    assert.is_not_nil(first.id)
  end)
end)
