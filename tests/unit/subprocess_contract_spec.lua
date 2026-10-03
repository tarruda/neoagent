local assert = require("luassert")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")
local fs = require("neoagent.fs")

describe("native subprocess contracts", function()
  if jit.os == "Windows" then
    pending("POSIX execution contracts; Windows uses its native suite")
    return
  end
  ---@type string
  local directory
  ---@type Neoagent.SubprocessScope
  local owner
  before_each(function()
    directory = vim.fn.tempname()
    assert(fs.mkdirp(directory))
    owner = subprocess.scope()
  end)
  after_each(function()
    owner:close("test finished")
    assert.is_true(helper.complete(function()
      return owner:wait(4000)
    end))
    vim.fn.delete(directory, "rf")
  end)

  for _, deadline in ipairs({ "timeout", "no-timeout" }) do
    it("bounds PTY cleanup with " .. deadline .. " when native exit leaves queued input pending", function()
      -- An in-editor timer cannot rescue a blocking native jobwait. The parent
      -- process owns this watchdog and kills the isolated editor if it hangs.
      local result = vim
        .system({
          assert(vim.env.NEOAGENT_NVIM),
          "--headless",
          "--noplugin",
          "-u",
          "tests/minimal_init.lua",
          "-l",
          "tests/fixtures/subprocess_pty_deadline.lua",
          deadline,
        }, { text = true })
        :wait(8000)
      assert.are.equal(0, result.code, result.stderr)
      assert.matches("cleanup observed", assert(result.stdout), 1, true)
    end)
  end

  it("rejects unsupported native pipe platforms before process creation", function()
    require("neoagent.subprocess.posix_child")
    local os, spawn = jit.os, vim.uv.spawn
    local launched = false
    vim.uv.spawn = function(...)
      launched = true
      return spawn(...)
    end
    jit.os = "BSD"
    local ok, result = pcall(function()
      return helper.failure(function()
        owner:spawn(helper.spec("exit 0"))
      end)
    end)
    jit.os, vim.uv.spawn = os, spawn
    assert.is_true(ok, vim.inspect(result))
    assert.are.equal("process_supervision", result.code)
    assert.matches("Unsupported native process platform", assert(result.message), 1, true)
    assert.is_false(launched)
  end)

  it("rejects unsupported native terminals before allocating resources", function()
    local platform = jit.os
    jit.os = "BSD"
    local ok, failure = pcall(helper.failure, function()
      owner:spawn(helper.spec("exit 0", { stdio = { kind = "pty", columns = 80, rows = 24 } }))
    end)
    jit.os = platform
    assert.is_true(ok, vim.inspect(failure))
    assert.are.equal("pty_unavailable", failure.code)
    assert.is_true(owner:is_settled())
  end)

  it("rejects an overlong executable component without publishing a handle", function()
    local failure = helper.failure(function()
      owner:spawn(helper.spec("unused", {
        argv = { ("x"):rep(256) },
        stdio = { kind = "pty", columns = 80, rows = 24 },
      }))
    end)
    assert.are.equal("process_start", failure.code)
    assert.matches("errno " .. (jit.os == "OSX" and 63 or 36), assert(failure.message), 1, true)
  end)

  it("continues native pipe PATH search after a candidate's interpreter is missing", function()
    assert(fs.mkdirp(directory .. "/broken"))
    assert(fs.mkdirp(directory .. "/working"))
    assert(fs.write_all(directory .. "/broken/target", "#!" .. directory .. "/absent\n", "w", 448))
    assert(fs.write_all(directory .. "/working/target", "#!/bin/sh\nprintf found", "w", 448))
    local result = helper.complete(function()
      return owner:run({
        argv = { "target" },
        cwd = directory,
        stdio = { kind = "pipes" },
        environment = { inherit = true, set = { PATH = "broken:working" } },
      }, { capture = { max_bytes = 100 } })
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("found", result.stdout)
  end)

  it("reports native observation errors without inventing an exit status", function()
    local pty = require("neoagent.subprocess.pty")
    local original = pty.new
    pty.new = function(spec, env, callbacks)
      local driver = original(spec, env, callbacks)
      driver.observe = function()
        error("native state unavailable")
      end
      return driver
    end
    local ok, err = pcall(function()
      local handle = owner:spawn(helper.spec("exec sleep 10", {
        stdio = { kind = "pty", columns = 80, rows = 24 },
        timeout_ms = 20,
      }))
      local result = helper.complete(function()
        return handle:wait()
      end)
      assert.are.equal("process_supervision", assert(result.error).code)
      assert.is_nil(handle:state().terminal)
    end)
    pty.new = original
    assert.is_true(ok, vim.inspect(err))
  end)

  it("selects a PTY executable independently of Neovim's ambient lookup", function()
    local exepath = vim.fn.exepath
    vim.fn.exepath = function()
      error("ambient lookup must not be used")
    end
    local ok, result = pcall(function()
      return helper.complete(function()
        return owner:run(
          helper.spec("printf selected", {
            stdio = { kind = "pty", columns = 80, rows = 24 },
          }),
          { capture = { max_bytes = 100 } }
        )
      end)
    end)
    vim.fn.exepath = exepath
    assert.is_true(ok, vim.inspect(result))
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("selected", result.output)
  end)

  for _, kind in ipairs({ "pipes", "pty" }) do
    local stdio = kind == "pty" and { kind = "pty", columns = 80, rows = 24 } or { kind = "pipes" }
    it("reports native execution failures with the " .. kind .. " backend's startup semantics", function()
      local target = directory .. "/missing-interpreter"
      assert(fs.write_all(target, "#!" .. directory .. "/absent\n", "w", 448))
      local selected = { argv = { target }, cwd = directory, stdio = stdio, timeout_ms = 1000 }
      local err = helper.failure(function()
        owner:spawn(selected)
      end)
      assert.are.equal("process_start", err.code)
      for _, code in ipairs({ 122, 127 }) do
        local result = helper.complete(function()
          return owner:run(helper.spec("exit " .. code, { stdio = stdio }), { capture = false })
        end)
        assert.are.equal(code, result.code)
      end
    end)

    if jit.os == "Linux" then
      it("reserves the " .. kind .. " identity until queued output and cleanup finish", function()
        local marker = directory .. "/pid"
        local handle = owner:spawn(helper.spec("printf '%s' $$ > " .. vim.fn.shellescape(marker) .. "; printf ready", {
          stdio = stdio,
          timeout_ms = 1000,
        }))
        local pid, status
        local observed = false
        local timer = assert(vim.uv.new_timer())
        timer:start(100, 0, function()
          observed = true
          timer:close()
        end)
        assert(vim.wait(2000, function()
          if not observed then
            return false
          end
          local value = fs.read(marker)
          pid = value and tonumber(value)
          if not pid then
            return false
          end
          local stat = fs.read("/proc/" .. pid .. "/stat")
          status = stat and stat:match("^%d+ %b() (%a)") or "reaped"
          return status == "Z" or status == "reaped"
        end, 5, true))
        assert.are.equal("Z", status, "the original PID was released before the last possible signal")
        assert.are.equal(
          0,
          helper.complete(function()
            return handle:wait()
          end).code
        )
        assert.is_nil(vim.uv.fs_stat("/proc/" .. assert(pid)))
      end)
    end
  end

  it("stops PTY signalling after native reaping", function()
    local kill = vim.uv.kill
    local calls = {}
    vim.uv.kill = function(pid, signal)
      calls[#calls + 1] = { pid, signal }
      return nil, "ESRCH", "ESRCH"
    end
    local ok, err = pcall(function()
      local handle = owner:spawn(helper.spec("exit 0", {
        stdio = { kind = "pty", columns = 80, rows = 24 },
        timeout_ms = 50,
      }))
      local elapsed = false
      local timer = assert(vim.uv.new_timer())
      timer:start(150, 0, function()
        elapsed = true
        timer:close()
      end)
      assert(vim.wait(2000, function()
        return elapsed
      end, 5, true))
      local result = helper.complete(function()
        return handle:wait()
      end)
      assert.are.equal(0, result.code)
      assert.is_false(result.timed_out)
      for _, call in ipairs(calls) do
        assert.is_not.equal(0, call[2], "PID probes do not establish process identity")
      end
      local count = #calls
      handle:terminate("already finished")
      handle:dispose("already finished")
      assert.are.equal(count, #calls)
    end)
    vim.uv.kill = kill
    assert.is_true(ok, vim.inspect(err))
  end)
end)
