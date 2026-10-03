local assert = require("luassert")
local async = require("neoagent.async")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")
local limits = require("neoagent.subprocess.validate")

describe("native subprocess PTY ownership", function()
  if jit.os == "Windows" then
    pending("POSIX native PTYs; Windows has its native suite")
    return
  end

  ---@type Neoagent.SubprocessScope
  local owner
  ---@type string[]
  local directories
  before_each(function()
    owner = subprocess.scope()
    directories = {}
  end)
  after_each(function()
    owner:close("test finished")
    assert.is_true(helper.complete(function()
      return owner:wait(8000)
    end, 9000))
    for _, directory in ipairs(directories) do
      vim.fn.delete(directory, "rf")
    end
  end)

  local function spec(command)
    return helper.spec(command, { stdio = { kind = "pty", columns = 80, rows = 24 } })
  end

  it("reports an unavailable shebang interpreter before publishing a handle", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root, "p")
    local file = root .. "/target"
    assert(require("neoagent.fs").write_all(file, "#!" .. root .. "/missing-interpreter\n", "w", 448))
    local selected = spec("unused")
    selected.argv = { file }
    assert.are.equal(
      "process_start",
      helper.failure(function()
        owner:spawn(selected)
      end).code
    )
  end)

  it("matches pipe execution of executable text without a shebang", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root, "p")
    assert(require("neoagent.fs").write_all(root .. "/target", 'printf "%s" "$1:$VALUE"; exit 23\n', "w", 448))
    for _, program in ipairs({ root .. "/target", "target" }) do
      local selected = spec("unused")
      selected.argv = { program, "literal $() *" }
      selected.environment = { inherit = false, set = { PATH = root, VALUE = "environment" } }
      selected.stdio = { kind = "pipes" }
      local pipes = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 1024 } })
      end)
      selected.stdio = { kind = "pty", columns = 80, rows = 24 }
      local terminal = helper.complete(function()
        return owner:run(selected, { capture = { max_bytes = 1024 } })
      end)
      if pipes.error then
        assert.are.equal("process_start", assert(terminal.error).code)
      else
        assert.are.equal(23, terminal.code, vim.inspect(terminal))
        assert.are.equal("literal $() *:environment", terminal.output)
      end
    end
  end)

  it("skips overlong PATH entries before a usable native executable", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root, "p")
    assert(require("neoagent.fs").write_all(root .. "/target", "#!/bin/sh\nprintf selected\n", "w", 448))
    for _, repetitions in ipairs({ 150, 600 }) do
      for _, stdio in ipairs({ { kind = "pipes" }, { kind = "pty", columns = 80, rows = 24 } }) do
        local selected = helper.spec("unused", {
          argv = { "target" },
          stdio = stdio,
          environment = { inherit = false, set = { PATH = ("/missing"):rep(repetitions) .. ":" .. root } },
        })
        local result = helper.complete(function()
          return owner:run(selected, { capture = { max_bytes = 1024 } })
        end)
        assert.are.equal(0, result.code, vim.inspect(result))
        assert.are.equal("selected", result.output)
      end
    end
  end)

  it("bounds accepted input until native writes complete", function()
    local ready = false
    local handle = owner:spawn(spec("stty raw -echo; printf ready; exec sleep 30"), {
      on_output = function(event)
        ready = ready or event.data:find("ready", 1, true) ~= nil
      end,
    })
    assert(vim.wait(2000, function()
      return ready
    end, 5))
    local chunk = string.rep("x", limits.WRITE_BYTES)
    for _ = 1, limits.PENDING_BYTES / limits.WRITE_BYTES do
      assert.is_true(handle:write(chunk))
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
    helper.wait(flushing)
    assert.are.equal("running", handle:state().phase)
  end)

  it("preserves an exact empty environment without injecting editor variables", function()
    local selected = spec("unused")
    selected.argv = { vim.fn.exepath("env") }
    selected.environment = { inherit = false, set = {} }
    local result = helper.complete(function()
      return owner:run(selected, { capture = { max_bytes = 1024 } })
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("", result.output)
  end)

  it("preserves native environment bytes across repeated launches with aggressive collection", function()
    local pause = collectgarbage("setpause", 0)
    local step = collectgarbage("setstepmul", 1000)
    local ok, failure = pcall(function()
      for iteration = 1, 80 do
        local values, expected = {}, {}
        for index = 1, 64 do
          local name = ("NATIVE_%02d"):format(index)
          local value = ("%d:%d:"):format(iteration, index) .. ("value"):rep(40)
          values[name] = value
          expected[#expected + 1] = name .. "=" .. value
        end
        local selected = spec("unused")
        -- NUL separators leave the environment bytes independent of the
        -- terminal's newline expansion, including retries on a full queue.
        selected.argv = { vim.fn.exepath("env"), "-0" }
        selected.environment = { inherit = false, set = values }
        collectgarbage("collect")
        local result = helper.complete(function()
          return owner:run(selected, { capture = { max_bytes = 32768 } })
        end)
        assert.are.equal(0, result.code, vim.inspect(result))
        local lines = vim.split(assert(result.output), "\0", { trimempty = true })
        table.sort(lines)
        assert.are.same(expected, lines)
      end
    end)
    collectgarbage("setpause", pause)
    collectgarbage("setstepmul", step)
    assert.is_true(ok, vim.inspect(failure))
  end)

  it("assigns the requested dimensions to the child's controlling terminal", function()
    local result = helper.complete(function()
      return owner:run(spec("stty size </dev/tty"), { capture = { max_bytes = 1024 } })
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("24 80", vim.trim(assert(result.output)))
  end)

  it("terminates original-group descendants after their leader exits", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root, "p")
    local marker = root .. "/survived"
    local result = helper.complete(function()
      return owner:run(spec("trap '' HUP; (sleep 0.2; printf late > " .. vim.fn.shellescape(marker) .. ") & exit 0"), {
        capture = false,
      })
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    local escaped = vim.wait(400, function()
      return vim.uv.fs_stat(marker) ~= nil
    end, 5)
    assert.is_false(escaped)
  end)

  it("continues PATH search after a missing interpreter and preserves native exit codes", function()
    local root = vim.fn.tempname()
    directories[#directories + 1] = root
    vim.fn.mkdir(root .. "/first", "p")
    vim.fn.mkdir(root .. "/second", "p")
    local fs = require("neoagent.fs")
    assert(fs.write_all(root .. "/first/target", "#!" .. root .. "/missing-interpreter\n", "w", 448))
    assert(fs.write_all(root .. "/second/target", "#!/bin/sh\nprintf selected\nexit 127\n", "w", 448))
    local selected = spec("unused")
    selected.argv = { "target" }
    selected.environment = { inherit = false, set = { PATH = root .. "/first:" .. root .. "/second" } }
    local result = helper.complete(function()
      return owner:run(selected, { capture = { max_bytes = 1024 } })
    end)
    assert.are.equal(127, result.code, vim.inspect(result))
    assert.are.equal("selected", result.output)
  end)

  it("escalates termination independently of other editor jobs", function()
    local output = ""
    local selected = spec("trap '' HUP TERM; printf ready; while :; do sleep 1; done")
    selected.kill_grace_ms = 30
    local handle = owner:spawn(selected, {
      on_output = function(event)
        output = output .. event.data
      end,
    })
    assert(vim.wait(2000, function()
      return output == "ready"
    end, 5))
    handle:terminate("test escalation")
    local result = helper.complete(function()
      return handle:wait()
    end, 2000)
    assert.are.equal(9, result.signal, vim.inspect(result))
    assert.are.equal("test escalation", result.termination_reason)
  end)

  it("drains all terminal bytes after the root exits", function()
    local result = helper.complete(function()
      return owner:run(spec("stty -opost; head -c 262144 /dev/zero"), {
        capture = { max_bytes = 262144 },
      })
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal(string.rep("\0", 262144), result.output)
  end)
end)
