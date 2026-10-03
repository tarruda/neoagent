local assert = require("luassert")
local subprocess = require("neoagent.subprocess_common")
local pipe = require("neoagent.subprocess.pipe")
local helper = require("tests.helpers.subprocess")

describe("subprocess call boundary", function()
  ---@type Neoagent.SubprocessScope
  local owner
  before_each(function()
    owner = subprocess.scope()
  end)
  after_each(function()
    owner:close("test finished")
    assert.is_true(helper.complete(function()
      return owner:wait(1000)
    end))
  end)

  it("rejects Windows PTY dimensions outside signed native coordinates before allocation", function()
    local platform = jit.os
    local pty = require("neoagent.subprocess.pty")
    local original = pty.new
    local attempted = false
    pty.new = function()
      attempted = true
      error("unexpected native allocation")
    end
    jit.os = "Windows"
    local ok, err = pcall(function()
      for _, size in ipairs({ { 32768, 24 }, { 80, 32768 }, { 65535, 65535 } }) do
        local failure = helper.failure(function()
          owner:spawn(helper.spec("unused", { stdio = { kind = "pty", columns = size[1], rows = size[2] } }))
        end)
        assert.are.equal("invalid_terminal_size", failure.code)
      end
    end)
    jit.os, pty.new = platform, original
    assert.is_true(ok, vim.inspect(err))
    assert.is_false(attempted)
  end)

  it("rejects invalid specs before creating a process", function()
    local original = pipe.new
    local started = 0
    pipe.new = function()
      started = started + 1
      error("unexpected process")
    end
    local ok, err = pcall(function()
      for _, edit in ipairs({
        function(v)
          v.argv = {}
        end,
        function(v)
          v.argv = { "" }
        end,
        function(v)
          v.argv = { "echo", "a\0b" }
        end,
        function(v)
          rawset(v.argv, "named", "value")
        end,
        function(v)
          rawset(v.argv, 3, 42)
        end,
        function(v)
          v.cwd = ""
        end,
        function(v)
          v.cwd = "a\0b"
        end,
        function(v)
          v.cwd = vim.fn.tempname() .. "/missing"
        end,
        function(v)
          v.cwd = "README.md"
        end,
        function(v)
          rawset(v, "worker", {})
        end,
        function(v)
          rawset(v, "stdio", nil)
        end,
        function(v)
          rawset(v.stdio, "kind", "terminal")
        end,
        function(v)
          rawset(v.stdio, "stdin", true)
        end,
        function(v)
          rawset(v.stdio, "columns", 80)
        end,
        function(v)
          v.stdio = { kind = "pty", columns = 0, rows = 1 }
        end,
        function(v)
          v.stdio = { kind = "pty", columns = 1, rows = 65536 }
        end,
        function(v)
          v.stdio = { kind = "pty", columns = 1.5, rows = 1 }
        end,
        function(v)
          v.timeout_ms = 0
        end,
        function(v)
          v.timeout_ms = math.huge
        end,
        function(v)
          v.timeout_ms = 0 / 0
        end,
        function(v)
          v.kill_grace_ms = -1
        end,
        function(v)
          v.kill_grace_ms = 60001
        end,
        function(v)
          rawset(v, "environment", { inherit = true })
        end,
        function(v)
          rawset(v, "environment", { inherit = "true", set = {} })
        end,
        function(v)
          v.environment = { inherit = true, set = { ["a=b"] = "x" } }
        end,
        function(v)
          v.environment = { inherit = true, set = { [""] = "x" } }
        end,
        function(v)
          v.environment = { inherit = true, set = { A = "x\0y" } }
        end,
        function(v)
          rawset(v, "environment", { inherit = true, set = { A = 1 } })
        end,
      }) do
        local spec = helper.spec("unused")
        edit(spec)
        local failure = helper.failure(function()
          owner:spawn(spec)
        end)
        assert.is_true(failure.kind == "process_validation" or failure.kind == "invalid_terminal_size")
      end
      local observer = {}
      rawset(observer, "on_output", false)
      assert.are.equal(
        "process_validation",
        helper.failure(function()
          owner:spawn(helper.spec("unused"), observer)
        end).kind
      )
    end)
    pipe.new = original
    assert.is_true(ok, vim.inspect(err))
    assert.are.equal(0, started)
  end)

  it("requires a capture policy and validates initial input before spawn", function()
    for _, options in ipairs({
      {},
      { capture = true },
      { capture = {} },
      { capture = { max_bytes = 0 } },
      { capture = { max_bytes = math.huge } },
      { capture = false, extra = true },
      { capture = false, input = { chunks = { "data" }, close = true } },
      { capture = false, input = { chunks = { 1 }, close = false } },
      { capture = false, input = { chunks = {}, close = 0 } },
      { capture = false, input = { chunks = {}, close = false, allow_early_close = "yes" } },
    }) do
      local result = helper.complete(function()
        ---@type Neoagent.SubprocessRunOptions
        local selected = { capture = false }
        rawset(selected, "capture", nil)
        for name, value in pairs(options) do
          rawset(selected, name, value)
        end
        return subprocess.run(helper.spec("unused"), selected)
      end)
      assert.are.equal("process_validation", assert(result.error).kind)
    end
    local result = helper.complete(function()
      return subprocess.run(helper.spec("unused", { stdio = { kind = "pty", columns = 80, rows = 24 } }), {
        capture = false,
        input = { chunks = {}, close = true },
      })
    end)
    assert.are.equal("process_validation", assert(result.error).kind)
  end)

  it("runs locally when higher-level packages are unavailable", function()
    if jit.os == "Windows" then
      return
    end
    local result = vim
      .system({
        assert(vim.env.NEOAGENT_NVIM),
        "--headless",
        "--noplugin",
        "-u",
        "tests/minimal_init.lua",
        "-l",
        "tests/fixtures/subprocess_boundary.lua",
      }, { text = true, timeout = 10000 })
      :wait()
    assert.are.equal(0, result.code, result.stderr)
    assert.are.equal("local", result.stdout)
  end)
end)
