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

end)
