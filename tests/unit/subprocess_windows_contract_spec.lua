local assert = require("luassert")
local helper = require("tests.helpers.subprocess")

-- Exercise Lua boundary decisions with native services injected internally.
-- Actual Windows lookup and Unicode mapping run in tests/windows.
describe("Windows subprocess boundary rules", function()
  it("releases reserved console work when native Job creation fails", function()
    local subprocess = require("neoagent.subprocess_common")
    local pty = require("neoagent.subprocess.pty")
    local trees = require("neoagent.process.windows")
    local native = require("ffi")
    local module = "neoagent.subprocess.windows_pty"
    local original_module, original_ffi = package.loaded[module], package.loaded.ffi
    local original_pty, original_tree, new_work = pty.new, trees.new, vim.uv.new_work
    local owner = subprocess.scope()
    ---@type table<integer, uv.luv_work_ctx_t>
    local contexts = setmetatable({}, { __mode = "v" })
    local created = 0
    local ok, failure = pcall(function()
      -- Only availability is checked before the injected Job allocation
      -- failure. Keep the real FFI allocation and real luv work context.
      package.loaded.ffi = setmetatable({
        cdef = function() end,
        load = function()
          return {
            CreatePseudoConsole = function()
              error("unexpected terminal allocation")
            end,
          }
        end,
      }, { __index = native })
      package.loaded[module] = nil
      pty.new = require(module).new
      package.loaded.ffi = original_ffi
      trees.new = function()
        return nil, "injected Job allocation failure"
      end
      vim.uv.new_work = function(work, completed)
        local context = new_work(work, completed)
        created = created + 1
        contexts[created] = context
        return context
      end
      assert.are.equal(
        "process_start",
        helper.failure(function()
          owner:spawn(helper.spec("unused", { stdio = { kind = "pty", columns = 80, rows = 24 } }))
        end).code
      )
      assert.are.equal(1, created)
    end)
    package.loaded.ffi, package.loaded[module] = original_ffi, original_module
    pty.new, trees.new, vim.uv.new_work = original_pty, original_tree, new_work
    owner:close("test finished")
    assert.is_true(helper.complete(function()
      return owner:wait(2000)
    end))
    assert.is_true(ok, vim.inspect(failure))
    assert.is_true(
      vim.wait(1000, function()
        collectgarbage("collect")
        return next(contexts) == nil
      end, 10),
      "failed PTY startup retained its console work context"
    )
  end)

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

  it("rejects failed native environment normalization before acquiring resources", function()
    local subprocess = require("neoagent.subprocess_common")
    local native = require("ffi")
    local module = "neoagent.subprocess.windows_environment"
    local previous, platform = package.loaded[module], jit.os
    local owner = subprocess.scope()
    package.loaded.ffi = setmetatable({
      load = function()
        return {
          LCMapStringW = function()
            return 0
          end,
        }
      end,
    }, { __index = native })
    package.loaded[module] = nil
    local loaded, load_error = pcall(require, module)
    package.loaded.ffi = native
    jit.os = "Windows"
    local ok, failure = pcall(helper.failure, function()
      assert.is_true(loaded, vim.inspect(load_error))
      local selected = helper.spec("unused")
      selected.environment = { inherit = false, set = { MARKER = "value" } }
      owner:spawn(selected)
    end)
    jit.os, package.loaded[module] = platform, previous
    owner:close("test complete")
    assert.is_true(ok, vim.inspect(failure))
    assert.are.equal("process_validation", failure.code)
    assert.is_true(owner:is_settled())
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

  for _, case in ipairs({
    {
      description = "preserves an unpaired UTF-16 surrogate during executable selection",
      program = "C:/tools/helper\237\160\128.exe",
      path = "",
      expected = "C:/tools/helper\237\160\128.exe",
    },
    {
      description = "selects a dangling executable link before a later working PATH candidate",
      program = "helper",
      path = "C:/dangling;C:/bin",
      no_cwd = "1",
      expected = "C:/dangling/helper.exe",
    },
    {
      description = "preserves native separators in an extended executable path",
      program = [[\\?\C:\tools\helper.exe]],
      path = "",
      expected = [[\\?\C:\tools\helper.exe]],
    },
    {
      description = "joins an extended PATH directory with native separators",
      program = "helper",
      path = [[\\?\C:\tools]],
      no_cwd = "1",
      expected = [[\\?\C:\tools\helper.exe]],
    },
    {
      description = "keeps a junction-backed cwd lexical during executable lookup",
      program = "../bin/helper.exe",
      path = "",
      resolved_cwd = "D:/physical/project",
      expected = "C:/work/../bin/helper.exe",
    },
    {
      description = "rejects a lone dot instead of selecting a hidden executable",
      program = ".",
      path = "",
      failure = "process_start",
    },
    {
      description = "appends an executable extension without duplicating a trailing dot",
      program = "helper.",
      path = "",
      expected = "C:/work/helper.exe",
    },
    {
      description = "honors an empty native cwd-search opt-out",
      program = "helper",
      path = "C:/bin",
      no_cwd = "",
      expected = "C:/bin/helper.exe",
    },
    {
      description = "preserves drive-relative PATH entries",
      program = "helper",
      path = "C:",
      no_cwd = "1",
      expected = "C:/work/helper.exe",
    },
    {
      description = "roots a drive-less absolute command in the requested cwd drive",
      program = "/bin/helper.exe",
      path = "",
      expected = "C:/bin/helper.exe",
    },
    {
      description = "preserves an explicit different drive's relative command",
      program = "D:helper.exe",
      path = "",
      expected = "D:helper.exe",
    },
    {
      description = "consumes an unmatched double quote through the end of PATH",
      program = "helper",
      path = '"C:/missing;C:/bin',
      no_cwd = "1",
      failure = "process_start",
    },
    {
      description = "consumes an unmatched single quote through the end of PATH",
      program = "helper",
      path = "'C:/missing;C:/bin",
      no_cwd = "1",
      failure = "process_start",
    },
  }) do
    it(case.description, function()
      local regular = assert(vim.uv.fs_stat(vim.fn.exepath(jit.os == "Windows" and "cmd.exe" or "sh")))
      local platform, no_cwd = jit.os, vim.uv.os_getenv("NoDefaultCurrentDirectoryInExePath")
      local realpath, stat, exepath = vim.uv.fs_realpath, vim.uv.fs_stat, vim.fn.exepath
      local native = require("ffi")
      local module = "neoagent.subprocess.windows_executable"
      local original_module, original_ffi = package.loaded[module], package.loaded.ffi
      vim.uv.fs_realpath = function(path)
        return case.resolved_cwd or path
      end
      vim.uv.fs_stat = function(path)
        if path == [[\\?\C:\tools\helper.exe]] then
          return regular
        end
        path = path:gsub("\\", "/")
        if
          vim.tbl_contains({
            "C:/work/helper.exe",
            "C:/work/../bin/helper.exe",
            "D:/physical/project/../bin/helper.exe",
            "D:helper.exe",
            "C:/work/helper..exe",
            "C:/bin/helper.exe",
            "C:/helper.exe",
            "C:/work/.com",
            "C:/work/.exe",
            "C:/tools/helper\237\160\128.exe",
          }, path)
        then
          return regular
        end
      end
      vim.fn.exepath = function(path)
        return path
      end
      jit.os = "Windows"
      if case.no_cwd then
        assert(vim.uv.os_setenv("NoDefaultCurrentDirectoryInExePath", case.no_cwd))
      else
        vim.env.NoDefaultCurrentDirectoryInExePath = nil
      end
      local ok, err = pcall(function()
        package.loaded.ffi = setmetatable({
          load = function()
            return {
              GetFileAttributesW = function(buffer)
                ---@type Neoagent.WindowsWideString
                local units = buffer
                local parts = {}
                for index = 0, assert(native.sizeof(units)) / 2 - 1 do
                  local unit = units[index]
                  if unit == 0 then
                    break
                  end
                  parts[#parts + 1] = unit == 0xd800 and "\237\160\128" or string.char(unit)
                end
                local path = table.concat(parts)
                if path:gsub("\\", "/") == "C:/dangling/helper.exe" then
                  return 0x400 -- FILE_ATTRIBUTE_REPARSE_POINT, without DIRECTORY.
                end
                return vim.uv.fs_stat(path) and 0 or 0xffffffff
              end,
            }
          end,
        }, { __index = native })
        package.loaded[module] = nil
        local executable = require(module)
        package.loaded.ffi = original_ffi
        local function resolve()
          return executable.resolve({
            argv = { case.program },
            cwd = "C:/work",
            stdio = { kind = "pty", columns = 80, rows = 24 },
          }, { PATH = case.path })
        end
        if case.failure then
          assert.are.equal(case.failure, helper.failure(resolve).code)
        else
          local selected = resolve()
          local expected = assert(case.expected)
          if expected:sub(1, 4) == [[\\?\]] then
            assert.are.equal(expected, selected)
          else
            assert.are.equal(expected, (selected:gsub("\\", "/")))
          end
        end
      end)
      package.loaded.ffi, package.loaded[module] = original_ffi, original_module
      jit.os = platform
      if no_cwd then
        assert(vim.uv.os_setenv("NoDefaultCurrentDirectoryInExePath", no_cwd))
      else
        vim.env.NoDefaultCurrentDirectoryInExePath = nil
      end
      vim.uv.fs_realpath, vim.uv.fs_stat, vim.fn.exepath = realpath, stat, exepath
      assert.is_true(ok, vim.inspect(err))
    end)
  end
end)
