local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local fs = require("neoagent.fs")
local tree = require("neoagent.session_tree")

local original_mkdirp = fs.mkdirp
local original_read = fs.read
local original_write_all = fs.write_all
local original_entry_messages = tree.entry_messages
local original_tree_messages = tree.messages

local function tempdir()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return assert(vim.uv.fs_realpath(path))
end

local function index_path(store)
  return fs.join(vim.fs.dirname(vim.fs.dirname(store:metadata().path)),
    "session-index.json")
end

describe("neoagent.storage", function()
  local dirs = {}

  after_each(function()
    fs.mkdirp = original_mkdirp
    fs.read = original_read
    fs.write_all = original_write_all
    tree.entry_messages = original_entry_messages
    tree.messages = original_tree_messages
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

  it("rejects invalid UTF-8 before persisting a Session message", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local session = assert(Session.new({ store = store }))
    local ok, err = session:append({ role = "user", content = "bad\255text" })

    assert.is_nil(ok)
    assert.are.equal("storage", err.kind)
    assert.matches("valid UTF%-8", err.detail)
    assert.are.equal(0, #session:messages())
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
      { lines = {
        vim.json.encode(header),
        vim.json.encode({ type = "message", id = "one", parentId = vim.NIL, timestamp = "t",
          message = { role = "user", content = "one" } }),
        vim.json.encode({
          type = "compaction", id = "compact", parentId = "one", timestamp = "t",
          summary = "bad", firstKeptEntryId = "missing", tokensBefore = 1,
        }),
      }, detail = "first kept entry" },
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

  it("projects Session appends incrementally without Store reloads", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local loads = 0
    local load = store.load
    store.load = function(self)
      loads = loads + 1
      return load(self)
    end
    local session = assert(Session.new({ store = store }))
    fs.write_all = function() return true end

    local append_projections = 0
    tree.entry_messages = function(...)
      append_projections = append_projections + 1
      return original_entry_messages(...)
    end
    local rebuilds = 0
    tree.messages = function(...)
      rebuilds = rebuilds + 1
      return original_tree_messages(...)
    end

    local first
    for index = 1, 100 do
      local ok, _, entry = session:append({
        role = "user", content = "message " .. index, timestamp = index,
      })
      assert(ok)
      first = first or entry
    end

    assert.are.equal(100, append_projections)
    assert.are.equal(0, rebuilds)
    assert.are.equal(1, loads)
    assert.are.equal(100, #session:messages())
    assert(session:move_to(first.id))
    assert.are.equal(1, rebuilds)
    assert.are.equal(1, loads)
    assert.are.equal(1, #session:messages())
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

  it("maintains a minimal workspace session index only for picker text changes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({
      directory = directory,
      cwd = directory,
      parent_session = "/tmp/parent.jsonl",
    })
    assert(store:append({ role = "user", content = "first\nquestion", timestamp = 1 }))
    local path = index_path(store)
    local data = assert(fs.read(path))
    local document = vim.json.decode(data)
    local filename = vim.fs.basename(store:metadata().path)
    assert.are.same({
      version = 1,
      sessions = {
        [filename] = {
          parent_session = "/tmp/parent.jsonl",
          text = "first question",
        },
      },
    }, document)

    local index_writes = 0
    fs.write_all = function(target, ...)
      if target:find("session-index.json", 1, true) then
        index_writes = index_writes + 1
      end
      return original_write_all(target, ...)
    end
    assert(store:append({ role = "assistant", content = "answer", timestamp = 2 }))
    assert(store:append_model_change("openai", "gpt-test"))
    assert.are.equal(0, index_writes)
    assert(store:append_entry("session_info", { name = "  Named\nsession  " }))
    assert.are.equal(1, index_writes)
    fs.write_all = original_write_all

    data = assert(fs.read(path))
    document = vim.json.decode(data)
    assert.are.equal("Named session", document.sessions[filename].text)
    local listed = storage.list_sessions(directory, directory)
    assert.are.equal(1, #listed)
    assert.are.equal(store:metadata().path, listed[1].path)
    assert.are.equal("/tmp/parent.jsonl", listed[1].parent_session)
    assert.are.equal("Named session", listed[1].text)
    assert.is_nil(listed[1].message_count)
    local stat = assert(vim.uv.fs_stat(store:metadata().path))
    assert.are.equal(stat.mtime.sec * 1000
      + math.floor((stat.mtime.nsec or 0) / 1000000), listed[1].modified_at)
  end)

  it("builds and repairs disposable indexes without reopening indexed sessions", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local first = storage.new({ directory = directory, cwd = directory })
    assert(first:append({ role = "user", content = "first" }))
    local second = storage.new({ directory = directory, cwd = directory })
    assert(second:append({ role = "user", content = "second" }))
    local path = index_path(first)
    assert(vim.uv.fs_unlink(path))

    local session_reads = 0
    fs.read = function(target, ...)
      if target:sub(-6) == ".jsonl" then session_reads = session_reads + 1 end
      return original_read(target, ...)
    end
    assert.are.equal(2, #storage.list_sessions(directory, directory))
    assert.are.equal(2, session_reads)
    assert.is_not_nil(vim.uv.fs_stat(path))
    session_reads = 0
    assert.are.equal(2, #storage.list_sessions(directory, directory))
    assert.are.equal(0, session_reads)

    assert(original_write_all(path, "{", "w", 384))
    session_reads = 0
    assert.are.equal(2, #storage.list_sessions(directory, directory))
    assert.are.equal(2, session_reads)
    local repaired_data = assert(original_read(path))
    local repaired = vim.json.decode(repaired_data)
    assert.are.equal(1, repaired.version)
    assert.are.equal("first",
      repaired.sessions[vim.fs.basename(first:metadata().path)].text)
    assert.are.equal("second",
      repaired.sessions[vim.fs.basename(second:metadata().path)].text)
  end)

  it("repairs invalid index entries and removes records for missing sessions", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local first = storage.new({ directory = directory, cwd = directory })
    assert(first:append({ role = "user", content = "first" }))
    local second = storage.new({ directory = directory, cwd = directory })
    assert(second:append({ role = "user", content = "second" }))
    local path = index_path(first)
    local first_name = vim.fs.basename(first:metadata().path)
    local second_name = vim.fs.basename(second:metadata().path)
    assert(original_write_all(path, vim.json.encode({
      version = 1,
      sessions = {
        [first_name] = { text = "" },
        [second_name] = { text = "bad", parent_session = 42 },
        ["missing.jsonl"] = { text = "missing" },
        ["../outside.jsonl"] = { text = "outside" },
        ["wrong.txt"] = { text = "wrong" },
      },
    }), "w", 384))

    local listed = storage.list_sessions(directory, directory)
    assert.are.equal(2, #listed)
    local data = assert(original_read(path))
    local repaired = vim.json.decode(data)
    assert.are.same({
      [first_name] = { text = "first" },
      [second_name] = { text = "second" },
    }, repaired.sessions)
  end)

  it("waits for index writers and recovers abandoned index locks", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local first = storage.new({ directory = directory, cwd = directory })
    local path = index_path(first)
    assert(fs.mkdirp(vim.fs.dirname(path)))
    assert(fs.write_all(path .. ".lock", "active", "wx", 384))
    vim.defer_fn(function() vim.uv.fs_unlink(path .. ".lock") end, 20)
    assert(first:append({ role = "user", content = "waited" }))

    local second = storage.new({ directory = directory, cwd = directory })
    assert(fs.write_all(path .. ".lock", "abandoned", "wx", 384))
    local old = os.time() - 180
    assert(vim.uv.fs_utime(path .. ".lock", old, old))
    assert(second:append({ role = "user", content = "recovered" }))

    assert.is_nil(vim.uv.fs_stat(path .. ".lock"))
    local data = assert(original_read(path))
    local document = vim.json.decode(data)
    local texts = {}
    for _, value in pairs(document.sessions) do texts[#texts + 1] = value.text end
    table.sort(texts)
    assert.are.same({ "recovered", "waited" }, texts)
  end)

  it("serializes session appends with a concurrent writer", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local ok, _, first = store:append({ role = "user", content = "first" })
    assert(ok)
    local path = store:metadata().path
    assert(fs.write_all(path .. ".lock", "held", "wx", 384))
    local external = {
      type = "message",
      id = "external-entry",
      parentId = first.id,
      timestamp = "2020-01-01T00:00:00.000Z",
      message = { role = "assistant", content = "external" },
    }
    local concurrent_done = false
    vim.defer_fn(function()
      assert(fs.write_all(path, vim.json.encode(external) .. "\n", "a", 384))
      assert(vim.uv.fs_unlink(path .. ".lock"))
      concurrent_done = true
    end, 20)

    assert(store:append({ role = "assistant", content = "local" }))
    assert(vim.wait(1000, function() return concurrent_done end))
    local lines = vim.split(assert(fs.read(path)), "\n",
      { plain = true, trimempty = true })
    assert.are.equal("external", vim.json.decode(lines[#lines - 1]).message.content)
    assert.are.equal("local", vim.json.decode(lines[#lines]).message.content)
  end)

  it("keeps session persistence independent from disposable index writes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = index_path(store)
    fs.write_all = function(target, ...)
      if target:find("session-index.json", 1, true) then
        return nil, "index unavailable"
      end
      return original_write_all(target, ...)
    end

    assert(store:append({ role = "user", content = "authoritative" }))
    assert.is_not_nil(vim.uv.fs_stat(store:metadata().path))
    assert.is_nil(vim.uv.fs_stat(path))
    fs.write_all = original_write_all

    local listed = storage.list_sessions(directory, directory)
    assert.are.equal("authoritative", listed[1].text)
    assert.is_not_nil(vim.uv.fs_stat(path))
  end)

  it("merges session index updates from concurrent Neovim processes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local parent = storage.new({ directory = directory, cwd = directory })
    local path = index_path(parent)
    local ready_path = directory .. "/child-ready"
    assert(fs.mkdirp(vim.fs.dirname(path)))
    assert(fs.write_all(path .. ".lock", "held", "wx", 384))

    local script = string.format(
      "local fs=require('neoagent.fs');"
        .. "local s=require('neoagent.storage').new({directory=%q,cwd=%q});"
        .. "vim.defer_fn(function() assert(fs.write_all(%q,'ready','wx')) end,0);"
        .. "assert(s:append({role='user',content='child'}))",
      directory, directory, ready_path)
    local child = vim.system({
      assert(vim.env.NEOAGENT_NVIM), "--headless", "--noplugin", "-u", "tests/minimal_init.lua",
      "-c", "lua " .. script, "-c", "qa",
    }, { text = true, env = { NEOAGENT_COVERAGE = "0" } })
    assert(vim.wait(30000, function()
      return vim.uv.fs_stat(ready_path) ~= nil
    end, 10), "child did not reach index lock contention")
    vim.defer_fn(function() assert(vim.uv.fs_unlink(path .. ".lock")) end, 20)
    assert(parent:append({ role = "user", content = "parent" }))
    local result = child:wait(15000)
    assert.are.equal(0, result.code, vim.inspect(result))

    local data = assert(original_read(path))
    local document = vim.json.decode(data)
    local texts = {}
    for _, value in pairs(document.sessions) do texts[#texts + 1] = value.text end
    table.sort(texts)
    assert.are.same({ "child", "parent" }, texts)
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
