local fs = require("neoagent.fs")

describe("neoagent.fs", function()
  local original
  local paths = {}

  before_each(function()
    original = {
      stat = vim.uv.fs_stat,
      lstat = vim.uv.fs_lstat,
      open = vim.uv.fs_open,
      read = vim.uv.fs_read,
      write = vim.uv.fs_write,
      close = vim.uv.fs_close,
      ftruncate = vim.uv.fs_ftruncate,
      fstat = vim.uv.fs_fstat,
      fchmod = vim.uv.fs_fchmod,
      chmod = vim.uv.fs_chmod,
      rename = vim.uv.fs_rename,
      random = vim.uv.random,
      mkstemp = vim.uv.fs_mkstemp,
      mkdtemp = vim.uv.fs_mkdtemp,
      unlink = vim.uv.fs_unlink,
      mkdir = vim.fn.mkdir,
    }
  end)

  it("recognizes host-specific absolute paths", function()
    assert.is_true(fs.is_absolute("/tmp/file", "Linux"))
    assert.is_false(fs.is_absolute("tmp/file", "Linux"))
    assert.is_true(fs.is_absolute("C:\\repo\\file", "Windows"))
    assert.is_true(fs.is_absolute("\\\\server\\share\\file", "Windows"))
    assert.is_false(fs.is_absolute("C:relative", "Windows"))
    assert.is_false(fs.is_absolute("\\rooted", "Windows"))
  end)

  after_each(function()
    vim.uv.fs_stat = original.stat
    vim.uv.fs_lstat = original.lstat
    vim.uv.fs_open = original.open
    vim.uv.fs_read = original.read
    vim.uv.fs_write = original.write
    vim.uv.fs_close = original.close
    vim.uv.fs_ftruncate = original.ftruncate
    vim.uv.fs_fstat = original.fstat
    vim.uv.fs_fchmod = original.fchmod
    vim.uv.fs_chmod = original.chmod
    vim.uv.fs_rename = original.rename
    vim.uv.random = original.random
    vim.uv.fs_mkstemp = original.mkstemp
    vim.uv.fs_mkdtemp = original.mkdtemp
    vim.uv.fs_unlink = original.unlink
    vim.fn.mkdir = original.mkdir
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  it("reports temporary file creation and close failures", function()
    vim.uv.fs_mkstemp = function(template)
      assert.are.equal(
        vim.fs.joinpath("custom", "neoagent-test-XXXXXX"),
        template
      )
      return nil, "create failed"
    end
    local path, err = fs.create_temp("neoagent-test-", "custom")
    assert.is_nil(path)
    assert.are.equal("create failed", err)

    local removed
    vim.uv.fs_mkstemp = function() return 7, "/tmp/neoagent-test-file" end
    vim.uv.fs_close = function() return nil, "close failed" end
    vim.uv.fs_unlink = function(value) removed = value return true end
    path, err = fs.create_temp()
    assert.is_nil(path)
    assert.are.equal("close failed", err)
    assert.are.equal("/tmp/neoagent-test-file", removed)
  end)

  it("creates temporary directories atomically", function()
    vim.uv.fs_mkdtemp = function(template)
      assert.are.equal(
        vim.fs.joinpath(vim.uv.os_tmpdir(), "neoagent-dir-XXXXXX"),
        template
      )
      return "/tmp/neoagent-dir-owned"
    end
    assert.are.equal("/tmp/neoagent-dir-owned",
      fs.create_temp_directory("neoagent-dir-"))

    vim.uv.fs_mkdtemp = function(template)
      assert.are.equal("/runtime/neoagent-dir-XXXXXX", template)
      return "/runtime/neoagent-dir-owned"
    end
    assert.are.equal("/runtime/neoagent-dir-owned",
      fs.create_temp_directory("neoagent-dir-", "/runtime"))

    vim.uv.fs_mkdtemp = function() return nil, "create failed" end
    local path, err = fs.create_temp_directory()
    assert.is_nil(path)
    assert.are.equal("create failed", err)
  end)

  it("reports open and read failures and closes opened files", function()
    vim.uv.fs_stat = function() return { type = "file", size = 4 } end
    vim.uv.fs_open = function() return nil, "open denied" end
    local data, err = fs.read("file")
    assert.is_nil(data)
    assert.are.equal("open denied", err)

    local closed = false
    vim.uv.fs_open = function() return 7 end
    vim.uv.fs_read = function() return nil, "read failed" end
    vim.uv.fs_close = function(fd) closed = fd == 7 return true end
    data, err = fs.read("file")
    assert.is_nil(data)
    assert.are.equal("read failed", err)
    assert.is_true(closed)
  end)

  it("streams file reads in bounded chunks and closes after callback failures", function()
    vim.uv.fs_stat = function() return { type = "file", size = 4 } end
    vim.uv.fs_open = function() return 7 end
    local offsets = {}
    vim.uv.fs_read = function(fd, size, offset)
      assert.are.equal(7, fd)
      assert.are.equal(2, size)
      offsets[#offsets + 1] = offset
      return ({ [0] = "ab", [2] = "cd", [4] = "" })[offset]
    end
    local closes = 0
    vim.uv.fs_close = function() closes = closes + 1 return true end
    local chunks = {}
    assert(fs.read_chunks("file", function(data, offset)
      chunks[#chunks + 1] = { data, offset }
    end, 2))
    assert.are.same({ 0, 2, 4 }, offsets)
    assert.are.same({ { "ab", 0 }, { "cd", 2 } }, chunks)

    local ok, err = fs.read_chunks("file", function() error("rejected chunk") end, 2)
    assert.is_nil(ok)
    assert.matches("rejected chunk", err)
    assert.are.equal(2, closes)
    assert.has_error(function() fs.read_chunks("file", function() end, 0) end)
  end)

  it("reports directory creation failures", function()
    assert.is_true(fs.mkdirp(""))
    vim.fn.mkdir = function() error("mkdir failed") end
    local ok, err = fs.mkdirp("directory")
    assert.is_nil(ok)
    assert.matches("mkdir failed", tostring(err))

    vim.fn.mkdir = function() return 0 end
    vim.uv.fs_stat = function() return nil end
    ok, err = fs.mkdirp("directory")
    assert.is_nil(ok)
    assert.are.equal("failed to create directory", err)
  end)

  it("reports write open, write, and close failures", function()
    vim.uv.fs_open = function() return nil, "open failed" end
    local ok, err = fs.write_all("file", "data")
    assert.is_nil(ok)
    assert.are.equal("open failed", err)

    local closes = 0
    vim.uv.fs_open = function() return 8 end
    vim.uv.fs_write = function() return nil, "write failed" end
    vim.uv.fs_close = function() closes = closes + 1 return true end
    ok, err = fs.write_all("file", "data")
    assert.is_nil(ok)
    assert.are.equal("write failed", err)
    assert.are.equal(1, closes)

    vim.uv.fs_write = function() return 0 end
    ok, err = fs.write_all("file", "data")
    assert.is_nil(ok)
    assert.are.equal("invalid write length", err)
    assert.are.equal(2, closes)

    vim.uv.fs_write = function(_, data) return #data + 1 end
    ok, err = fs.write_all("file", "data")
    assert.is_nil(ok)
    assert.are.equal("invalid write length", err)
    assert.are.equal(3, closes)

    vim.uv.fs_write = function(_, data) return #data end
    vim.uv.fs_close = function() return nil, "close failed" end
    ok, err = fs.write_all("file", "data")
    assert.is_nil(ok)
    assert.are.equal("close failed", err)
  end)

  it("owns regular file I/O and rollback through one descriptor", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local path = vim.fs.joinpath(directory, "session.jsonl")
    assert(fs.write_all(path, "before", "wx", 384))

    local file = assert(fs.open_regular(path, { mode = 384 }))
    local identity = file:identity()
    assert.are.equal(6, assert(file:stat()).size)
    assert(file:append(" appended", 6))
    assert.are.equal("before appended", assert(file:read_all()))
    assert(file:truncate(6))
    assert(file:verify_path())
    assert(file:close())
    assert.are.equal("before", assert(fs.read(path)))

    file = assert(fs.open_regular(path, {
      identity = identity,
      mode = 384,
    }))
    local detached = path .. ".detached"
    assert(vim.uv.fs_rename(path, detached))
    assert(fs.write_all(path, "successor", "wx", 384))
    assert(file:append(" failed", 6))
    local verified, verify_err, verify_code = file:verify_path()
    assert.is_nil(verified)
    assert.matches("identity changed", verify_err)
    assert.are.equal("ownership", verify_code)
    assert(file:truncate(6))
    assert(file:close())
    assert.are.equal("successor", assert(fs.read(path)))
    assert.are.equal("before", assert(fs.read(detached)))

    local reopened, reopen_err, reopen_code = fs.open_regular(path, {
      identity = identity,
      mode = 384,
    })
    assert.is_nil(reopened)
    assert.matches("identity changed", reopen_err)
    assert.are.equal("ownership", reopen_code)
  end)

  it("reports regular file handle and identity failures", function()
    local observed = { type = "file", dev = 1, ino = 2, size = 6 }
    vim.uv.fs_lstat = function() return vim.deepcopy(observed) end
    vim.uv.fs_open = function() return 7 end
    vim.uv.fs_fstat = function() return vim.deepcopy(observed) end

    vim.uv.fs_close = function() return true end

    local file = assert(fs.open_regular("session", { mode = 384 }))
    vim.uv.fs_fstat = function() return nil, "stat failed" end
    local value, err, code = file:stat()
    assert.is_nil(value)
    assert.are.equal("stat failed", err)
    vim.uv.fs_fstat = function() return vim.deepcopy(observed) end

    vim.uv.fs_fstat = function()
      return { type = "file", dev = 1, ino = 3, size = 6 }
    end
    value, err, code = file:stat()
    assert.is_nil(value)
    assert.matches("handle identity changed", err)
    assert.are.equal("ownership", code)
    vim.uv.fs_fstat = function() return vim.deepcopy(observed) end

    vim.uv.fs_lstat = function()
      return { type = "file", dev = 1, ino = 3, size = 6 }
    end
    value, err, code = file:verify_path()
    assert.is_nil(value)
    assert.matches("identity changed", err)
    assert.are.equal("ownership", code)
    vim.uv.fs_lstat = function() return vim.deepcopy(observed) end

    vim.uv.fs_read = function() return nil, "read failed" end
    value, err, code = file:read_all()
    assert.is_nil(value)
    assert.are.equal("read failed", err)
    assert.are.equal("read", code)

    vim.uv.fs_write = function() return 0, "write failed" end
    value, err, code = file:append("x", 6)
    assert.is_nil(value)
    assert.are.equal("write failed", err)
    assert.are.equal("write", code)

    vim.uv.fs_ftruncate = function() return nil, "truncate failed" end
    value, err, code = file:truncate(6)
    assert.is_nil(value)
    assert.are.equal("truncate failed", err)
    assert.are.equal("truncate", code)

    vim.uv.fs_ftruncate = function() return true end
    vim.uv.fs_fstat = function()
      return { type = "file", dev = 1, ino = 2, size = 7 }
    end
    value, err, code = file:truncate(6)
    assert.is_nil(value)
    assert.matches("unexpected size", err)
    assert.are.equal("truncate", code)
    assert(file:close())
    assert.is_nil(file:stat())
    assert.is_nil(file:append("x", 0))
    assert.is_nil(file:truncate(0))

    vim.uv.fs_lstat = function() return vim.deepcopy(observed) end
    vim.uv.fs_fstat = function() return vim.deepcopy(observed) end
    vim.uv.fs_close = function() return nil, "close failed" end
    file = assert(fs.open_regular("session", { mode = 384 }))
    value, err, code = file:close()
    assert.is_nil(value)
    assert.are.equal("close failed", err)
    assert.are.equal("close", code)

    local closes = 0
    vim.uv.fs_close = function() closes = closes + 1 return true end
    vim.uv.fs_fstat = function()
      return { type = "file", dev = 1, ino = 3, size = 6 }
    end
    value, err, code = fs.open_regular("session", { mode = 384 })
    assert.is_nil(value)
    assert.matches("identity changed during open", err)
    assert.are.equal("ownership", code)
    assert.are.equal(1, closes)

    vim.uv.fs_lstat = function() return { type = "link" } end
    value, err, code = fs.open_regular("session", { mode = 384 })
    assert.is_nil(value)
    assert.matches("not a regular file", err)
    assert.are.equal("ownership", code)
    assert.has_error(function()
      fs.open_regular("session", { unsupported = true })
    end, "unsupported regular file option unsupported")
  end)

  it("truncates and confirms a file through one descriptor", function()
    local closed = 0
    vim.uv.fs_open = function(path, flags)
      assert.are.equal("file", path)
      assert.are.equal("r+", flags)
      return 8
    end
    vim.uv.fs_ftruncate = function(fd, size)
      assert.are.equal(8, fd)
      assert.are.equal(3, size)
      return true
    end
    vim.uv.fs_fstat = function(fd)
      assert.are.equal(8, fd)
      return { size = 3 }
    end
    vim.uv.fs_close = function(fd)
      assert.are.equal(8, fd)
      closed = closed + 1
      return true
    end

    assert(fs.truncate("file", 3))
    assert.are.equal(1, closed)

    vim.uv.fs_ftruncate = function() return nil, "truncate failed" end
    local ok, err = fs.truncate("file", 3)
    assert.is_nil(ok)
    assert.are.equal("truncate failed", err)
    assert.are.equal(2, closed)

    vim.uv.fs_ftruncate = function() return true end
    vim.uv.fs_fstat = function() return nil, "stat failed" end
    ok, err = fs.truncate("file", 3)
    assert.is_nil(ok)
    assert.are.equal("stat failed", err)

    vim.uv.fs_fstat = function() return { size = 4 } end
    ok, err = fs.truncate("file", 3)
    assert.is_nil(ok)
    assert.matches("unexpected size", err)

    vim.uv.fs_fstat = function() return { size = 3 } end
    vim.uv.fs_close = function() return nil, "close failed" end
    ok, err = fs.truncate("file", 3)
    assert.is_nil(ok)
    assert.are.equal("close failed", err)
    assert.has_error(function() fs.truncate("file", -1) end,
      "truncate size must be a non-negative integer")
  end)

  it("atomically replaces regular files under explicit mode policies", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local existing = vim.fs.joinpath(directory, "existing.txt")
    assert(fs.write_all(existing, "old", "w", 420))
    assert(original.chmod(existing, 384))

    assert(fs.atomic_replace(existing, "updated", {
      preserve_mode = true,
      new_mode = 420,
    }))
    assert.are.equal("updated", assert(fs.read(existing)))
    assert.are.equal(384, bit.band(assert(original.stat(existing)).mode, 511))

    assert(fs.atomic_replace(existing, "owned", { mode = 384 }))
    assert.are.equal("owned", assert(fs.read(existing)))
    assert.are.equal(384, bit.band(assert(original.stat(existing)).mode, 511))

    local created = vim.fs.joinpath(directory, "created.txt")
    assert(fs.atomic_replace(created, "new", {
      preserve_mode = true,
      new_mode = 420,
    }))
    local created_mode = bit.band(assert(original.stat(created)).mode, 511)
    assert.are.equal(384, bit.band(created_mode, 384))
    assert.are.equal(0, bit.band(created_mode, bit.bnot(420)))

    local missing = vim.fs.joinpath(directory, "missing.txt")
    local ok, err = fs.atomic_replace(missing, "no", {
      preserve_mode = true,
      new_mode = 420,
      require_existing = true,
    })
    assert.is_nil(ok)
    assert.matches("must already exist", err)
  end)

  it("returns the identity of its atomic replacement candidate", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local target = vim.fs.joinpath(directory, "created.txt")
    local detached = target .. ".detached"
    vim.uv.fs_rename = function(source, destination)
      assert(original.rename(source, destination))
      assert(original.rename(destination, detached))
      assert(fs.write_all(destination, "successor", "wx", 384))
      return true
    end

    local ok, identity = fs.atomic_replace(target, "created", { mode = 384 })
    vim.uv.fs_rename = original.rename

    assert(ok)
    assert.is_table(identity)
    local created = assert(fs.open_regular(detached, { identity = identity }))
    assert.are.equal("created", assert(created:read_all()))
    assert(created:close())
    assert.are.equal("successor", assert(fs.read(target)))
  end)

  it("rejects unconfirmed atomic replacement candidates", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local target = vim.fs.joinpath(directory, "created.txt")
    local function rejected(pattern)
      local ok, err = fs.atomic_replace(target, "data", { mode = 384 })
      assert.is_nil(ok)
      assert.matches(pattern, err)
      assert.are.same({}, vim.fn.glob(target .. ".*.tmp", false, true))
    end

    vim.uv.fs_fstat = function() return nil, "candidate stat failed" end
    rejected("candidate stat failed")
    vim.uv.fs_fstat = function()
      return { type = "directory", dev = 1, ino = 2, size = 4, mode = 384 }
    end
    rejected("not a regular file")
    vim.uv.fs_fstat = function()
      return { type = "file", dev = 1, ino = 2, size = 3, mode = 384 }
    end
    rejected("unexpected size")
    vim.uv.fs_fstat = function()
      return { type = "file", dev = 1, ino = 2, size = 4,
        mode = jit.os == "Windows" and 292 or 420 }
    end
    rejected("unexpected mode")

    vim.uv.fs_fstat = original.fstat
    vim.uv.fs_write = function(_, data) return #data + 1 end
    rejected("invalid write length")
    vim.uv.fs_write = original.write
    vim.uv.fs_close = function(fd)
      assert(original.close(fd))
      return nil, "candidate close failed"
    end
    rejected("candidate close failed")

    vim.uv.fs_close = original.close
    vim.uv.fs_fstat = function(fd)
      local stat = assert(original.fstat(fd))
      stat.dev = stat.dev + 1
      return stat
    end
    local candidate_inspections = 0
    vim.uv.fs_lstat = function(path)
      local stat, err, code = original.lstat(path)
      if path ~= target and stat then
        candidate_inspections = candidate_inspections + 1
        if candidate_inspections > 1 then stat.dev = stat.dev + 1 end
      end
      return stat, err, code
    end
    rejected("candidate identity changed")
  end)

  it("rejects symlinks and cleans temporary files after rename failure", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local target = vim.fs.joinpath(directory, "target.txt")
    local link = vim.fs.joinpath(directory, "link.txt")
    assert(fs.write_all(target, "original", "w", 420))
    assert(vim.uv.fs_symlink(target, link))

    local ok, err = fs.atomic_replace(link, "changed", {
      preserve_mode = true,
      new_mode = 420,
    })
    assert.is_nil(ok)
    assert.matches("symbolic link", err)
    assert.are.equal("original", assert(fs.read(target)))

    local temporary
    vim.uv.fs_rename = function(source, destination)
      temporary = source
      assert.are.equal(target, destination)
      return nil, "rename failed"
    end
    ok, err = fs.atomic_replace(target, "changed", {
      preserve_mode = true,
      new_mode = 420,
    })
    assert.is_nil(ok)
    assert.matches("rename failed", err)
    assert.is_not_nil(temporary)
    assert.is_nil(original.lstat(temporary))
    assert.are.equal("original", assert(fs.read(target)))
  end)

  it("validates atomic replacement policy and preparation failures", function()
    for _, policy in ipairs({
      false,
      {},
      { unknown = true },
      { mode = "0600" },
      { mode = 512 },
      { mode = 384, preserve_mode = true },
      { mode = 384, new_mode = 420 },
      { preserve_mode = true },
      { preserve_mode = "yes", new_mode = 420 },
      { preserve_mode = true, new_mode = -1 },
      { mode = 384, require_existing = "yes" },
    }) do
      assert.has_error(function()
        fs.atomic_replace("file", "data", policy)
      end)
    end

    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local target = vim.fs.joinpath(directory, "target")
    local result, err = fs.atomic_replace(directory, "data", { mode = 384 })
    assert.is_nil(result)
    assert.matches("not a regular file", err)

    vim.uv.fs_lstat = function() return nil, "EACCES: denied", "EACCES" end
    result, err = fs.atomic_replace(target, "data", { mode = 384 })
    assert.is_nil(result)
    assert.matches("denied", err)
    vim.uv.fs_lstat = original.lstat

    vim.uv.random = function() return nil, "entropy failed" end
    result, err = fs.atomic_replace(target, "data", { mode = 384 })
    assert.is_nil(result)
    assert.matches("entropy failed", err)
  end)

  it("cleans atomic candidates after write, mode, and target races", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local target = vim.fs.joinpath(directory, "target.txt")
    assert(fs.write_all(target, "original", "w", 420))

    local temporary
    vim.uv.fs_open = function(path)
      temporary = path
      return nil, "open failed"
    end
    local result, err = fs.atomic_replace(target, "data", {
      preserve_mode = true, new_mode = 420,
    })
    assert.is_nil(result)
    assert.matches("open failed", err)
    assert.is_nil(original.lstat(temporary))
    vim.uv.fs_open = original.open

    vim.uv.fs_fchmod = function()
      return nil, "chmod failed"
    end
    result, err = fs.atomic_replace(target, "data", {
      preserve_mode = true, new_mode = 420,
    })
    assert.is_nil(result)
    assert.matches("chmod failed", err)
    assert.is_nil(original.lstat(temporary))
    vim.uv.fs_fchmod = original.fchmod

    local function race(value, race_err, race_code, pattern, policy)
      local calls = 0
      vim.uv.fs_lstat = function(path)
        if path ~= target then return original.lstat(path) end
        calls = calls + 1
        if calls == 1 then return original.lstat(path) end
        return value, race_err, race_code
      end
      local ok, failure = fs.atomic_replace(target, "data", policy or {
        preserve_mode = true, new_mode = 420,
      })
      vim.uv.fs_lstat = original.lstat
      assert.is_nil(ok)
      assert.matches(pattern, failure)
      assert.are.same({}, vim.fn.glob(target .. ".*.tmp", false, true))
      assert.are.equal("original", assert(fs.read(target)))
    end
    race(nil, "EACCES: changed", "EACCES", "changed")
    race({ type = "link" }, nil, nil, "symbolic link")
    race({ type = "directory" }, nil, nil, "not a regular file")
    race(nil, "ENOENT", "ENOENT", "must already exist", {
      preserve_mode = true, new_mode = 420, require_existing = true,
    })
  end)

  it("rejects target identity, mode, and content changes during preparation", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local target = vim.fs.joinpath(directory, "target.txt")
    assert(fs.write_all(target, "original", "w", 384))

    local function race(mutator, policy)
      local inspections = 0
      vim.uv.fs_lstat = function(path)
        if path == target then
          inspections = inspections + 1
          if inspections == 2 then mutator() end
        end
        return original.lstat(path)
      end
      local ok, err, stage = fs.atomic_replace(target, "replacement",
        policy or { preserve_mode = true, new_mode = 420 })
      vim.uv.fs_lstat = original.lstat
      assert.is_nil(ok)
      assert.are.equal("target_changed", stage)
      assert.are.same({}, vim.fn.glob(target .. ".*.tmp", false, true))
      return err
    end

    local err = race(function() assert(original.chmod(target, 420)) end)
    assert.matches("target changed", err)
    assert.are.equal("original", assert(fs.read(target)))
    assert(original.chmod(target, 384))

    local retained = assert(original.open(target, "r", 384))
    err = race(function()
      assert(original.unlink(target))
      assert(fs.write_all(target, "successor", "wx", 384))
    end)
    assert(original.close(retained))
    assert.matches("target changed", err)
    assert.are.equal("successor", assert(fs.read(target)))

    assert(fs.write_all(target, "original", "w", 384))
    err = race(function()
      assert(fs.write_all(target, "concurrent", "w", 384))
    end, {
      preserve_mode = true,
      new_mode = 420,
      expected_content_fingerprint = fs.content_fingerprint("original"),
    })
    assert.matches("content changed", err)
    assert.are.equal("concurrent", assert(fs.read(target)))
  end)

  it("detects every target change while fingerprinting replacement content", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local target = vim.fs.joinpath(directory, "target.txt")
    assert(fs.write_all(target, "original", "w", 384))
    local expected = fs.content_fingerprint("original")

    local function rejected(stage)
      local verification_fd
      local target_inspections = 0
      local verification_stats = 0
      vim.uv.fs_open = function(path, flags, mode)
        local fd, err = original.open(path, flags, mode)
        if path == target and flags == "r" then verification_fd = fd end
        return fd, err
      end
      vim.uv.fs_fstat = function(fd)
        local stat, err = original.fstat(fd)
        if fd == verification_fd then
          verification_stats = verification_stats + 1
          if stage == "initial identity" and verification_stats == 1
              or stage == "confirmed identity" and verification_stats == 2 then
            stat.ino = stat.ino + 1
          end
        end
        return stat, err
      end
      vim.uv.fs_lstat = function(path)
        local stat, err, code = original.lstat(path)
        if path == target then
          target_inspections = target_inspections + 1
          if target_inspections == 3 then
            if stage == "final inspection" then
              return nil, "final inspection denied", "EACCES"
            elseif stage == "final identity" then
              stat.ino = stat.ino + 1
            end
          end
        end
        return stat, err, code
      end
      local ok, err, code = fs.atomic_replace(target, "replacement", {
        preserve_mode = true,
        new_mode = 420,
        expected_content_fingerprint = expected,
      })
      vim.uv.fs_open = original.open
      vim.uv.fs_fstat = original.fstat
      vim.uv.fs_lstat = original.lstat
      assert.is_nil(ok)
      assert.are.equal("target_changed", code)
      assert.matches(stage == "final inspection" and "inspection denied"
        or "content verification", err)
      assert.are.same({}, vim.fn.glob(target .. ".*.tmp", false, true))
    end

    for _, stage in ipairs({
      "initial identity", "confirmed identity", "final inspection",
      "final identity",
    }) do
      rejected(stage)
    end

    local missing = vim.fs.joinpath(directory, "missing.txt")
    local ok, err, code = fs.atomic_replace(missing, "replacement", {
      mode = 384,
      expected_content_fingerprint = expected,
    })
    assert.is_nil(ok)
    assert.are.equal("target_changed", code)
    assert.matches("content is missing", err)
    assert.are.same({}, vim.fn.glob(missing .. ".*.tmp", false, true))
  end)

  it("verifies newly created private directory permissions", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local ok, created = fs.ensure_private_directory(directory, 448)
    assert.is_true(ok)
    assert.is_true(created)
    assert.are.equal(448,
      bit.band(assert(original.lstat(directory)).mode, 511))
    assert.are.same({ true, false }, {
      fs.ensure_private_directory(directory, 448),
    })

    local denied = vim.fn.tempname()
    paths[#paths + 1] = denied
    vim.uv.fs_chmod = function(candidate)
      if candidate == denied then return nil, "chmod denied" end
      return original.chmod(candidate, 448)
    end
    local prepared, err = fs.ensure_private_directory(denied, 448)
    vim.uv.fs_chmod = original.chmod
    assert.is_nil(prepared)
    assert.matches("chmod denied", err)

    vim.uv.fs_lstat = function()
      return nil, "inspection denied", "EACCES"
    end
    prepared, err = fs.ensure_private_directory("denied", 448)
    assert.is_nil(prepared)
    assert.matches("inspection denied", err)

    local inspections = 0
    vim.uv.fs_lstat = function()
      inspections = inspections + 1
      if inspections == 1 then return nil, "ENOENT", "ENOENT" end
      return { type = "file", mode = 448 }
    end
    vim.fn.mkdir = function() return 1 end
    prepared, err = fs.ensure_private_directory("changed", 448)
    assert.is_nil(prepared)
    assert.matches("not a directory", err)

    inspections = 0
    vim.uv.fs_lstat = function()
      inspections = inspections + 1
      if inspections == 1 then return nil, "ENOENT", "ENOENT" end
      if inspections == 2 then return { type = "directory", mode = 448 } end
      return { type = "directory", mode = 420 }
    end
    vim.uv.fs_chmod = function() return true end
    prepared, err = fs.ensure_private_directory("wrong-mode", 448)
    assert.is_nil(prepared)
    assert.matches("unexpected permission mode", err)
  end)
end)
