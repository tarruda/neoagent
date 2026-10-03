local assert = require("luassert")
local async = require("neoagent.async")
local helper = require("tests.helpers.subprocess")
local pipes = require("neoagent.subprocess.pipe")
local workers = require("neoagent.rpc.worker_lease")
local util = require("neoagent.util")

local native_new, new_timer = pipes.new, vim.uv.new_timer

describe("worker lease ownership", function()
  ---@type Neoagent.SubprocessCallbacks
  local events
  ---@type Neoagent.WorkerLease[]
  local leases
  ---@type string[]
  local actions
  local allocated, disposed
  ---@type fun()?
  local start_action
  ---@type fun()?
  local kill_action
  local write_fails, close_fails

  before_each(function()
    leases, actions = {}, {}
    allocated, disposed = 0, 0
    start_action, write_fails, close_fails = nil, false, false
    kill_action = nil
    pipes.new = function(_, _, callbacks)
      events = callbacks
      allocated = allocated + 1
      return {
        start = function()
          if start_action then
            start_action()
          end
          return true
        end,
        observe = function(done) done(true) end,
        cleanup_ms = 20,
        write = function(bytes)
          if write_fails then error("write failed") end
          actions[#actions + 1] = bytes
          return true
        end,
        close_stdin = function()
          if close_fails then error("close failed") end
          actions[#actions + 1] = "eof"
          return true
        end,
        flush = function() return true end,
        writable = function() return true end,
        resize = function() error("not a terminal") end,
        stop = function()
          actions[#actions + 1] = "term"
          return true
        end,
        kill = function()
          actions[#actions + 1] = "kill"
          if kill_action then kill_action() end
          return true
        end,
        dispose = function()
          disposed = disposed + 1
        end,
      }
    end
  end)

  after_each(function()
    vim.uv.new_timer = new_timer
    for _, lease in ipairs(leases) do
      lease:dispose("test finished")
    end
    if events then
      events.exited(0, 9)
      events.closed()
    end
    for _, lease in ipairs(leases) do
      helper.complete(function() return lease:wait() end)
    end
    pipes.new = native_new
  end)

  ---@param overrides? {reap_grace_ms?: integer, on_stdout?: fun(bytes: string), on_stderr?: fun(bytes: string), on_exit?: fun(result: Neoagent.WorkerResult)}
  ---@return Neoagent.WorkerLease
  local function start(overrides)
    overrides = overrides or {}
    local lease = workers.start({
      argv = { "worker" }, cwd = assert(vim.uv.cwd()), env = {},
      kill_grace_ms = 0, reap_grace_ms = overrides.reap_grace_ms or 20,
      on_stdout = overrides.on_stdout,
      on_stderr = overrides.on_stderr,
      on_exit = overrides.on_exit,
    })
    leases[#leases + 1] = lease
    return lease
  end

  it("drains output before notifying waiters and disposes native ownership once", function()
    local stdout, stderr, exits = {}, {}, {}
    local lease = start({
      on_stdout = function(bytes) stdout[#stdout + 1] = bytes end,
      on_stderr = function(bytes) stderr[#stderr + 1] = bytes end,
      on_exit = function(result) exits[#exits + 1] = result end,
    })
    assert.is_true(assert(lease.wait_ready)(lease))
    assert.is_true((lease:write("input")))
    assert.is_true((lease:close_stdin()))
    assert.is_true((lease:close_stdin()))
    assert.are.same({ "input", "eof" }, actions)
    assert.is_nil((lease:write("late")))
    local wait = async.run(function() return lease:wait() end)
    events.exited(0, 0)
    assert.is_false(wait:is_done())
    events.output("stdout", "out\0")
    events.output("stderr", string.rep("e", 20000))
    events.closed()
    assert.are.equal(0, helper.wait(wait).code)
    assert.are.same({ "out\0" }, stdout)
    assert.are.equal(20000, #stderr[1])
    assert.are.equal(16384, #lease:wait().stderr)
    assert.are.equal(1, #exits)
    assert.are.equal(1, disposed)
    lease:dispose("duplicate")
    events.closed()
    events.exited(23, 0)
    events.output("stdout", "late output")
    assert.are.same({ "out\0" }, stdout)
    assert.are.equal(0, lease:wait().code)
    assert.are.equal(1, disposed)
  end)

  it("bounds remaining output cleanup when disposed after observing native exit", function()
    local lease = start({ reap_grace_ms = 20 })
    events.exited(23, 0)
    lease:dispose("owner ended after exit")
    local result = helper.complete(function() return lease:wait() end)
    assert.are.equal(23, result.code)
    assert.is_nil(result.error)
    assert.are.equal("worker_exit", assert(result.cleanup_error).kind)
    assert.are.same({ "kill" }, actions)
  end)

  it("accepts native completion during the final tree signal exactly once", function()
    kill_action = function() events.closed() end
    local lease = start()
    events.exited(23, 0)
    assert.are.equal(23, lease:wait().code)
    assert.are.equal(1, disposed)
    assert.are.same({ "kill" }, actions)
  end)

  it("normalizes exact worker environments before handing them to the native driver", function()
    local platform = jit.os
    local module = "neoagent.subprocess.windows_environment"
    local previous = package.loaded[module]
    package.loaded[module] = { key = string.upper }
    jit.os = "Windows"
    local capture = pipes.new
    local selected
    pipes.new = function(spec, env, callbacks, limits)
      selected = env
      return capture(spec, env, callbacks, limits)
    end
    local ok, err = pcall(function()
      local lease = workers.start({
        argv = { "worker" }, cwd = assert(vim.uv.cwd()),
        env = { SystemRoot = "C:\\Windows", Marker = "exact" }, clear_env = true,
      })
      leases[#leases + 1] = lease
      assert.are.same({ SYSTEMROOT = "C:\\Windows", MARKER = "exact" }, selected)
      events.exited(0, 0)
      events.closed()
      assert.are.equal(0, helper.complete(function() return lease:wait() end).code)
    end)
    jit.os, package.loaded[module] = platform, previous
    assert.is_true(ok, vim.inspect(err))
  end)

  it("keeps the worker alive when a waiter is cancelled and reserves stop timers", function()
    local lease = start()
    local wait = async.run(function() return lease:wait() end)
    wait:cancel()
    helper.wait(wait)
    assert.are.same({}, actions)
    vim.uv.new_timer = function() error("no more native timers") end
    lease:dispose("owner ended")
    -- The stop request must use its reserved timer. Neovim's own vim.wait may
    -- allocate a timer, so end allocation injection before observing escalation.
    vim.uv.new_timer = new_timer
    assert(vim.wait(1000, function() return actions[#actions] == "kill" end, 5))
    assert.are.same({ "eof", "term", "kill" }, actions)
    events.exited(0, 9)
    events.closed()
    assert.are.equal(137, helper.complete(function() return lease:wait() end).code)
  end)

  it("reports missing native completion without fabricating an exit status", function()
    local exits = 0
    local lease = start({ reap_grace_ms = 0, on_exit = function() exits = exits + 1 end })
    lease:dispose("unresponsive worker")
    local result = helper.complete(function() return lease:wait() end)
    assert.are.equal("worker_exit", assert(result.cleanup_error).kind)
    assert.is_nil(result.code)
    assert.is_nil(result.signal)
    assert.are.equal(1, disposed)
    events.exited(0, 9)
    events.closed()
    assert.are.equal(1, exits)
    assert.is_nil(lease:wait().code)
  end)

  it("retains failed startup until allocated native resources close", function()
    start_action = function() error("native startup failed") end
    ---@type Neoagent.WorkerResult[]
    local observed = {}
    local lease = start({ on_exit = function(result) observed[#observed + 1] = result end })
    local readiness = helper.complete(function() return assert(lease.wait_ready)(lease) end)
    assert.is_false(readiness.ok)
    local err = assert(readiness.error)
    assert.are.equal("worker_start", err.kind)
    assert.are.equal(0, #observed)
    assert.is_nil((lease:write("input after failed startup")))
    lease:dispose("failed startup caller ended")
    local waited = async.run(function() return lease:wait() end)
    assert.is_false(waited:is_done())
    events.closed()
    assert.are.equal("worker_start", assert(helper.wait(waited).error).kind)
    assert.are.equal("worker_start", assert(assert(observed[1]).error).kind)
    assert.are.equal(1, disposed)
  end)

  it("settles early native completion after startup publishes its driver", function()
    start_action = function()
      events.output("stderr", "early")
      events.exited(7, 0)
      events.closed()
    end
    local lease = start({ on_exit = function() error("observer failed") end })
    assert.are.equal(7, lease:wait().code)
    assert.are.equal("early", lease:wait().stderr)
    assert.are.equal(1, disposed)
  end)

  it("rejects startup before allocating a driver when timer reservation fails", function()
    local allocations = 0
    vim.uv.new_timer = function()
      allocations = allocations + 1
      if allocations == 2 then return nil end
      return new_timer()
    end
    local lease = start()
    local readiness = helper.complete(function() return assert(lease.wait_ready)(lease) end)
    assert.is_false(readiness.ok)
    local err = assert(readiness.error)
    assert.are.equal("worker_start", err.kind)
    assert.are.equal("worker_start", assert(lease:wait().error).kind)
    assert.are.equal(0, allocated)
  end)

  for _, failure in ipairs({ "output", "input", "read", "write", "close" }) do
    it("retains cleanup after " .. failure .. " failure", function()
      local lease = start({ on_stdout = function() error("observer failed") end })
      if failure == "output" then
        events.output("stdout", "bytes")
      elseif failure == "input" then
        assert(events.input_failed)()
      elseif failure == "read" then
        events.failed("process_stream", "read failed")
      elseif failure == "write" then
        write_fails = true
        local wrote, err = lease:write("bytes")
        assert.is_nil(wrote)
        assert.are.equal("protocol", assert(err).kind)
      else
        close_fails = true
        local closed, err = lease:close_stdin()
        assert.is_nil(closed)
        assert.are.equal("protocol", assert(err).kind)
        lease:dispose("close failed")
      end
      events.exited(0, 15)
      events.closed()
      local result = helper.complete(function() return lease:wait() end)
      assert.are.equal(143, result.code)
      if failure ~= "write" and failure ~= "close" then
        assert.are.equal("worker_exit", assert(result.error).kind)
      end
      assert.are.equal(1, disposed)
    end)
  end

  it("preserves the operation failure when native cleanup also fails", function()
    local lease = start()
    events.failed("process_stream", "initial read failure")
    local result = helper.complete(function() return lease:wait() end)
    assert.matches("cleanup did not settle", assert(result.cleanup_error).message, 1, true)
    assert.are.equal("initial read failure", assert(result.error).message)
  end)
end)
