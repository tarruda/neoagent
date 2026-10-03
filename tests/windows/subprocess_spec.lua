local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")

describe("native Windows subprocess handles", function()
  if jit.os ~= "Windows" then
    pending("requires native Windows")
    return
  end
  ---@type Neoagent.SubprocessScope
  local owner
  local directories = {}
  before_each(function()
    owner = subprocess.scope()
  end)
  after_each(function()
    owner:close("test finished")
    assert.is_true(helper.complete(function()
      return owner:wait(4000)
    end))
    for _, directory in ipairs(directories) do
      vim.fn.delete(directory, "rf")
    end
    directories = {}
  end)

  local function spec(argv, stdio)
    return { argv = argv, cwd = assert(vim.uv.cwd()), stdio = stdio or { kind = "pipes" }, timeout_ms = 10000 }
  end

  it("binds all standard handles to ConPTY when the editor has redirected stdio", function()
    local result = helper.complete(function()
      return owner:run(spec({
        "python", "-c",
        "import os; print('PTY_STDIO=' + ''.join(str(int(os.isatty(fd))) for fd in range(3)))",
      }, { kind = "pty", columns = 80, rows = 24 }), { capture = { max_bytes = 4096 } })
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.matches("PTY_STDIO=111", assert(result.output), 1, true)
  end)

  for _, startup_failure in ipairs({ false, true }) do
    it("releases console work after " .. (startup_failure and "failed execution" or "successful execution"), function()
      ---@type string[]
      local argv = { "cmd.exe", "/d", "/s", "/c", "exit 0" }
      if startup_failure then
        local root = vim.fn.tempname()
        directories[#directories + 1] = root
        vim.fn.mkdir(root, "p")
        argv = { root .. "/invalid.exe" }
        assert(fs.write_all(argv[1], "invalid executable", "w", 448))
      end
      local new_work = vim.uv.new_work
      ---@type table<integer, uv.luv_work_ctx_t>
      local contexts = setmetatable({}, { __mode = "v" })
      local created = 0
      ---@type Neoagent.SubprocessHandle?
      local handle
      vim.uv.new_work = function(work, completed)
        local context = new_work(work, completed)
        created = created + 1
        contexts[created] = context
        return context
      end
      local ok, failure = pcall(function()
        local selected = spec(argv, { kind = "pty", columns = 80, rows = 24 })
        if startup_failure then
          assert.are.equal(
            "process_start",
            helper.failure(function()
              owner:spawn(selected)
            end).code
          )
        else
          handle = owner:spawn(selected)
          local outcome = helper.complete(function()
            return assert(handle):wait()
          end)
          assert.are.equal(0, outcome.code, vim.inspect(outcome))
        end
        assert.is_true(helper.complete(function()
          return owner:wait(4000)
        end))
      end)
      vim.uv.new_work = new_work
      assert.is_true(ok, vim.inspect(failure))
      assert.are.equal(1, created)
      assert.is_true(
        vim.wait(1000, function()
          collectgarbage("collect")
          return next(contexts) == nil
        end, 10),
        "finished PTY retained its console work context"
      )
      if handle then
        -- A caller retaining its completed handle must not retain native work.
        assert.are.equal("exited", handle:state().phase)
      end
    end)
  end

  it("keeps native startup storage alive across repeated launches with aggressive collection", function()
    -- Keep the watchdog outside the VM whose collection and native launch are
    -- under stress. Report the last completed phase if that VM stops progressing.
    local result = vim.system({
      assert(vim.env.NEOAGENT_NVIM), "--headless", "--noplugin",
      "-u", "tests/minimal_init.lua", "-l", "tests/fixtures/subprocess_windows_gc.lua",
    }, { text = true }):wait(90000)
    assert.are.equal(0, result.code, (result.stdout or "") .. (result.stderr or ""))
    assert.matches("20 native launches survived aggressive collection", assert(result.stdout), 1, true)
  end)

  it("gives native children an environment block ordered by variable name", function()
    local script = [[
import ctypes
api = ctypes.WinDLL('kernel32', use_last_error=True)
api.GetEnvironmentStringsW.restype = ctypes.c_void_p
api.FreeEnvironmentStringsW.argtypes = [ctypes.c_void_p]
block = api.GetEnvironmentStringsW()
assert block
names = []
try:
    current = block
    while True:
        entry = ctypes.wstring_at(current)
        if not entry:
            break
        name = entry.split('=', 1)[0]
        if name in ('A', 'A!', 'PROGRAMFILES', 'PROGRAMFILES(X86)'):
            names.append(name)
        current += len(entry.encode('utf-16-le', 'surrogatepass')) + 2
finally:
    api.FreeEnvironmentStringsW(block)
print('native-order:' + '>'.join(names), flush=True)
]]
    for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 200, rows = 24 } }) do
      local selected = spec({ "python", "-c", script }, stdio)
      selected.environment = {
        inherit = true,
        set = { A = "one", ["A!"] = "two", PROGRAMFILES = "base", ["PROGRAMFILES(X86)"] = "compat" },
      }
      local result = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 8192 } })
      end)
      assert.are.equal(0, result.code, vim.inspect(result))
      assert.matches("native-order:A>A!>PROGRAMFILES>PROGRAMFILES(X86)", assert(result.output), 1, true)
    end
  end)

  it("preserves native Windows strings across pipe and PTY launches", function()
    local high, low = "\237\160\128", "\237\191\191"
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    assert(vim.uv.fs_mkdir(root, 448))
    local cwd = root .. "/cwd" .. high
    assert(vim.uv.fs_mkdir(cwd, 448))
    local executable = cwd .. "/cmd.exe"
    local ok, failure = pcall(function()
      assert(vim.uv.fs_copyfile(vim.fn.exepath("cmd.exe"), executable))
      local script = [[
import os, sys
assert os.getcwd().endswith('cwd\ud800'), repr(os.getcwd())
assert sys.argv[1] == 'arg\ud800', repr(sys.argv)
assert os.environ.get('MARKER\ud800') == 'value\udfff', repr(os.environ.get('MARKER\ud800'))
print('native-strings:ok', flush=True)
]]
      for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 200, rows = 24 } }) do
        local selected = spec({ executable, "/d", "/s", "/c", "exit 0" }, stdio)
        selected.cwd = cwd
        local launched = helper.complete(function()
          return owner:run(selected, { capture = false })
        end)
        assert.are.equal(0, launched.code, vim.inspect(launched))
        selected = spec({ "python", "-c", script, "arg" .. high }, stdio)
        selected.cwd = cwd
        selected.environment = { inherit = true, set = { ["marker" .. high] = "value" .. low } }
        local result = helper.complete(function()
          return owner:run(selected, { capture = { max_bytes = 8192 } })
        end)
        assert.are.equal(0, result.code, vim.inspect(result))
        assert.matches("native-strings:ok", assert(result.output), 1, true)
      end
    end)
    owner:close("native string test complete")
    assert.is_true(helper.complete(function()
      return owner:wait(4000)
    end))
    if vim.uv.fs_stat(executable) then
      assert(vim.uv.fs_unlink(executable))
    end
    assert(vim.uv.fs_rmdir(cwd))
    assert.is_true(ok, vim.inspect(failure))
  end)

  it("rejects malformed Windows strings before native execution", function()
    for _, selected in ipairs({
      spec({ "cmd.exe", "\255" }, { kind = "pty", columns = 80, rows = 24 }),
      spec({ "C:/invalid\255.exe" }, { kind = "pty", columns = 80, rows = 24 }),
    }) do
      assert.are.equal(
        "process_start",
        helper.failure(function()
          owner:spawn(selected)
        end).code
      )
    end
    local selected = spec({ "cmd.exe" })
    selected.environment = { inherit = true, set = { ["invalid\255"] = "unused" } }
    assert.are.equal(
      "process_validation",
      helper.failure(function()
        owner:spawn(selected)
      end).code
    )
  end)

  it("retains scope ownership when it closes during native PTY startup", function()
    local pty = require("neoagent.subprocess.pty")
    local original = pty.new
    local exited = false
    pty.new = function(selected, env, callbacks)
      local exit = callbacks.exited
      callbacks.exited = function(...)
        exited = true
        exit(...)
      end
      local driver = original(selected, env, callbacks)
      local start = driver.start
      driver.start = function()
        start()
        owner:close("closed during native startup")
        return true
      end
      return driver
    end
    local ok, failure = pcall(
      owner.spawn,
      owner,
      spec({ "cmd.exe", "/d", "/s", "/c", "set /p value=" }, { kind = "pty", columns = 80, rows = 24 })
    )
    pty.new = original
    assert.is_false(ok)
    assert.are.equal("process_disposed", require("neoagent.util").normalize_error(failure).code)
    assert.is_true(helper.complete(function()
      return owner:wait(4000)
    end))
    assert.is_true(exited)
  end)

  it("preserves native pipe exit when its completion callback arrives after the deadline", function()
    local spawn = vim.uv.spawn
    local pending = {}
    vim.uv.spawn = function(file, options, callback)
      return spawn(file, options, function(code, signal)
        local timer = assert(vim.uv.new_timer())
        local complete = function()
          timer:stop()
          timer:close()
          pending[timer] = nil
          callback(code, signal)
        end
        pending[timer] = complete
        vim.uv.update_time()
        timer:start(500, 0, complete)
      end)
    end
    local ok, err = pcall(function()
      local selected = spec({ "cmd.exe", "/d", "/s", "/c", "exit 0" })
      selected.timeout_ms = 300
      local result = helper.complete(function()
        return owner:run(selected, { capture = false })
      end)
      assert.are.equal(0, result.code, vim.inspect(result))
      assert.is_false(result.timed_out)
      assert.is_nil(result.termination_reason)
    end)
    vim.uv.spawn = spawn
    for _, complete in pairs(pending) do
      complete()
    end
    assert.is_true(ok, vim.inspect(err))
  end)

  it("preserves native PTY exit while terminal cleanup completes", function()
    local new_work = vim.uv.new_work
    local pending = {}
    vim.uv.new_work = function(work, completed)
      return new_work(work, function(...)
        local values = { ... }
        local timer = assert(vim.uv.new_timer())
        local function deliver()
          if not pending[timer] then
            return
          end
          pending[timer] = nil
          timer:stop()
          timer:close()
          completed(unpack(values))
        end
        pending[timer] = deliver
        timer:start(400, 0, deliver)
      end)
    end
    local ok, err = pcall(function()
      local selected = spec({ "cmd.exe", "/d", "/s", "/c", "exit 0" }, { kind = "pty", columns = 80, rows = 24 })
      selected.timeout_ms = 300
      local result = helper.complete(function()
        return owner:run(selected, { capture = false })
      end)
      assert.are.equal(0, result.code, vim.inspect(result))
      assert.is_false(result.timed_out)
      assert.is_nil(result.termination_reason)
    end)
    vim.uv.new_work = new_work
    for _, deliver in pairs(pending) do
      deliver()
    end
    assert.is_true(ok, vim.inspect(err))
  end)

  it("rejects unrepresentable PTY dimensions before spawning or resizing", function()
    local argv = { "cmd.exe", "/d", "/s", "/c", "set /p value=" }
    for _, size in ipairs({ { 32768, 24 }, { 80, 32768 }, { 65535, 65535 } }) do
      assert.are.equal(
        "invalid_terminal_size",
        helper.failure(function()
          owner:spawn(spec(argv, { kind = "pty", columns = size[1], rows = size[2] }))
        end).code
      )
    end
    local handle = owner:spawn(spec(argv, { kind = "pty", columns = 80, rows = 24 }))
    for _, size in ipairs({ { 32768, 24 }, { 80, 32768 } }) do
      assert.are.equal(
        "invalid_terminal_size",
        helper.failure(function()
          handle:resize(size[1], size[2])
        end).code
      )
    end
    assert.are.equal("running", handle:state().phase)
    handle:terminate("test finished")
  end)

  it("launches the selected executable independently of ambient PATHEXT", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root, "p")
    local cmd = vim.fn.exepath("cmd.exe")
    local target = root .. "/helper.exe"
    assert(vim.uv.fs_copyfile(cmd, target))
    assert(fs.write_all(target .. ".com", "invalid executable", "w", 448))
    local pathext, shell = vim.env.PATHEXT, vim.o.shell
    vim.env.PATHEXT, vim.o.shell = ".COM;.EXE", cmd
    local ok, err = pcall(function()
      local selected = spec({ target, "/d", "/s", "/c", "echo selected" })
      local pipes = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 8192 } })
      end)
      assert.are.equal(0, pipes.code, vim.inspect(pipes))
      assert.matches("selected", assert(pipes.output), 1, true)
      selected.stdio = { kind = "pty", columns = 80, rows = 24 }
      local first = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 8192 } })
      end)
      assert.are.equal(0, first.code, vim.inspect(first))
      assert.matches("selected", assert(first.output), 1, true)
      assert.are.equal(".COM;.EXE", vim.env.PATHEXT)
      assert(vim.uv.fs_unlink(target .. ".com"))
      local pty = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 8192 } })
      end)
      assert.are.equal(0, pty.code, vim.inspect(pty))
      vim.env.PATHEXT = ".COM"
      local second = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 8192 } })
      end)
      assert.are.equal(0, second.code, vim.inspect(second))
      assert.are.equal(".COM", vim.env.PATHEXT)
    end)
    vim.env.PATHEXT, vim.o.shell = pathext, shell
    assert.is_true(ok, vim.inspect(err))
  end)

  it("launches the exact cmd PTY executable when its path contains spaces", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root .. "/cmd tools", "p")
    local cmd = vim.fn.exepath("cmd.exe")
    assert(vim.uv.fs_copyfile(cmd, root .. "/cmd.exe"))
    assert(vim.uv.fs_copyfile(cmd, root .. "/cmd tools/cmd.exe"))
    local result = helper.complete(function()
      return owner:run(
        spec({ root .. "/cmd tools/cmd.exe", "/d", "/s", "/c", "echo expected" }, {
          kind = "pty",
          columns = 80,
          rows = 24,
        }),
        { capture = { max_bytes = 4096 } }
      )
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.matches("expected", assert(result.output), 1, true)
  end)

  it("selects the same executable from cwd and quoted PATH entries in both modes", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    local cwd, bin = root .. "/working", root .. "/quoted tools"
    vim.fn.mkdir(cwd, "p")
    vim.fn.mkdir(bin, "p")
    local cmd = vim.fn.exepath("cmd.exe")
    assert(vim.uv.fs_copyfile(cmd, cwd .. "/helper.exe"))
    assert(fs.write_all(bin .. "/helper.exe", "invalid executable", "w", 448))
    local no_cwd = vim.env.NoDefaultCurrentDirectoryInExePath
    vim.env.NoDefaultCurrentDirectoryInExePath = nil
    local ok, err = pcall(function()
      for _, expected in ipairs({ cwd, bin }) do
        for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 80, rows = 24 } }) do
          local selected = spec({ "helper.exe", "/d", "/s", "/c", "echo selected" }, stdio)
          selected.cwd = cwd
          selected.environment = { inherit = true, set = { PATH = '"' .. bin .. '"' } }
          local result = helper.complete(function()
            return owner:run(selected, { capture = { max_bytes = 8192 } })
          end)
          assert.are.equal(0, result.code, vim.inspect(result))
          assert.matches("selected", assert(result.output), 1, true)
        end
        if expected == cwd then
          assert(vim.uv.fs_unlink(cwd .. "/helper.exe"))
          assert(vim.uv.fs_copyfile(cmd, bin .. "/helper.exe"))
        end
      end
    end)
    vim.env.NoDefaultCurrentDirectoryInExePath = no_cwd
    assert.is_true(ok, vim.inspect(err))
  end)

  it("does not skip a dangling executable link to launch a later PATH candidate", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    local first, second = root .. "/first", root .. "/second"
    vim.fn.mkdir(first, "p")
    vim.fn.mkdir(second, "p")
    assert(vim.uv.fs_symlink(root .. "/missing.exe", first .. "/helper.exe"))
    assert.are.equal("link", assert(vim.uv.fs_lstat(first .. "/helper.exe")).type)
    assert(vim.uv.fs_copyfile(vim.fn.exepath("cmd.exe"), second .. "/helper.exe"))
    for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 80, rows = 24 } }) do
      local selected = spec({ "helper.exe", "/d", "/s", "/c", "exit 0" }, stdio)
      selected.cwd = root
      selected.environment = { inherit = true, set = { PATH = first .. ";" .. second } }
      assert.are.equal(
        "process_start",
        helper.failure(function()
          owner:spawn(selected)
        end).code
      )
      assert.is_true(helper.complete(function()
        return owner:wait(4000)
      end))
    end
  end)

  it("matches native lookup with an empty cwd opt-out and drive-relative PATH", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    local cwd, bin = root .. "/working", root .. "/bin"
    vim.fn.mkdir(cwd, "p")
    vim.fn.mkdir(bin, "p")
    local cmd = vim.fn.exepath("cmd.exe")
    local drive = assert(assert(vim.uv.fs_realpath(cwd)):match("^%a:"))
    local no_cwd = vim.uv.os_getenv("NoDefaultCurrentDirectoryInExePath")
    assert(vim.uv.os_setenv("NoDefaultCurrentDirectoryInExePath", ""))
    local ok, err = pcall(function()
      assert.are.equal("", vim.uv.os_getenv("NoDefaultCurrentDirectoryInExePath"))
      for _, lookup in ipairs({ { path = bin, expected = bin }, { path = drive, expected = cwd } }) do
        for _, directory in ipairs({ cwd, bin }) do
          if directory == lookup.expected then
            assert(vim.uv.fs_copyfile(cmd, directory .. "/helper.exe"))
          else
            assert(fs.write_all(directory .. "/helper.exe", "invalid executable", "w", 448))
          end
        end
        for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 80, rows = 24 } }) do
          local selected = spec({ "helper.exe", "/d", "/s", "/c", "echo selected" }, stdio)
          selected.cwd = cwd
          selected.environment = { inherit = true, set = { PATH = lookup.path } }
          local result = helper.complete(function()
            return owner:run(selected, { capture = { max_bytes = 8192 } })
          end)
          assert.are.equal(0, result.code, vim.inspect(result))
          assert.matches("selected", assert(result.output), 1, true)
        end
      end
    end)
    if no_cwd then
      assert(vim.uv.os_setenv("NoDefaultCurrentDirectoryInExePath", no_cwd))
    else
      vim.env.NoDefaultCurrentDirectoryInExePath = nil
    end
    assert.is_true(ok, vim.inspect(err))
  end)

  it("keeps relative executable lookup outside a junction's physical parent", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root .. "/physical/project", "p")
    local cwd = root .. "/alias"
    assert(vim.uv.fs_symlink(root .. "/physical/project", cwd, { dir = true, junction = true }))
    assert(vim.uv.fs_copyfile(vim.fn.exepath("cmd.exe"), root .. "/helper.exe"))
    assert(fs.write_all(root .. "/physical/helper.exe", "invalid executable", "w", 448))
    for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 80, rows = 24 } }) do
      local selected = spec({ "../helper.exe", "/d", "/s", "/c", "echo selected" }, stdio)
      selected.cwd = cwd
      local result = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 4096 } })
      end)
      assert.are.equal(0, result.code, vim.inspect(result))
      assert.matches("selected", assert(result.output), 1, true)
    end
  end)

  it("launches extended executable and PATH names with native separators", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root .. "/bin", "p")
    assert(vim.uv.fs_copyfile(vim.fn.exepath("cmd.exe"), root .. "/bin/helper.exe"))
    local bin = assert(vim.uv.fs_realpath(root .. "/bin")):gsub("/", "\\")
    assert.matches("^%a:", bin)
    local extended = [[\\?\]] .. bin
    for _, program in ipairs({ extended .. [[\helper.exe]], "helper" }) do
      for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 80, rows = 24 } }) do
        local selected = spec({ program, "/d", "/s", "/c", "echo selected" }, stdio)
        selected.cwd = root
        selected.environment = { inherit = true, set = { PATH = extended } }
        local result = helper.complete(function()
          return owner:run(selected, { capture = { max_bytes = 4096 } })
        end)
        assert.are.equal(0, result.code, vim.inspect(result))
        assert.matches("selected", assert(result.output), 1, true)
      end
    end
  end)

  it("preserves the invocation name and arguments when switching to PTY transport", function()
    local argv = {
      "python",
      "-c",
      [=[import json,sys; print('ARGV=' + json.dumps([sys.orig_argv[0], *sys.argv[1:]]))]=],
      "",
      "two words",
      [[quotes"and\slashes]],
    }
    local outputs = {}
    for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 1000, rows = 24 } }) do
      local result = helper.complete(function()
        return owner:run(spec(argv, stdio), { capture = { max_bytes = 8192 } })
      end)
      assert.are.equal(0, result.code, vim.inspect(result))
      local encoded = assert(assert(result.output):match("ARGV=([^\r\n]+)"), vim.inspect(result))
      outputs[#outputs + 1] = vim.json.decode(encoded)
    end
    assert.are.same({ "python", "", "two words", [[quotes"and\slashes]] }, outputs[1])
    assert.are.same(outputs[1], outputs[2])
  end)

  it("matches native rejection of unmatched quotes in PATH", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    local cwd, bin = root .. "/working", root .. "/bin"
    vim.fn.mkdir(cwd, "p")
    vim.fn.mkdir(bin, "p")
    assert(vim.uv.fs_copyfile(vim.fn.exepath("cmd.exe"), bin .. "/helper.exe"))
    local no_cwd = vim.uv.os_getenv("NoDefaultCurrentDirectoryInExePath")
    assert(vim.uv.os_setenv("NoDefaultCurrentDirectoryInExePath", "1"))
    local ok, err = pcall(function()
      for _, quote in ipairs({ '"', "'" }) do
        for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 80, rows = 24 } }) do
          local selected = spec({ "helper.exe", "/d", "/s", "/c", "echo unexpected" }, stdio)
          selected.cwd = cwd
          selected.environment = { inherit = true, set = { PATH = quote .. root .. "/missing;" .. bin } }
          assert.are.equal(
            "process_start",
            helper.failure(function()
              owner:spawn(selected)
            end).code
          )
        end
      end
    end)
    if no_cwd then
      assert(vim.uv.os_setenv("NoDefaultCurrentDirectoryInExePath", no_cwd))
    else
      vim.env.NoDefaultCurrentDirectoryInExePath = nil
    end
    assert.is_true(ok, vim.inspect(err))
  end)

  it("rejects implicit inheritance of an empty native environment value", function()
    local original = vim.uv.os_getenv("TEMP")
    assert(vim.uv.os_setenv("TEMP", ""))
    local ok, err = pcall(function()
      local selected = spec({
        vim.fn.exepath("python"),
        "-c",
        "import os; print('present' if 'TEMP' in os.environ and os.environ['TEMP'] == '' else 'missing')",
      })
      local exact = require("neoagent.subprocess.environment").normalize({ inherit = true, set = {} })
      exact.TEMP = nil
      selected.environment = { inherit = false, set = exact }
      assert.are.equal(
        "process_validation",
        helper.failure(function()
          owner:spawn(selected)
        end).code
      )
      exact.TEMP = ""
      local result = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 1024 } })
      end)
      assert.are.equal(0, result.code)
      assert.are.equal("present", vim.trim(assert(result.stdout)))
    end)
    if original then
      assert(vim.uv.os_setenv("TEMP", original))
    else
      vim.env.TEMP = nil
    end
    assert.is_true(ok, vim.inspect(err))
  end)

  it("preserves an exact pipe environment without silently inheriting native values", function()
    local python = vim.fn.exepath("python")
    assert.is_not.equal("", python)
    local selected = spec({ python, "-c", "import os,json; print(json.dumps(dict(os.environ)))" })
    selected.environment = { inherit = false, set = {} }
    assert.are.equal(
      "process_validation",
      helper.failure(function()
        owner:spawn(selected)
      end).code
    )
    selected.environment.set.SAFE = "value"
    for _, name in ipairs({
      "HOMEDRIVE",
      "HOMEPATH",
      "LOGONSERVER",
      "PATH",
      "SYSTEMDRIVE",
      "SYSTEMROOT",
      "TEMP",
      "USERDOMAIN",
      "USERNAME",
      "USERPROFILE",
      "WINDIR",
    }) do
      if vim.env[name] ~= nil then
        selected.environment.set[name] = vim.env[name]
      end
    end
    local result = helper.complete(function()
      return owner:run(selected, { capture = { max_bytes = 65536 } })
    end)
    assert.are.equal(0, result.code)
    assert.are.same(selected.environment.set, vim.json.decode((assert(result.stdout))))
  end)

  it("merges case-insensitive environment names and rejects duplicates", function()
    local selected = spec({ "cmd.exe", "/d", "/s", "/c", "echo %NEOAGENT_CASE%" })
    selected.environment = { inherit = true, set = { neoagent_case = "value" } }
    local result = helper.complete(function()
      return owner:run(selected, { capture = { max_bytes = 1024 } })
    end)
    assert.are.equal(0, result.code)
    assert.are.equal("value", vim.trim(assert(result.stdout)))
    selected.environment.set.NEOAGENT_CASE = "duplicate"
    assert.are.equal(
      "process_validation",
      helper.failure(function()
        owner:spawn(selected)
      end).code
    )
    assert.is_true(owner:is_settled())
  end)

  it("uses Windows Unicode equivalence when replacing and rejecting environment names", function()
    local original = vim.env["éVAR"]
    vim.env["éVAR"] = "inherited"
    local ok, err = pcall(function()
      local selected = spec({ "python", "-c", "import os; print(os.environ['\\u00e9VAR'])" })
      selected.environment = { inherit = true, set = { ["ÉVAR"] = "replacement" } }
      local result = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 1024 } })
      end)
      assert.are.equal(0, result.code, vim.inspect(result))
      assert.are.equal("replacement", vim.trim(assert(result.stdout)))
      selected.environment.set["éVAR"] = "duplicate"
      assert.are.equal(
        "process_validation",
        helper.failure(function()
          owner:spawn(selected)
        end).code
      )
      selected.environment.set = { ["invalid\255"] = "value" }
      assert.are.equal(
        "process_validation",
        helper.failure(function()
          owner:spawn(selected)
        end).code
      )
    end)
    vim.env["éVAR"] = original
    assert.is_true(ok, vim.inspect(err))
  end)

  it("rejects a lone dot even when hidden executables exist in the lookup directory", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root, "p")
    local cmd = vim.fn.exepath("cmd.exe")
    assert(vim.uv.fs_copyfile(cmd, root .. "/.com"))
    assert(vim.uv.fs_copyfile(cmd, root .. "/.exe"))
    for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 80, rows = 24 } }) do
      local selected = spec({ ".", "/d", "/s", "/c", "exit 0" }, stdio)
      selected.cwd = root
      selected.environment = { inherit = true, set = { PATH = root } }
      assert.are.equal(
        "process_start",
        helper.failure(function()
          owner:spawn(selected)
        end).code
      )
    end
  end)

  it("selects the same executable for trailing-dot names in pipes and PTYs", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root, "p")
    local cmd = vim.fn.exepath("cmd.exe")
    assert(vim.uv.fs_copyfile(cmd, root .. "/helper.exe"))
    assert(fs.write_all(root .. "/helper..exe", "invalid executable", "w", 448))
    for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 80, rows = 24 } }) do
      local selected = spec({ root .. "/helper.", "/d", "/s", "/c", "echo selected" }, stdio)
      local result = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 8192 } })
      end)
      assert.are.equal(0, result.code, vim.inspect(result))
      assert.matches("selected", assert(result.output), 1, true)
    end
  end)

  it("owns a writable pipe independently of a cancelled observer", function()
    local python = vim.fn.exepath("python")
    assert.is_not.equal("", python)
    local selected = spec({ python, "-c", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())" }, {
      kind = "pipes",
      stdin = "open",
    })
    local bytes = "\0first\r\nlast\255"
    local output = ""
    local handle = owner:spawn(selected, {
      on_output = function(event)
        output = output .. event.data
      end,
    })
    local observer = async.run(function()
      return handle:wait()
    end)
    observer:cancel()
    assert.are.equal("cancelled", assert(helper.wait(observer).error).kind)
    handle:write(bytes)
    handle:close_stdin()
    assert.is_true(helper.complete(function()
      return handle:flush()
    end))
    assert.are.equal(
      0,
      helper.complete(function()
        return handle:wait()
      end).code
    )
    assert.are.equal(bytes, output)
  end)

  it("uses native PTY input, resize, combined output, and termination", function()
    local selected = spec({ "cmd.exe", "/d", "/q" }, { kind = "pty", columns = 80, rows = 24 })
    local output = ""
    local handle = owner:spawn(selected, {
      on_output = function(event)
        assert.are.equal("pty", event.stream)
        output = output .. event.data
      end,
    })
    assert.is_true(handle:resize(100, 30))
    assert.is_true(handle:write("echo neoagent-ready\r\n"))
    assert(vim.wait(5000, function()
      return output:find("neoagent-ready", 1, true) ~= nil
    end, 10))
    assert.is_true(helper.complete(function()
      return handle:flush()
    end))
    assert.are.equal(
      "unsupported_control",
      helper.failure(function()
        handle:close_stdin()
      end).code
    )
    handle:terminate("Windows PTY finished")
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal("Windows PTY finished", result.termination_reason)
  end)

  it("keeps editor deadlines responsive during resize with paused terminal output", function()
    -- The parent owns the watchdog: a blocked native resize would prevent
    -- the child editor from executing its own timeout callback.
    local selected = spec({
      vim.v.progpath,
      "--headless",
      "--noplugin",
      "-u",
      "tests/minimal_init.lua",
      "-l",
      "tests/fixtures/subprocess_windows_resize.lua",
    })
    selected.timeout_ms, selected.kill_grace_ms = 10000, 0
    local result = helper.complete(function()
      return owner:run(selected, { capture = { max_bytes = 8192 } })
    end, 15000)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.is_false(result.timed_out)
    assert.matches("resize remained responsive", assert(result.stdout), 1, true)
  end)

  it("bounds queued PTY input and keeps ownership after a flush waiter cancels", function()
    local limits = require("neoagent.subprocess.validate")
    local handle = owner:spawn(spec({ "python", "-c", "import time; time.sleep(30)" }, {
      kind = "pty",
      columns = 80,
      rows = 24,
    }))
    local chunk = string.rep("x", limits.WRITE_BYTES)
    for _ = 1, limits.PENDING_BYTES / limits.WRITE_BYTES do
      handle:write(chunk)
    end
    assert.are.equal(
      "input_limit",
      helper.failure(function()
        handle:write(chunk)
      end).code
    )
    local flushing = async.run(function()
      return handle:flush()
    end)
    assert.is_false(flushing:is_done())
    flushing:cancel()
    assert.are.equal("cancelled", assert(helper.wait(flushing).error).kind)
    assert.are.equal("running", handle:state().phase)
  end)

  it("retains Job ownership of descendants when the PTY leader exits", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root, "p")
    local marker = root .. "/survived"
    local script = [=[import subprocess,sys
subprocess.Popen([sys.executable, '-c', "import time,pathlib,sys; time.sleep(1); pathlib.Path(sys.argv[1]).write_text('escaped')", sys.argv[1]])]=]
    local result = helper.complete(function()
      return owner:run(
        spec({ "python", "-c", script, marker }, {
          kind = "pty",
          columns = 80,
          rows = 24,
        }),
        { capture = false }
      )
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    local escaped = vim.wait(1500, function()
      return vim.uv.fs_stat(marker) ~= nil
    end, 10)
    assert.is_false(escaped)
  end)

  it("preserves an exact PTY environment without native additions", function()
    local selected = spec({
      vim.fn.exepath("python"),
      "-E",
      "-S",
      "-c",
      "import os,json; print('ENV:' + json.dumps(dict(os.environ)) + ':END')",
    }, {
      kind = "pty",
      columns = 80,
      rows = 24,
    })
    selected.environment = { inherit = false, set = { SAFE = "exact" } }
    local result = helper.complete(function()
      return owner:run(selected, { capture = { max_bytes = 65536 } })
    end)
    assert.are.equal(0, result.code)
    local bytes = assert(assert(result.output):match("ENV:(.-):END"))
    assert.are.same({ SAFE = "exact" }, vim.json.decode(bytes))
  end)
end)
