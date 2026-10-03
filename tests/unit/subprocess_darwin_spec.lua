local assert = require("luassert")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")

describe("macOS PTY fork boundary", function()
  if jit.os ~= "OSX" then
    pending("requires native macOS")
    return
  end

  ---@type Neoagent.SubprocessScope
  local owner
  before_each(function()
    owner = subprocess.scope()
  end)
  after_each(function()
    owner:close("test complete")
    assert.is_true(helper.complete(function()
      return owner:wait(4000)
    end))
  end)
  local function spec()
    return helper.spec("test -t 0 && test -t 1 && test -t 2 && printf native", {
      stdio = { kind = "pty", columns = 80, rows = 24 },
    })
  end

  it("spawns and rejects execution under native worker pressure within an external watchdog", function()
    local directory = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(directory, 448))
    -- The observing editor stays outside the fork critical section, so a native
    -- deadlock in the fixture cannot disable this watchdog or test teardown.
    local ok, value = pcall(function()
      return vim
        .system({
          assert(vim.env.NEOAGENT_NVIM),
          "--headless",
          "--noplugin",
          "-u",
          "tests/minimal_init.lua",
          "-l",
          "tests/fixtures/subprocess_fork_stress.lua",
          directory,
        }, { text = true })
        :wait(20000)
    end)
    vim.fn.delete(directory, "rf")
    assert.is_true(ok, vim.inspect(value))
    assert.are.equal(0, value.code, value.stderr)
    assert.matches("48 PTY starts under native worker pressure completed", assert(value.stdout), 1, true)
  end)

  it("restores Lua hooks and a stopped collector after native startup", function()
    local previous, mask, count = debug.gethook()
    local collecting = collectgarbage("isrunning")
    local calls = 0
    local function hook(...)
      calls = calls + 1
      if type(previous) == "function" then
        previous(...)
      end
    end
    local ok, err = pcall(function()
      collectgarbage("stop")
      debug.sethook(hook, "l")
      local handle = owner:spawn(spec())
      assert.is_false(collectgarbage("isrunning"))
      assert.are.equal(hook, debug.gethook())
      assert.is_true(calls > 0)
      assert.are.equal(
        0,
        helper.complete(function()
          return handle:wait()
        end).code
      )
    end)
    if collecting then
      collectgarbage("restart")
    end
    assert(previous == nil or type(previous) == "function")
    debug.sethook(previous, mask, count)
    assert.is_true(ok, vim.inspect(err))
  end)

  it("rejects active sampling before creating a child and allows retry after it stops", function()
    local profiler = require("jit.profile")
    profiler.start("i10", function() end)
    local ok, failure = pcall(helper.failure, function()
      owner:spawn(spec())
    end)
    profiler.stop()
    assert.is_true(ok, vim.inspect(failure))
    assert.are.equal("process_start", failure.code)
    assert.matches("sampling profiling", assert(failure.message), 1, true)
    local result = helper.complete(function()
      return owner:run(spec(), { capture = { max_bytes = 1024 } })
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("native", result.output)
  end)

  it("rejects an un-restorable native hook before forking", function()
    local gethook = debug.gethook
    debug.gethook = function()
      return "external hook", "l", 0
    end
    local ok, failure = pcall(helper.failure, function()
      owner:spawn(spec())
    end)
    debug.gethook = gethook
    assert.is_true(ok, vim.inspect(failure))
    assert.are.equal("process_start", failure.code)
    assert.matches("external native debug hook", assert(failure.message), 1, true)
  end)

  for _, operation in ipairs({ "signal set", "fork", "attachment" }) do
    it("retains partial terminal ownership after " .. operation .. " failure", function()
      local module = "neoagent.subprocess.fork_exec"
      local original = require(module)
      local native = require("ffi")
      local children = require("neoagent.subprocess.posix_child")
      local new_child = children.new
      local hook, mask, count = debug.gethook()
      local collecting = collectgarbage("isrunning")
      local C = native.C
      package.loaded.ffi = setmetatable({
        cdef = function() end,
        C = setmetatable({
          sigfillset = function(set)
            if operation == "signal set" then
              local _ = native.errno(22)
              return -1
            end
            return C.sigfillset(set)
          end,
          fork = function()
            if operation == "fork" then
              local _ = native.errno(11)
              return -1
            end
            return C.fork()
          end,
        }, { __index = C }),
      }, { __index = native })
      package.loaded[module] = nil
      local loaded, load_error = pcall(require, module)
      package.loaded.ffi = native
      children.new = function(callbacks)
        local child = new_child(callbacks)
        local attach = child.attach
        child.attach = function(pid)
          attach(pid)
          if operation == "attachment" then
            error("child attachment failed after acquiring ownership")
          end
        end
        return child
      end
      local ok, failure = pcall(helper.failure, function()
        assert.is_true(loaded, vim.inspect(load_error))
        owner:spawn(spec())
      end)
      package.loaded[module], children.new = original, new_child
      assert.is_true(ok, vim.inspect(failure))
      assert.are.equal("process_start", failure.code)
      assert.are.same({ hook, mask, count }, { debug.gethook() })
      assert.are.equal(collecting, collectgarbage("isrunning"))
      assert.is_true(helper.complete(function()
        return owner:wait(4000)
      end))
    end)
  end

  it("bounds missing native execution acknowledgement and retains startup cleanup", function()
    local limits = require("neoagent.subprocess.validate")
    local duration = limits.START_MS
    local probe = assert(vim.uv.new_pipe(false))
    local methods = getmetatable(probe).__index
    local read_start = methods.read_start
    probe:close()
    ---@type uv.uv_pipe_t?
    local acknowledgement
    ---@type uv.read_start.callback?
    local receive
    methods.read_start = function(stream, callback)
      acknowledgement, receive = stream, callback
      return 0
    end
    limits.START_MS = 20
    local ok, failure = pcall(helper.failure, function()
      owner:spawn(spec())
    end)
    methods.read_start, limits.START_MS = read_start, duration
    local stream = assert(acknowledgement)
    if not stream:is_closing() then
      assert(read_start(stream, assert(receive)))
    end
    assert.is_true(ok, vim.inspect(failure))
    assert.are.equal("process_start", failure.code)
    assert.matches("acknowledgement", assert(failure.message), 1, true)
    assert.is_true(helper.complete(function()
      return owner:wait(4000)
    end))
  end)
end)
