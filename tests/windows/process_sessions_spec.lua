local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local sessions = require("neoagent.process_sessions")

describe("Windows retained process sessions", function()
  if jit.os ~= "Windows" then
    pending("requires native Windows")
    return
  end
  ---@type Neoagent.ProcessSessions
  local owner
  before_each(function()
    owner = sessions.new({ capacity = 1, output_bytes = 1024 })
  end)
  after_each(function()
    owner:close("test complete")
    helper.complete(function() return owner:wait_cleanup(15000) end, 20000)
    assert.is_true(helper.complete(function() return owner:wait_release(15000) end, 20000))
  end)
  for _, terminal in ipairs({ false, true }) do
    it("retains " .. (terminal and "ConPTY" or "pipe") .. " input and native ownership across handoff", function()
      local admission = helper.success(function()
        return owner:prepare({
          argv = { "python", "-u", "-c", "import sys; print('READY', flush=True); print('VALUE=' + sys.stdin.readline(), flush=True)" },
          cwd = assert(vim.uv.cwd()), timeout_ms = 15000,
          stdio = terminal and { kind = "pty", columns = 80, rows = 24 } or { kind = "pipes", stdin = "open" },
        }, 0)
      end, 15000)
      local id = assert(admission.commit())
      local output = admission.result.text
      if not output:find("READY", 1, true) then
        output = output .. helper.success(function() return owner:interact(id, 5000) end, 10000).text
      end
      assert.matches("READY", output, 1, true)
      if terminal then
        helper.success(function() return owner:interact(id, 0, { kind = "resize", columns = 99, rows = 31 }) end)
      end
      local result = helper.success(function()
        -- ConPTY input is terminal input: Enter is CR, not a pipe's LF.
        return owner:interact(id, 1000, { kind = "write", data = terminal and "retained\r" or "retained\n" })
      end)
      output = output .. result.text
      assert(vim.wait(10000, function()
        if not result.done then
          result = helper.success(function() return owner:interact(id, 100) end)
          output = output .. result.text
        end
        return result.done
      end, 5))
      assert.are.equal(0, assert(result.outcome).code, vim.inspect(result))
      assert.matches("VALUE=retained", output, 1, true)
      assert.is_nil(result.error, vim.inspect(result))
      assert.is_nil(result.cleanup_error, vim.inspect(result))
      assert.is_true(helper.complete(function() return owner:wait_release(5000) end, 10000))
      assert.are.equal(0, owner:status().reserved)
    end)
  end
end)
