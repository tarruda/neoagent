local assert = require("luassert")
local async = require("neoagent.async")
local helper = require("tests.helpers.subprocess")
local util = require("neoagent.util")

describe("sandbox worker lease admission", function()
  ---@type Neoagent.ProcessSessions
  local owner
  ---@type Neoagent.ProcessControllerFactory
  local factory
  ---@type Neoagent.WorkerLease?
  local lease
  ---@type table<string, function>
  local methods
  ---@type string
  local omitted
  ---@type Neoagent.Error[]
  local failures
  ---@type Neoagent.AwaitCallbacks<true>?
  local finish_cleanup
  local hold_cleanup, writes = false, 0

  before_each(function()
    lease, finish_cleanup = nil, nil
    methods, failures = {}, {}
    hold_cleanup, writes = false, 0
    owner = require("neoagent.process_sessions").new({ capacity = 1 }, function(err)
      failures[#failures + 1] = err
    end, function(spec, maximum, cleanup, released) return factory(spec, maximum, cleanup, released) end)
  end)

  after_each(function()
    if lease then
      for name, method in pairs(methods) do
        rawset(lease, name, method)
      end
    end
    if finish_cleanup then finish_cleanup.resolve(true) end
    owner:close("test complete")
    helper.complete(function() return owner:wait_cleanup(5000) end)
    helper.complete(function() return owner:wait_release(5000) end)
    if lease then
      lease:dispose("worker admission regression cleanup")
      assert.is_true(helper.complete(function() return assert(lease):wait_release() end))
    end
  end)

  ---@async
  local function prepare()
    local root = assert(vim.uv.cwd())
    factory = require("neoagent.sandbox.process_session").factory(require("neoagent.sandbox.placement").new({
      profile = {
        id = "lease-admission",
        filesystem = { default = "read", entries = {} },
        network = "restricted",
        environment = { clear = false, inherit = {}, set = {} },
      },
      platform = {
        name = "test",
        check = function() return { ok = true, platform = "test" } end,
        start_worker = function(request)
          lease = require("neoagent.rpc.worker_lease").start(request)
          for _, name in ipairs({ "write", "close_stdin", "terminate", "wait", "dispose", "is_released", "wait_release" }) do
            methods[name] = lease[name]
          end
          function lease:write(bytes)
            writes = writes + 1
            return methods.write(self, bytes)
          end
          if hold_cleanup then
            function lease:wait()
              local result = methods.wait(self)
              async.await(function(done) finish_cleanup = done end)
              result.cleanup_error = util.error("process_cleanup", "Rejected worker cleanup failed")
              return result
            end
          end
          rawset(lease, omitted, false)
          return lease
        end,
      },
      nvim = vim.env.NEOAGENT_NVIM,
    }), { context = { workspace = { root = root, cwd = root } } })
    return helper.admit(owner, {
      argv = { assert(vim.env.NEOAGENT_NVIM), "--headless", "-u", "NONE", "-i", "NONE", "-c", "sleep 30" },
      cwd = root,
      stdio = { kind = "pipes" },
    }, 0)
  end

  for _, method in ipairs({ "is_released", "wait_release" }) do
    it("rejects a worker missing " .. method .. " before RPC and retains cleanup ownership", function()
      omitted = method
      local result = helper.complete(prepare)
      local err = assert(result.error, "an incomplete worker lease passed admission")
      assert.are.equal("sandbox_unavailable", err.kind)
      assert.matches("invalid worker lease", err.message, 1, true)
      assert.are.equal(0, writes)
      assert.is_true(helper.complete(function() return owner:wait_cleanup(5000) end))
      if method == "is_released" then
        assert.are.equal(1, owner:status().reserved)
        assert.is_false(owner:status().released)
      else
        assert.is_true(helper.complete(function() return owner:wait_release(5000) end))
        assert.are.equal(0, owner:status().reserved)
      end
    end)
  end

  it("reports rejected worker cleanup independently of the failed admitting Run", function()
    omitted, hold_cleanup = "write", true
    local admitting = async.run(prepare)
    local result = helper.wait(admitting)
    assert.matches("invalid worker lease", assert(result.error).message, 1, true)
    assert(vim.wait(5000, function() return finish_cleanup ~= nil end, 5), "rejected worker cleanup was abandoned")
    assert.are.equal(0, writes)
    assert.are.equal(1, owner:status().reserved)
    assert.are.equal(0, #failures)
    admitting:cancel()
    owner:close("Agent destroyed after failed admission")
    assert(finish_cleanup).resolve(true)
    assert(vim.wait(1000, function() return #failures == 1 end, 5))
    assert.are.equal("Rejected worker cleanup failed", assert(failures[1]).message)
    assert.are.same(failures[1], owner:status().cleanup_error)
    assert.is_true(helper.complete(function() return owner:wait_release(5000) end))
  end)
end)
