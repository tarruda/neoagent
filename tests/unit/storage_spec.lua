local it = require("tests.helpers.async_test")
local assert = require("luassert")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local fs = require("neoagent.fs")
local file_lock = require("neoagent.file_lock")
local tree = require("neoagent.session_tree")

local original_mkdirp = fs.mkdirp
local original_read = fs.read
local original_write_all = fs.write_all
local original_atomic_replace = fs.atomic_replace
local original_sync_directory = fs.sync_directory
local original_truncate = fs.truncate
local original_open_regular = fs.open_regular
local original_file_lock_new = file_lock.new
local original_entry_messages = tree.entry_messages
local original_tree_messages = tree.messages
local original_indexed_path = tree.indexed_path
local original_uv_open = vim.uv.fs_open
local original_uv_write = vim.uv.fs_write
local original_uv_read = vim.uv.fs_read
local original_uv_close = vim.uv.fs_close
local original_rename = vim.uv.fs_rename
local original_json_encode = vim.json.encode

---@return string
local function tempdir()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return (assert(vim.uv.fs_realpath(path)))
end

---@param path string
---@return Neoagent.SessionStore?, Neoagent.Error?
---@return_overload Neoagent.SessionStore
---@return_overload nil, Neoagent.Error
local function open_session(path)
  return storage.open(path, require("neoagent.workspace_storage").new(
    assert(vim.fs.dirname(vim.fs.dirname(path)))))
end

---@param directory string
---@param name string
---@return string
local function document_path(directory, name)
  local settings = require("neoagent.workspace_settings").new({ directory = directory, root = directory })
  local workspace = require("neoagent.workspace_storage").new(settings.directory)
  assert(workspace.prepare())
  assert(fs.mkdirp(workspace.sessions_directory))
  return fs.join(workspace.sessions_directory, name)
end

---@param store Neoagent.SessionStore
---@return string
local function index_path(store)
  return fs.join(vim.fs.dirname(vim.fs.dirname(store:metadata().path)),
    "session-index.json")
end

---@param callback fun(file: Neoagent.RegularFile, path: string)
local function intercept_regular(callback)
  ---@param path string
  ---@param opts? { mode?: integer, identity?: Neoagent.FileIdentity }
  fs.open_regular = function(path, opts)
    local file, err, code = original_open_regular(path, opts)
    if file then callback(file, path) end
    return file, err, code
  end
end

