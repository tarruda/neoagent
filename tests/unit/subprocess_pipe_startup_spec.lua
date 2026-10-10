local assert = require("luassert")
local helper = require("tests.helpers.subprocess")

describe("native pipe admission ownership", function()
  for _, rejected in ipairs({ "allocation", "attachment", "observation" }) do
    it("settles pipe ownership after native supervisor " .. rejected .. " failure", function()
      local trees = require("neoagent.process.windows")
      local new_tree, platform, spawn = trees.new, jit.os, vim.uv.spawn
      local argv = platform == "Windows" and { vim.fn.exepath("cmd.exe"), "/d", "/s", "/c", "set /p value=" }
        or { vim.fn.exepath("sh"), "-c", "read line" }
      local closed, exited = false, false
      local failures = {}
      local restore_kill
      trees.new = function(options)
        return new_tree({
          callbacks = options.callbacks,
          backend = {
            create = function()
              if rejected == "allocation" then
                return nil, "native Job allocation failed"
              end
              return 1
            end,
            open = function()
              return 2
            end,
            assign = function()
              if rejected == "attachment" then
                return nil, "native Job assignment failed"
              end
              return true
            end,
            running = function()
              return true
            end,
            terminate = function()
              return nil, "native Job termination failed"
            end,
            empty = function()
              return true
            end,
            close = function() end,
          },
        })
      end
      vim.uv.spawn = function(file, options, callback)
        local process, pid, code = spawn(file, options, callback)
        if process and rejected == "observation" then
          local methods = getmetatable(process).__index
          local kill = methods.kill
          restore_kill = function()
            methods.kill = kill
          end
          methods.kill = function(target, signal)
            if signal == 0 then
              return nil, "native observation failed", "EACCES"
            end
            return kill(target, signal)
          end
        end
        return process, pid, code
      end
      jit.os = "Windows"
      local driver = require("neoagent.subprocess.pipe").new(
        {
          argv = argv,
          cwd = assert(vim.uv.cwd()),
          stdio = { kind = "pipes", stdin = "open" },
        },
        assert(vim.uv.os_environ()),
        {
          output = function() end,
          released = function() end,
          exited = function()
            exited = true
          end,
          closed = function()
            closed = true
          end,
          failed = function(code)
            failures[#failures + 1] = code
          end,
        }
      )
      local ok, failure = pcall(function()
        local err = helper.failure(function()
          driver.start()
          driver.observe(function()
            error("invalid native observation was accepted")
          end)
        end)
        assert.are.equal("process_supervision", err.code)
        assert.is_true(driver.kill())
      end)
      jit.os, trees.new, vim.uv.spawn = platform, new_tree, spawn
      if restore_kill then
        restore_kill()
      end
      driver.kill()
      local drained = vim.wait(2000, function()
        return closed
      end, 5)
      driver.dispose()
      assert.is_true(drained, "failed native admission left unobserved pipes open")
      assert.are.equal(rejected ~= "allocation", exited)
      if rejected == "attachment" then
        assert.are.same({ "process_supervision" }, failures)
      end
      assert.is_true(ok, vim.inspect(failure))
    end)
  end
end)
