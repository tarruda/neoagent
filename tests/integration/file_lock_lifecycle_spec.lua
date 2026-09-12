local assert = require("luassert")
local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")

describe("native file lock ownership across processes", function()
  ---@type string
  local directory
  ---@type table<vim.SystemObj, boolean>
  local children = {}
  ---@type Neoagent.FileLockLease[]
  local leases = {}

  before_each(function()
    directory = vim.fn.tempname() .. "-néo-lock"
    assert(fs.mkdirp(directory))
  end)

  after_each(function()
    for _, lease in ipairs(leases) do lease:release() end
    for process in pairs(children) do pcall(process.kill, process, 9) end
    for process in pairs(children) do pcall(process.wait, process, 5000) end
    leases, children = {}, {}
    vim.fn.delete(directory, "rf")
  end)

  ---@param script string
  ---@return vim.SystemObj
  local function child(script)
    local process = vim.system({ assert(vim.env.NEOAGENT_NVIM), "--headless", "--noplugin",
      "-u", "tests/minimal_init.lua", "-c", "lua " .. script, "-c", "qa!" }, { text = true })
    children[process] = true
    return process
  end

  ---@param path string
  local function await_file(path)
    assert(vim.wait(15000, function() return vim.uv.fs_stat(path) ~= nil end, 5), "Missing lifecycle marker: " .. path)
  end

  it("observes contention before handing a stable native lock to another process", function()
    local path = fs.join(directory, "resource.lock")
    local blocked = fs.join(directory, "blocked")
    local acquired = fs.join(directory, "acquired")
    local parent = assert(file_lock.new({ path = path }):acquire())
    leases[#leases + 1] = parent
    local identity = assert(vim.uv.fs_lstat(path))
    local contender = child(string.format([[
      local fs = require("neoagent.fs")
      local locks = require("neoagent.file_lock")
      local early, err = locks.new({ path = %q, timeout_ms = 20, poll_ms = 2 }):acquire()
      assert(early == nil and err.code == "timeout", "parent's lock did not exclude the child")
      assert(fs.write_all(%q, "blocked", "wx", 384))
      local lease = assert(locks.new({ path = %q, timeout_ms = 15000, poll_ms = 5 }):acquire())
      assert(fs.write_all(%q, "acquired", "wx", 384))
      assert(lease:release())
    ]], path, blocked, path, acquired))
    await_file(blocked)
    assert.is_nil((vim.uv.fs_stat(acquired)))
    assert(parent:release())
    assert(parent:release())
    await_file(acquired)
    local result = contender:wait(15000)
    children[contender] = nil
    assert.are.equal(0, result.code, result.stderr)
    local released = assert(vim.uv.fs_lstat(path))
    assert.are.equal(identity.dev, released.dev)
    assert.are.equal(identity.ino, released.ino)
    assert.are.equal("acquired", assert(fs.read(acquired)))
  end)

  it("releases a dead owner's native lock and serializes both waiting successors", function()
    local path = fs.join(directory, "resource.lock")
    local ready = fs.join(directory, "owner-ready")
    local active = fs.join(directory, "active")
    local stop = fs.join(directory, "stop-owner")
    local owner = child(string.format([[
      local fs = require("neoagent.fs")
      local lease = assert(require("neoagent.file_lock").new({ path = %q }):acquire())
      assert(fs.write_all(%q, "ready", "wx", 384))
      assert(vim.wait(30000, function() return vim.uv.fs_stat(%q) ~= nil end, 5))
      assert(lease:release())
    ]], path, ready, stop))
    await_file(ready)
    local identity = assert(vim.uv.fs_lstat(path))
    local waiters, acquired, gates, blocked = {}, {}, {}, {}
    for id = 1, 2 do
      acquired[id] = fs.join(directory, "acquired-" .. id)
      gates[id] = fs.join(directory, "release-" .. id)
      blocked[id] = fs.join(directory, "blocked-" .. id)
      waiters[id] = child(string.format([[
        local fs = require("neoagent.fs")
        local locks = require("neoagent.file_lock")
        local early, err = locks.new({ path = %q, timeout_ms = 20, poll_ms = 2 }):acquire()
        assert(early == nil and err.code == "timeout", "owner's lock did not exclude the waiter")
        assert(fs.write_all(%q, "blocked", "wx", 384))
        local lease = assert(locks.new({ path = %q, timeout_ms = 15000, poll_ms = 5 }):acquire())
        assert(lease:run(function()
          assert(fs.write_all(%q, "active", "wx", 384))
          assert(fs.write_all(%q, "acquired", "wx", 384))
          assert(vim.wait(15000, function() return vim.uv.fs_stat(%q) ~= nil end, 5))
          assert(vim.uv.fs_unlink(%q))
          return true
        end))
      ]], path, blocked[id], path, active, acquired[id], gates[id], active))
    end
    for _, marker in ipairs(blocked) do await_file(marker) end
    owner:kill(9)
    owner:wait(5000)
    children[owner] = nil
    assert(vim.wait(15000, function()
      return vim.uv.fs_stat(acquired[1]) ~= nil or vim.uv.fs_stat(acquired[2]) ~= nil
    end, 5))
    local first = vim.uv.fs_stat(acquired[1]) ~= nil and 1 or 2
    local second = first == 1 and 2 or 1
    assert.is_nil((vim.uv.fs_stat(acquired[second])))
    assert(fs.write_all(gates[first], "release", "wx", 384))
    await_file(acquired[second])
    assert(fs.write_all(gates[second], "release", "wx", 384))
    for _, waiter in ipairs(waiters) do
      local result = waiter:wait(15000)
      children[waiter] = nil
      assert.are.equal(0, result.code, result.stderr)
    end
    assert.is_nil((vim.uv.fs_stat(active)))
    local released = assert(vim.uv.fs_lstat(path))
    assert.are.equal(identity.dev, released.dev)
    assert.are.equal(identity.ino, released.ino)
  end)
end)
