local assert = require("luassert")
local helper = require("tests.helpers.subprocess")

describe("sandbox worker lease admission", function()
  for _, missing in ipairs({ "start", "wait_ready", "write", "close_stdin", "terminate", "wait", "dispose", "is_released", "wait_release" }) do
    it("rejects a worker missing " .. missing .. " before allocating native resources", function()
      local started = false
      local root = assert(vim.uv.cwd())
      local factory = require("neoagent.sandbox.process_session").factory(require("neoagent.sandbox.placement").new({
        profile = {
          id = "lease-admission", filesystem = { default = "read", entries = {} },
          network = "restricted", environment = { clear = false, inherit = {}, set = {} },
        },
        platform = {
          name = "test", check = function() return { ok = true, platform = "test" } end,
          create_worker = function(request)
            local lease = require("neoagent.rpc.worker_lease").new(request)
            local start = lease.start
            function lease:start() started = true; start(self) end
            rawset(lease, missing, false)
            return lease
          end,
        },
        nvim = vim.env.NEOAGENT_NVIM,
      }), {})
      local owner = require("neoagent.process_sessions").new({ capacity = 1 }, nil, factory)
      local result = helper.complete(function()
        return helper.admit(owner, {
          argv = { assert(vim.env.NEOAGENT_NVIM), "--headless", "-u", "NONE", "-i", "NONE", "-c", "sleep 30" },
          cwd = root, stdio = { kind = "pipes" },
        }, 0)
      end)
      owner:close("test complete")
      assert.matches("invalid worker lease", assert(result.error).message, 1, true)
      assert.is_false(started)
      assert.is_true(helper.complete(function() return owner:wait_cleanup(1000) end))
      assert.is_true(helper.complete(function() return owner:wait_release(1000) end))
      assert.are.equal(0, owner:status().reserved)
    end)
  end
end)
