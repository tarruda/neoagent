local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local subprocess = require("neoagent.subprocess_common")

describe("Windows Job release accounting", function()
  it("retains capacity after root exit until every Job member has terminated", function()
    local trees = require("neoagent.process.windows")
    local pipes = require("neoagent.subprocess.pipe")
    local original, platform = trees.new, jit.os
    local original_pipe = pipes.new
    local empty = false
    local owner = subprocess.scope()
    trees.new = function(options)
      local selected = options or {}
      selected.backend = {
        create = function()
          return 1
        end,
        open = function()
          return 2
        end,
        assign = function()
          return true
        end,
        running = function()
          return false
        end,
        empty = function()
          return empty
        end,
        terminate = function()
          return true
        end,
        close = function() end,
      }
      return original(selected)
    end
    pipes.new = function(...)
      jit.os = "Windows"
      local driver = original_pipe(...)
      jit.os = platform
      local start = driver.start
      driver.start = function()
        jit.os = "Windows"
        local started, result = pcall(start)
        jit.os = platform
        if not started then
          error(result, 0)
        end
        assert(result)
        return true
      end
      return driver
    end
    local handle
    local ok, err = pcall(function()
      local argv = platform == "Windows" and { vim.fn.exepath("cmd.exe"), "/d", "/c", "exit 0" }
        or { vim.fn.exepath("sh"), "-c", "exit 0" }
      handle = owner:spawn(helper.spec("unused", { argv = argv }))
      local result = helper.complete(function()
        return handle:wait()
      end, 5000)
      assert.is_false(
        vim.wait(50, function()
          return owner:is_released()
        end, 5),
        "root exit released capacity without observing the remaining Job members"
      )
      assert.are.equal("process_cleanup", assert(result.error).code)
      assert.is_true(owner:is_settled())
      empty = true
      assert.is_true(helper.complete(function()
        return owner:wait_release(3000)
      end))
      assert.are.equal(
        "process_cleanup",
        assert(helper.complete(function()
          return handle:wait_cleanup()
        end).error).code
      )
    end)
    jit.os, trees.new, pipes.new = platform, original, original_pipe
    empty = true
    owner:close("release regression finished")
    assert.is_true(helper.complete(function()
      return owner:wait_release(3000)
    end))
    assert.is_true(ok, vim.inspect(err))
  end)
end)
