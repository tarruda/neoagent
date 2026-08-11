local async = require("neoagent.async")
local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end, 5))
  return run:result()
end

describe("neoagent file locks", function()
  local paths = {}
  local children = {}

  after_each(function()
    for _, child in ipairs(children) do pcall(child.kill, child, 15) end
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

  it("acquires synchronously after contention and recovers stale locks", function()
    local lock_path = path()
    assert(fs.write_all(lock_path, "held", "wx", 384))
    vim.defer_fn(function() vim.uv.fs_unlink(lock_path) end, 20)
    local lease = assert(file_lock.new({
      path = lock_path,
      timeout_ms = 500,
      poll_ms = 5,
    }):acquire())
    assert.is_not.equal("held", assert(fs.read(lock_path)))
    assert(lease:release())
    assert.is_nil(vim.uv.fs_stat(lock_path))

    assert(fs.write_all(lock_path, "abandoned", "wx", 384))
    local old = os.time() - 121
    assert(vim.uv.fs_utime(lock_path, old, old))
    lease = assert(file_lock.new({ path = lock_path }):acquire())
    assert(lease:release())
  end)

  it("serializes leases across Neovim processes and recovers an abandoned lease", function()
    local lock_path = path()
    local directory = vim.fs.dirname(lock_path)
    local blocked_path = directory .. "/child-blocked"
    local acquired_token_path = directory .. "/child-token"
    local parent = assert(file_lock.new({ path = lock_path }):acquire())
    local parent_token = assert(fs.read(lock_path))
    local script = string.format(
      "local fs=require('neoagent.fs');"
        .. "vim.defer_fn(function() "
        .. "assert(fs.write_all(%q,'blocked','wx',384)) end,0);"
        .. "local lease=assert(require('neoagent.file_lock').new({"
        .. "path=%q,timeout_ms=15000,poll_ms=5}):acquire());"
        .. "assert(fs.write_all(%q,assert(fs.read(%q)),'wx',384))",
      blocked_path, lock_path, acquired_token_path, lock_path)
    local child = vim.system({
      assert(vim.env.NEOAGENT_NVIM), "--headless", "--noplugin",
      "-u", "tests/minimal_init.lua", "-c", "lua " .. script, "-c", "qa",
    }, { text = true, env = { NEOAGENT_COVERAGE = "0" } })
    children[#children + 1] = child

    assert(vim.wait(30000, function()
      return vim.uv.fs_stat(blocked_path) ~= nil
    end, 10), "child did not reach file lock contention")
    assert.is_nil(vim.uv.fs_stat(acquired_token_path))
    assert.are.equal(parent_token, assert(fs.read(lock_path)))

    assert(parent:release())
    local result = child:wait(15000)
    assert.are.equal(0, result.code, vim.inspect(result))
    local child_token = assert(fs.read(acquired_token_path))
    assert.are.equal(child_token, assert(fs.read(lock_path)))
    assert.is_not.equal(parent_token, child_token)

    local old = os.time() - 2
    assert(vim.uv.fs_utime(lock_path, old, old))
    local recovered = assert(file_lock.new({
      path = lock_path,
      timeout_ms = 500,
      poll_ms = 5,
      stale_ms = 100,
    }):acquire())
    assert.is_not.equal(child_token, assert(fs.read(lock_path)))
    assert(recovered:release())
    assert.is_nil(vim.uv.fs_stat(lock_path))
  end)

  it("preserves a successor lock when lease ownership changes", function()
    local lock_path = path()
    local lease = assert(file_lock.new({ path = lock_path }):acquire())
    assert(vim.uv.fs_unlink(lock_path))
    assert(fs.write_all(lock_path, "successor", "wx", 384))
    local released, err = lease:release()
    assert.is_nil(released)
    assert.are.equal("ownership", err.code)
    assert.are.equal("successor", assert(fs.read(lock_path)))

    assert(vim.uv.fs_unlink(lock_path))
    lease = assert(file_lock.new({ path = lock_path }):acquire())
    assert(vim.uv.fs_unlink(lock_path))
    released, err = lease:release()
    assert.is_nil(released)
    assert.are.equal("ownership", err.code)
  end)

  it("releases protected callbacks after success and errors", function()
    local lock_path = path()
    local first, second = file_lock.new({ path = lock_path }):with(function()
      assert.is_not_nil(vim.uv.fs_stat(lock_path))
      return "one", "two"
    end)
    assert.are.same({ "one", "two" }, { first, second })
    assert.is_nil(vim.uv.fs_stat(lock_path))

    local ok, err = pcall(function()
      file_lock.new({ path = lock_path }):with(function() error("callback failed") end)
    end)
    assert.is_false(ok)
    assert.matches("callback failed", err)
    assert.is_nil(vim.uv.fs_stat(lock_path))
  end)

  it("refreshes asynchronous leases and cancels bounded acquisition", function()
    local lock_path = path()
    local acquired = async.run(function()
      local lease = file_lock.new({
        path = lock_path,
        timeout_ms = 500,
        poll_ms = 5,
        stale_ms = 100,
        refresh_ms = 10,
      }):acquire_async()
      return { ok = true, lease = lease }
    end, { error_kind = "file_lock" })
    local result = wait(acquired)
    assert.is_true(result.ok)
    local old = os.time() - 121
    assert(vim.uv.fs_utime(lock_path, old, old))
    assert(vim.wait(500, function()
      local stat = vim.uv.fs_stat(lock_path)
      return stat and stat.mtime.sec > old
    end, 5))
    assert(result.lease:release())

    assert(fs.write_all(lock_path, "held", "wx", 384))
    local blocked = async.run(function()
      file_lock.new({ path = lock_path }):acquire_async()
      return { ok = true }
    end, { error_kind = "file_lock" })
    assert.is_false(vim.wait(50, function() return blocked:is_done() end, 5))
    blocked:cancel()
    assert.are.equal("cancelled", wait(blocked).error.kind)
  end)

  it("reports heartbeat setup, ownership, and refresh failures", function()
    local lock_path = path()
    local original_new_timer = vim.uv.new_timer
    vim.uv.new_timer = function() return nil end
    local lease = assert(file_lock.new({
      path = lock_path,
      refresh_ms = 10,
    }):acquire())
    vim.uv.new_timer = original_new_timer
    local released, err = lease:release()
    assert.is_nil(released)
    assert.are.equal("refresh", err.code)

    local acquired = async.run(function()
      return { ok = true, lease = file_lock.new({
        path = lock_path,
        refresh_ms = 10,
      }):acquire_async() }
    end, { error_kind = "file_lock" })
    lease = wait(acquired).lease
    local original_read = fs.read
    local reads = 0
    fs.read = function(candidate, ...)
      if candidate == lock_path then
        reads = reads + 1
        return "changed owner"
      end
      return original_read(candidate, ...)
    end
    assert(vim.wait(500, function() return reads > 0 end, 5))
    fs.read = original_read
    released, err = lease:release()
    assert.is_nil(released)
    assert.are.equal("ownership", err.code)

    local original_utime = vim.uv.fs_utime
    local refreshes = 0
    vim.uv.fs_utime = function(candidate, ...)
      if candidate == lock_path then
        refreshes = refreshes + 1
        return nil, "EACCES: denied"
      end
      return original_utime(candidate, ...)
    end
    acquired = async.run(function()
      return { ok = true, lease = file_lock.new({
        path = lock_path,
        refresh_ms = 10,
      }):acquire_async() }
    end, { error_kind = "file_lock" })
    lease = wait(acquired).lease
    assert(vim.wait(500, function() return refreshes > 0 end, 5))
    vim.uv.fs_utime = original_utime
    released, err = lease:release()
    assert.is_nil(released)
    assert.are.equal("refresh", err.code)

    vim.uv.new_timer = function() return nil end
    local failed = async.run(function()
      file_lock.new({ path = lock_path }):acquire_async()
      return { ok = true }
    end, { error_kind = "file_lock" })
    vim.uv.new_timer = original_new_timer
    assert.are.equal("acquire", wait(failed).error.code)
  end)

  it("normalizes unexpected and inspection filesystem failures", function()
    local lock_path = path()
    local original_open = vim.uv.fs_open
    vim.uv.fs_open = function(candidate, ...)
      if candidate == lock_path then error("open exploded") end
      return original_open(candidate, ...)
    end
    local lease, err = file_lock.new({ path = lock_path }):acquire()
    assert.is_nil(lease)
    assert.are.equal("acquire", err.code)
    local failed = async.run(function()
      file_lock.new({ path = lock_path }):acquire_async()
      return { ok = true }
    end, { error_kind = "file_lock" })
    assert.are.equal("acquire", wait(failed).error.code)
    vim.uv.fs_open = original_open

    assert(fs.write_all(lock_path, "held", "wx", 384))
    local original_stat = vim.uv.fs_stat
    vim.uv.fs_stat = function(candidate, ...)
      if candidate == lock_path then return nil, "EACCES: denied" end
      return original_stat(candidate, ...)
    end
    lease, err = file_lock.new({ path = lock_path }):acquire()
    vim.uv.fs_stat = original_stat
    assert.is_nil(lease)
    assert.are.equal("inspect", err.code)

    local old = os.time() - 121
    assert(vim.uv.fs_utime(lock_path, old, old))
    local original_unlink = vim.uv.fs_unlink
    vim.uv.fs_unlink = function(candidate, ...)
      if candidate == lock_path then return nil, "EACCES: denied" end
      return original_unlink(candidate, ...)
    end
    lease, err = file_lock.new({ path = lock_path }):acquire()
    vim.uv.fs_unlink = original_unlink
    assert.is_nil(lease)
    assert.are.equal("recover", err.code)

    assert(vim.uv.fs_unlink(lock_path))
    lease = assert(file_lock.new({ path = lock_path }):acquire())
    local original_read = fs.read
    fs.read = function(candidate, ...)
      if candidate == lock_path then return nil, "EACCES: denied" end
      return original_read(candidate, ...)
    end
    local released
    released, err = lease:release()
    fs.read = original_read
    assert.is_nil(released)
    assert.are.equal("release", err.code)
  end)

  it("reports acquisition, timeout, and release failures", function()
    local lock_path = path()
    assert(fs.write_all(lock_path, "held", "wx", 384))
    local lease, err = file_lock.new({
      path = lock_path,
      timeout_ms = 20,
      poll_ms = 5,
    }):acquire()
    assert.is_nil(lease)
    assert.are.equal("timeout", err.code)
    assert(vim.uv.fs_unlink(lock_path))

    local original_open = vim.uv.fs_open
    vim.uv.fs_open = function(candidate, ...)
      if candidate == lock_path then return nil, "EACCES: denied" end
      return original_open(candidate, ...)
    end
    lease, err = file_lock.new({ path = lock_path }):acquire()
    vim.uv.fs_open = original_open
    assert.is_nil(lease)
    assert.are.equal("open", err.code)

    lease = assert(file_lock.new({ path = lock_path }):acquire())
    local original_unlink = vim.uv.fs_unlink
    vim.uv.fs_unlink = function(candidate, ...)
      if candidate == lock_path then return nil, "EACCES: denied" end
      return original_unlink(candidate, ...)
    end
    local released
    released, err = lease:release()
    vim.uv.fs_unlink = original_unlink
    assert.is_nil(released)
    assert.are.equal("release", err.code)
  end)
end)
