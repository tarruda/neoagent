local assert = require("luassert")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")

describe("owned subprocess interruption", function()
  if jit.os == "Windows" then
    pending("native Windows interruption is exercised in tests/windows")
    return
  end
  ---@type Neoagent.SubprocessScope
  local owner
  before_each(function()
    owner = subprocess.scope()
  end)
  after_each(function()
    owner:close("test finished")
    assert.is_true(helper.complete(function()
      return owner:wait(4000)
    end))
  end)

  for _, kind in ipairs({ "pipes", "pty" }) do
    it("lets a " .. kind .. " command catch interruption without starting termination", function()
      local output = ""
      local handle = owner:spawn(
        helper.spec(
          -- A child launched after readiness can consume SIGINT before exec,
          -- leaving the shell's trap deferred until that child exits. Keep the
          -- waiting operation in the shell whose trap we are asserting.
          "trap 'printf interrupted; exit 42' INT; printf ready; while :; do read line; done",
          { stdio = kind == "pty" and { kind = "pty", columns = 80, rows = 24 } or { kind = "pipes", stdin = "open" } }
        ),
        {
          on_output = function(event)
            output = output .. event.data
          end,
        }
      )
      assert(vim.wait(3000, function()
        return output:find("ready", 1, true) ~= nil
      end, 5))
      assert.is_true(handle:interrupt())
      local result = helper.complete(function()
        return handle:wait()
      end)
      assert.are.equal(42, result.code, vim.inspect(result))
      assert.are.equal(0, result.signal)
      assert.is_nil(result.termination_reason)
      assert.is_false(result.timed_out)
      assert.matches("interrupted", output, 1, true)
      assert.are.equal(
        "process_terminal",
        helper.failure(function()
          handle:interrupt()
        end).code
      )
    end)
  end

  it("keeps raw PTY interruption governed by terminal input modes", function()
    local output = ""
    local handle = owner:spawn(
      helper.spec("stty raw -echo; printf ready; dd bs=1 count=1 2>/dev/null", {
        stdio = { kind = "pty", columns = 80, rows = 24 },
      }),
      {
        on_output = function(event)
          output = output .. event.data
        end,
      }
    )
    assert(vim.wait(3000, function()
      return output == "ready"
    end, 5))
    assert.is_true(handle:interrupt())
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("ready\3", output)
  end)

  it("reports a denied native interrupt without ending ownership", function()
    local handle = owner:spawn(helper.spec("exec sleep 30"))
    local kill = vim.uv.kill
    vim.uv.kill = function(pid, signal)
      if signal == 2 then
        return nil, "EPERM", "EPERM"
      end
      return kill(pid, signal)
    end
    local ok, failure = pcall(helper.failure, function()
      handle:interrupt()
    end)
    vim.uv.kill = kill
    assert.is_true(ok, vim.inspect(failure))
    assert.are.equal("process_signal", failure.code)
    assert.are.equal("running", handle:state().phase)
    handle:terminate("test finished")
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal("test finished", result.termination_reason)
  end)
end)
