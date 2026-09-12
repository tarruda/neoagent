local assert = require("luassert")
local async_test = require("tests.helpers.async_test")
local async = require("neoagent.async")
local files = require("neoagent.files")
local memory = require("neoagent.files.memory")
local digest = require("neoagent.files.digest")
local fs = require("neoagent.fs")
local workspace_storage = require("neoagent.workspace_storage")
local semantic = require("neoagent.semantic_message")
local util = require("neoagent.util")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")

describe("workspace attachment storage", function()
  local directories = {}
  ---@type Neoagent.FileReader[]
  local readers = {}
  local original_open = fs.open_regular
  local original_replace = fs.atomic_replace
  local original_digest = digest.sha256
  local original_fsync = vim.uv.fs_fsync
  local original_read = vim.uv.fs_read
  local original_lstat = vim.uv.fs_lstat
  local original_close = vim.uv.fs_close
  local original_scandir = vim.uv.fs_scandir
  local original_sync_directory = fs.sync_directory
  local locks = require("neoagent.file_lock")
  local original_lock = locks.new
  after_each(function()
    fs.open_regular, fs.atomic_replace = original_open, original_replace
    digest.sha256, vim.uv.fs_fsync = original_digest, original_fsync
    vim.uv.fs_read, fs.sync_directory, locks.new = original_read, original_sync_directory, original_lock
    vim.uv.fs_lstat = original_lstat
    vim.uv.fs_close = original_close
    vim.uv.fs_scandir = original_scandir
    for _, reader in ipairs(readers) do reader.close() end
    readers = {}
    for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
    directories = {}
  end)

  ---@return Neoagent.WorkspaceStorage
  local function workspace()
    local directory = vim.fn.tempname()
    directories[#directories + 1] = directory
    return workspace_storage.new(directory)
  end

  ---@param store Neoagent.WorkspaceStorage
  ---@param id string
  ---@return string
  local function path(store, id)
    return fs.join(store.directory, "files", id, "content")
  end

  ---@return Neoagent.SessionStore
  local function session_store()
    local directory = workspace().directory
    return storage.new({ directory = directory, cwd = directory })
  end

  async_test("commits only published references and resumes without opening their bytes", function()
    local store = session_store()
    local session = assert(Session.new({ store = store }))
    ---@type Neoagent.ImageBlock
    local image = { type = "image", file_id = digest.sha256("image"), bytes = 5,
      mime_type = "image/png", filename = "example.png" }
    assert.is_nil((store:append({ role = "user", content = { image } })))
    assert.is_nil((vim.uv.fs_stat(store:metadata().path)))
    assert.same({}, store:entries())
    assert.same({}, session:messages())
    assert(session:files().put("image"))
    assert(session:append({ role = "user", content = { image } }))
    local bytes = assert(fs.read(store:metadata().path))
    assert.is_nil((bytes:find("base64", 1, true)))
    assert.is_nil((bytes:find("mimeType", 1, true)))
    local header = vim.json.decode((assert(vim.split(bytes, "\n", { plain = true })[1])))
    assert.are.equal("neoagent-session", header.format)
    assert.is_number(header.created_at)
    assert.is_nil((header.version))
    fs.open_regular = function(target, options)
      assert.are_not.equal("content", vim.fs.basename(target))
      return original_open(target, options)
    end
    local resumed = assert(Session.new({ store = assert(storage.open(store:metadata().path,
      store:workspace_storage())) }))
    assert.same(session:entries(), resumed:entries())
    assert.same(session:messages(), resumed:messages())
    assert.are.equal(session:files().identity, resumed:files().identity)
  end)

  async_test("copies every retained branch attachment before publishing a derived Session", function()
    local source, destination = session_store(), session_store()
    local first = assert(source:files().put("first image"))
    local second = assert(source:files().put("second image"))
    local ok, _, branch = source:append({ role = "user", content = {
      { type = "image", file_id = first.file_id, bytes = first.bytes, mime_type = "image/png" },
    } })
    assert(ok)
    assert(source:append({ role = "user", content = {
      { type = "image", file_id = second.file_id, bytes = second.bytes, mime_type = "image/png" },
    } }))
    assert(source:set_leaf(assert(branch).id))
    local directory = assert(vim.fs.dirname(destination:workspace_storage().directory))
    local copied = assert(storage.derive({ entries = source:entries(), leaf_id = source:leaf_id() }, {
      directory = directory, cwd = destination:metadata().cwd, source_files = source:files(),
    }))
    assert.same(source:entries(), copied:entries())
    assert.are.equal("first image", assert(files.read(copied:files(), first.file_id, first.bytes)))
    assert.are.equal("second image", assert(files.read(copied:files(), second.file_id, second.bytes)))
    assert.are_not.equal(source:files().identity, copied:files().identity)
  end)

  for _, failure in ipairs({ "missing source", "occupied destination" }) do
    async_test("leaves derived Sessions unpublished after an attachment has a " .. failure, function()
      local source, destination = session_store(), session_store()
      local contents = "retained image"
      local file = assert(source:files().put(contents))
      assert(source:append({ role = "user", content = {{
        type = "image", file_id = file.file_id, bytes = file.bytes, mime_type = "image/png",
      }} }))
      local journal = assert(fs.read(source:metadata().path))
      local target = destination:workspace_storage()
      local obstruction = fs.join(target.directory, "files", file.file_id)
      if failure == "missing source" then
        assert(vim.uv.fs_unlink(path(source:workspace_storage(), file.file_id)))
      else
        assert(target.prepare())
        assert(fs.ensure_private_directory(fs.join(target.directory, "files"), 448))
        assert(fs.write_all(obstruction, "external file"))
      end
      local options = { directory = assert(vim.fs.dirname(target.directory)),
        cwd = destination:metadata().cwd, source_files = source:files() }
      local snapshot = { entries = source:entries(), leaf_id = source:leaf_id() }
      local derived, err = storage.derive(snapshot, options)
      assert.is_nil(derived)
      assert.matches(failure == "missing source" and "missing" or "attachment directory", assert(err).message)
      assert.are.same({}, storage.list(options.directory, options.cwd))
      assert.are.equal(journal, assert(fs.read(source:metadata().path)))
      if failure == "missing source" then
        assert(source:files().put(contents))
      else
        assert.are.equal("external file", assert(fs.read(obstruction)))
        assert(vim.uv.fs_unlink(obstruction))
      end
      derived = assert(storage.derive(snapshot, options))
      assert.are.same(source:entries(), derived:entries())
      assert.are.equal(contents, assert(files.read(derived:files(), file.file_id, file.bytes)))
    end)
  end

  async_test("rejects an old Session header before recovering an incomplete trailing record", function()
    local store = session_store()
    assert(store:append({ role = "user", content = "synthetic" }))
    local target = store:metadata().path
    local old = '{"type":"session","version":3,"id":"old"}\n{"type":'
    assert(fs.write_all(target, old))
    local reopened, err = storage.open(target, store:workspace_storage())
    assert.is_nil((reopened))
    assert.matches("neoagent%-session header", tostring(assert(err).detail))
    assert.are.equal(old, assert(fs.read(target)))
  end)

  async_test("publishes one binary snapshot and reuses its hash across filenames and capability copies", function()
    local store = workspace()
    local bytes = "\0\1\255synthetic snapshot\r\n"
    local first = assert(store.files.put(bytes))
    assert.are.equal(digest.sha256(bytes), first.file_id)
    assert.are.equal(#bytes, first.bytes)
    local inode = assert(vim.uv.fs_stat(path(store, first.file_id))).ino
    assert.same(first, assert(util.copy(store.files).put(bytes)))
    assert.are.equal(inode, assert(vim.uv.fs_stat(path(store, first.file_id))).ino)
    local reopened = workspace_storage.new(store.directory)
    assert.same(first, assert(reopened.files.inspect(first.file_id)))
    assert.are.equal(bytes, assert(files.read(reopened.files, first.file_id, #bytes)))
    assert.same({ format = "neoagent-workspace" }, vim.json.decode((assert(fs.read(
      fs.join(store.directory, "workspace.json"))))))
    if jit.os ~= "Windows" then
      assert.are.equal(384, bit.band(assert(vim.uv.fs_stat(path(store, first.file_id))).mode, 511))
      assert.are.equal(448, bit.band(assert(vim.uv.fs_stat(store.directory)).mode, 511))
    end
  end)

  async_test("validates references and metadata without loading or hashing attachment bytes", function()
    local store = workspace()
    local file = assert(store.files.put("synthetic image"))
    digest.sha256 = function() error("metadata must not hash content") end
    fs.open_regular = function(target, options)
      local handle, err, stage = original_open(target, options)
      if handle then handle.read_chunks = function() error("metadata must not read content") end end
      return handle, err, stage
    end
    ---@type Neoagent.ImageBlock
    local image = { type = "image", file_id = file.file_id, bytes = file.bytes,
      mime_type = "image/png", filename = "snapshot.png" }
    assert.same(image, assert(semantic.normalize_image(image)))
    assert.is_true((files.check_messages(store.files, { { role = "user", content = { image } } })))
    image.bytes = image.bytes + 1
    local ok, err = files.check_messages(store.files, { { role = "user", content = { image } } })
    assert.is_nil((ok))
    assert.matches("size does not match", assert(err).message)
    local rejected, invalid = semantic.normalize_image({ type = "image", data = "cG5n", mimeType = "image/png" })
    assert.is_nil((rejected))
    assert.matches("unsupported field", assert(invalid))
  end)

  async_test("imports snapshots into another workspace independently of the source", function()
    local source, target = memory.new(), workspace()
    local file = assert(source.put("synthetic image"))
    ---@type Neoagent.Message[]
    local messages = { { role = "user", content = {
      { type = "image", file_id = file.file_id, bytes = file.bytes, mime_type = "image/png" },
    } } }
    assert.is_nil((files.check_messages(target.files, messages)))
    assert.is_true((files.import(source, target.files, messages)))
    assert.are.equal("synthetic image", assert(files.read(target.files, file.file_id, file.bytes)))
    assert.are_not.equal(source.identity, target.files.identity)
    assert.are_not.equal(source.identity, memory.new().identity)
  end)

  async_test("rejects attachment validation without its file capability", function()
    local store = workspace()
    local file = assert(store.files.put("synthetic image"))
    local ok, err = files.check_messages(nil, {{ role = "user", content = {{
      type = "image", file_id = file.file_id, bytes = file.bytes, mime_type = "image/png",
    }} }})
    assert.is_nil(ok)
    assert.are.equal("Attachment file reader is required", assert(err).message)
    assert.are.equal("synthetic image", assert(files.read(store.files, file.file_id, file.bytes)))
  end)

  async_test("preserves the source when an import cannot publish the destination blob", function()
    local source, target = memory.new(), workspace()
    local file = assert(source.put("synthetic image"))
    assert(target.prepare())
    assert(fs.ensure_private_directory(fs.join(target.directory, "files"), 448))
    local occupied = fs.join(target.directory, "files", file.file_id)
    assert(fs.write_all(occupied, "occupied by another file"))
    local ok, err = files.import(source, target.files, {{ role = "user", content = {{
      type = "image", file_id = file.file_id, bytes = file.bytes, mime_type = "image/png",
    }} }})
    assert.is_nil(ok)
    assert.matches("Could not create attachment directory", assert(err).message)
    assert.are.equal("occupied by another file", assert(fs.read(occupied)))
    assert.are.equal("synthetic image", assert(files.read(source, file.file_id, file.bytes)))
    assert.is_nil((target.files.inspect(file.file_id)))
    assert(vim.uv.fs_unlink(occupied))
    assert(files.import(source, target.files, {{ role = "user", content = {{
      type = "image", file_id = file.file_id, bytes = file.bytes, mime_type = "image/png",
    }} }}))
    assert.are.equal("synthetic image", assert(files.read(target.files, file.file_id, file.bytes)))
  end)

  async_test("rejects missing, oversized, corrupt and symlinked blobs without recreating content", function()
    local store = workspace()
    local file = assert(store.files.put("synthetic image"))
    assert.is_nil((store.files.open(file.file_id, file.bytes - 1)))
    assert(fs.write_all(path(store, file.file_id), "different image"))
    local bytes, corrupt = files.read(store.files, file.file_id, file.bytes)
    assert.is_nil((bytes))
    assert.matches("does not match", assert(corrupt).message)
    assert.is_nil((store.files.put("synthetic image")))
    assert(vim.uv.fs_unlink(path(store, file.file_id)))
    assert.is_nil((store.files.inspect(file.file_id)))
    if jit.os ~= "Windows" then
      assert(vim.uv.fs_symlink(fs.join(store.directory, "workspace.json"), path(store, file.file_id)))
      assert.is_nil((store.files.open(file.file_id, 1024)))
      assert.is_nil((store.files.put("synthetic image")))
    end
  end)

  for _, change in ipairs({ "growth", "replacement" }) do
    async_test("rejects attachment " .. change .. " after opening its reader", function()
      local store = workspace()
      local contents = "retained attachment"
      local file = assert(store.files.put(contents))
      local reader = assert(store.files.open(file.file_id, file.bytes))
      readers[#readers + 1] = reader
      if change == "growth" then
        assert(fs.write_all(path(store, file.file_id), contents .. "extra"))
      elseif jit.os == "Windows" then
        local target = path(store, file.file_id)
        vim.uv.fs_lstat = function(selected)
          local stat, err, code = original_lstat(selected)
          if selected == target and stat then
            stat.ino = stat.ino + 1
          end
          return stat, err, code
        end
      else
        assert(fs.atomic_replace(path(store, file.file_id), contents, { mode = 384 }))
      end
      local data, err = reader.read()
      vim.uv.fs_lstat = original_lstat
      assert(reader.close())
      assert.is_nil(data)
      assert.matches(change == "growth" and "exceeds the byte limit" or "changed during read", assert(err).message)
      assert.are.equal(change == "growth" and contents .. "extra" or contents,
        assert(fs.read(path(store, file.file_id))))
    end)
  end

  async_test("rejects metadata whose file is replaced after its descriptor opens", function()
    local store = workspace()
    local file = assert(store.files.put("attachment"))
    local target = path(store, file.file_id)
    fs.open_regular = function(selected, options)
      local opened, err = original_open(selected, options)
      if selected == target and opened then
        if jit.os == "Windows" then
          vim.uv.fs_lstat = function(pathname)
            local stat, stat_err, code = original_lstat(pathname)
            if pathname == target and stat then
              stat.ino = stat.ino + 1
            end
            return stat, stat_err, code
          end
        else
          assert(original_replace(target, "replacement", { mode = 384 }))
        end
      end
      return opened, err
    end
    local metadata, err = store.files.inspect(file.file_id)
    fs.open_regular = original_open
    vim.uv.fs_lstat = original_lstat
    assert.is_nil(metadata)
    assert.matches("Could not inspect attachment", assert(err).message)
    assert.are.equal(jit.os == "Windows" and "attachment" or "replacement", assert(fs.read(target)))
  end)

  async_test("rejects a file removed between metadata inspection and content opening", function()
    local store = workspace()
    local file = assert(store.files.put("attachment"))
    local target = path(store, file.file_id)
    local closes = 0
    vim.uv.fs_close = function(fd)
      closes = closes + 1
      local closed, err = original_close(fd)
      if closes == 1 then assert(vim.uv.fs_unlink(target)) end
      return closed, err
    end
    local reader, err = store.files.open(file.file_id, file.bytes)
    vim.uv.fs_close = original_close
    assert.is_nil(reader)
    assert.matches("Could not open attachment", assert(err).message)
    assert.is_nil((vim.uv.fs_lstat(target)))
    assert.are.equal(1, closes)
  end)

  async_test("closes a failed content read without returning partial attachment bytes", function()
    local store = workspace()
    local contents = string.rep("attachment", 7000)
    local file = assert(store.files.put(contents))
    local reads, closes = 0, 0
    vim.uv.fs_read = function(fd, size, offset)
      reads = reads + 1
      if reads == 2 then return nil, "synthetic device read failure", "EIO" end
      return original_read(fd, size, offset)
    end
    vim.uv.fs_close = function(fd)
      closes = closes + 1
      return original_close(fd)
    end
    local data, err = files.read(store.files, file.file_id, file.bytes)
    vim.uv.fs_read, vim.uv.fs_close = original_read, original_close
    assert.is_nil(data)
    assert.matches("Could not read attachment", assert(err).message)
    assert.matches("synthetic device read failure", tostring(assert(err).detail))
    assert.are.equal(2, reads)
    assert.are.equal(2, closes)
    assert.are.equal(contents, assert(files.read(store.files, file.file_id, file.bytes)))
  end)

  async_test("preserves a file obstructing the attachment directory and permits repair", function()
    local store = workspace()
    assert(store.prepare())
    local obstruction = fs.join(store.directory, "files")
    assert(fs.write_all(obstruction, "obstruction"))
    local file, err = store.files.put("attachment")
    assert.is_nil(file)
    assert.matches("Could not create attachment directory", assert(err).message)
    assert.are.equal("obstruction", assert(fs.read(obstruction)))
    assert(vim.uv.fs_unlink(obstruction))
    file = assert(store.files.put("attachment"))
    assert.are.equal("attachment", assert(files.read(store.files, file.file_id, file.bytes)))
  end)

  for _, operation in ipairs({ "metadata", "content" }) do
    async_test("reports attachment " .. operation .. " close failures without retrying the descriptor", function()
      local store = workspace()
      local file = assert(store.files.put("attachment"))
      local calls = 0
      vim.uv.fs_close = function(fd)
        calls = calls + 1
        assert(original_close(fd))
        if calls == (operation == "metadata" and 1 or 2) then
          return nil, "synthetic native close failure"
        end
        return true
      end
      local value, err
      if operation == "metadata" then
        value, err = store.files.inspect(file.file_id)
      else
        value, err = files.read(store.files, file.file_id, file.bytes)
      end
      vim.uv.fs_close = original_close
      assert.is_nil(value)
      assert.matches("Could not close attachment", assert(err).message)
      assert.are.equal(operation == "metadata" and 1 or 2, calls)
      assert.are.equal("attachment", assert(files.read(store.files, file.file_id, file.bytes)))
    end)
  end

  async_test("leaves incompatible nonempty workspaces untouched", function()
    local store = workspace()
    assert(fs.mkdirp(store.directory))
    local old = fs.join(store.directory, "old-session.jsonl")
    assert(fs.write_all(old, '{"version":3}\n'))
    local published, err = store.files.put("synthetic image")
    assert.is_nil((published))
    assert.matches("nonempty directory", assert(err).message)
    assert.same({ "old-session.jsonl" }, vim.fn.readdir(store.directory))
    assert.are.equal('{"version":3}\n', assert(fs.read(old)))
  end)

  async_test("rejects incorrect and non-regular workspace markers", function()
    local store = workspace()
    assert(fs.mkdirp(store.directory))
    local marker = fs.join(store.directory, "workspace.json")
    assert(fs.write_all(marker, '{"format":"other"}'))
    assert.is_nil((store.prepare()))
    assert(fs.write_all(marker, '{"format":"neoagent-workspace","version":1}'))
    assert.is_nil((store.prepare()))
    assert(vim.uv.fs_unlink(marker))
    assert(fs.mkdirp(marker))
    assert.is_nil((store.prepare()))
  end)

  async_test("rejects Session access after the workspace format marker changes", function()
    local store = session_store()
    assert(store:append({ role = "user", content = "retained conversation" }))
    local metadata = store:metadata()
    local workspace = store:workspace_storage()
    local directory = assert(vim.fs.dirname(workspace.directory))
    local marker = fs.join(workspace.directory, "workspace.json")
    local before = assert(fs.read(metadata.path))
    assert(fs.write_all(marker, '{"format":"unrecognized-workspace"}'))
    local opened, err = storage.open(metadata.path, workspace)
    assert.is_nil(opened)
    assert.are.equal("Unsupported workspace storage format", assert(err).message)
    assert.same({}, storage.list(directory, metadata.cwd))
    assert.same({}, storage.list_sessions(directory, metadata.cwd))
    assert.are.equal(before, assert(fs.read(metadata.path)))
    assert(fs.write_all(marker, '{"format":"neoagent-workspace"}'))
    local reopened = assert(storage.open(metadata.path, workspace))
    assert.same(store:entries(), reopened:entries())
    assert.same({ metadata.path }, storage.list(directory, metadata.cwd))
  end)

  async_test("preserves a regular file occupying the workspace storage path", function()
    local store = workspace()
    assert(fs.write_all(store.directory, "existing file"))
    local ready, err = store.prepare()
    assert.is_nil(ready)
    assert.are.equal("Workspace storage is not a directory", assert(err).message)
    assert.are.equal("existing file", assert(fs.read(store.directory)))
  end)

  async_test("rejects an unreadable workspace marker without retrying its closed descriptor", function()
    local store = workspace()
    assert(store.prepare())
    local closes = 0
    vim.uv.fs_close = function(fd)
      closes = closes + 1
      assert(original_close(fd))
      return nil, "native marker close failed"
    end
    local valid, err = store.validate()
    vim.uv.fs_close = original_close
    assert.is_nil(valid)
    assert.are.equal("Could not close workspace marker", assert(err).message)
    assert.matches("native marker close failed", tostring(assert(err).detail))
    assert.are.equal(1, closes)
    assert(store.validate())
  end)

  for _, format in ipairs({ "neoagent-workspace", "unrecognized-workspace" }) do
    async_test("revalidates a " .. format .. " marker published by the preceding lock owner", function()
      local store = workspace()
      assert(fs.ensure_private_directory(store.directory, 448))
      local marker = fs.join(store.directory, "workspace.json")
      local holder = assert(locks.new({ path = marker .. ".lock" }):acquire())
      local published = '{"format":"' .. format .. '"}\n'
      local completed, publication_error = false, nil
      local timer = vim.defer_fn(function()
        local written, write_err = fs.write_all(marker, published)
        local released, release_err = holder:release()
        publication_error = write_err or release_err
        completed = written == true and released == true
      end, 10)
      local called, ready, err = pcall(store.prepare)
      if not timer:is_closing() then timer:stop(); timer:close() end
      holder:release()
      assert(called, ready)
      assert.is_true(completed, vim.inspect(publication_error))
      if format == "neoagent-workspace" then
        assert.is_true(ready)
        assert.is_nil(err)
      else
        assert.is_nil(ready)
        assert.matches("Unsupported workspace storage format", vim.inspect(err))
      end
      assert.are.equal(published, assert(fs.read(marker)))
      assert.is_nil((vim.uv.fs_stat(store.sessions_directory)))
    end)
  end

  async_test("blocks later writes after uncertain authoritative publication", function()
    local store = workspace()
    assert(store.prepare())
    fs.atomic_replace = function(target, data, policy)
      if target:sub(-7) == "content" then
        assert(original_replace(target, data, policy))
        return nil, "synthetic uncertain publication", "sync"
      end
      return original_replace(target, data, policy)
    end
    assert.is_nil((store.files.put("first image")))
    fs.atomic_replace = original_replace
    local second, err = store.files.put("second image")
    assert.is_nil((second))
    assert.matches("further writes are blocked", assert(err).message)
    assert.is_nil((vim.uv.fs_stat(path(store, digest.sha256("second image")))))
  end)

  async_test("rejects incomplete and mismatched Session file dependencies before commitment", function()
    local store = session_store()
    local incomplete = memory.new()
    rawset(incomplete, "put", nil)
    local session, err = Session.new({ files = incomplete })
    assert.is_nil(session)
    assert.matches("complete attachment store", assert(err).message)
    session, err = Session.new({ store = store, files = memory.new() })
    assert.is_nil(session)
    assert.matches("must share attachment storage", assert(err).message)
    session, err = Session.new({ files = memory.new(), file_cache = store:file_cache() })
    assert.is_nil(session)
    assert.matches("cache must belong", assert(err).message)
    assert.is_nil((vim.uv.fs_stat(store:metadata().path)))
    assert(store:append({ role = "user", content = "source" }))
    local foreign = workspace()
    local reopened, open_err = storage.open(store:metadata().path, foreign)
    assert.is_nil(reopened)
    assert.matches("outside the supplied workspace", assert(open_err).message)
    session, err = Session.new({store = store, messages = {}})
    assert.is_nil(session)
    assert.matches("mutually exclusive", assert(err).message)
    local malformed = util.copy(store)
    rawset(malformed, "files", false)
    session, err = Session.new({store = malformed})
    assert.is_nil(session)
    assert.matches("storage contract", assert(err).message)
  end)

  async_test("refuses uninspectable workspace storage without creating it", function()
    local store = workspace()
    vim.uv.fs_lstat = function(target)
      if target == store.directory then return nil, "synthetic permission failure", "EACCES" end
      return original_lstat(target)
    end
    local saved, err = store.files.put("image")
    assert.is_nil(saved)
    assert.matches("Could not inspect workspace storage", assert(err).message)
    assert.is_nil((vim.uv.fs_stat(store.directory)))
  end)

  async_test("reports a failed scan of an unmarked Workspace directory", function()
    local store = workspace()
    assert(fs.mkdirp(store.directory))
    vim.uv.fs_scandir = function(target)
      if target == store.directory then
        return nil, "synthetic scan failure"
      end
      return original_scandir(target)
    end

    local valid, err = store.validate()
    assert.is_nil(valid)
    assert.matches("Could not inspect workspace storage", assert(err).message)
    assert.are.equal("synthetic scan failure", assert(err).detail)
  end)

  async_test("blocks Workspace writes after directory publication is uncertain", function()
    local store = workspace()
    fs.sync_directory = function(target)
      if target == assert(vim.fs.dirname(store.directory)) then
        return nil, "synthetic parent sync failure"
      end
      return original_sync_directory(target)
    end

    local ready, err = store.prepare()
    assert.is_nil(ready)
    assert.matches("further writes are blocked", assert(err).message)
    assert.matches("publish workspace directory", vim.inspect(err))
    local retried, retry_err = store.prepare()
    assert.is_nil(retried)
    assert.are.same(err, retry_err)
  end)

  async_test("blocks the Session after uncertain initial journal publication", function()
    local store = session_store()
    fs.atomic_replace = function(target, data, policy)
      local saved, identity, stage = original_replace(target, data, policy)
      if target == store:metadata().path then return nil, "synthetic journal flush failure", "sync" end
      return saved, identity, stage
    end
    local saved, err = store:append({role = "user", content = "first prompt"})
    assert.is_nil(saved)
    assert.matches("further writes are blocked", assert(err).message)
    fs.atomic_replace = original_replace
    assert.is_nil((store:append({role = "user", content = "next prompt"})))
    assert.same({}, assert(store:load()))
    local reopened = assert(storage.open(store:metadata().path, store:workspace_storage()))
    local messages = assert(reopened:load())
    assert.are.equal("first prompt", assert(messages[1]).content)
  end)

  async_test("removes deleted Sessions from the derived index without deleting their blobs", function()
    local store = session_store()
    local image = require("tests.helpers.attachments").new(store:files()).image("retained image")
    assert(store:append({role = "user", content = {image}}))
    local metadata = store:metadata()
    assert(vim.uv.fs_unlink(metadata.path))
    local managed = store:workspace_storage()
    assert.same({}, storage.list_sessions(assert(vim.fs.dirname(managed.directory)), assert(metadata.cwd)))
    local index = vim.json.decode((assert(fs.read(managed.directory .. "/session-index.json"))))
    assert.same(vim.empty_dict(), index.sessions)
    assert.are.equal("retained image", assert(files.read(store:files(), image.file_id, image.bytes)))
  end)

  async_test("blocks workspace publication after an uncertain format-marker write", function()
    local store = workspace()
    fs.atomic_replace = function(target, data, policy)
      assert(original_replace(target, data, policy))
      return nil, "synthetic marker uncertainty", "sync"
    end
    local file, err = store.files.put("image")
    assert.is_nil(file)
    assert.matches("further writes are blocked", assert(err).message)
    fs.atomic_replace = original_replace
    assert.is_nil((store.files.put("another image")))
    assert.is_nil((store.validate()))
    assert.is_nil((vim.uv.fs_stat(store.directory .. "/files")))
  end)

  async_test("blocks attachment publication after a directory flush fails", function()
    local store = workspace()
    assert(store.prepare())
    fs.sync_directory = function() return nil, "synthetic directory flush failure" end
    local file, err = store.files.put("image")
    assert.is_nil(file)
    assert.matches("publish attachment directory", assert(err).message)
    fs.sync_directory = original_sync_directory
    assert.is_nil((store.files.put("another image")))
    assert.is_nil((vim.uv.fs_stat(path(store, digest.sha256("image")))))
  end)

  async_test("retains an unused published blob and blocks writes after lock release fails", function()
    local store = workspace()
    assert(store.prepare())
    locks.new = function(options)
      local lock = original_lock(options)
      local acquire = lock.acquire_async
      ---@async
      function lock:acquire_async()
        local lease = acquire(self)
        local release = lease.release
        function lease:release()
          assert(release(self))
          return nil, { kind = "file_lock", code = "release", message = "synthetic release failure" }
        end
        return lease
      end
      return lock
    end
    local file, err = store.files.put("image")
    assert.is_nil(file)
    assert.matches("publication lock failed", assert(err).message)
    locks.new = original_lock
    assert.is_nil((store.files.put("another image")))
    assert.are.equal("image", assert(files.read(store.files, digest.sha256("image"), 5)))
  end)

  async_test("verifies candidate bytes before committing an attachment reference", function()
    local store = session_store()
    assert(store:workspace_storage().prepare())
    vim.uv.fs_read = function(...)
      local data, err = original_read(...)
      if data == "payload" then return "corrupt" end
      return data, err
    end
    local file, err = store:files().put("payload")
    assert.is_nil(file)
    assert.matches("content verification failed", tostring(assert(err).detail))
    assert.is_nil((vim.uv.fs_stat(store:metadata().path)))
    assert.same({}, store:entries())
  end)

  async_test("rolls back an unflushed message and prevents further Session mutations", function()
    local store = session_store()
    assert(store:append({ role = "user", content = "accepted" }))
    local path = store:metadata().path
    local before = assert(fs.read(path))
    fs.open_regular = function(target, options)
      local handle, err, stage = original_open(target, options)
      if target == path and handle then
        local opened = assert(handle)
        local sync, calls = opened.sync, 0
        function opened:sync()
          calls = calls + 1
          if calls == 1 then return nil, "synthetic append flush failure" end
          return sync(self)
        end
      end
      return handle, err, stage
    end
    local saved, err = store:append({ role = "user", content = "unflushed" })
    assert.is_nil(saved)
    assert.matches("flush failed", tostring(assert(err).detail))
    fs.open_regular = original_open
    assert.are.equal(before, assert(fs.read(path)))
    assert.are.equal(1, #store:entries())
    assert.is_nil((store:append({ role = "user", content = "later" })))
  end)

  async_test("keeps a close failure after releasing descriptor ownership", function()
    local closes = 0
    local reader = files.reader({ file_id = digest.sha256("image"), bytes = 5 }, 5,
      function() return "image" end, function()
        closes = closes + 1
        return nil, files.error("synthetic close failure")
      end)
    assert.are.equal("image", assert(reader.read()))
    assert.is_nil((reader.close()))
    local closed, err = reader.close()
    assert.is_nil((closed))
    assert.are.equal("synthetic close failure", assert(err).message)
    assert.is_nil((reader.read()))
    assert.are.equal(1, closes)
  end)

  async_test("rejects an oversized reader before reading bytes and retains close ownership", function()
    local reads, closes = 0, 0
    local reader = files.reader({ file_id = digest.sha256("image"), bytes = 5 }, 4,
      function() reads = reads + 1; return "image" end,
      function() closes = closes + 1; return true end)
    readers[#readers + 1] = reader
    local data, err = reader.read()
    assert.is_nil(data)
    assert.are.equal("Attachment exceeds the byte limit", assert(err).message)
    assert.are.equal(0, reads)
    assert.are.equal(0, closes)
    assert(reader.close())
    assert(reader.close())
    assert.are.equal(1, closes)
  end)

  async_test("closes a blob reader when its bounded read is cancelled", function()
    local store = workspace()
    local file = assert(store.files.put(string.rep("image", 30000)))
    local closes = 0
    fs.open_regular = function(target, options)
      local handle, err, stage = original_open(target, options)
      if handle then
        local close = handle.close
        handle.close = function() closes = closes + 1; return close(handle) end
      end
      return handle, err, stage
    end
    local run = async.run(function() return (files.read(store.files, file.file_id, file.bytes)) end)
    assert.is_false(run:is_done())
    run:cancel()
    assert(vim.wait(5000, function() return run:is_done() end))
    assert.are.equal(2, closes) -- Metadata handle and byte reader.
  end)
end)
