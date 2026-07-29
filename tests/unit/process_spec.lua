local async = require("neoagent.async")
local process = require("neoagent.process")

local function complete(fn, timeout)
  local run = async.run(fn)
  assert(vim.wait(timeout or 3000, function() return run:is_done() end, 5))
  return run:result()
end

describe("neoagent process runner", function()
  it("clears the ambient environment when requested", function()
    local saved = vim.env.NEOAGENT_PROCESS_SECRET
    vim.env.NEOAGENT_PROCESS_SECRET = "hidden"
    local completed = complete(function()
      return process.run({
        "sh", "-c", "printf '%s:%s' \"${SAFE-unset}\" \"${NEOAGENT_PROCESS_SECRET-unset}\"",
      }, {
        clear_env = true,
        env = { SAFE = "visible" },
      })
    end)
    vim.env.NEOAGENT_PROCESS_SECRET = saved
    assert.are.equal(0, completed.code)
    assert.are.equal("visible:unset", completed.stdout)
  end)

  it("escalates timed-out TERM-resistant processes to KILL", function()
    local completed = complete(function()
      return process.run({
        "sh", "-c", "trap '' TERM; while :; do sleep 1; done",
      }, {
        timeout_ms = 20,
        kill_grace_ms = 20,
      })
    end)
    assert.is_true(completed.timed_out)
    assert.are.equal(137, completed.code)

    completed = complete(function()
      return process.run({
        "sh", "-c", "trap '' TERM; while :; do sleep 1; done",
      }, {
        timeout_ms = 20,
        kill_grace_ms = 0,
      })
    end)
    assert.is_true(completed.timed_out)
    assert.are.equal(137, completed.code)
  end)

  it("reports stdout and stderr stream read failures", function()
    local original_system = vim.system
    for _, stream in ipairs({ "stdout", "stderr" }) do
      vim.system = function(_, options)
        options[stream]("stream failed")
        return { kill = function() end }
      end
      local completed = complete(function()
        return process.run({ "true" })
      end)
      assert.is_false(completed.ok)
      assert.are.equal("tool", completed.error.kind)
      assert.matches("Failed reading process " .. stream, completed.error.message)
    end
    vim.system = original_system
  end)
end)
