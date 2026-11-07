local assert = require("luassert")
local fs = require("neoagent.fs")
---@type Neoagent.LuaJitProfiler
local native = require("jit.profile")
local profiler = require("neoagent.profiler")

describe("LuaJIT profiling", function()
  local original_start, original_stop, original_dumpstack = native.start, native.stop, native.dumpstack
  local original_stdpath, original_write, original_notify = vim.fn.stdpath, fs.write_all, vim.notify
  local original_preload = package.preload["jit.profile"]
  ---@type string
  local directory
  ---@type (fun(thread: thread, samples: integer, vmstate: string))?
  local sample
  local stack, starts, stops
  ---@type {message: string, level: integer}[]
  local notifications

  before_each(function()
    directory = vim.fn.tempname()
    assert(fs.mkdirp(directory))
    vim.fn.stdpath = function()
      return directory
    end
    sample, stack, starts, stops = nil, "", 0, 0
    notifications = {}
    native.start = function(mode, callback)
      assert.are.equal("fi2", mode)
      starts = starts + 1
      sample = callback
    end
    native.stop = function()
      stops = stops + 1
    end
    native.dumpstack = function(_, format, depth)
      assert.are.equal("pFZ\n", format)
      assert.are.equal(10, depth)
      return stack
    end
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level or vim.log.levels.INFO }
    end
  end)

  after_each(function()
    fs.write_all = original_write
    native.start, native.stop, native.dumpstack = original_start, original_stop, original_dumpstack
    profiler.stop()
    vim.fn.stdpath, vim.notify = original_stdpath, original_notify
    package.loaded["jit.profile"], package.preload["jit.profile"] = native, original_preload
    vim.fn.delete(directory, "rf")
  end)

  ---@param text string
  ---@param count integer
  ---@param state string
  local function emit(text, count, state)
    stack = text
    assert(sample)(coroutine.create(function() end), count, state)
  end

  it("saves weighted function samples, callers, and VM states in a private report", function()
    local path = assert(profiler.start())
    assert.are.equal(directory .. "/neoagent/profiling", vim.fs.dirname(path))
    assert.are.equal("", assert(fs.read(path)))
    emit("/plugin.lua:work\n/plugin.lua:tool", 8, "N")
    emit("/plugin.lua:work\n/plugin.lua:render", 2, "I")
    emit("/plugin.lua:native\n/plugin.lua:tool", 4, "C")
    emit("/plugin.lua:allocate", 1, "G")
    emit("/plugin.lua:compile", 1, "J")

    assert.are.equal(path, assert(profiler.stop()))
    assert.are.equal(1, starts)
    assert.are.equal(1, stops)
    assert.are.equal(0, vim.fn.exists("#NeoagentProfiler#VimLeavePre"))
    local report = assert(fs.read(path))
    assert.matches("Samples: 16", report, 1, true)
    assert.matches(" 50.00%        8  Compiled Lua", report, 1, true)
    assert.matches(" 12.50%        2  Interpreted Lua", report, 1, true)
    assert.matches(" 25.00%        4  C code", report, 1, true)
    assert.matches("  6.25%        1  Garbage collector", report, 1, true)
    assert.matches("  6.25%        1  JIT compiler", report, 1, true)
    assert.matches(" 62.50%       10  /plugin.lua:work\n", report, 1, true)
    assert.matches("/plugin.lua:work < /plugin.lua:tool", report, 1, true)
    assert.is_true(assert((report:find("Garbage collector", 1, true))) < assert((report:find("JIT compiler", 1, true))))
    if jit.os ~= "Windows" then
      assert.are.equal(384, bit.band(assert(vim.uv.fs_stat(path)).mode, 511))
      assert.are.equal(448, bit.band(assert(vim.uv.fs_stat(vim.fs.dirname(path))).mode, 511))
    end
  end)

  it("rejects duplicate starts and leaves the sampler untouched when inactive", function()
    local _, inactive = profiler.stop()
    assert.matches("No LuaJIT profile", assert(inactive), 1, true)
    assert.are.equal(0, stops)
    local path = assert(profiler.start())
    local duplicate, err = profiler.start()
    assert.is_nil(duplicate)
    assert.matches("already active", assert(err), 1, true)
    assert.are.equal(1, starts)
    emit("/plugin.lua:work", 3, "N")
    assert.are.equal(path, assert(profiler.stop()))
    local next_path = assert(profiler.start())
    assert.are_not.equal(path, next_path)
    assert.are.equal(next_path, assert(profiler.stop()))
    assert.matches("No samples collected.", assert(fs.read(next_path)), 1, true)
  end)

  it("represents unavailable stacks without losing sample counts", function()
    local path = assert(profiler.start())
    emit("", 1, "C")
    emit("/plugin.lua:unknown", 1, "unknown")
    assert(profiler.stop())
    local report = assert(fs.read(path))
    assert.matches("Samples: 2", report, 1, true)
    assert.matches("(unavailable)", report, 1, true)
    assert.matches("unknown", report, 1, true)
  end)

  it("reports unavailable profiler support without creating a recording", function()
    package.loaded["jit.profile"] = nil
    package.preload["jit.profile"] = function()
      error("profiler is not built in", 0)
    end
    local path, err = profiler.start()
    assert.is_nil(path)
    assert.matches("LuaJIT sampling profiler is unavailable", assert(err), 1, true)
    assert.are.equal(0, starts)
    assert.are.equal(0, vim.fn.isdirectory(directory .. "/neoagent"))
  end)

  it("reports directory and file creation failures before starting sampling", function()
    assert(fs.write_all(directory .. "/neoagent", "file"))
    local path, err = profiler.start()
    assert.is_nil(path)
    assert.matches("Cannot create profiling directory", assert(err), 1, true)
    vim.fn.delete(directory .. "/neoagent")
    fs.write_all = function()
      return nil, "disk full"
    end
    path, err = profiler.start()
    assert.is_nil(path)
    assert.matches("Cannot create LuaJIT profile: disk full", assert(err), 1, true)
    assert.are.equal(0, starts)
  end)

  it("removes reserved files and exit callbacks after profiler startup fails", function()
    native.start = function()
      error("cannot start sampling", 0)
    end
    local path, err = profiler.start()
    assert.is_nil(path)
    assert.matches("Cannot start LuaJIT profiler: cannot start sampling", assert(err), 1, true)
    assert.are.same({}, vim.fn.globpath(directory, "**/*.txt", false, true))
    assert.are.equal(0, vim.fn.exists("#NeoagentProfiler#VimLeavePre"))
    local _, inactive = profiler.stop()
    assert.matches("No LuaJIT profile", assert(inactive), 1, true)
  end)

  it("retains ownership when stopping fails and allows a retry", function()
    local path = assert(profiler.start())
    emit("/plugin.lua:work", 1, "N")
    local stop = native.stop
    native.stop = function()
      error("cannot stop sampling", 0)
    end
    local saved, err = profiler.stop()
    assert.is_nil(saved)
    assert.matches("Cannot stop LuaJIT profiler", assert(err), 1, true)
    assert.are.equal(1, vim.fn.exists("#NeoagentProfiler#VimLeavePre"))
    native.stop = stop
    assert.are.equal(path, assert(profiler.stop()))
  end)

  it("retries a failed save without stopping sampling again", function()
    local path = assert(profiler.start())
    emit("/plugin.lua:work", 5, "N")
    fs.write_all = function()
      return nil, "disk full"
    end
    local saved, err = profiler.stop()
    assert.is_nil(saved)
    assert.matches("retry :NeoagentProfile stop", assert(err), 1, true)
    assert.are.equal(1, stops)
    local duplicate, duplicate_err = profiler.start()
    assert.is_nil(duplicate)
    assert.matches("awaiting save", assert(duplicate_err), 1, true)
    fs.write_all = original_write
    assert.are.equal(path, assert(profiler.stop()))
    assert.are.equal(1, stops)
    assert.matches("Samples: 5", assert(fs.read(path)), 1, true)
  end)

  it("reports exit save failures and preserves the data for retry", function()
    local path = assert(profiler.start())
    emit("/plugin.lua:work", 3, "N")
    fs.write_all = function()
      return nil, "disk full"
    end
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "NeoagentProfiler" })
    assert.are.equal(1, #notifications)
    local notification = assert(notifications[1])
    assert.are.equal(vim.log.levels.ERROR, notification.level)
    assert.matches("Cannot save LuaJIT profile", notification.message, 1, true)
    fs.write_all = original_write
    assert.are.equal(path, assert(profiler.stop()))
  end)

  it("exposes start and stop commands with completion and reports the saved path", function()
    if not vim.g.loaded_neoagent then
      vim.cmd("runtime plugin/neoagent.lua")
    end
    assert.are.same({ "start", "stop" }, vim.fn.getcompletion("NeoagentProfile ", "cmdline"))
    vim.cmd("NeoagentProfile invalid")
    vim.cmd("NeoagentProfile stop")
    vim.cmd("NeoagentProfile start")
    vim.cmd("NeoagentProfile start")
    emit("/plugin.lua:work", 2, "N")
    vim.cmd("NeoagentProfile stop")
    assert.are.equal(5, #notifications)
    assert.matches("expected :NeoagentProfile start", assert(notifications[1]).message, 1, true)
    assert.matches("No LuaJIT profile", assert(notifications[2]).message, 1, true)
    local started, duplicate = assert(notifications[3]), assert(notifications[4])
    assert.matches("LuaJIT profiling started; report: ", started.message, 1, true)
    assert.are.equal(vim.log.levels.INFO, started.level)
    assert.matches("already active", duplicate.message, 1, true)
    assert.are.equal(vim.log.levels.ERROR, duplicate.level)
    local path = assert(assert(notifications[5]).message:match("LuaJIT profile saved: (.*)$"))
    assert.matches("Samples: 2", assert(fs.read(path)), 1, true)
  end)

  it("samples real Lua functions and native Neovim calls", function()
    native.start, native.stop, native.dumpstack = original_start, original_stop, original_dumpstack
    local path = assert(profiler.start())
    local value = 0
    local deadline = os.clock() + 0.2
    repeat
      for index = 1, 100000 do
        value = (value + index) % 1000003
      end
    until os.clock() >= deadline
    assert.is_number(value)
    local payload = string.rep("abcdefgh", 16384)
    deadline = os.clock() + 0.2
    repeat
      vim.fn.sha256(payload)
    until os.clock() >= deadline
    assert(profiler.stop())
    local report = assert(fs.read(path))
    assert.matches("tests/unit/profiler_spec.lua", report, 1, true)
    assert.matches("C code", report, 1, true)
    assert.is_nil((report:find("No samples collected.", 1, true)))
  end)

  it("saves the report automatically when an editor exits", function()
    local marker = directory .. "/report-path"
    local script = string.format(
      "vim.fn.stdpath=function() return %q end; "
        .. "local path=assert(require('neoagent.profiler').start()); "
        .. "assert(require('neoagent.fs').write_all(%q,path))",
      directory,
      marker
    )
    local result = vim
      .system({
        assert(vim.env.NEOAGENT_NVIM),
        "--headless",
        "--noplugin",
        "-u",
        "tests/minimal_init.lua",
        "-c",
        "lua " .. script,
        "-c",
        "qa!",
      }, { text = true })
      :wait(10000)
    assert.are.equal(0, result.code, result.stderr)
    local path = assert(fs.read(marker))
    assert.matches("Neoagent LuaJIT profile", assert(fs.read(path)), 1, true)
  end)
end)
