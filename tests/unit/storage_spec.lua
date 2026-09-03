local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local fs = require("neoagent.fs")
local file_lock = require("neoagent.file_lock")
local tree = require("neoagent.session_tree")

local original_mkdirp = fs.mkdirp
local original_read = fs.read
local original_write_all = fs.write_all
local original_atomic_replace = fs.atomic_replace
local original_truncate = fs.truncate
local original_open_regular = fs.open_regular
local original_file_lock_new = file_lock.new
local original_entry_messages = tree.entry_messages
local original_tree_messages = tree.messages
local original_indexed_path = tree.indexed_path
local original_uv_open = vim.uv.fs_open
local original_uv_write = vim.uv.fs_write
local original_rename = vim.uv.fs_rename
local original_json_encode = vim.json.encode

local function tempdir()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return assert(vim.uv.fs_realpath(path))
end

local function index_path(store)
  return fs.join(vim.fs.dirname(vim.fs.dirname(store:metadata().path)),
    "session-index.json")
end

local function intercept_regular(callback)
  fs.open_regular = function(path, ...)
    local file, err, code = original_open_regular(path, ...)
    if file then callback(file, path) end
    return file, err, code
  end
end

describe("neoagent.storage", function()
  local dirs = {}

  after_each(function()
    fs.mkdirp = original_mkdirp
    fs.read = original_read
    fs.write_all = original_write_all
    fs.atomic_replace = original_atomic_replace
    fs.truncate = original_truncate
    fs.open_regular = original_open_regular
    file_lock.new = original_file_lock_new
    tree.entry_messages = original_entry_messages
    tree.messages = original_tree_messages
    tree.indexed_path = original_indexed_path
    vim.uv.fs_open = original_uv_open
    vim.uv.fs_write = original_uv_write
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
    local temporary
    vim.uv.fs_open = function(target, ...)
      if target:find(".jsonl.", 1, true)
          and target:sub(-4) == ".tmp" then
        temporary = target
        local published = target:match("^(.*%.jsonl)%.%x+%.tmp$")
        assert.is_not_nil(published)
        assert.is_nil(vim.uv.fs_stat(published))
      end
      return original_uv_open(target, ...)
    end
    assert(session:append({ role = "user", content = "hello", timestamp = 1 }, {
      model = { provider = "openai", model = "gpt-test" },
      thinking_level = "high",
    }))
    vim.uv.fs_open = original_uv_open
    assert.is_not_nil(temporary)
    assert.is_nil(vim.uv.fs_stat(temporary))
    assert.is_not_nil(vim.uv.fs_stat(path))
    local lines = vim.fn.readfile(path)
    local accepted = vim.json.decode(lines[2])
    assert.are.equal("message", accepted.type)
    assert.are.same({
      model = { provider = "openai", model = "gpt-test" },
      thinkingLevel = "high",
    }, accepted.request)
    assert.are.equal(2, #lines)
    local reopened = assert(storage.open(path))
    assert.are.same(store:state(), reopened:state())
    assert.are.equal("hello", reopened:load()[1].content)
  end)

  it("persists pending in-memory journal entries with the first message", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local moved, _, leaf, projection = store:set_leaf(nil)
    assert.is_true(moved)
    assert.are.equal("leaf", leaf.type)
    assert.are.same({ type = "replace", messages = {} }, projection)
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))

    assert(store:append({ role = "user", content = "first" }))
    local reopened = assert(storage.open(store:metadata().path))
    assert.are.equal(2, #reopened:entries())
    assert.are.equal("leaf", reopened:entries()[1].type)
    assert.are.equal("first", reopened:load()[1].content)
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
    local reopened = assert(storage.open(path))
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
    assert.matches("blocked append", err.detail)
    reopened = assert(storage.open(path))
    assert.are.equal(1, #reopened:load())
    assert.are.same({ provider = "openai", model = "gpt-test" },
      reopened:state().model)
    assert.are.equal("low", reopened:state().thinking_level)

    fs.open_regular = original_open_regular
    assert(store:append({ role = "user", content = "second", timestamp = 3 }, {
      model = { provider = "openai", model = "gpt-next" },
      thinking_level = "high",
    }))
    reopened = assert(storage.open(path))
    assert.are.equal(2, #reopened:load())
    assert.are.same({ provider = "openai", model = "gpt-next" },
      reopened:state().model)
    assert.are.equal("high", reopened:state().thinking_level)

    assert(store:append({ role = "user", content = "plain", timestamp = 4 }, {
      model = { provider = "openai", model = "plain" },
      thinking_level = vim.NIL,
    }))
    reopened = assert(storage.open(path))
    assert.is_nil(reopened:state().thinking_level)
    assert.are.equal(vim.NIL,
      reopened:entries()[3].request.thinkingLevel)
    assert.matches('"thinkingLevel":null', assert(fs.read(path)))
  end)

  it("writes and resumes the current JSONL session", function()
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

  it("loads branches and follows the persisted active leaf", function()
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
    local ok, err = store:append({ role = "user", content = "x" }, {
      model = { provider = "", model = "model" },
    })
    assert.is_nil(ok)
    assert.matches("provider", err.detail)
    ok, err = store:append({ role = "user", content = "x" }, {
      thinking_level = 42,
    })
    assert.is_nil(ok)
    assert.matches("thinkingLevel", err.detail)
    ok, err = store:append({ role = "user", content = "x" }, {
      unknown = true,
    })
    assert.is_nil(ok)
    assert.matches("unsupported message state field", err.detail)
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
    assert.matches("duplicate entry id", append_err.detail)
  end)

  it("rejects invalid UTF-8 before persisting a Session message", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local session = assert(Session.new({ store = store }))
    local ok, err = session:append({ role = "user", content = "bad\255text" })

    assert.is_nil(ok)
    assert.are.equal("session", err.kind)
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
      { lines = { vim.json.encode({ type = "session", version = 2 }) },
        detail = "expected Neoagent session version 3" },
      { lines = { vim.json.encode(vim.tbl_extend("force", header, { parentSession = 42 })) },
        detail = "parentSession must be a string" },
      { lines = { vim.json.encode(vim.tbl_extend("force", header, {
        unknown = true,
      })) }, detail = "unsupported session header field" },
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
    vim.uv.fs_write = function() return nil, "disk full" end
    ok, err = store:append({ role = "user", content = "first" })
    assert.is_nil(ok)
    assert.matches("create session file", err.message)
    assert.are.equal(0, #store:entries())

    vim.uv.fs_write = original_uv_write
    assert(store:append({ role = "user", content = "first" }))
    intercept_regular(function(file)
      file.append = function() return nil, "disk full" end
    end)
    ok, err = store:append({ role = "assistant", content = {} })
    assert.is_nil(ok)
    assert.matches("append session entry", err.message)
    assert.are.equal(1, #store:entries())
  end)

  it("binds first persistence to the atomic replacement identity", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = store:metadata().path
    local detached = path .. ".created"
    local successor = "successor must remain unchanged"
    fs.atomic_replace = function(target, ...)
      local result = { original_atomic_replace(target, ...) }
      if result[1] and target == path then
        assert(vim.uv.fs_rename(path, detached))
        assert(original_write_all(path, successor, "wx", 384))
      end
      return unpack(result)
    end

    assert(store:append({ role = "user", content = "first" }))
    fs.atomic_replace = original_atomic_replace

    assert.are.equal(1, #store:entries())
    local ok, err = store:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.matches("unusable", err.message)
    assert.are.equal(successor, assert(original_read(path)))
    assert.matches('"content":"first"', assert(original_read(detached)))
  end)

  it("commits and poisons an unconfirmed first persistence", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = store:metadata().path
    local session = assert(Session.new({ store = store }))
    fs.open_regular = function(target, ...)
      if target == path then return nil, "inspection failed", "open" end
      return original_open_regular(target, ...)
    end

    assert(session:append({ role = "user", content = "committed" }))
    fs.open_regular = original_open_regular

    assert.are.equal(1, #store:entries())
    assert.are.equal("committed", session:messages()[1].content)
    local before = assert(original_read(path))
    local ok, err = session:append({ role = "user", content = "blocked" })
    assert.is_nil(ok)
    assert.matches("unusable", err.message)
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
      file.close = function(self)
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
    assert.matches("unusable", err.message)
    assert.matches("close confirmation failed", err.detail)
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
        file.append = function(self, data, offset)
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
      assert.matches(failure.pattern, err.detail)
      assert.are.equal(before, assert(original_read(path)))
      assert.are.equal(entry_count, #store:entries())
      assert(store:append({
        role = "assistant",
        content = { { type = "text", text = "recovered " .. index } },
        timestamp = index + 10,
      }))
    end

    local reopened = assert(storage.open(path))
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
      file.append = function(self, data, offset)
        assert(append(self, data:sub(1, 1), offset))
        assert(vim.uv.fs_rename(path, detached))
        assert(original_write_all(path, successor, "wx", 384))
        return nil, "append failed after replacement"
      end
    end)

    local ok, err = store:append({ role = "user", content = "failed" })
    fs.open_regular = original_open_regular

    assert.is_nil(ok)
    assert.matches("unusable", err.message)
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
        file.append = function(self, data, offset)
          append_attempts = append_attempts + 1
          assert(append(self, data:sub(1, 1), offset))
          return nil, "append failed"
        end
        file.truncate = function(_, size)
          assert.is_number(size)
          return nil, "truncate failed"
        end
      end
    end)

    local ok, err = store:append({
      role = "assistant", content = { { type = "text", text = "lost" } },
    })
    assert.is_nil(ok)
    assert.matches("unusable", err.message)
    assert.matches("append failed", err.detail)
    assert.matches("truncate failed", err.detail)
    assert.are.equal(1, append_attempts)
    local poisoned = vim.deepcopy(err)

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
      file.append = function(self, data, offset)
        assert(append(self, data:sub(1, 1), offset))
        return nil, "append failed"
      end
      local truncate = file.truncate
      file.truncate = function(self, size)
        assert(truncate(self, size))
        return nil, "post-truncate stat failed"
      end
    end)

    local ok, err = store:append({ role = "user", content = "failed" })

    assert.is_nil(ok)
    assert.matches("unusable", err.message)
    assert.matches("post%-truncate stat failed", err.detail)
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
    assert.matches("unusable", err.message)
    assert.matches("lock ownership was lost", err.detail)

    file_lock.new = original_file_lock_new
    local reopened = assert(storage.open(path))
    assert.are.equal(2, #reopened:entries())
    assert.are.equal("committed", reopened:load()[2].content[1].text)
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
        file.append = function(self, data, offset)
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
        with = function(_, callback)
          callback()
          return nil, release_error
        end,
      }
    end

    local ok, err = store:append({ role = "user", content = "failed" })
    assert.is_nil(ok)
    assert.matches("unusable", err.message)
    assert.matches("lock ownership was lost", err.detail)
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

    local reopened = assert(storage.open(path))

    assert.are.equal(complete, assert(original_read(path)))
    assert.are.equal("complete", reopened:load()[1].content)
    assert.are.equal(1, #reopened:entries())

    local incomplete_header = directory .. "/incomplete-header.jsonl"
    assert(original_write_all(incomplete_header, vim.json.encode({
      type = "session", version = 3, id = "incomplete", timestamp = "time",
      cwd = directory,
    }), "w", 384))
    local missing, err = storage.open(incomplete_header)
    assert.is_nil(missing)
    assert.matches("no complete JSONL record", err.detail)

    local unrecoverable = directory .. "/unrecoverable.jsonl"
    assert(original_write_all(unrecoverable,
      complete .. '{"type":"message"', "w", 384))
    intercept_regular(function(file, target)
      if target == unrecoverable then
        file.truncate = function() return nil, "truncate denied" end
      end
    end)
    missing, err = storage.open(unrecoverable)
    fs.open_regular = original_open_regular
    assert.is_nil(missing)
    assert.matches("failed to recover incomplete final record", err.detail)
    assert.matches("truncate denied", err.detail)
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
    assert.are.equal("lock ownership was lost", append_err.detail)
    local opened, open_err = storage.open(path)
    assert.is_nil(opened)
    assert.are.equal("lock ownership was lost", open_err.detail)
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
      summary = "Old work", firstKeptEntryId = first.id, tokensBefore = 100,
    }))

    local reopened = assert(storage.open(store:metadata().path))
    assert.are.equal("/tmp/parent.jsonl", reopened:metadata().parent_session)
    assert.are.same({ owner = "test" }, reopened:metadata().data)
    assert.are.equal(2, #reopened:entries())
    assert.are.same({
      model = { provider = "openai", model = "gpt-test" },
      thinking_level = "high",
    }, reopened:state())
    local context = assert(reopened:context_messages())
    assert.matches("Old work", context[1].content[1].text)
    assert.are.equal("old", context[2].content)
    assert.are.same({
      path = reopened:metadata().path,
      id = reopened:metadata().id,
      cwd = directory,
      parent_session = "/tmp/parent.jsonl",
      created_at = reopened:metadata().timestamp,
      modified_at = reopened:info().modified_at,
      message_count = 1,
      first_message = "old",
    }, reopened:info())
    vim.fn.writefile({ "invalid" }, vim.fs.dirname(reopened:metadata().path) .. "/invalid.jsonl")
    local listed = storage.list_sessions(directory, directory)
    assert.are.equal(1, #listed)
    assert.are.equal(reopened:metadata().path, listed[1].path)
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
      version = 3,
      sessions = {
        [filename] = {
          attributes = { profileId = "neo" },
          parent_session = "/tmp/parent.jsonl",
          text = "first question",
        },
      },
    }, document)

    local index_writes = 0
    fs.atomic_replace = function(target, ...)
      if target:find("session-index.json", 1, true) then
        index_writes = index_writes + 1
      end
      return original_atomic_replace(target, ...)
    end
    assert(store:append({ role = "assistant",
      content = { { type = "text", text = "answer" } }, timestamp = 2 }))
    assert.are.equal(0, index_writes)
    fs.atomic_replace = original_atomic_replace

    data = assert(fs.read(path))
    document = vim.json.decode(data)
    assert.are.equal("first question", document.sessions[filename].text)
    local reopened = assert(storage.open(store:metadata().path))
    assert.are.same({ profileId = "neo" },
      document.sessions[filename].attributes)
    local listed = storage.list_sessions(directory, directory)
    assert.are.equal(1, #listed)
    assert.are.equal(store:metadata().path, listed[1].path)
    assert.are.equal("/tmp/parent.jsonl", listed[1].parent_session)
    assert.are.same({ profileId = "neo" }, listed[1].attributes)
    assert.are.equal("first question", listed[1].text)
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
        return { "invalid-list-projection" }
      end,
    })
    assert.are.equal(2, #projected)
    assert.are.same({}, projected[1].attributes)
    assert.are.same({}, projected[2].attributes)

    assert(original_write_all(path, "{", "w", 384))
    session_reads = 0
    assert.are.equal(2, #storage.list_sessions(directory, directory))
    assert.are.equal(2, session_reads)
    local repaired_data = assert(original_read(path))
    local repaired = vim.json.decode(repaired_data)
    assert.are.equal(3, repaired.version)
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
      version = 3,
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

  it("waits for index writers and accepts unowned stable lock files", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local first = storage.new({ directory = directory, cwd = directory })
    local path = index_path(first)
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
      parentId = first.id,
      timestamp = "2020-01-01T00:00:00.000Z",
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
      vim.json.decode(lines[#lines - 1]).message.content[1].text)
    assert.are.equal("local",
      vim.json.decode(lines[#lines]).message.content[1].text)
  end)

  it("keeps session persistence independent from disposable index writes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = index_path(store)
    vim.uv.fs_open = function(target, ...)
      if target:find("session-index.json", 1, true) then
        return nil, "index unavailable"
      end
      return original_uv_open(target, ...)
    end

    assert(store:append({ role = "user", content = "authoritative" }))
    assert.is_not_nil(vim.uv.fs_stat(store:metadata().path))
    assert.is_nil(vim.uv.fs_stat(path))
    vim.uv.fs_open = original_uv_open

    local listed = storage.list_sessions(directory, directory)
    assert.are.equal("authoritative", listed[1].text)
    assert.is_not_nil(vim.uv.fs_stat(path))
  end)

  it("rejects malformed index projections and cleans failed atomic writes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = index_path(store)
    assert(fs.mkdirp(vim.fs.dirname(path)))
    assert(fs.write_all(path, vim.json.encode({
      version = 3,
      sessions = {
        ["value.jsonl"] = false,
        ["parent.jsonl"] = { text = "parent", parent_session = 42 },
        ["attributes.jsonl"] = { text = "attributes", attributes = { "x" } },
      },
    })))
    assert.are.same({}, storage.list_sessions(directory, directory))

    local temporary
    vim.uv.fs_open = function(target, ...)
      if target:sub(-4) == ".tmp" then temporary = target end
      return original_uv_open(target, ...)
    end
    vim.uv.fs_rename = function() return nil, "rename unavailable" end
    local ok, err = store:append({ role = "user", content = "atomic" })
    assert.is_nil(ok)
    assert.matches("rename unavailable", err.detail)
    assert.is_not_nil(temporary)
    assert.is_nil(vim.uv.fs_stat(temporary))
  end)

  it("merges session index updates from concurrent Neovim processes", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local parent = storage.new({ directory = directory, cwd = directory })
    local path = index_path(parent)
    local ready_path = directory .. "/child-ready"
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
    }, { text = true, env = { NEOAGENT_COVERAGE = "0" } })
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
    assert.matches("entry not found", err.detail)
    ok, err = store:append_compaction({
      summary = "bad", firstKeptEntryId = "missing", tokensBefore = 1,
    })
    assert.is_nil(ok)
    assert.matches("first kept entry", err.detail)
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))
    local forked, fork_err = storage.fork(store, { directory = directory })
    assert.is_nil(forked)
    assert.matches("not persisted", fork_err.detail)
  end)

  it("encodes empty session header metadata as an object", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory, metadata = {} })
    assert(store:append({ role = "user", content = "metadata" }))
    local header = vim.fn.readfile(store:metadata().path)[1]
    assert.matches('"metadata":{}', header)
    assert.are.same({}, assert(storage.open(store:metadata().path)):metadata().data)
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
      directory = directory, entry_id = second.id, position = "before",
    }))
    assert.are.equal(source:metadata().path, before:metadata().parent_session)
    assert.are.same({ "first", "assistant" }, vim.tbl_map(function(message)
      return message.role == "user" and message.content or message.role
    end, before:load()))
    assert.are.equal(answer.id, before:leaf_id())
    assert.are.equal("high", before:state().thinking_level)

    local at = assert(storage.fork(source:metadata().path, {
      directory = directory, entry_id = second.id, position = "at",
    }))
    assert.are.equal("second", at:load()[3].content)
    assert.is_nil(at:state().thinking_level)
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
    assert.is_nil(full:state().thinking_level)
    assert.is_not_nil(first.id)
  end)

  it("bounds derivation and fork publication failures", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local derived, err = storage.derive(false, {})
    assert.is_nil(derived)
    assert.matches("source snapshot", err.detail)
    derived, err = storage.derive({
      entries = { { type = "invalid" } }, leaf_id = nil,
    }, { directory = directory, cwd = directory })
    assert.is_nil(derived)
    assert.matches("unsupported entry type", err.detail)
    derived, err = storage.derive({ entries = {}, leaf_id = "missing" }, {
      directory = directory, cwd = directory,
    })
    assert.is_nil(derived)
    assert.matches("active leaf", err.detail)

    fs.mkdirp = function() return nil, "mkdir unavailable" end
    derived, err = storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory, cwd = directory,
    })
    assert.is_nil(derived)
    assert.matches("mkdir unavailable", err.detail)
    fs.mkdirp = original_mkdirp

    tree.indexed_path = function() return nil, "rebuild unavailable" end
    derived, err = storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory, cwd = directory,
    })
    assert.is_nil(derived)
    assert.matches("rebuild unavailable", err.detail)
    tree.indexed_path = original_indexed_path

    local malformed = {
      metadata = function()
        return { persisted = true, cwd = directory, path = "source.jsonl" }
      end,
      entries = function() return false end,
    }
    local forked
    forked, err = storage.fork(malformed, { directory = directory })
    assert.is_nil(forked)
    assert.matches("entries must be an array", err.detail)

    local source = storage.new({ directory = directory, cwd = directory })
    assert(source:append({ role = "user", content = "source" }))
    fs.mkdirp = function() return nil, "fork directory unavailable" end
    forked, err = storage.fork(source, { directory = directory })
    assert.is_nil(forked)
    assert.matches("fork directory unavailable", err.detail)
    assert.matches("fork", err.message)
  end)

  it("rejects encoded Session values that are not valid UTF-8", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    vim.json.encode = function() return "invalid\255json" end

    local ok, err = store:append({ role = "user", content = "valid" })

    vim.json.encode = original_json_encode
    assert.is_nil(ok)
    assert.matches("valid UTF%-8", err.detail)
    assert.is_nil(vim.uv.fs_stat(store:metadata().path))
  end)

  it("contains every held Session handle inspection failure", function()
    local function persisted()
      local directory = tempdir()
      dirs[#dirs + 1] = directory
      local store = storage.new({ directory = directory, cwd = directory })
      assert(store:append({ role = "user", content = "first" }))
      return store, store:metadata().path
    end

    local store, path = persisted()
    fs.open_regular = function(target, ...)
      if target == path then
        return nil, "open ownership failed", "ownership"
      end
      return original_open_regular(target, ...)
    end
    local ok, err = store:append({ role = "user", content = "blocked" })
    fs.open_regular = original_open_regular
    assert.is_nil(ok)
    assert.matches("open ownership failed", err.detail)

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
    assert.matches("stat ownership failed", err.detail)

    store, path = persisted()
    intercept_regular(function(file, target)
      if target ~= path then return end
      local stat = file.stat
      local calls = 0
      file.stat = function(self)
        calls = calls + 1
        if calls == 1 then return stat(self) end
        return nil, "post-append ownership failed", "ownership"
      end
    end)
    ok, err = store:append({ role = "user", content = "blocked" })
    fs.open_regular = original_open_regular
    assert.is_nil(ok)
    assert.matches("post%-append ownership failed", err.detail)

    store, path = persisted()
    intercept_regular(function(file, target)
      if target ~= path then return end
      file.append = function() return nil, "append failed" end
      local close = file.close
      file.close = function(self)
        assert(close(self))
        return nil, string.rep("close confirmation failed ", 100)
      end
    end)
    ok, err = store:append({ role = "user", content = "blocked" })
    fs.open_regular = original_open_regular
    assert.is_nil(ok)
    assert.matches("handle close failed", err.detail)
    assert.is_true(vim.fn.strchars(err.detail) <= 1200)
  end)

  it("contains incremental projection failures before and after persistence", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    tree.indexed_path = function() return nil, "pending projection failed" end
    local ok, err = store:set_leaf(nil)
    tree.indexed_path = original_indexed_path
    assert.is_nil(ok)
    assert.matches("pending projection failed", err.detail)

    assert(store:append({ role = "user", content = "persisted" }))
    tree.indexed_path = function() return nil, "persisted projection failed" end
    ok, err = store:set_leaf(nil)
    tree.indexed_path = original_indexed_path
    assert.is_nil(ok)
    assert.matches("persisted projection failed", err.detail)
  end)

  it("rejects a derived Session whose published identity cannot be inspected", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    fs.atomic_replace = function(...)
      local result = { original_atomic_replace(...) }
      if result[1] then
        fs.open_regular = function()
          return nil, "derived identity unavailable"
        end
      end
      return unpack(result)
    end

    local derived, err = storage.derive({ entries = {}, leaf_id = nil }, {
      directory = directory,
      cwd = directory,
    })

    fs.atomic_replace = original_atomic_replace
    fs.open_regular = original_open_regular
    assert.is_nil(derived)
    assert.matches("Failed to inspect derived session", err.message)
    assert.matches("derived identity unavailable", err.detail)
  end)
end)
