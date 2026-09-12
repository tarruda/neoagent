local assert = require("luassert")
local async = require("neoagent.async")
local files = require("neoagent.files")
local fs = require("neoagent.fs")
local locks = require("neoagent.file_lock")
local workspace_storage = require("neoagent.workspace_storage")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end), "File publication did not settle")
  return (assert(run:result()))
end

describe("file persistence after uncertain publication", function()
  local original_replace = fs.atomic_replace
  local original_lock = locks.new
  local directories = {}
  ---@type Neoagent.FileLockLease[]
  local leases = {}
  ---@type Neoagent.Run<unknown, unknown>[]
  local runs = {}

  after_each(function()
    fs.atomic_replace, locks.new = original_replace, original_lock
    for _, run in ipairs(runs) do run:cancel() end
    for _, lease in ipairs(leases) do assert(lease:release()) end
    for _, run in ipairs(runs) do wait(run) end
    for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
    directories, leases, runs = {}, {}, {}
  end)

  ---@return Neoagent.WorkspaceStorage
  local function workspace()
    local directory = vim.fn.tempname()
    directories[#directories + 1] = directory
    local value = workspace_storage.new(directory)
    assert(value.prepare())
    return value
  end

  ---@param store Neoagent.Files
  ---@param data string
  ---@return Neoagent.Run<Neoagent.LocalFile, nil>
  local function put(store, data)
    local run = async.run(function()
      local file, err = store.put(data)
      if not file then error(err, 0) end
      return file
    end)
    runs[#runs + 1] = run
    return run
  end

  for _, boundary in ipairs({ "hashing", "lock acquisition" }) do
    it("blocks a blob suspended during " .. boundary .. " before further mutation", function()
      local store = workspace()
      local retained = wait(put(store.files, "retained image"))
      local data = string.rep("pending image", 12000)
      local id = vim.fn.sha256(data)
      local directory = fs.join(store.directory, "files", id)
      local target = fs.join(directory, "content")
      local waiting = false
      local lease
      if boundary == "lock acquisition" then
        assert(fs.ensure_private_directory(directory, 448))
        local lock_path = fs.join(directory, "publish.lock")
        lease = assert(locks.new({ path = lock_path }):acquire())
        leases[#leases + 1] = lease
        locks.new = function(options)
          local lock = original_lock(options)
          if options.path == lock_path then
            local acquire = lock.acquire_async
            ---@async
            function lock:acquire_async()
              waiting = true
              return acquire(self)
            end
          end
          return lock
        end
      end
      local pending = put(store.files, data)
      if lease then assert(vim.wait(5000, function() return waiting end)) end
      assert.is_false(pending:is_done())

      local writes = 0
      fs.atomic_replace = function(path, contents, policy)
        local saved, identity, stage = original_replace(path, contents, policy)
        writes = writes + 1
        if contents == "failed image" then
          assert(saved)
          return nil, "synthetic uncertain attachment publication", "sync"
        end
        return saved, identity, stage
      end
      local failed = wait(put(store.files, "failed image"))
      if lease then assert(lease:release()) end
      local result = wait(pending)
      assert.is_false(failed.ok)
      assert.matches("further writes are blocked", assert(failed.error).message)
      assert.is_false(result.ok, "a suspended writer must observe the Store's failure")
      assert.are.same(failed.error, result.error)
      assert.are.equal(1, writes)
      assert.is_nil((vim.uv.fs_lstat(target)))
      if not lease then assert.is_nil((vim.uv.fs_lstat(directory))) end
      local read = wait(async.run(function()
        return { ok = true, data = files.read(store.files, assert(retained.file_id), assert(retained.bytes)) }
      end))
      assert.are.equal("retained image", read.data)
      if lease then
        local released = assert(original_lock({ path = fs.join(directory, "publish.lock") }):acquire())
        assert(released:release())
      end
    end)
  end

  it("blocks a cache publication that acquired its lock after another publication failed", function()
    local store = workspace()
    local cache = store.file_cache
    ---@param id string
    ---@return Neoagent.FileRecord
    local function record(id)
      return {
        format = "neoagent-provider-file",
        key = vim.fn.sha256("authorization") .. "/" .. vim.fn.sha256(id),
        generation = vim.fn.sha256("generation:" .. id),
        object = { locator = "file-" .. id, state = "ready", lifetime = { kind = "until_deleted" } },
      }
    end
    local first, second, third = record("pending"), record("failed"), record("later")
    ---@param value Neoagent.FileRecord
    ---@return string
    local function path(value)
      return fs.join(store.directory, "provider-cache", value.key .. ".json")
    end
    assert(fs.ensure_private_directory(assert(vim.fs.dirname(path(first))), 448))
    local lease = assert(locks.new({ path = path(first) .. ".lock" }):acquire())
    leases[#leases + 1] = lease
    local pending = async.run(function() return { ok = true, saved = cache:publish(first) } end)
    runs[#runs + 1] = pending
    assert.is_false(pending:is_done())

    local writes = 0
    fs.atomic_replace = function(target, data, policy)
      local saved, identity, stage = original_replace(target, data, policy)
      writes = writes + 1
      if target == path(second) then
        assert(saved)
        return nil, "synthetic uncertain cache publication", "sync"
      end
      return saved, identity, stage
    end
    local failed = wait(async.run(function() return { ok = true, saved = cache:publish(second) } end))
    local later = wait(async.run(function() return { ok = true, saved = cache:publish(third) } end))
    assert(lease:release())
    local result = wait(pending)
    assert.is_false(failed.saved)
    assert.is_false(later.saved, "the failed publication must disable new writes")
    assert.is_false(result.saved, "the waiting publication must observe the same failure")
    assert.are.equal(1, writes)
    assert.is_nil((vim.uv.fs_lstat(path(first))))
    assert.are.same(second, cache:read(second.key))
    local released = assert(locks.new({ path = path(first) .. ".lock" }):acquire())
    assert(released:release())
  end)
end)
