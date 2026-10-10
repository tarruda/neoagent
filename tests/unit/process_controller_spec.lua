local assert = require("luassert")
local async = require("neoagent.async")
local helper = require("tests.helpers.subprocess")
local controllers = require("neoagent.process_sessions.local")

describe("local retained process admission", function()
  for _, throws in ipairs({ false, true }) do
    it("retains process ownership when an observation timer fails with throw=" .. tostring(throws), function()
      local script = "import sys; print(sys.stdin.readline(), end='', flush=True)"
      local controller = controllers.new({
        argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c", script },
        cwd = assert(vim.uv.cwd()), stdio = { kind = "pipes", stdin = "open" },
      }, 64)
      assert.is_true(controller:start())
      local probe = assert(vim.uv.new_timer())
      local methods = getmetatable(probe).__index
      probe:close()
      local start = methods.start
      ---@type uv.uv_timer_t?
      local refused
      methods.start = function(timer, ...)
        refused = timer
        if throws then error("observation timer refused") end
        return nil, "observation timer refused"
      end
      local observing = async.run(function() return controller:collect(1000) end)
      methods.start = start
      local checked, err = pcall(function()
        local result = helper.wait(observing)
        assert.matches("observation timer refused", assert(result.error).message, 1, true)
        assert.is_true(assert(refused):is_closing())
        assert.is_false(controller:state().done)
        controller:control({ kind = "write", data = "still-owned\n" })
        local output = helper.success(function() return controller:collect(3000, true) end)
        assert.are.equal("still-owned\n", (assert(output.events[1]).data:gsub("\r\n", "\n")))
      end)
      observing:cancel()
      controller:dispose("test complete")
      helper.complete(function() return controller:wait_cleanup() end)
      assert(vim.wait(2000, function() return controller:state().released end, 5))
      assert.is_true(checked, vim.inspect(err))
    end)
  end

  it("releases a revoked constructor and rejects startup and control without native allocation", function()
    local controller = controllers.new(helper.spec("unused"), 64)
    assert.is_false(controller:state().released)
    controller:dispose("admission revoked")
    assert.is_true(controller:state().done)
    assert.is_true(controller:state().released)
    assert.is_true(helper.complete(function() return controller:wait_cleanup() end))
    local started = helper.complete(function() return controller:start() end)
    assert.are.equal("process_disposed", assert(started.error).code)
    local written = helper.complete(function() return controller:control({ kind = "write", data = "unused" }) end)
    assert.are.equal("process_disposed", assert(written.error).code)
  end)
end)
