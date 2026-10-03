local assert = require("luassert")
local helper = require("tests.helpers.subprocess")

-- Exercise Lua boundary decisions with native services injected internally.
-- Actual Windows lookup and Unicode mapping run in tests/windows.
describe("Windows subprocess boundary rules", function()

  it("observes a pipe's native exit before a delayed completion callback", function()
    local windows = require("neoagent.process.windows")
    local spawn, new_tree, platform = vim.uv.spawn, windows.new, jit.os
    local argv = platform == "Windows" and { vim.fn.exepath("cmd.exe"), "/d", "/s", "/c", "set /p value=" }
      or { vim.fn.exepath("sh"), "-c", "read line" }
    ---@type uv.uv_process_t?
    local native_process
    ---@type fun()?
    local complete
    windows.new = function()
      return new_tree({
        backend = {
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
            return true
          end,
          terminate = function()
            return true
          end,
          close = function() end,
        },
      })
    end
    vim.uv.spawn = function(file, options, callback)
      local process, pid, code = spawn(file, options, function(exit_code, signal)
        complete = function()
          callback(exit_code, signal)
        end
      end)
      native_process = process
      return process, pid, code
    end
    local closed = false
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
        exited = function() end,
        closed = function()
          closed = true
        end,
        failed = function(code)
          error(code)
        end,
      }
    )
    local ok, err = pcall(function()
      driver.start()
      driver.observe(function(running)
        assert.is_true(running)
      end)
      driver.close_stdin()
      assert(vim.wait(2000, function()
        return complete ~= nil
      end, 5))
      driver.observe(function(running)
        assert.is_false(running)
      end)
    end)
    jit.os, vim.uv.spawn, windows.new = platform, spawn, new_tree
    if native_process and not complete then
      native_process:kill(9)
      assert(vim.wait(2000, function()
        return complete ~= nil
      end, 5))
    end
    if complete then
      complete()
    end
    driver.dispose()
    driver.observe(function(running)
      assert.is_false(running)
    end)
    assert.is_false(driver.kill())
    assert(vim.wait(2000, function()
      return closed
    end, 5))
    assert.is_true(ok, vim.inspect(err))
  end)

  it("accepts native drive-directory entries in explicit Windows snapshots", function()
    local platform = jit.os
    jit.os = "Windows"
    local ok, err = pcall(function()
      local selected = require("neoagent.subprocess.validate").spec(helper.spec("unused", {
        environment = { inherit = false, set = { ["=C:"] = "C:/work" } },
      }))
      assert.are.equal("C:/work", assert(selected.environment).set["=C:"])
      for _, name in ipairs({ "=C:extra", "a=b", "=invalid" }) do
        assert.are.equal(
          "process_validation",
          helper.failure(function()
            require("neoagent.subprocess.validate").spec(helper.spec("unused", {
              environment = { inherit = false, set = { [name] = "value" } },
            }))
          end).code
        )
      end
    end)
    jit.os = platform
    assert.is_true(ok, vim.inspect(err))
  end)

  it("uses native name equivalence for inherited overrides and duplicate rejection", function()
    local platform, inherited = jit.os, vim.env["éVAR"]
    local module = "neoagent.subprocess.windows_environment"
    local original = package.loaded[module]
    package.loaded[module] = {
      key = function(name)
        return (name:gsub("é", "É"):upper())
      end,
    }
    jit.os = "Windows"
    vim.env["éVAR"] = "inherited"
    local ok, err = pcall(function()
      local environment = require("neoagent.subprocess.environment")
      local selected = environment.normalize({ inherit = true, set = { ["ÉVAR"] = "replacement" } })
      assert.are.equal("replacement", selected["ÉVAR"])
      assert.is_nil(selected["éVAR"])
      assert.are.equal(
        "process_validation",
        helper.failure(function()
          environment.normalize({ inherit = true, set = { ["éVAR"] = "one", ["ÉVAR"] = "two" } })
        end).code
      )
    end)
    jit.os, vim.env["éVAR"], package.loaded[module] = platform, inherited, original
    assert.is_true(ok, vim.inspect(err))
  end)

  it("requires empty inherited native additions in an exact Windows environment", function()
    local platform, original_temp = jit.os, vim.uv.os_getenv("TEMP")
    local module = "neoagent.subprocess.windows_environment"
    local original = package.loaded[module]
    package.loaded[module] = { key = string.upper }
    jit.os = "Windows"
    assert(vim.uv.os_setenv("TEMP", ""))
    local ok, err = pcall(function()
      local environment = require("neoagent.subprocess.environment")
      local exact = environment.normalize({ inherit = true, set = {} })
      exact.TEMP = nil
      assert.are.equal(
        "process_validation",
        helper.failure(function()
          environment.for_pipes(environment.normalize({ inherit = false, set = exact }))
        end).code
      )
      exact.TEMP = ""
      assert.are.same(exact, environment.normalize({ inherit = false, set = exact }))
      assert.are.same(environment.list(exact), environment.for_pipes(exact))
    end)
    jit.os, package.loaded[module] = platform, original
    if original_temp then
      assert(vim.uv.os_setenv("TEMP", original_temp))
    else
      vim.env.TEMP = nil
    end
    assert.is_true(ok, vim.inspect(err))
  end)

end)
