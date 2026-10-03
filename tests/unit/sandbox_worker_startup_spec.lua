local assert = require("luassert")
local fs = require("neoagent.fs")
local helper = require("tests.helpers.subprocess")
local linux = require("neoagent.sandbox.linux")

describe("sandbox failed-start ownership", function()
  if jit.os ~= "Linux" then
    pending("Linux sandbox staging ownership")
    return
  end

  local new_timer, spawn, rmdir = vim.uv.new_timer, vim.uv.spawn, vim.uv.fs_rmdir
  ---@type string
  local directory
  ---@type string?
  local staging
  ---@type Neoagent.WorkerLease?
  local lease
  ---@type Neoagent.WorkerResult[]
  local exits
  local removals, cleanup_denied

  before_each(function()
    directory = vim.fn.tempname()
    assert(fs.mkdirp(directory))
    staging, lease = nil, nil
    exits, removals = {}, 0
    cleanup_denied = false
    vim.uv.fs_rmdir = function(path)
      if path == staging then
        removals = removals + 1
        if cleanup_denied then
          return nil, "EACCES: staging removal denied", "EACCES"
        end
      end
      return rmdir(path)
    end
  end)

  after_each(function()
    vim.uv.new_timer, vim.uv.spawn, vim.uv.fs_rmdir = new_timer, spawn, rmdir
    if lease then
      lease:dispose("startup regression complete")
      helper.complete(function()
        return assert(lease):wait()
      end)
    elseif staging and vim.uv.fs_stat(staging) then
      -- A failed assertion against the old implementation can leave its
      -- detached native cleanup in flight. Let its callback complete first.
      vim.wait(5000, function()
        return #exits > 0
      end, 5)
    end
    if staging then
      vim.fn.delete(staging, "rf")
    end
    vim.fn.delete(directory, "rf")
  end)

  ---@param grace? integer
  local function launch(grace)
    ---@type Neoagent.SandboxFilesystemService
    local filesystem = vim.tbl_extend("force", fs, {
      create_temp_directory = function(prefix, parent)
        staging = assert(fs.create_temp_directory(prefix, parent))
        return staging
      end,
    })
    lease = linux.start_worker({
      argv = { "/bin/sh", "-c", "true" },
      cwd = directory,
      env = { PATH = "/bin:/usr/bin" },
      kill_grace_ms = grace,
      profile = assert(require("neoagent.sandbox.profile").validate({
        id = "startup-regression",
        filesystem = { default = "read", entries = { { path = directory, access = "write" } } },
        network = "restricted",
        environment = { clear = true, inherit = {}, set = { PATH = "/bin:/usr/bin" } },
      })),
      on_exit = function(result)
        exits[#exits + 1] = result
      end,
    }, {
      nvim = vim.env.NEOAGENT_NVIM,
      fs = filesystem,
    })
    return lease
  end

  it("keeps timer-allocation failure and removes its staging root once", function()
    vim.uv.new_timer = function()
      error("startup timer unavailable")
    end
    local ok, value = pcall(launch)
    vim.uv.new_timer = new_timer
    assert.is_true(ok, vim.inspect(value))
    local readiness = helper.complete(function()
      return assert(assert(lease).wait_ready)(assert(lease))
    end)
    assert.is_false(readiness.ok)
    local err = assert(readiness.error)
    assert.are.equal("worker_start", err.kind)
    assert.matches("startup timer unavailable", tostring(err.detail), 1, true)
    local result = helper.complete(function()
      return assert(lease):wait()
    end)
    assert.are.equal("", result.stderr)
    assert.are.equal("worker_start", assert(result.error).kind)
    assert.are.equal(1, #exits)
    assert.are.equal(1, removals)
    assert.is_nil(vim.uv.fs_stat(assert(staging)))
  end)

  it("retains staging until partial native startup cleanup completes", function()
    vim.uv.spawn = function()
      return nil, "injected launch failure", "EACCES"
    end
    local ok, value = pcall(launch)
    vim.uv.spawn = spawn
    assert.is_not_nil(vim.uv.fs_stat(assert(staging)))
    assert.are.equal(0, removals)
    assert.are.equal(0, #exits)
    assert.is_true(ok, vim.inspect(value))
    local readiness = helper.complete(function()
      return assert(assert(lease).wait_ready)(assert(lease))
    end)
    assert.is_false(readiness.ok)
    local err = assert(readiness.error)
    assert.are.equal("worker_start", err.kind)
    assert.matches("EACCES", tostring(err.detail), 1, true)
    local result = helper.complete(function()
      return assert(lease):wait()
    end)
    assert.are.equal("", result.stderr)
    assert.are.equal("worker_start", assert(result.error).kind)
    assert.are.equal(1, #exits)
    assert.are.equal(1, removals)
    assert.is_nil(vim.uv.fs_stat(assert(staging)))
  end)

  it("cleans rejected requests before any worker owns native resources", function()
    local err = helper.failure(function()
      launch(-1)
    end)
    assert.are.equal("sandbox_unavailable", err.kind)
    assert.matches("worker kill grace", tostring(err.detail), 1, true)
    assert.are.equal(0, #exits)
    assert.are.equal(1, removals)
    assert.is_nil(vim.uv.fs_stat(assert(staging)))
  end)

  for _, partial in ipairs({ false, true }) do
    it("reports staging cleanup failure after failed startup with partial allocation=" .. tostring(partial), function()
      cleanup_denied = true
      if partial then
        vim.uv.spawn = function()
          return nil, "injected launch failure", "EACCES"
        end
      else
        vim.uv.new_timer = function()
          error("startup timer unavailable")
        end
      end
      launch()
      vim.uv.new_timer, vim.uv.spawn = new_timer, spawn
      local readiness = helper.complete(function()
        return assert(assert(lease).wait_ready)(assert(lease))
      end)
      local startup_error = assert(readiness.error)
      assert.are.equal("worker_start", startup_error.kind)
      local result = helper.complete(function()
        return assert(lease):wait()
      end)
      local failure = assert(result.cleanup_error)
      assert.are.equal("sandbox_unavailable", failure.kind)
      assert.are.equal("Could not clean native sandbox resources", failure.message)
      assert.matches("staging removal denied", tostring(failure.detail), 1, true)
      assert.are.same(startup_error, result.error)
      assert.are.same({ result }, exits)
      assert.are.equal(1, removals)
      assert.is_not_nil(vim.uv.fs_stat(assert(staging)))
    end)
  end
end)
