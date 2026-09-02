local async = require("neoagent.async")
local bit = require("bit")
local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end, 5))
  return run:result()
end

describe("neoagent file locks", function()
  local paths = {}
  local children = {}
  local posix = require("neoagent.file_lock.posix")
  local original_backend_new = posix.new

  after_each(function()
    posix.new = original_backend_new
    for child in pairs(children) do pcall(child.kill, child, 9) end
    for child in pairs(children) do pcall(child.wait, child, 1000) end
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
    children = {}
  end)

  local function path()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert(fs.mkdirp(directory))
    return directory .. "/resource.lock"
  end

  local function child(script)
    local value = vim.system({
      assert(vim.env.NEOAGENT_NVIM), "--headless", "--noplugin",
      "-u", "tests/minimal_init.lua", "-c", "lua " .. script,
      "-c", "qa!",
    }, { text = true, env = { NEOAGENT_COVERAGE = "0" } })
    children[value] = true
    return value
  end

  it("reuses one stable regular lock file with restrictive permissions", function()
    local lock_path = path()
    assert(fs.write_all(lock_path, "legacy", "wx", 420))
    local before = assert(vim.uv.fs_lstat(lock_path))
    local lease = assert(file_lock.new({ path = lock_path }):acquire())
    local first_token = assert(fs.read(lock_path))
    assert.is_not.equal("legacy", first_token)
    assert.are.equal(384, bit.band(assert(vim.uv.fs_lstat(lock_path)).mode, 511))
    assert(lease:release())
    local released = assert(vim.uv.fs_lstat(lock_path))
    assert.are.equal(before.dev, released.dev)
    assert.are.equal(before.ino, released.ino)
    assert.are.equal(first_token, assert(fs.read(lock_path)))

    lease = assert(file_lock.new({ path = lock_path }):acquire())
    assert.is_not.equal(first_token, assert(fs.read(lock_path)))
    assert(lease:release())
    assert.is_not_nil(vim.uv.fs_lstat(lock_path))
  end)

  it("serializes leases across Neovim processes", function()
    local lock_path = path()
    local directory = vim.fs.dirname(lock_path)
    local acquired_path = directory .. "/child-acquired"
    local parent = assert(file_lock.new({ path = lock_path }):acquire())
    local process = child(string.format(
      "local fs=require('neoagent.fs');"
        .. "local lease=assert(require('neoagent.file_lock').new({"
        .. "path=%q,timeout_ms=15000,poll_ms=5}):acquire());"
        .. "assert(fs.write_all(%q,'acquired','wx',384));"
        .. "assert(lease:release())",
      lock_path, acquired_path))
    assert.is_false(vim.wait(100, function()
      return vim.uv.fs_stat(acquired_path) ~= nil
    end, 5))
    assert(parent:release())
    local result = process:wait(15000)
    children[process] = nil
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("acquired", assert(fs.read(acquired_path)))
    assert.is_not_nil(vim.uv.fs_lstat(lock_path))
  end)

  it("releases ownership on process death without replacing the path", function()
    local lock_path = path()
    local directory = vim.fs.dirname(lock_path)
    local owner_ready = directory .. "/owner-ready"
    local active_path = directory .. "/active"
    local owner = child(string.format(
      "local fs=require('neoagent.fs');"
        .. "local lease=assert(require('neoagent.file_lock').new({path=%q}):acquire());"
        .. "assert(fs.write_all(%q,'ready','wx',384));"
        .. "vim.wait(30000,function() return false end,10)",
      lock_path, owner_ready))
    assert(vim.wait(5000, function()
      return vim.uv.fs_stat(owner_ready) ~= nil
    end, 5), "owner did not acquire file lock")
    local held = assert(vim.uv.fs_lstat(lock_path))

    local waiters = {}
    for id = 1, 2 do
      waiters[id] = child(string.format(
        "local fs=require('neoagent.fs');"
          .. "local lease=assert(require('neoagent.file_lock').new({"
          .. "path=%q,timeout_ms=15000,poll_ms=5}):acquire());"
          .. "assert(lease:run(function() "
          .. "assert(fs.write_all(%q,%q,'wx',384));"
          .. "vim.wait(50,function() return false end,5);"
          .. "assert(vim.uv.fs_unlink(%q)); return true end))",
        lock_path, active_path, tostring(id), active_path))
    end
    assert.is_false(vim.wait(100, function()
      return vim.uv.fs_stat(active_path) ~= nil
    end, 5))
    owner:kill(9)
    owner:wait(5000)
    children[owner] = nil

    for _, waiter in ipairs(waiters) do
      local result = waiter:wait(15000)
      children[waiter] = nil
      assert.are.equal(0, result.code, vim.inspect(result))
    end
    local current = assert(vim.uv.fs_lstat(lock_path))
    assert.are.equal(held.dev, current.dev)
    assert.are.equal(held.ino, current.ino)
  end)

  it("rejects symbolic links and detects pathname replacement", function()
    local lock_path = path()
    local target = lock_path .. ".target"
    assert(fs.write_all(target, "target", "wx", 384))
    assert(vim.uv.fs_symlink(target, lock_path))
    local lease, err = file_lock.new({ path = lock_path }):acquire()
    assert.is_nil(lease)
    assert.are.equal("target", err.code)
    assert(vim.uv.fs_unlink(lock_path))

    lease = assert(file_lock.new({ path = lock_path }):acquire())
    assert(vim.uv.fs_unlink(lock_path))
    assert(fs.write_all(lock_path, "successor", "wx", 384))
    local released
    released, err = lease:release()
    assert.is_nil(released)
    assert.are.equal("ownership", err.code)
    assert.are.equal("successor", assert(fs.read(lock_path)))
  end)

  it("releases protected callbacks after success and errors", function()
    local lock_path = path()
    local first, second = file_lock.new({ path = lock_path }):with(function()
      return "one", "two"
    end)
    assert.are.same({ "one", "two" }, { first, second })
    assert(file_lock.new({ path = lock_path, timeout_ms = 50 }):with(
      function() return true end))

    local ok, err = pcall(function()
      file_lock.new({ path = lock_path }):with(function()
        error("callback failed")
      end)
    end)
    assert.is_false(ok)
    assert.matches("callback failed", err)
    assert(file_lock.new({ path = lock_path, timeout_ms = 50 }):with(
      function() return true end))
  end)

  it("cancels asynchronous contention and releases scheduled handoffs", function()
    local lock_path = path()
    local holder = assert(file_lock.new({ path = lock_path }):acquire())
    local blocked = async.run(function()
      file_lock.new({ path = lock_path }):acquire_async()
      return { ok = true }
    end, { error_kind = "file_lock" })
    assert.is_false(vim.wait(50, function() return blocked:is_done() end, 5))
    blocked:cancel()
    assert.are.equal("cancelled", wait(blocked).error.kind)

    local util = require("neoagent.util")
    local schedule = util.schedule
    local scheduled = {}
    util.schedule = function(callback) scheduled[#scheduled + 1] = callback end
    local acquired
    local checked, check_err = pcall(function()
      acquired = async.run(function()
        local lease = file_lock.new({
          path = lock_path, timeout_ms = 500, poll_ms = 5,
        }):acquire_async()
        return { ok = true, lease = lease }
      end, { error_kind = "file_lock" })
      assert(holder:release())
      assert(vim.wait(500, function() return #scheduled > 0 end, 5))
      acquired:cancel()
    end)
    util.schedule = schedule
    if not checked then error(check_err, 0) end
    for _, callback in ipairs(scheduled) do callback() end
    assert.are.equal("cancelled", wait(acquired).error.kind)
    assert(file_lock.new({ path = lock_path, timeout_ms = 50 }):with(
      function() return true end))
  end)

  local function fake_backend(config)
    config = config or {}
    local calls = {}
    local handle = {
      try_acquire = function()
        calls[#calls + 1] = "try"
        if config.busy then return false end
        if config.acquire_error then return nil, config.acquire_error end
        return true
      end,
      prepare = function()
        calls[#calls + 1] = "prepare"
        return true
      end,
      write_token = function()
        calls[#calls + 1] = "write"
        return true
      end,
      verify_token = function()
        calls[#calls + 1] = "verify"
        config.verifies = (config.verifies or 0) + 1
        if config.verify_error and config.verifies > 1 then
          return nil, config.verify_error
        end
        return true
      end,
      release = function()
        calls[#calls + 1] = "release"
        if config.release_error then return nil, config.release_error end
        return true
      end,
      close = function()
        calls[#calls + 1] = "close"
        if config.close_error then return nil, config.close_error end
        return true
      end,
    }
    posix.new = function()
      return {
        open = function()
          calls[#calls + 1] = "open"
          if config.open_error then return nil, config.open_error end
          return handle
        end,
      }
    end
    return calls
  end

  it("closes bounded synchronous and asynchronous contenders", function()
    local lock_path = path()
    local calls = fake_backend({ busy = true })
    local lease, err = file_lock.new({
      path = lock_path, timeout_ms = 10, poll_ms = 2,
    }):acquire()
    assert.is_nil(lease)
    assert.are.equal("timeout", err.code)
    assert.are.equal("close", calls[#calls])

    calls = fake_backend({ busy = true })
    local run = async.run(function()
      file_lock.new({
        path = lock_path, timeout_ms = 10, poll_ms = 2,
      }):acquire_async()
      return { ok = true }
    end, { error_kind = "file_lock" })
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("timeout", result.error.code)
    assert.are.equal("close", calls[#calls])
  end)

  it("reports verification, unlock, close, and backend failures", function()
    local lock_path = path()
    fake_backend({
      verify_error = { code = "ownership", message = "changed" },
    })
    local lease = assert(file_lock.new({ path = lock_path }):acquire())
    local released, err = lease:release()
    assert.is_nil(released)
    assert.are.equal("ownership", err.code)

    fake_backend({
      release_error = { code = "release", message = "unlock failed" },
    })
    lease = assert(file_lock.new({ path = lock_path }):acquire())
    released, err = lease:release()
    assert.is_nil(released)
    assert.are.equal("release", err.code)

    fake_backend({
      close_error = { code = "release", message = "close failed" },
    })
    lease = assert(file_lock.new({ path = lock_path }):acquire())
    released, err = lease:release()
    assert.is_nil(released)
    assert.are.equal("release", err.code)

    fake_backend({
      open_error = { code = "open", message = "open failed" },
    })
    lease, err = file_lock.new({ path = lock_path }):acquire()
    assert.is_nil(lease)
    assert.are.equal("open", err.code)

    fake_backend({
      acquire_error = { code = "lock", message = "lock failed" },
    })
    lease, err = file_lock.new({ path = lock_path }):acquire()
    assert.is_nil(lease)
    assert.are.equal("lock", err.code)
  end)

  it("rejects removed and malformed options", function()
    local lock_path = path()
    assert.has_error(function() file_lock.new({ path = lock_path, stale_ms = 1 }) end)
    assert.has_error(function() file_lock.new({ path = lock_path, refresh_ms = 1 }) end)
    assert.has_error(function() file_lock.new({ path = lock_path, mode = 512 }) end)
    assert.has_error(function() file_lock.new({ path = lock_path, poll_ms = 0 }) end)
  end)

  it("owns Windows locks through one native file handle", function()
    local windows = require("neoagent.file_lock.windows")
    local calls = {}
    local contents = "legacy"
    local ffi = {
      cdef = function() end,
      new = function(name)
        calls[#calls + 1] = "new:" .. name
        if name == "unsigned long[1]" then return { [0] = 0 } end
        return { QuadPart = 0 }
      end,
      cast = function(_, value) return value end,
      string = function(buffer, size)
        return (buffer.value or ""):sub(1, size)
      end,
    }
    local identity = 7
    local failures = {}
    local attributes = 128
    local kernel = {
      GetLastError = function() return failures.error or 5 end,
      CreateFileW = function(path, _, _, _, disposition)
        calls[#calls + 1] = "open:" .. path.path .. ":" .. disposition
        if failures.open or failures.verify_open and disposition == 3 then
          return -1
        end
        return disposition == 4 and 10 or 11
      end,
      MultiByteToWideChar = function(_, _, path, size, encoded)
        if failures.encode then return 0 end
        if encoded then encoded.path = path:sub(1, size) end
        return size
      end,
      CloseHandle = function(native)
        calls[#calls + 1] = "close:" .. native
        if failures.close then return 0 end
        return 1
      end,
      GetFileInformationByHandle = function(native, info)
        if failures.information then return 0 end
        info.dwFileAttributes = attributes
        info.dwVolumeSerialNumber = 1
        info.nFileIndexHigh = 0
        info.nFileIndexLow = native == 10 and 7 or identity
        return 1
      end,
      LockFileEx = function()
        calls[#calls + 1] = "lock"
        if failures.lock then return 0 end
        return 1
      end,
      UnlockFileEx = function()
        calls[#calls + 1] = "unlock"
        if failures.unlock then return 0 end
        return 1
      end,
      SetFilePointerEx = function()
        calls[#calls + 1] = "seek"
        if failures.seek then return 0 end
        return 1
      end,
      SetEndOfFile = function()
        calls[#calls + 1] = "truncate"
        if failures.truncate then return 0 end
        contents = ""
        return 1
      end,
      WriteFile = function(_, value, size, written)
        calls[#calls + 1] = "write"
        if failures.write then return 0 end
        contents = value:sub(1, size)
        written[0] = failures.short_write and size - 1 or size
        return 1
      end,
      ReadFile = function(_, buffer, size, read)
        calls[#calls + 1] = "read"
        if failures.read then return 0 end
        buffer.value = contents:sub(1, size)
        read[0] = #buffer.value
        return 1
      end,
      FlushFileBuffers = function()
        calls[#calls + 1] = "sync"
        if failures.sync then return 0 end
        return 1
      end,
    }
    local uv = {
      fs_chmod = function(path, mode)
        calls[#calls + 1] = "chmod:" .. path .. ":" .. mode
        if failures.chmod then return nil, "chmod failed" end
        return true
      end,
    }
    local backend = windows.new({
      ffi = ffi,
      kernel = kernel,
      uv = uv,
    })
    local handle = assert(backend:open("C:\\state.lock", 384))
    assert.is_true(handle:try_acquire())
    assert(handle:prepare(384))
    assert(handle:write_token("token"))
    assert(handle:verify_token("token"))
    assert(handle:release())
    assert(handle:close())
    assert.is_true(vim.tbl_contains(calls, "lock"))
    assert.is_true(vim.tbl_contains(calls, "unlock"))
    assert.is_true(vim.tbl_contains(calls, "close:10"))
    assert.is_false(vim.tbl_contains(calls, "open:a+"))

    handle = assert(backend:open("C:\\state.lock", 384))
    identity = 8
    local verified, err = handle:verify_token("token")
    assert.is_nil(verified)
    assert.are.equal("ownership", err.code)
    assert(handle:close())

    identity = 7
    failures.encode = true
    local opened
    opened, err = backend:open("C:\\state.lock", 384)
    assert.is_nil(opened)
    assert.are.equal("open", err.code)
    failures.encode = nil

    failures.open = true
    opened, err = backend:open("C:\\state.lock", 384)
    assert.is_nil(opened)
    assert.are.equal("open", err.code)
    failures.open = nil

    attributes = 1024
    opened, err = backend:open("C:\\state.lock", 384)
    assert.is_nil(opened)
    assert.are.equal("target", err.code)
    attributes = 128

    failures.information = true
    opened, err = backend:open("C:\\state.lock", 384)
    assert.is_nil(opened)
    assert.are.equal("open", err.code)
    failures.information = nil

    failures.verify_open = true
    opened, err = backend:open("C:\\state.lock", 384)
    assert.is_nil(opened)
    assert.are.equal("ownership", err.code)
    failures.verify_open = nil

    handle = assert(backend:open("C:\\state.lock", 384))
    failures.chmod = true
    local prepared
    prepared, err = handle:prepare(384)
    assert.is_nil(prepared)
    assert.are.equal("mode", err.code)
    failures.chmod = nil
    assert(handle:close())

    handle = assert(backend:open("C:\\state.lock", 384))
    failures.lock = true
    failures.error = 33
    assert.is_false(handle:try_acquire())
    failures.error = 5
    local acquired
    acquired, err = handle:try_acquire()
    assert.is_nil(acquired)
    assert.are.equal("lock", err.code)
    failures.lock = nil
    failures.error = nil
    assert(handle:close())

    for _, failure in ipairs({
      "seek", "truncate", "write", "short_write", "sync",
    }) do
      handle = assert(backend:open("C:\\state.lock", 384))
      failures[failure] = true
      local written
      written, err = handle:write_token("token")
      assert.is_nil(written)
      assert.are.equal("write", err.code)
      failures[failure] = nil
      assert(handle:close())
    end

    handle = assert(backend:open("C:\\state.lock", 384))
    assert(handle:write_token("token"))
    failures.read = true
    verified, err = handle:verify_token("token")
    assert.is_nil(verified)
    assert.are.equal("release", err.code)
    failures.read = nil
    assert(handle:close())

    handle = assert(backend:open("C:\\state.lock", 384))
    assert.is_true(handle:try_acquire())
    failures.unlock = true
    local released
    released, err = handle:release()
    assert.is_nil(released)
    assert.are.equal("release", err.code)
    failures.unlock = nil
    assert(handle:release())
    assert(handle:close())

    handle = assert(backend:open("C:\\state.lock", 384))
    failures.close = true
    local closed
    closed, err = handle:close()
    assert.is_nil(closed)
    assert.are.equal("release", err.code)
    failures.close = nil
    assert(handle:close())
  end)
end)