describe("neoagent.storage", function()
  ---@type string[]
  local dirs = {}

  after_each(function()
    fs.mkdirp = original_mkdirp
    fs.read = original_read
    fs.write_all = original_write_all
    fs.atomic_replace = original_atomic_replace
    fs.sync_directory = original_sync_directory
    fs.truncate = original_truncate
    fs.open_regular = original_open_regular
    file_lock.new = original_file_lock_new
    tree.entry_messages = original_entry_messages
    tree.messages = original_tree_messages
    tree.indexed_path = original_indexed_path
    vim.uv.fs_open = original_uv_open
    vim.uv.fs_write = original_uv_write
    vim.uv.fs_read = original_uv_read
    vim.uv.fs_close = original_uv_close
    vim.uv.fs_rename = original_rename
    vim.json.encode = original_json_encode
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
    local root = assert(vim.uv.fs_realpath(directory))
    local workspace_directory = directory .. "/" .. vim.fs.basename(root)
      .. "-" .. vim.fn.sha256(root)
    assert.are.equal(workspace_directory .. "/sessions", vim.fs.dirname(path))
    assert.is_nil(vim.uv.fs_stat(path))
    local session = assert(Session.new({ store = store }))
    assert.is_nil(vim.uv.fs_stat(path))
    assert.is_nil(vim.uv.fs_stat(workspace_directory))
    ---@type string?
    local temporary
    ---@param target string
    ---@param flags uv.fs_open.flags
    ---@param mode integer
    vim.uv.fs_open = function(target, flags, mode)
      if target:find(".jsonl.", 1, true)
          and target:sub(-4) == ".tmp" then
        temporary = target
        local published = target:match("^(.*%.jsonl)%.%x+%.tmp$")
        assert.is_not_nil(published)
        assert.is_nil(vim.uv.fs_stat((assert(published))))
      end
      return original_uv_open(target, flags, mode)
    end
    assert(session:append({ role = "user", content = "hello", timestamp = 1 }, {
      model = { provider = "openai", model = "gpt-test" },
      thinking_level = "high",
    }))
    vim.uv.fs_open = original_uv_open
    assert.is_not_nil(temporary)
    assert.is_nil(vim.uv.fs_stat((assert(temporary))))
    assert.is_not_nil(vim.uv.fs_stat(path))
    local lines = vim.fn.readfile(path)
    local accepted = vim.json.decode((assert(lines[2])))
    assert.are.equal("message", accepted.type)
    assert.are.same({
      model = { provider = "openai", model = "gpt-test" },
      thinking_level = "high",
    }, accepted.request)
    assert.are.equal(2, #lines)
    local reopened = assert(open_session(path))
    assert.are.same(store:state(), reopened:state())
    assert.are.equal("hello", assert(reopened:load()[1]).content)
  end)

  it("persists pending in-memory journal entries with the first message", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local moved, _, leaf, projection = store:set_leaf(nil)
    assert.is_true(moved)
    assert.are.equal("leaf", assert(leaf).type)
    assert.are.same({ type = "replace", messages = {} }, projection)
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))

    assert(store:append({ role = "user", content = "first" }))
    local reopened = assert(open_session(store:metadata().path))
    assert.are.equal(2, #reopened:entries())
    assert.are.equal("leaf", assert(reopened:entries()[1]).type)
    assert.are.equal("first", assert(reopened:load()[1]).content)
  end)

  it("reopens and forks a session with no active leaf", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "one" }))
    assert(store:set_leaf(nil))
    assert.is_nil(store:leaf_id())
    local reopened = assert(open_session(store:metadata().path))
    assert.is_nil(reopened:leaf_id())
    local forked = assert(storage.fork(reopened, { directory = directory }))
    assert.is_nil(forked:leaf_id())
    assert.are.same({}, assert(forked:context_messages()))
    assert(forked:append({ role = "user", content = "new branch" }))
    assert.are.equal(1, #forked:load())
    assert.are.equal("new branch", assert(forked:load()[1]).content)
  end)

  it("opens journals with blank lines without changing embedded whitespace", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local message = { role = "user", content = "  synthetic content\n\twith whitespace  " }
    assert(store:append(message))
    local path = store:metadata().path
    local document = assert(fs.read(path))
    assert(fs.atomic_replace(path, " \t\r\n" .. document:gsub("\n", "\n\t \r\n"), { mode = 384 }))
    local reopened = assert(open_session(path))
    assert.are.same({ message }, reopened:load())
    assert.are.equal(" \t\r\n" .. document:gsub("\n", "\n\t \r\n"), fs.read(path))
  end)

  it("journals the selected model atomically with each message", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first", timestamp = 1 }, {
      model = { provider = "openai", model = "gpt-test" },
      thinking_level = "low",
    }))
    local path = store:metadata().path
    local reopened = assert(open_session(path))
    assert.are.same({ provider = "openai", model = "gpt-test" },
      reopened:state().model)
    assert.are.equal("low", reopened:state().thinking_level)

    intercept_regular(function(file, target)
      if target == path then
        file.append = function() return nil, "blocked append" end
      end
    end)
    local ok, err = store:append({
      role = "user", content = "not committed", timestamp = 2,
    }, {
      model = { provider = "openai", model = "gpt-next" },
      thinking_level = "high",
    })
    assert.is_nil(ok)
    assert.matches("blocked append", tostring(assert(err).detail))
    reopened = assert(open_session(path))
    assert.are.equal(1, #reopened:load())
    assert.are.same({ provider = "openai", model = "gpt-test" },
      reopened:state().model)
    assert.are.equal("low", reopened:state().thinking_level)

    fs.open_regular = original_open_regular
    assert(store:append({ role = "user", content = "second", timestamp = 3 }, {
      model = { provider = "openai", model = "gpt-next" },
      thinking_level = "high",
    }))
    reopened = assert(open_session(path))
    assert.are.equal(2, #reopened:load())
    assert.are.same({ provider = "openai", model = "gpt-next" },
      reopened:state().model)
    assert.are.equal("high", reopened:state().thinking_level)

    assert(store:append({ role = "user", content = "plain", timestamp = 4 }, {
      model = { provider = "openai", model = "plain" },
      thinking_level = vim.NIL,
    }))
    reopened = assert(open_session(path))
    assert.is_nil(reopened:state().thinking_level)
    assert.are.equal(vim.NIL,
      assert(assert(reopened:entries()[3]).request).thinking_level)
    assert.matches('"thinking_level":null', assert(fs.read(path)))
  end)

  it("writes and resumes the current JSONL session", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local cwd = assert(vim.uv.fs_realpath(directory))
    local store = storage.new({ directory = directory, cwd = cwd })
    assert(store:append({ role = "user", content = "one", timestamp = 1 }))
    assert(store:append({ role = "assistant", content = { { type = "text", text = "two" } }, timestamp = 2 }))
    local data = assert(require("neoagent.fs").read(store:metadata().path))
    local lines = vim.split(data, "\n", { plain = true, trimempty = true })
    local header = vim.json.decode((assert(lines[1])))
    local first = vim.json.decode((assert(lines[2])))
    local second = vim.json.decode((assert(lines[3])))
    assert.are.equal("session", header.type)
    assert.are.equal("neoagent-session", header.format)
    assert.are.equal(cwd, header.cwd)
    assert.are.equal(vim.NIL, assert(first).parent_id)
    assert.are.equal(assert(first).id, assert(second).parent_id)

    local reopened = assert(open_session(store:metadata().path))
    assert.are.equal(2, #reopened:load())
    assert.are.equal(store:metadata().id, reopened:metadata().id)
    assert.are.same({ store:metadata().path }, storage.list(directory, cwd))
  end)

  it("loads branches and follows the persisted active leaf", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local path = document_path(directory, "tree.jsonl")
    local header = vim.json.encode({ type = "session", format = "neoagent-session", id = "s", created_at = 1767225600000, cwd = directory })
    local first = vim.json.encode({
      type = "message", id = "one", parent_id = vim.NIL, created_at = 1767225600000,
      message = { role = "user", content = "one" },
    })
    local left = vim.json.encode({
      type = "message", id = "left", parent_id = "one", created_at = 1767225600000,
      message = { role = "assistant", content = { { type = "text", text = "left" } } },
    })
    local right = vim.json.encode({
      type = "message", id = "right", parent_id = "one", created_at = 1767225600000,
      message = { role = "assistant", content = { { type = "text", text = "right" } } },
    })
    local leaf = vim.json.encode({
      type = "leaf", id = "move", parent_id = "right", created_at = 1767225600000, target_id = "left",
    })
    vim.fn.writefile({ "", header, first, left, right, leaf, "" }, path, "b")
    local store = assert(open_session(path))
    assert.are.equal("left", store:leaf_id())
    assert.are.same({ "one", "left" }, vim.tbl_map(function(message)
      return require("neoagent.util").text_content(message.content)
    end, store:load()))
    assert(store:set_leaf("right"))
    local ok, _, appended = store:append({ role = "user", content = "continued" })
    assert(ok)
    assert.are.equal("right", assert(appended).parent_id)
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
      local ok, err = store:append(case.value --[[@as Neoagent.Message]])
      assert.is_nil(ok)
      assert.matches(case.message, tostring(assert(err).detail))
    end
    local ok, err = store:append({ role = "user", content = "x" }, {
      model = { provider = "", model = "model" },
    })
    assert.is_nil(ok)
    assert.matches("provider", tostring(assert(err).detail))
    ok, err = store:append({ role = "user", content = "x" }, {
      thinking_level = 42,
    })
    assert.is_nil(ok)
    assert.matches("thinking_level", tostring(assert(err).detail))
    ok, err = store:append({ role = "user", content = "x" }, {
      unknown = true,
    })
    assert.is_nil(ok)
    assert.matches("unsupported message state field", tostring(assert(err).detail))
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))
  end)

  it("rejects duplicate generated entry ids", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local random = vim.uv.random
    vim.uv.random = function() return string.rep("x", 8) end
    local call_ok, append_ok, append_err = pcall(function()
      assert(store:append({ role = "user", content = "first" }))
      return store:append({ role = "user", content = "second" })
    end)
    vim.uv.random = random

    assert(call_ok, append_ok)
    assert.is_nil(append_ok)
    assert.matches("duplicate entry id", tostring(assert(append_err).detail))
  end)

  it("rejects invalid UTF-8 before persisting a Session message", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local session = assert(Session.new({ store = store }))
    local ok, err = session:append({ role = "user", content = "bad\255text" })

    assert.is_nil(ok)
    assert.are.equal("session", assert(err).kind)
    assert.matches("valid UTF%-8", tostring(assert(err).detail))
    assert.are.equal(0, #session:messages())
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))
  end)

  it("rejects unsafe derived journal ids without throwing", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local derived, err = storage.derive({
      entries = {
        {
          type = "message",
          id = "invalid\255id",
          parent_id = vim.NIL,
          created_at = 1767225600000,
          message = { role = "user", content = "valid" },
        },
      },
      leaf_id = "invalid\255id",
    }, {
      directory = directory,
      cwd = directory,
    })

    assert.is_nil(derived)
    assert.are.equal("storage", assert(err).kind)
    assert.matches("entry id", tostring(assert(err).detail))
    assert.are.same({}, storage.list_sessions(directory, directory))
  end)

  it("reports malformed headers, entries, and messages precisely", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    assert.are.same({}, storage.list(directory, directory .. "/missing"))
    local missing, missing_err = open_session(document_path(directory, "missing.jsonl"))
    assert.is_nil(missing)
    assert.matches("Failed to read", assert(missing_err).message)

    local path = document_path(directory, "bad.jsonl")
    local header = { type = "session", format = "neoagent-session", id = "session", created_at = 1767225600000, cwd = directory }
    local cases = {
      { lines = { "42" }, detail = "expected object" },
      { lines = { "{" }, detail = ".+" },
      { lines = { vim.json.encode({ type = "session", version = 2 }) },
        detail = "expected neoagent%-session header" },
      { lines = { vim.json.encode(vim.tbl_extend("force", header, { parent_session = 42 })) },
        detail = "parent_session must be a string" },
      { lines = { vim.json.encode(vim.tbl_extend("force", header, {
        unknown = true,
      })) }, detail = "unsupported session header field" },
      { lines = { vim.json.encode({
        type = "session", format = "neoagent-session", id = "session", created_at = 1767225600000, cwd = directory, metadata = { 1 },
      }) }, detail = "metadata must be an object" },
      { lines = { vim.json.encode(header), vim.json.encode({ type = "other", id = "one" }) }, detail = "unsupported entry type" },
      { lines = {
        vim.json.encode(header),
        vim.json.encode({ type = "message", id = "one", parent_id = vim.NIL, created_at = 1767225600000,
          message = { role = "user", content = "one" } }),
        vim.json.encode({ type = "message", id = "one", parent_id = "one", created_at = 1767225600000,
          message = { role = "user", content = "two" } }),
      }, detail = "duplicate entry id" },
      { lines = {
        vim.json.encode(header),
        vim.json.encode({ type = "message", id = "one", parent_id = vim.NIL, created_at = 1767225600000,
          message = { role = "user" } }),
      }, detail = "content is required" },
      { lines = {
        vim.json.encode(header),
        vim.json.encode({ type = "message", id = "one", parent_id = vim.NIL, created_at = 1767225600000,
          message = { role = "user", content = "one" } }),
        vim.json.encode({
          type = "compaction", id = "compact", parent_id = "one", created_at = 1767225600000,
          summary = "bad", first_kept_entry_id = "missing", tokens_before = 1,
        }),
      }, detail = "first kept entry" },
    }
    for _, case in ipairs(cases) do
      vim.fn.writefile(case.lines, path)
      local opened, err = open_session(path)
      assert.is_nil(opened)
      assert.matches(case.detail, tostring(tostring(assert(err).detail)))
    end
  end)

  it("preserves in-memory state when session writes fail", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:workspace_storage().prepare())

    fs.mkdirp = function() return nil, "permission denied" end
    local ok, err = store:append({ role = "user", content = "first" })
    assert.is_nil(ok)
    assert.matches("create session directory", assert(err).message)
    assert.are.equal(0, #store:entries())

    fs.mkdirp = original_mkdirp
    vim.uv.fs_write = function() return nil, "disk full" end
    ok, err = store:append({ role = "user", content = "first" })
    assert.is_nil(ok)
    assert.matches("create session file", assert(err).message)
    assert.are.equal(0, #store:entries())

    vim.uv.fs_write = original_uv_write
    assert(store:append({ role = "user", content = "first" }))
    intercept_regular(function(file)
      file.append = function() return nil, "disk full" end
    end)
    ok, err = store:append({ role = "assistant", content = {} })
    assert.is_nil(ok)
    assert.matches("append session entry", assert(err).message)
    assert.are.equal(1, #store:entries())
  end)

  it("reports Workspace and directory publication failures before commitment", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local blocked = storage.new({ directory = directory, cwd = directory })
    assert(original_write_all(blocked:workspace_storage().directory, "occupied"))
    local ok, err = blocked:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.matches("not a directory", assert(err).message)
    assert.are.same({}, blocked:entries())

    local published_directory = tempdir()
    dirs[#dirs + 1] = published_directory
    local published = storage.new({
      directory = published_directory,
      cwd = published_directory,
    })
    assert(published:workspace_storage().prepare())
    fs.sync_directory = function(target)
      if target == published:workspace_storage().directory then
        return nil, "session directory sync failed"
      end
      return original_sync_directory(target)
    end
    ok, err = published:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.matches("publish session directory", assert(err).message)
    assert.are.same({}, published:entries())
  end)

  it("binds first persistence to the atomic replacement identity", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = store:metadata().path
    local detached = path .. ".created"
    local successor = "successor must remain unchanged"
    ---@param target string
    ---@param data string
    ---@param policy Neoagent.AtomicPolicy
    fs.atomic_replace = function(target, data, policy)
      local ok, result, stage = original_atomic_replace(target, data, policy)
      if ok and target == path then
        assert(vim.uv.fs_rename(path, detached))
        assert(original_write_all(path, successor, "wx", 384))
      end
      return ok, result, stage
    end

    assert(store:append({ role = "user", content = "first" }))
    fs.atomic_replace = original_atomic_replace

    assert.are.equal(1, #store:entries())
    local ok, err = store:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.matches("unusable", assert(err).message)
    assert.are.equal(successor, assert(original_read(path)))
    assert.matches('"content":"first"', assert(original_read(detached)))
  end)

  it("commits and poisons an unconfirmed first persistence", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = store:metadata().path
    local session = assert(Session.new({ store = store }))
    ---@param target string
    ---@param opts? { mode?: integer, identity?: Neoagent.FileIdentity }
    fs.open_regular = function(target, opts)
      if target == path then return nil, "inspection failed", "open" end
      return original_open_regular(target, opts)
    end

    assert(session:append({ role = "user", content = "committed" }))
    fs.open_regular = original_open_regular

    assert.are.equal(1, #store:entries())
    assert.are.equal("committed", assert(session:messages()[1]).content)
    local before = assert(original_read(path))
    local ok, err = session:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.matches("unusable", assert(err).message)
    assert.are.equal(before, assert(original_read(path)))
    assert.matches('"content":"committed"', before)
  end)

  it("commits and poisons when creation handle close is unconfirmed", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = store:metadata().path
    intercept_regular(function(file, target)
      if target ~= path then return end
      local close = file.close
      function file:close()
        assert(close(self))
        return nil, "close confirmation failed", "close"
      end
    end)

    assert(store:append({ role = "user", content = "committed" }))
    fs.open_regular = original_open_regular

    assert.are.equal(1, #store:entries())
    local before = assert(original_read(path))
    local ok, err = store:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.matches("unusable", assert(err).message)
    assert.matches("close confirmation failed", tostring(assert(err).detail))
    assert.are.equal(before, assert(original_read(path)))
  end)

  it("rolls back every failed subsequent append before releasing its lock", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first", timestamp = 1 }, {
      model = { provider = "openai", model = "gpt-test" },
      thinking_level = "low",
    }))
    local path = store:metadata().path

    ---@alias Neoagent.TestFileAppend fun(self: Neoagent.RegularFile, data: string, offset: integer): true?, string?, Neoagent.FileFailureStage?
    ---@class Neoagent.TestAppendFailure
    ---@field pattern string
    ---@field write fun(file: Neoagent.RegularFile, append: Neoagent.TestFileAppend, data: string, offset: integer): nil, string?
    ---@type Neoagent.TestAppendFailure[]
    local failures = {
      {
        pattern = "partial append",
        write = function(file, append, data, offset)
          assert(append(file,
            data:sub(1, math.max(1, math.floor(#data / 2))), offset))
          return nil, "partial append"
        end,
      },
      {
        pattern = "close failed",
        write = function(file, append, data, offset)
          assert(append(file, data, offset))
          return nil, "close failed"
        end,
      },
      {
        pattern = "append crashed",
        write = function(file, append, data, offset)
          assert(append(file, data:sub(1, 1), offset))
          error("append crashed")
        end,
      },
    }
    for index, failure in ipairs(failures) do
      local before = assert(original_read(path))
      local entry_count = #store:entries()
      intercept_regular(function(file, target)
        if target ~= path then return end
        local append = file.append
        function file:append(data, offset)
          return failure.write(self, append, data, offset)
        end
      end)

      local ok, err = store:append({
        role = "user", content = "failed " .. index, timestamp = index + 1,
      }, {
        model = { provider = "openai", model = "gpt-" .. index },
        thinking_level = "high",
      })
      fs.open_regular = original_open_regular

      assert.is_nil(ok)
      assert.matches(failure.pattern, tostring(assert(err).detail))
      assert.are.equal(before, assert(original_read(path)))
      assert.are.equal(entry_count, #store:entries())
      assert(store:append({
        role = "assistant",
        content = { { type = "text", text = "recovered " .. index } },
        timestamp = index + 10,
      }))
    end

    local reopened = assert(open_session(path))
    assert.are.same(store:entries(), reopened:entries())
    assert.are.same(store:state(), reopened:state())
  end)

  it("rolls back a replaced Session through its original handle", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first" }))
    local path = store:metadata().path
    local detached = path .. ".detached"
    local before = assert(original_read(path))
    local successor = "successor must remain unchanged"

    intercept_regular(function(file, target)
      if target ~= path then return end
      local append = file.append
      function file:append(data, offset)
        assert(append(self, data:sub(1, 1), offset))
        assert(vim.uv.fs_rename(path, detached))
        assert(original_write_all(path, successor, "wx", 384))
        return nil, "append failed after replacement"
      end
    end)

    local ok, err = store:append({ role = "user", content = "failed" })
    fs.open_regular = original_open_regular

    assert.is_nil(ok)
    assert.matches("unusable", assert(err).message)
    assert.are.equal(successor, assert(original_read(path)))
    assert.are.equal(before, assert(original_read(detached)))
    assert.are.equal(1, #store:entries())
  end)

  it("poisons a Store when append rollback cannot be confirmed", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first" }))
    local path = store:metadata().path
    local append_attempts = 0
    intercept_regular(function(file, target)
      if target == path then
        local append = file.append
        function file:append(data, offset)
          append_attempts = append_attempts + 1
          assert(append(self, data:sub(1, 1), offset))
          return nil, "append failed"
        end
        function file:truncate(size)
          assert.is_number(size)
          return nil, "truncate failed"
        end
      end
    end)

    local ok, err = store:append({
      role = "assistant", content = { { type = "text", text = "lost" } },
    })
    assert.is_nil(ok)
    assert.matches("unusable", assert(err).message)
    assert.matches("append failed", tostring(assert(err).detail))
    assert.matches("truncate failed", tostring(assert(err).detail))
    assert.are.equal(1, append_attempts)
    local poisoned = vim.deepcopy((assert(err)))

    fs.open_regular = original_open_regular
    ok, err = store:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.are.same(poisoned, err)
    local moved, move_err = store:set_leaf("missing")
    assert.is_nil(moved)
    assert.are.same(poisoned, move_err)
    assert.are.equal(1, append_attempts)
    assert.are.equal(1, #store:entries())
  end)

  it("poisons a Store when a rolled-back append cannot be flushed", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first" }))
    local path = store:metadata().path
    intercept_regular(function(file, target)
      if target ~= path then return end
      file.append = function() return nil, "append failed" end
      file.sync = function() return nil, "rollback sync failed" end
    end)

    local ok, err = store:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.matches("unusable", assert(err).message)
    assert.matches("flush failed: rollback sync failed",
      tostring(assert(err).detail))
    assert.are.equal(1, #store:entries())
  end)

  it("poisons a Store when post-truncate size confirmation fails", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first" }))
    local path = store:metadata().path
    local before = assert(original_read(path))
    intercept_regular(function(file, target)
      if target ~= path then return end
      local append = file.append
      function file:append(data, offset)
        assert(append(self, data:sub(1, 1), offset))
        return nil, "append failed"
      end
      local truncate = file.truncate
      function file:truncate(size)
        assert(truncate(self, size))
        return nil, "post-truncate stat failed"
      end
    end)

    local ok, err = store:append({ role = "user", content = "failed" })

    assert.is_nil(ok)
    assert.matches("unusable", assert(err).message)
    assert.matches("post%-truncate stat failed", tostring(assert(err).detail))
    assert.are.equal(before, assert(original_read(path)))
    assert.are.equal(1, #store:entries())
  end)

  it("commits once and poisons after append lock release failure", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first" }))
    local path = store:metadata().path
    local release_error = {
      kind = "file_lock", code = "ownership", message = "release failed",
      detail = "lock ownership was lost",
    }
    file_lock.new = function()
      return {
        acquire = function()
          return { release = function() return nil, release_error end }
        end,
        ---@param _ Neoagent.FileLock
        ---@param callback fun(): unknown
        with = function(_, callback)
          assert(callback())
          return nil, release_error
        end,
      }
    end

    assert(store:append({ role = "assistant",
      content = { { type = "text", text = "committed" } } }))
    assert.are.equal(2, #store:entries())
    local ok, err = store:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.matches("unusable", assert(err).message)
    assert.matches("lock ownership was lost", tostring(assert(err).detail))

    file_lock.new = original_file_lock_new
    local reopened = assert(open_session(path))
    assert.are.equal(2, #reopened:entries())
    assert.are.equal("committed", require("neoagent.util").text_content(assert(reopened:load()[2]).content))
  end)

  it("poisons after rollback succeeds but lock release fails", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first" }))
    local path = store:metadata().path
    local before = assert(original_read(path))
    intercept_regular(function(file, target)
      if target == path then
        local append = file.append
        function file:append(data, offset)
          assert(append(self, data:sub(1, 1), offset))
          return nil, "append failed"
        end
      end
    end)
    local release_error = {
      kind = "file_lock", code = "ownership", message = "release failed",
      detail = "lock ownership was lost",
    }
    file_lock.new = function()
      return {
        acquire = function()
          return { release = function() return nil, release_error end }
        end,
        ---@param _ Neoagent.FileLock
        ---@param callback fun(): unknown
        with = function(_, callback)
          callback()
          return nil, release_error
        end,
      }
    end

    local ok, err = store:append({ role = "user", content = "failed" })
    assert.is_nil(ok)
    assert.matches("unusable", assert(err).message)
    assert.matches("lock ownership was lost", tostring(assert(err).detail))
    assert.are.equal(before, assert(original_read(path)))
    assert.are.equal(1, #store:entries())
  end)

  it("recovers an incomplete final JSONL record while opening", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "complete" }))
    local path = store:metadata().path
    local complete = assert(original_read(path))
    assert(original_write_all(path, '{"type":"message"', "a", 384))

    local reopened = assert(open_session(path))

    assert.are.equal(complete, assert(original_read(path)))
    assert.are.equal("complete", assert(reopened:load()[1]).content)
    assert.are.equal(1, #reopened:entries())

    local incomplete_header = document_path(directory, "incomplete-header.jsonl")
    assert(original_write_all(incomplete_header, vim.json.encode({
      type = "session", format = "neoagent-session", id = "incomplete", created_at = 1767225600000,
      cwd = directory,
    }), "w", 384))
    local missing, err = open_session(incomplete_header)
    assert.is_nil(missing)
    assert.matches("no complete JSONL record", tostring(assert(err).detail))

    local unrecoverable = document_path(directory, "unrecoverable.jsonl")
    assert(original_write_all(unrecoverable,
      complete .. '{"type":"message"', "w", 384))
    intercept_regular(function(file, target)
      if target == unrecoverable then
        file.truncate = function() return nil, "truncate denied" end
      end
    end)
    missing, err = open_session(unrecoverable)
    fs.open_regular = original_open_regular
    assert.is_nil(missing)
    assert.matches("failed to recover incomplete final record", tostring(assert(err).detail))
    assert.matches("truncate denied", tostring(assert(err).detail))
  end)

  it("rejects invalid session prefixes without truncating their final bytes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "complete" }))
    local complete = assert(original_read(store:metadata().path))
    for index, prefix in ipairs({
      '{"type":"foreign-document"}\n',
      complete .. '{broken-json}\n',
      complete .. vim.json.encode({ type = "message", id = "invalid-entry" }) .. "\n",
    }) do
      local path = document_path(directory, "invalid-" .. index .. ".jsonl")
      local contents = prefix .. "valuable unterminated data"
      assert(original_write_all(path, contents, "w", 384))

      local reopened, err = open_session(path)

      assert.is_nil(reopened)
      assert.matches("Invalid session", assert(err).message)
      assert.are.equal(contents, assert(original_read(path)))
    end
  end)

  it("closes a recovery handle when projection throws before truncation", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "complete" }))
    local path = store:metadata().path
    local contents = assert(original_read(path)) .. '{"unfinished":'
    assert(original_write_all(path, contents, "w", 384))
    local closed = 0
    intercept_regular(function(file, target)
      if target ~= path then return end
      local close = file.close
      function file:close()
        closed = closed + 1
        return close(self)
      end
    end)
    tree.indexed_path = function() error("projection failed") end

    local reopened, err = open_session(path)

    assert.is_nil(reopened)
    assert.matches("Failed to decode session", assert(err).message)
    assert.matches("projection failed", tostring(assert(err).detail))
    assert.are.equal(1, closed)
    assert.are.equal(contents, assert(original_read(path)))
  end)

  it("preserves file-lock diagnostics for append and open failures", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first" }))
    local path = store:metadata().path
    file_lock.new = function()
      local err = {
        kind = "file_lock",
        message = "lock failed",
        detail = "lock ownership was lost",
      }
      return {
        acquire = function() return nil, err end,
        with = function()
          return nil, err
        end,
      }
    end

    local appended, append_err = store:append({
      role = "assistant", content = { { type = "text", text = "second" } },
    })
    assert.is_nil(appended)
    assert.are.equal("lock ownership was lost", tostring(assert(append_err).detail))
    local opened, open_err = open_session(path)
    assert.is_nil(opened)
    assert.are.equal("lock ownership was lost", tostring(assert(open_err).detail))
  end)

  it("reports projection failures through Store path APIs", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "message" }))
    tree.indexed_path = function() return nil, "projection unavailable" end

    local path, path_err = store:path()
    assert.is_nil(path)
    assert.matches("Failed to build session path", assert(path_err).message)
    local context, context_err = store:context_messages()
    assert.is_nil(context)
    assert.matches("Failed to build session context", assert(context_err).message)
    assert.matches("projection unavailable", vim.inspect(context_err))
  end)

  it("projects Session appends incrementally without Store reloads", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local loads = 0
    local load = store.load
    function store:load()
      loads = loads + 1
      return load(self)
    end
    local session = assert(Session.new({ store = store }))
    local append_projections = 0
    tree.entry_messages = function(entry)
      append_projections = append_projections + 1
      return original_entry_messages(entry)
    end
    local rebuilds = 0
    tree.messages = function(entries, context_only)
      rebuilds = rebuilds + 1
      return original_tree_messages(entries, context_only)
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
    assert(session:move_to(assert(first).id))
    assert.are.equal(1, rebuilds)
    assert.are.equal(1, loads)
    assert.are.equal(1, #session:messages())
  end)

  it("round-trips current entries and projects compacted context", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({
      directory = directory,
      cwd = directory,
      parent_session = "/tmp/parent.jsonl",
      index_attributes = { profileId = "neo" },
      metadata = { owner = "test" },
    })
    local ok, _, first = store:append({ role = "user", content = "old" }, {
      model = { provider = "openai", model = "gpt-test" },
      thinking_level = "high",
    })
    assert(ok)
    assert(store:append_compaction({
      summary = "Old work", first_kept_entry_id = assert(first).id, tokens_before = 100,
    }))

    local reopened = assert(open_session(store:metadata().path))
    assert.are.equal("/tmp/parent.jsonl", reopened:metadata().parent_session)
    assert.are.same({ owner = "test" }, reopened:metadata().data)
    assert.are.equal(2, #reopened:entries())
    assert.are.same({
      model = { provider = "openai", model = "gpt-test" },
      thinking_level = "high",
    }, reopened:state())
    local context = assert(reopened:context_messages())
    assert.matches("Old work", require("neoagent.util").text_content(assert(context[1]).content))
    assert.are.equal("old", assert(context[2]).content)
    assert.are.same({
      path = reopened:metadata().path,
      id = reopened:metadata().id,
      cwd = directory,
      parent_session = "/tmp/parent.jsonl",
      created_at = reopened:metadata().created_at,
      modified_at = reopened:info().modified_at,
      message_count = 1,
      first_message = "old",
    }, reopened:info())
    vim.fn.writefile({ "invalid" }, vim.fs.dirname(reopened:metadata().path) .. "/invalid.jsonl")
    local listed = storage.list_sessions(directory, directory)
    assert.are.equal(1, #listed)
    assert.are.equal(reopened:metadata().path, assert(listed[1]).path)
  end)

  it("maintains a minimal workspace session index from the first message", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({
      directory = directory,
      cwd = directory,
      parent_session = "/tmp/parent.jsonl",
      index_attributes = { profileId = "neo" },
    })
    assert(store:append({ role = "user", content = "first\nquestion", timestamp = 1 }))
    local path = index_path(store)
    local data = assert(fs.read(path))
    local document = vim.json.decode(data)
    local filename = vim.fs.basename(store:metadata().path)
    assert.are.same({
      format = "neoagent-session-index",
      sessions = {
        [filename] = {
          id = store:metadata().id,
          attributes = { profileId = "neo" },
          parent_session = "/tmp/parent.jsonl",
          text = "first question",
        },
      },
    }, document)

    local index_writes = 0
    ---@param target string
    ---@param data string
    ---@param policy Neoagent.AtomicPolicy
    fs.atomic_replace = function(target, data, policy)
      if target:find("session-index.json", 1, true) then
        index_writes = index_writes + 1
      end
      return original_atomic_replace(target, data, policy)
    end
    assert(store:append({ role = "assistant",
      content = { { type = "text", text = "answer" } }, timestamp = 2 }))
    assert.are.equal(0, index_writes)
    fs.atomic_replace = original_atomic_replace

    data = assert(fs.read(path))
    document = vim.json.decode(data)
    assert.are.equal("first question", document.sessions[filename].text)
    local reopened = assert(open_session(store:metadata().path))
    assert.are.same({ profileId = "neo" },
      document.sessions[filename].attributes)
    local listed = storage.list_sessions(directory, directory)
    assert.are.equal(1, #listed)
    assert.are.equal(store:metadata().path, assert(listed[1]).path)
    assert.are.equal("/tmp/parent.jsonl", assert(listed[1]).parent_session)
    assert.are.same({ profileId = "neo" }, assert(listed[1]).attributes)
    assert.are.equal("first question", assert(listed[1]).text)
    assert.is_nil(rawget(assert(listed[1]), "message_count"))
    local stat = assert(vim.uv.fs_stat(store:metadata().path))
    assert.are.equal(stat.mtime.sec * 1000
      + math.floor((stat.mtime.nsec or 0) / 1000000), assert(listed[1]).modified_at)
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
    intercept_regular(function(_, target)
      if target:sub(-6) == ".jsonl" then session_reads = session_reads + 1 end
    end)
    assert.are.equal(2, #storage.list_sessions(directory, directory))
    assert.are.equal(2, session_reads)
    assert.is_not_nil(vim.uv.fs_stat(path))
    session_reads = 0
    assert.are.equal(2, #storage.list_sessions(directory, directory))
    assert.are.equal(0, session_reads)

    local projected = storage.list_sessions(directory, directory, {
      index_attributes = function()
        return { "invalid-list-projection" } --[[@as Neoagent.JsonObject]]
      end,
    })
    assert.are.equal(2, #projected)
    assert.are.same({}, assert(projected[1]).attributes)
    assert.are.same({}, assert(projected[2]).attributes)

    assert(original_write_all(path, "{", "w", 384))
    session_reads = 0
    assert.are.equal(2, #storage.list_sessions(directory, directory))
    assert.are.equal(2, session_reads)
    local repaired_data = assert(original_read(path))
    local repaired = vim.json.decode(repaired_data)
    assert.are.equal("neoagent-session-index", repaired.format)
    assert.are.equal("first",
      repaired.sessions[vim.fs.basename(first:metadata().path)].text)
    assert.are.equal("second",
      repaired.sessions[vim.fs.basename(second:metadata().path)].text)
  end)

  it("rebuilds unreadable indexes and ignores index observer exceptions", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local first = storage.new({ directory = directory, cwd = directory })
    assert(first:append({ role = "user", content = "first" }))
    local path = index_path(first)
    fs.read = function(target)
      if target == path then return nil, "index read failed" end
      return original_read(target)
    end
    local listed = storage.list_sessions(directory, directory)
    fs.read = original_read
    assert.are.equal("first", assert(listed[1]).text)

    local second = storage.new({ directory = directory, cwd = directory })
    file_lock.new = function(options)
      if options.path == path .. ".lock" then
        error("index lock construction failed")
      end
      return original_file_lock_new(options)
    end
    assert(second:append({ role = "user", content = "second" }))
    assert.is_not_nil(vim.uv.fs_stat(second:metadata().path))
  end)

  it("indexes and orders empty Sessions with identical modification times", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local first = assert(storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory, cwd = directory,
    }))
    local second = assert(storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory, cwd = directory,
    }))
    local timestamp = 1767225600
    assert(vim.uv.fs_utime(first:metadata().path, timestamp, timestamp))
    assert(vim.uv.fs_utime(second:metadata().path, timestamp, timestamp))
    assert(vim.uv.fs_unlink(index_path(first)))

    local listed = storage.list_sessions(directory, directory)
    assert.are.equal(2, #listed)
    assert.are.equal("(no messages)", assert(listed[1]).text)
    assert.are.equal("(no messages)", assert(listed[2]).text)
    assert.is_true(assert(listed[1]).path > assert(listed[2]).path)
  end)

  it("uses the empty-session label for user messages without visible text", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = " \n\t " }))

    local listed = storage.list_sessions(directory, directory)
    assert.are.equal(1, #listed)
    assert.are.equal("(no messages)", assert(listed[1]).text)
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
    for _, invalid in ipairs({ { parent_session = 42 }, { attributes = { "array" } }, { attributes = false } }) do
      local entry = vim.tbl_extend("force", { id = second:metadata().id, text = "bad" }, invalid)
      assert(original_write_all(path, vim.json.encode({
        format = "neoagent-session-index",
        sessions = {
          [first_name] = { text = "" },
          [second_name] = entry,
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
        [first_name] = { id = first:metadata().id, text = "first" },
        [second_name] = { id = second:metadata().id, text = "second" },
      }, repaired.sessions)
    end
  end)

  it("waits for index writers and accepts unowned stable lock files", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local first = storage.new({ directory = directory, cwd = directory })
    local path = index_path(first)
    assert(first:workspace_storage().prepare())
    assert(fs.mkdirp(vim.fs.dirname(path)))
    local holder = assert(require("neoagent.file_lock").new({
      path = path .. ".lock",
    }):acquire())
    vim.defer_fn(function() assert(holder:release()) end, 20)
    assert(first:append({ role = "user", content = "waited" }))

    local second = storage.new({ directory = directory, cwd = directory })
    assert(second:append({ role = "user", content = "recovered" }))

    assert.is_not_nil(vim.uv.fs_stat(path .. ".lock"))
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
    local holder = assert(require("neoagent.file_lock").new({
      path = path .. ".lock",
    }):acquire())
    local external = {
      type = "message",
      id = "external-entry",
      parent_id = assert(first).id,
      created_at = 1577836800000,
      message = { role = "assistant",
        content = { { type = "text", text = "external" } } },
    }
    local concurrent_done = false
    vim.defer_fn(function()
      assert(fs.write_all(path, vim.json.encode(external) .. "\n", "a", 384))
      assert(holder:release())
      concurrent_done = true
    end, 20)

    assert(store:append({ role = "assistant",
      content = { { type = "text", text = "local" } } }))
    assert(vim.wait(1000, function() return concurrent_done end))
    local lines = vim.split(assert(fs.read(path)), "\n",
      { plain = true, trimempty = true })
    assert.are.equal("external",
      vim.json.decode((assert(lines[#lines - 1]))).message.content[1].text)
    assert.are.equal("local",
      vim.json.decode((assert(lines[#lines]))).message.content[1].text)
  end)

  it("keeps session persistence independent from disposable index writes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = index_path(store)
    ---@param target string
    ---@param flags uv.fs_open.flags
    ---@param mode integer
    vim.uv.fs_open = function(target, flags, mode)
      if target:find("session-index.json", 1, true) then
        return nil, "index unavailable"
      end
      return original_uv_open(target, flags, mode)
    end

    assert(store:append({ role = "user", content = "authoritative" }))
    assert.is_not_nil(vim.uv.fs_stat(store:metadata().path))
    assert.is_nil(vim.uv.fs_stat(path))
    vim.uv.fs_open = original_uv_open

    local listed = storage.list_sessions(directory, directory)
    assert.are.equal("authoritative", assert(listed[1]).text)
    assert.is_not_nil(vim.uv.fs_stat(path))
  end)

  it("rejects malformed index projections and cleans failed atomic writes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:workspace_storage().prepare())
    local path = index_path(store)
    assert(fs.mkdirp(vim.fs.dirname(path)))
    assert(fs.write_all(path, vim.json.encode({
      format = "neoagent-session-index",
      sessions = {
        ["value.jsonl"] = false,
        ["parent.jsonl"] = { text = "parent", parent_session = 42 },
        ["attributes.jsonl"] = { text = "attributes", attributes = { "x" } },
      },
    })))
    assert.are.same({}, storage.list_sessions(directory, directory))

    ---@type string?
    local temporary
    ---@param target string
    ---@param flags uv.fs_open.flags
    ---@param mode integer
    vim.uv.fs_open = function(target, flags, mode)
      if target:sub(-4) == ".tmp" then temporary = target end
      return original_uv_open(target, flags, mode)
    end
    vim.uv.fs_rename = function() return nil, "rename unavailable" end
    local ok, err = store:append({ role = "user", content = "atomic" })
    assert.is_nil(ok)
    assert.matches("rename unavailable", tostring(assert(err).detail))
    assert.is_not_nil(temporary)
    assert.is_nil(vim.uv.fs_stat((assert(temporary))))
  end)

  it("merges session index updates from concurrent Neovim processes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local parent = storage.new({ directory = directory, cwd = directory })
    local path = index_path(parent)
    local ready_path = directory .. "/child-ready"
    assert(parent:workspace_storage().prepare())
    assert(fs.mkdirp(vim.fs.dirname(path)))
    local holder = assert(require("neoagent.file_lock").new({
      path = path .. ".lock",
    }):acquire())

    local script = string.format(
      "local fs=require('neoagent.fs');"
        .. "local s=require('neoagent.storage').new({directory=%q,cwd=%q});"
        .. "vim.defer_fn(function() assert(fs.write_all(%q,'ready','wx')) end,0);"
        .. "assert(s:append({role='user',content='child'}))",
      directory, directory, ready_path)
    local child = vim.system({
      assert(vim.env.NEOAGENT_NVIM), "--headless", "--noplugin", "-u", "tests/minimal_init.lua",
      "-c", "lua " .. script, "-c", "qa",
    }, { text = true })
    assert(vim.wait(30000, function()
      return vim.uv.fs_stat(ready_path) ~= nil
    end, 10), "child did not reach index lock contention")
    vim.defer_fn(function() assert(holder:release()) end, 20)
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
    assert.matches("entry not found", tostring(assert(err).detail))
    ok, err = store:append_compaction({
      summary = "bad", first_kept_entry_id = "missing", tokens_before = 1,
    })
    assert.is_nil(ok)
    assert.matches("first kept entry", tostring(assert(err).detail))
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))
    local forked, fork_err = storage.fork(store, { directory = directory })
    assert.is_nil(forked)
    assert.matches("not persisted", tostring(assert(fork_err).detail))
  end)

  it("encodes empty session header metadata as an object", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory, metadata = {} })
    assert(store:append({ role = "user", content = "metadata" }))
    local header = vim.fn.readfile(store:metadata().path)[1]
    assert.matches('"metadata":{}', header)
    assert.are.same({}, assert(open_session(store:metadata().path)):metadata().data)
  end)

  it("forks a session at an entry into a linked child file", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local source = storage.new({ directory = directory, cwd = directory })
    local _, _, first = source:append({ role = "user", content = "first" }, {
      model = { provider = "fake", model = "reasoning" },
      thinking_level = "high",
    })
    local _, _, answer = source:append({ role = "assistant", content = {} })
    local _, _, second = source:append({ role = "user", content = "second" }, {
      model = { provider = "fake", model = "plain" },
      thinking_level = vim.NIL,
    })
    assert(source:append({ role = "assistant", content = {} }))

    local before = assert(storage.fork(source, {
      directory = directory, entry_id = assert(second).id, position = "before",
    }))
    assert.are.equal(source:metadata().id, before:metadata().parent_session)
    assert.are.same({ "first", "assistant" }, vim.tbl_map(function(message)
      return message.role == "user" and message.content or message.role
    end, before:load()))
    assert.are.equal(assert(answer).id, before:leaf_id())
    assert.are.equal("high", before:state().thinking_level)

    local at = assert(storage.fork(source, {
      directory = directory, entry_id = assert(second).id, position = "at",
    }))
    assert.are.equal("second", assert(at:load()[3]).content)
    assert.is_nil(at:state().thinking_level)
    local missing, err = storage.fork(source, { directory = directory, entry_id = "missing" })
    assert.is_nil(missing)
    assert.matches("entry not found", tostring(assert(err).detail))
    local invalid
    invalid, err = storage.fork(source, { directory = directory, entry_id = assert(answer).id, position = "before" })
    assert.is_nil(invalid)
    assert.matches("requires a user message", tostring(assert(err).detail))
    invalid, err = storage.fork(source, { directory = directory, entry_id = assert(second).id, position = "sideways" --[[@as "before"|"at"]] })
    assert.is_nil(invalid)
    assert.matches("before or at", tostring(assert(err).detail))
    local missing_store = {}
    invalid, err = storage.fork(missing_store --[[@as Neoagent.SessionStore]], { directory = directory })
    assert.is_nil(invalid)
    assert.matches("source store", tostring(assert(err).detail))

    local full = assert(storage.fork(source, { directory = directory, metadata = { fork = true } }))
    assert.are.equal(#source:entries(), #full:entries())
    assert.are.same({ fork = true }, full:metadata().data)
    assert.is_nil(full:state().thinking_level)
    assert.is_not_nil(assert(first).id)
  end)

  it("bounds derivation and fork publication failures", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local invalid_snapshot, invalid_options = false, {}
    local derived, err = storage.derive(
      invalid_snapshot --[[@as { entries: Neoagent.JournalEntry[], leaf_id: string? }]],
      invalid_options --[[@as Neoagent.StoreOptions]])
    assert.is_nil(derived)
    assert.matches("source snapshot", tostring(assert(err).detail))
    derived, err = storage.derive({
      entries = { { type = "invalid" } --[[@as Neoagent.JournalEntry]] }, leaf_id = nil,
    }, { directory = directory, cwd = directory })
    assert.is_nil(derived)
    assert.matches("unsupported entry type", tostring(assert(err).detail))
    derived, err = storage.derive({ entries = {}, leaf_id = "missing" }, {
      directory = directory, cwd = directory,
    })
    assert.is_nil(derived)
    assert.matches("active leaf", tostring(assert(err).detail))

    fs.mkdirp = function() return nil, "mkdir unavailable" end
    derived, err = storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory, cwd = directory,
    })
    assert.is_nil(derived)
    assert.matches("mkdir unavailable", tostring(assert(err).detail))
    fs.mkdirp = original_mkdirp

    tree.indexed_path = function() return nil, "rebuild unavailable" end
    derived, err = storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory, cwd = directory,
    })
    assert.is_nil(derived)
    assert.matches("rebuild unavailable", tostring(assert(err).detail))
    tree.indexed_path = original_indexed_path

    local malformed = {
      metadata = function()
        return { persisted = true, cwd = directory, path = "source.jsonl" }
      end,
      entries = function() return false end,
    }
    local forked
    forked, err = storage.fork(malformed --[[@as Neoagent.SessionStore]], { directory = directory })
    assert.is_nil(forked)
    assert.matches("entries must be an array", tostring(assert(err).detail))

    local source = storage.new({ directory = directory, cwd = directory })
    assert(source:append({ role = "user", content = "source" }))
    fs.mkdirp = function() return nil, "fork directory unavailable" end
    forked, err = storage.fork(source, { directory = directory })
    assert.is_nil(forked)
    assert.matches("fork directory unavailable", tostring(assert(err).detail))
    assert.matches("fork", assert(err).message)
  end)

  it("reports derived Session directory publication failures", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local probe = storage.new({ directory = directory, cwd = directory })
    assert(probe:workspace_storage().prepare())
    fs.sync_directory = function(target)
      if target == probe:workspace_storage().directory then
        return nil, "derived directory sync failed"
      end
      return original_sync_directory(target)
    end

    local derived, err = storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory, cwd = directory,
    })
    assert.is_nil(derived)
    assert.matches("publish session directory", assert(err).message)
    assert.are.equal("derived directory sync failed", assert(err).detail)
  end)

  for _, derive in ipairs({ false, true }) do
    it("rejects unserializable metadata before " .. (derive and "deriving" or "persisting") .. " a Session", function()
      local directory = tempdir()
      dirs[#dirs + 1] = directory
      local opts = { directory = directory, cwd = directory,
        metadata = { invalid = math.huge },
      }
      local store = storage.new(opts)
      local accepted, err
      if derive then
        accepted, err = storage.derive({ entries = {}, leaf_id = nil }, opts)
      else
        accepted, err = store:append({ role = "user", content = "unpublished" })
      end
      assert.is_nil(accepted)
      assert.are.equal("Failed to encode session header", assert(err).message)
      assert.is_nil(vim.uv.fs_stat(store:metadata().path))
      assert.are.same({}, store:entries())
      assert.are.same({}, storage.list_sessions(directory, directory))
      local replacement = storage.new({ directory = directory, cwd = directory })
      assert(replacement:append({ role = "user", content = "valid metadata" }))
      assert.are.equal("valid metadata", assert(storage.list_sessions(directory, directory)[1]).text)
    end)
  end

  it("rejects encoded Session values that are not valid UTF-8", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    vim.json.encode = function() return "invalid\255json" end

    local ok, err = store:append({ role = "user", content = "valid" })

    vim.json.encode = original_json_encode
    assert.is_nil(ok)
    assert.matches("valid UTF%-8", tostring(assert(err).detail))
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))
  end)

  for _, failure in ipairs({ "read", "path replacement", "close", "append close" }) do
    it("contains a native Session " .. failure .. " failure without losing journal ownership", function()
      local directory = tempdir()
      dirs[#dirs + 1] = directory
      local store = storage.new({ directory = directory, cwd = directory })
      assert(store:append({ role = "user", content = "retained" }))
      local path = store:metadata().path
      local before = assert(original_read(path))
      local descriptor, closes, replaced = nil, 0, false
      local diagnostic = failure == "append close" and string.rep("é", 1500) or "native close EIO"
      vim.uv.fs_open = function(target, flags, mode)
        local fd, err = original_uv_open(target, flags, mode)
        if target == path and descriptor == nil then descriptor = fd end
        return fd, err
      end
      vim.uv.fs_read = function(fd, size, offset)
        if fd == descriptor and failure == "read" then return nil, "native read EIO" end
        local data, err = original_uv_read(fd, size, offset)
        if fd == descriptor and failure == "path replacement" and data == "" and not replaced then
          replaced = true
          assert(original_rename(path, path .. ".retained"))
          assert(original_write_all(path, "external replacement"))
        end
        return data, err
      end
      vim.uv.fs_close = function(fd)
        local closed, err = original_uv_close(fd)
        if fd == descriptor then
          closes = closes + 1
          if failure == "close" or failure == "append close" then return nil, diagnostic end
        end
        return closed, err
      end
      local accepted, err
      if failure == "append close" then
        accepted, err = store:append({ role = "user", content = "committed" })
      else
        accepted, err = open_session(path)
      end
      vim.uv.fs_open, vim.uv.fs_read, vim.uv.fs_close = original_uv_open, original_uv_read, original_uv_close
      assert.are.equal(1, closes)
      if failure == "append close" then
        assert.is_true(accepted)
        assert.are.equal(2, #store:entries())
        local committed = assert(original_read(path))
        local blocked, blocked_error = store:append({ role = "user", content = "blocked" })
        assert.is_nil(blocked)
        assert.matches("unusable", assert(blocked_error).message)
        local detail = tostring(assert(blocked_error).detail)
        assert.is_true(vim.fn.strchars(detail) < 1200)
        assert.is_not_nil((detail:find("…", 1, true)))
        assert.are.equal(committed, assert(original_read(path)))
        assert.are.equal(2, #assert(open_session(path)):entries())
      else
        assert.is_nil(accepted)
        local detail = tostring(assert(err).detail)
        assert.matches(failure == "path replacement" and "identity changed" or "native " .. failure .. " EIO", detail)
        if replaced then
          assert.are.equal("external replacement", assert(original_read(path)))
          assert.are.equal(before, assert(original_read(path .. ".retained")))
          assert(vim.uv.fs_unlink(path))
          assert(original_rename(path .. ".retained", path))
        end
        assert.are.equal(before, assert(original_read(path)))
        assert.are.same(store:entries(), assert(open_session(path)):entries())
      end
    end)
  end

  it("contains every held Session handle inspection failure", function()
    ---@return Neoagent.SessionStore, string
    local function persisted()
      local directory = tempdir()
      dirs[#dirs + 1] = directory
      local store = storage.new({ directory = directory, cwd = directory })
      assert(store:append({ role = "user", content = "first" }))
      return store, store:metadata().path
    end

    local store, path = persisted()
    ---@param target string
    ---@param opts? { mode?: integer, identity?: Neoagent.FileIdentity }
    fs.open_regular = function(target, opts)
      if target == path then
        return nil, "open ownership failed", "ownership"
      end
      return original_open_regular(target, opts)
    end
    local ok, err = store:append({ role = "user", content = "blocked" })
    fs.open_regular = original_open_regular
    assert.is_nil(ok)
    assert.matches("open ownership failed", tostring(assert(err).detail))

    store, path = persisted()
    intercept_regular(function(file, target)
      if target == path then
        file.stat = function()
          return nil, "stat ownership failed", "ownership"
        end
      end
    end)
    ok, err = store:append({ role = "user", content = "blocked" })
    fs.open_regular = original_open_regular
    assert.is_nil(ok)
    assert.matches("stat ownership failed", tostring(assert(err).detail))

    store, path = persisted()
    intercept_regular(function(file, target)
      if target ~= path then return end
      local stat = file.stat
      local calls = 0
      function file:stat()
        calls = calls + 1
        if calls == 1 then return stat(self) end
        return nil, "post-append ownership failed", "ownership"
      end
    end)
    ok, err = store:append({ role = "user", content = "blocked" })
    fs.open_regular = original_open_regular
    assert.is_nil(ok)
    assert.matches("post%-append ownership failed", tostring(assert(err).detail))

    store, path = persisted()
    intercept_regular(function(file, target)
      if target ~= path then return end
      file.append = function() return nil, "append failed" end
      local close = file.close
      function file:close()
        assert(close(self))
        return nil, {
          kind = "native",
          message = string.rep("close confirmation failed ", 80),
          detail = string.rep("unconfirmed close detail ", 80),
        }
      end
    end)
    ok, err = store:append({ role = "user", content = "blocked" })
    fs.open_regular = original_open_regular
    assert.is_nil(ok)
    assert.matches("handle close failed", tostring(assert(err).detail))
    assert.is_true(vim.fn.strchars(tostring(assert(err).detail)) <= 1200)
  end)

  it("contains incremental projection failures before and after persistence", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    tree.indexed_path = function() return nil, "pending projection failed" end
    local ok, err = store:set_leaf(nil)
    tree.indexed_path = original_indexed_path
    assert.is_nil(ok)
    assert.matches("pending projection failed", tostring(assert(err).detail))

    assert(store:append({ role = "user", content = "persisted" }))
    tree.indexed_path = function() return nil, "persisted projection failed" end
    ok, err = store:set_leaf(nil)
    tree.indexed_path = original_indexed_path
    assert.is_nil(ok)
    assert.matches("persisted projection failed", tostring(assert(err).detail))
  end)

  it("rejects a derived Session whose published identity cannot be inspected", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    ---@param target string
    ---@param data string
    ---@param policy Neoagent.AtomicPolicy
    fs.atomic_replace = function(target, data, policy)
      local ok, result, stage = original_atomic_replace(target, data, policy)
      if ok then
        fs.open_regular = function()
          return nil, "derived identity unavailable"
        end
      end
      return ok, result, stage
    end

    local derived, err = storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory,
      cwd = directory,
    })

    fs.atomic_replace = original_atomic_replace
    fs.open_regular = original_open_regular
    assert.is_nil(derived)
    assert.matches("Failed to inspect derived session", assert(err).message)
    assert.matches("derived identity unavailable", tostring(assert(err).detail))
  end)

  it("rejects a derived Session whose published path identity changes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    fs.atomic_replace = function(target, data, policy)
      local ok, identity, stage = original_atomic_replace(target, data, policy)
      if ok then
        intercept_regular(function(file, opened)
          if opened == target then
            file.verify_path = function()
              return nil, "derived path was replaced"
            end
          end
        end)
      end
      return ok, identity, stage
    end

    local derived, err = storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory,
      cwd = directory,
    })

    assert.is_nil(derived)
    assert.matches("Failed to inspect derived session", assert(err).message)
    assert.are.equal("derived path was replaced", assert(err).detail)
  end)
end)
