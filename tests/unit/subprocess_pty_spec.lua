local assert = require("luassert")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")

describe("local subprocess PTYs", function()
  if jit.os == "Windows" then
    pending("native Windows PTYs are exercised in tests/windows")
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
  local function spec(command)
    return helper.spec(command, { stdio = { kind = "pty", columns = 80, rows = 24 } })
  end

  it("uses a controlling terminal with input and column-first resize", function()
    local output = ""
    local buffers = vim.api.nvim_list_bufs()
    local handle =
      owner:spawn(spec("stty -echo; test -t 0 && printf ready; IFS= read -r line; printf '%s:' \"$line\"; stty size"), {
        on_output = function(event)
          assert.are.equal("pty", event.stream)
          output = output .. event.data
        end,
      })
    assert(vim.wait(3000, function()
      return output:find("ready", 1, true) ~= nil
    end, 5))
    assert.is_true(handle:resize(100, 30))
    assert.is_true(handle:resize(120, 40))
    assert.is_true(handle:write("input\n"))
    assert.is_true(helper.complete(function()
      return handle:flush()
    end))
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal(0, result.code)
    assert.matches("input:40 120", output, 1, true)
    assert.are.same(buffers, vim.api.nvim_list_bufs())
  end)

  it("reconstructs binary line fragments and ANSI bytes without decoding UTF-8", function()
    local result = helper.complete(function()
      return owner:run(spec("stty -opost; printf '\\000a\\nb\\033[31m\\303'; printf '\\251\\033[0m' >&2"), {
        capture = { max_bytes = 100 },
      })
    end)
    assert.are.equal("\0a\nb\27[31m\195\169\27[0m", result.stdout)
    assert.are.equal(result.stdout, result.output)
    assert.are.equal("", result.stderr)
  end)

  it("treats Ctrl-C as bytes when the target terminal has signals disabled", function()
    local output = ""
    local handle = owner:spawn(spec("stty raw -echo; printf ready; dd bs=1 count=1 2>/dev/null"), {
      on_output = function(event)
        output = output .. event.data
      end,
    })
    assert(vim.wait(3000, function()
      return output == "ready"
    end, 5))
    handle:write("\3")
    assert.are.equal(
      0,
      helper.complete(function()
        return handle:wait()
      end).code
    )
    assert.are.equal("ready\3", output)
  end)

  it("rejects portable EOF and terminates explicitly", function()
    local handle = owner:spawn(spec("sleep 10"))
    local err = helper.failure(function()
      handle:close_stdin()
    end)
    assert.are.equal("unsupported_control", err.code)
    handle:terminate("finished")
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal("finished", result.termination_reason)
    assert.is_false(result.timed_out)
  end)

  it("sends NUL and partial UTF-8 input through a raw PTY", function()
    local output = ""
    local handle = owner:spawn(spec("stty raw -echo; printf ready; dd bs=1 count=4 2>/dev/null"), {
      on_output = function(event)
        output = output .. event.data
      end,
    })
    assert(vim.wait(3000, function()
      return output == "ready"
    end, 5))
    handle:write("\0\195")
    handle:write("\169\n")
    assert.are.equal(
      0,
      helper.complete(function()
        return handle:wait()
      end).code
    )
    assert.are.equal("ready\0\195\169\n", output)
  end)

  it("preserves exact environments without adding Neovim variables", function()
    local selected = spec("unused")
    selected.argv = { vim.fn.exepath("env") }
    selected.environment = { inherit = false, set = {} }
    local empty = helper.complete(function()
      return owner:run(selected, { capture = { max_bytes = 1024 } })
    end)
    assert.are.equal(0, empty.code, vim.inspect(empty))
    assert.are.equal("", empty.stdout)
    selected.environment.set = { TERM = "vt100", NVIM = "", SAFE = "value" }
    local result = helper.complete(function()
      return owner:run(selected, { capture = { max_bytes = 1024 } })
    end)
    local entries = vim.split(assert(result.stdout):gsub("\r", ""), "\n", { plain = true, trimempty = true })
    table.sort(entries)
    assert.are.same({ "NVIM=", "SAFE=value", "TERM=vt100" }, entries)
  end)

  it("requires PATH for a bare executable instead of guessing a libc search default", function()
    local selected = spec("exit 0")
    selected.environment = { inherit = false, set = { TERM = "vt100", NVIM = "" } }
    assert.are.equal(
      "pty_unavailable",
      helper.failure(function()
        owner:spawn(selected)
      end).code
    )
    selected.environment.set.PATH = vim.fn.fnamemodify(vim.fn.exepath("sh"), ":h")
    assert.are.equal(
      0,
      helper.complete(function()
        return owner:run(selected, { capture = false })
      end).code
    )
  end)

  it("resolves a relative executable against the target cwd and PATH", function()
    local root = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(root, "p"))
    assert(require("neoagent.fs").write_all(root .. "/custom-command", "#!/bin/sh\nprintf found", "w", 448))
    local selected = spec("unused")
    selected.argv = { "custom-command" }
    selected.cwd = root
    selected.environment = { inherit = true, set = { PATH = "." } }
    local result = helper.complete(function()
      return owner:run(selected, { capture = { max_bytes = 100 } })
    end)
    vim.fn.delete(root, "rf")
    assert.are.equal("found", result.stdout)
  end)

  it("enforces timeout without a terminal buffer", function()
    local selected = spec("sleep 10")
    selected.timeout_ms = 100
    local handle = owner:spawn(selected)
    assert.is_true(helper.complete(function()
      return handle:wait()
    end).timed_out)
  end)

  it("preserves native exit when the deadline's editor callback is delayed", function()
    local selected = spec("exit 0")
    selected.timeout_ms = 200
    local handle = owner:spawn(selected)
    local elapsed = false
    local timer = assert(vim.uv.new_timer())
    timer:start(400, 0, function()
      timer:close()
      elapsed = true
    end)
    assert(vim.wait(2000, function()
      return elapsed
    end, 5, true))
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal(0, result.code)
    assert.is_false(result.timed_out)
    assert.is_nil(result.termination_reason)
  end)

  it("retains scope ownership when it closes before native startup returns", function()
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
    local ok, failure = pcall(owner.spawn, owner, spec("exec sleep 10"))
    pty.new = original
    assert.is_false(ok)
    assert.are.equal("process_disposed", require("neoagent.util").normalize_error(failure).code)
    assert.is_true(helper.complete(function()
      return owner:wait(3000)
    end))
    assert.is_true(exited)
  end)

  it("joins native cleanup before a standalone run reports an observer error", function()
    local pty = require("neoagent.subprocess.pty")
    local original = pty.new
    local exited = false
    pty.new = function(selected, env, callbacks)
      local exit = callbacks.exited
      callbacks.exited = function(...)
        exited = true
        exit(...)
      end
      return original(selected, env, callbacks)
    end
    local ok, err = pcall(function()
      local result = helper.complete(function()
        return subprocess.run(spec("trap '' HUP TERM; printf ready; while :; do sleep 1; done"), {
          capture = false,
          on_output = function()
            error("observer rejected output")
          end,
        })
      end)
      assert.are.equal("process_observer", assert(result.error).code)
      assert.is_true(exited, "the operation returned before native cleanup")
    end)
    pty.new = original
    assert.is_true(ok, vim.inspect(err))
  end)

  it("forces native cleanup when the target ignores HUP and TERM", function()
    local ready = false
    local handle = owner:spawn(spec("trap '' HUP TERM; printf ready; while :; do sleep 1; done"), {
      on_output = function(event)
        ready = ready or event.data:find("ready", 1, true) ~= nil
      end,
    })
    assert(vim.wait(2000, function()
      return ready
    end, 5))
    handle:dispose("owner finished")
    assert.is_true(helper.complete(function()
      return handle:wait_cleanup()
    end, 7000))
  end)
end)
