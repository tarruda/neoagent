local assert = require("luassert")
local async = require("neoagent.async")
local subprocess = require("neoagent.subprocess_common")
local pipe = require("neoagent.subprocess.pipe")
local limits = require("neoagent.subprocess.validate")
local helper = require("tests.helpers.subprocess")

describe("subprocess ownership and terminal races", function()
  local original_new, original_reap = pipe.new, limits.REAP_MS
  ---@type Neoagent.SubprocessCallbacks
  local events
  ---@type Neoagent.SubprocessHandle[]
  local handles
  ---@type Neoagent.SubprocessScope
  local owner
  ---@type (integer|string)[]
  local signals
  local disposals, attachments
  ---@type fun(callbacks: Neoagent.SubprocessCallbacks)?
  local during_start
  ---@type fun()?
  local during_kill
  ---@type fun(now: number): number
  local delivery_delay
  local attach_fails, close_fails, tree_fails, spawn_fails, running

  before_each(function()
    signals, handles = {}, {}
    owner = subprocess.scope()
    disposals, attachments = 0, 0
    during_start, attach_fails, close_fails, tree_fails, spawn_fails = nil, false, false, false, false
    during_kill = nil
    running = true
    delivery_delay = function(_)
      return 0
    end
    limits.REAP_MS = 30
    pipe.new = function(_, _, callbacks)
      if tree_fails then
        error(limits.error("process_supervision", "private native failure"), 0)
      end
      if spawn_fails then
        error("private spawn failure")
      end
      events = callbacks
      return {
        start = function()
          attachments = attachments + 1
          if attach_fails then
            error(limits.error("process_supervision", "private attachment failure"), 0)
          end
          if during_start then
            during_start(callbacks)
          end
          return true
        end,
        observe = function(done)
          done(running)
        end,
        cleanup_ms = limits.REAP_MS,
        delivery_delay_ns = function(now)
          return delivery_delay(now)
        end,
        writable = function()
          return true
        end,
        write = function()
          return true
        end,
        close_stdin = function()
          return true
        end,
        flush = function()
          return true
        end,
        resize = function()
          return true
        end,
        stop = function()
          signals[#signals + 1] = "term"
          return true
        end,
        kill = function()
          signals[#signals + 1] = "kill"
          if during_kill then
            during_kill()
          end
          return true
        end,
        dispose = function()
          disposals = disposals + 1
          if close_fails then
            error("private cleanup failure")
          end
        end,
      }
    end
  end)

  after_each(function()
    owner:close("test finished")
    for _, handle in ipairs(handles) do
      handle:dispose("test finished")
    end
    if events then
      events.exited(0, 9)
      events.closed()
    end
    for _, handle in ipairs(handles) do
      helper.complete(function()
        return handle:wait_cleanup()
      end)
    end
    pipe.new, limits.REAP_MS = original_new, original_reap
  end)

  local function spawn(observer, spec)
    local handle = owner:spawn(spec or helper.spec("unused"), observer)
    handles[#handles + 1] = handle
    return handle
  end

  -- Model synchronous editor work without polling libuv or refreshing its
  -- cached clock. The bounded loop is deliberate: vim.wait would mask this.
  local function block_editor(milliseconds)
    local until_ns = vim.uv.hrtime() + milliseconds * 1000000
    while vim.uv.hrtime() < until_ns do
    end
  end

  it("settles once when the native driver completes during its final signal", function()
    during_kill = function()
      events.closed()
    end
    local handle = spawn()
    events.exited(23, 0)
    assert.are.equal(
      23,
      helper.complete(function()
        return handle:wait()
      end).code
    )
    assert.are.equal(1, disposals)
    assert.are.same({ "kill" }, signals)
  end)

  it("delivers cleanup failure to an already waiting scope", function()
    spawn()
    local waiter = async.run(function()
      return owner:wait(1000)
    end)
    assert.is_false(waiter:is_done())
    close_fails = true
    events.exited(23, 0)
    events.closed()
    assert.are.equal("process_cleanup", assert(helper.wait(waiter).error).code)
  end)

  for _, thrown in ipairs({ false, true }) do
    it("owns completed native resources when startup " .. (thrown and "throws" or "reports failure"), function()
      during_start = function(callbacks)
        callbacks.closed()
        if thrown then
          error(limits.error("process_start", "native startup failed"), 0)
        end
        callbacks.failed("process_start", "native startup failed")
      end
      local failure = helper.failure(function()
        spawn()
      end)
      assert.are.equal("process_start", failure.code)
      assert.is_true(owner:is_settled())
      assert.are.equal(1, disposals)
    end)
  end

  for _, completion in ipairs({ "empty", "success", "failure" }) do
    it("observes settled scope " .. completion .. " without another native timer", function()
      if completion ~= "empty" then
        spawn()
        close_fails = completion == "failure"
        events.exited(0, 0)
        events.closed()
      end
      assert.is_true(owner:is_settled())
      local new_timer = vim.uv.new_timer
      vim.uv.new_timer = function()
        error("timer allocation unavailable")
      end
      local waiting = async.run(function()
        return owner:wait(500)
      end)
      vim.uv.new_timer = new_timer
      local result = helper.wait(waiting)
      if completion == "failure" then
        assert.are.equal("process_cleanup", assert(result.error).kind)
      else
        assert.is_true(result, vim.inspect(result))
      end
    end)
  end

  it("bounds cleanup after native exit when no exit callback arrives", function()
    local handle = spawn(nil, helper.spec("unused", { timeout_ms = 10 }))
    running = false
    local result = helper.complete(function()
      return handle:wait()
    end, 500)
    assert.are.equal("process_cleanup", assert(result.error).code)
    assert.is_nil(handle:state().terminal)
    assert.are.equal(1, disposals)
    events.exited(0, 0)
    events.closed()
    assert.is_nil(handle:state().terminal)
    assert.are.equal(1, disposals)
  end)

  for _, deadline in ipairs({ false, true }) do
    it("retains observed exit status after cleanup failure with deadline=" .. tostring(deadline), function()
      local handle = spawn()
      local waiter = async.run(function()
        return handle:wait()
      end)
      events.exited(23, 0)
      assert.is_false(waiter:is_done())
      if not deadline then
        close_fails = true
        events.closed()
      end
      local failure = assert(helper.wait(waiter).error)
      assert.are.equal("process_cleanup", failure.kind)
      local state = handle:state()
      assert.are.equal("failed", state.phase)
      local outcome = assert(state.terminal)
      assert.are.equal(23, outcome.code)
      assert.are.equal(0, outcome.signal)
      assert.is_false(outcome.timed_out)
      assert.are.same(failure, state.failure)
      assert.are.same(
        failure,
        helper.complete(function()
          return handle:wait_cleanup()
        end).error
      )
      assert.are.same(
        failure,
        helper.complete(function()
          return owner:wait(500)
        end).error
      )
      assert.are.same(
        failure,
        helper.complete(function()
          return handle:wait()
        end).error
      )
    end)
  end

  it("bounds cleanup when ongoing output delivery consumes the drain budget", function()
    local beginning = vim.uv.hrtime()
    delivery_delay = function(now)
      return now - beginning
    end
    local handle = spawn()
    events.exited(0, 0)
    assert(
      vim.wait(300, function()
        return owner:is_settled()
      end, 5),
      "output delivery renewed cleanup indefinitely"
    )
    assert.are.equal("process_cleanup", assert(handle:state().failure).code)
    assert.are.equal(1, disposals)
  end)

  it("stops controls after native exit and preserves its later status", function()
    limits.REAP_MS = 250
    local handle = spawn(nil, helper.spec("unused", { timeout_ms = 10 }))
    running = false
    assert(
      vim.wait(500, function()
        return #signals > 0
      end, 5),
      "native exit did not begin cleanup"
    )
    assert.is_false(handle:state().stdin_writable)
    assert.are.equal(
      "process_terminal",
      helper.failure(function()
        handle:write("late input")
      end).code
    )
    events.exited(7, 0)
    events.closed()
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal(7, result.code)
    assert.is_false(result.timed_out)
    assert.is_nil(result.termination_reason)
    assert.are.same({ "kill" }, signals)
    assert.are.equal(1, disposals)
  end)

  it("starts the lifetime interval after preceding synchronous editor work", function()
    vim.uv.update_time()
    block_editor(80)
    local handle = spawn(nil, helper.spec("unused", { timeout_ms = 40 }))
    local observe = assert(vim.uv.new_timer())
    local observed
    vim.uv.update_time()
    observe:start(1, 0, function()
      observe:close()
      observed = handle:state().phase
    end)
    assert(vim.wait(1000, function()
      return observed ~= nil
    end, 1))
    assert.are.equal("running", observed)
  end)

  it("allows graceful termination its full interval after synchronous editor work", function()
    local handle = spawn(nil, helper.spec("unused", { kill_grace_ms = 40 }))
    vim.uv.update_time()
    block_editor(80)
    handle:terminate("requested")
    local observe = assert(vim.uv.new_timer())
    local observed
    vim.uv.update_time()
    observe:start(1, 0, function()
      observe:close()
      observed = vim.deepcopy(signals)
    end)
    assert(vim.wait(1000, function()
      return observed ~= nil
    end, 1))
    assert.are.same({ "term" }, observed)
  end)

  it("gives a scope waiter its full interval after synchronous editor work", function()
    local owner = subprocess.scope()
    owner:spawn(helper.spec("unused"))
    local current = events
    vim.uv.update_time()
    block_editor(80)
    local waiter = async.run(function()
      return owner:wait(40)
    end)
    local finish = assert(vim.uv.new_timer())
    vim.uv.update_time()
    finish:start(10, 0, function()
      finish:close()
      current.exited(0, 0)
      current.closed()
    end)
    local result = helper.wait(waiter)
    if not finish:is_closing() then
      finish:close()
    end
    owner:close("test finished")
    current.closed()
    assert.is_true(result, vim.inspect(result))
  end)

  it("allows the full output-drain interval after synchronous editor work", function()
    local output = ""
    local handle = spawn({
      on_output = function(event)
        output = output .. event.data
      end,
    })
    local current = events
    local drain = assert(vim.uv.new_timer())
    vim.schedule(function()
      vim.uv.update_time()
      block_editor(80)
    end)
    current.exited(0, 0)
    vim.schedule(function()
      vim.uv.update_time()
      drain:start(10, 0, function()
        drain:close()
        current.output("stdout", "trailing")
        current.closed()
      end)
    end)
    local result = helper.complete(function()
      return handle:wait()
    end)
    if not drain:is_closing() then
      drain:close()
    end
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("trailing", output)
  end)

  it("attaches before delivering immediate output and publishes an immediate exit once", function()
    during_start = function(callbacks)
      callbacks.output("stdout", "first")
      callbacks.output("stderr", "last")
      callbacks.exited(7, 0)
      callbacks.closed()
    end
    local received = {}
    local handle = spawn({
      on_output = function(event)
        assert.are.equal(1, attachments)
        received[#received + 1] = event
      end,
    })
    assert.are.same({}, received)
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal(7, result.code)
    assert.are.same({ { stream = "stdout", data = "first" }, { stream = "stderr", data = "last" } }, received)
    assert.are.equal("exited", handle:state().phase)
    events.output("stdout", "late")
    events.exited(1, 9)
    events.closed()
    handle:dispose("already done")
    assert.are.equal(1, disposals)
    assert.are.equal(2, #received)
    assert.are.equal(
      7,
      helper.complete(function()
        return handle:wait()
      end).code
    )
  end)

  it("keeps exit latched until output and native resource cleanup finish", function()
    local output = ""
    local handle = spawn({
      on_output = function(event)
        output = output .. event.data
      end,
    })
    local waiter = async.run(function()
      return handle:wait()
    end)
    events.exited(0, 0)
    events.output("stdout", "trailing")
    assert.is_false(waiter:is_done())
    assert.is_false(handle:state().stdin_writable)
    events.closed()
    assert.are.equal(0, helper.wait(waiter).code)
    assert.are.equal("trailing", output)
  end)

  for _, timer_kind in ipairs({ "kill_grace_ms", "timeout_ms" }) do
    it("ignores a stale " .. timer_kind .. " callback after publishing the outcome", function()
      local probe = assert(vim.uv.new_timer())
      local methods = getmetatable(probe).__index
      probe:close()
      local start_timer = methods.start
      ---@type fun()?
      local escalate
      methods.start = function(timer, timeout, repeat_ms, callback)
        if timeout == 13 then
          escalate = callback
        end
        return start_timer(timer, timeout, repeat_ms, callback)
      end
      local ok, err = pcall(function()
        local selected = helper.spec("unused", { kill_grace_ms = 13 })
        if timer_kind == "timeout_ms" then
          selected.timeout_ms, selected.kill_grace_ms = 13, 500
        end
        local handle = spawn(nil, selected)
        handle:terminate("finished")
        events.exited(0, 0)
        events.closed()
        local before = #signals
        local callback = assert(escalate)
        callback()
        assert.are.equal(before, #signals)
        assert.are.equal(1, disposals)
        assert.are.equal(
          "finished",
          helper.complete(function()
            return handle:wait()
          end).termination_reason
        )
      end)
      methods.start = start_timer
      assert.is_true(ok, vim.inspect(err))
    end)
  end

  it("bounds startup output before process-tree attachment", function()
    during_start = function(callbacks)
      callbacks.output("stdout", ("x"):rep(limits.PENDING_BYTES + 1))
    end
    local observed = 0
    local owner = subprocess.scope()
    local failure = helper.failure(function()
      owner:spawn(helper.spec("unused"), {
        on_output = function()
          observed = observed + 1
        end,
      })
    end)
    assert.are.equal("process_stream", failure.code)
    assert.are.equal(0, observed)
    assert.is_false(owner:is_settled())
    events.exited(0, 9)
    events.closed()
    assert.is_true(helper.complete(function()
      return owner:wait(1000)
    end))
  end)

  it("defers startup output until the caller receives its handle and preserves ordering", function()
    during_start = function(callbacks)
      callbacks.output("stdout", "early")
    end
    local output = ""
    ---@type Neoagent.SubprocessHandle?
    local handle
    handle = spawn({
      on_output = function(event)
        assert.is_table(assert(handle):state())
        output = output .. event.data
      end,
    })
    assert.are.equal("", output, "the observer ran before spawn returned")
    events.output("stdout", "later")
    events.exited(0, 0)
    events.closed()
    assert.are.equal(
      0,
      helper.complete(function()
        return assert(handle):wait()
      end).code
    )
    assert.are.equal("earlylater", output)
  end)

  it("rejects startup if its native cleanup deadline already failed", function()
    during_start = function(callbacks)
      callbacks.exited(0, 0)
      assert(vim.wait(500, function()
        return owner:is_settled()
      end, 5))
    end
    local err = helper.failure(function()
      spawn()
    end)
    assert.are.equal("process_cleanup", err.code)
    assert.is_true(owner:is_settled())
    assert.are.equal(1, disposals)
  end)

  it("stops publishing the remaining chunk when its observer disposes the owner", function()
    local owner = subprocess.scope()
    local observed = 0
    local handle = owner:spawn(helper.spec("unused"), {
      on_output = function()
        observed = observed + 1
        owner:close("observer finished")
      end,
    })
    events.output("stdout", ("x"):rep(limits.OUTPUT_BYTES + 1))
    assert.are.equal(1, observed)
    assert.are.equal(
      "process_disposed",
      assert(helper.complete(function()
        return handle:flush()
      end).error).code
    )
    events.exited(0, 9)
    events.closed()
    assert.is_true(helper.complete(function()
      return owner:wait(1000)
    end))
  end)

  it("does not start a target for an already cancelled run", function()
    local run = async.run(function(run)
      run:cancel()
      return subprocess.run(helper.spec("unused"), { capture = false })
    end)
    assert.are.equal("cancelled", assert(helper.wait(run).error).kind)
    assert.are.equal(0, attachments)
  end)

  it("owns cleanup when cancellation happens during native startup", function()
    during_start = function()
      assert(async.current()):cancel()
    end
    local run = async.run(function()
      return subprocess.run(helper.spec("unused"), { capture = false })
    end)
    assert.are.equal("cancelled", assert(helper.wait(run).error).kind)
    assert.are.equal(0, disposals)
    events.exited(0, 9)
    events.closed()
    assert.are.equal(1, disposals)
  end)

  it("cancels native startup before it returns and preserves cancellation when startup fails", function()
    local stopped_during_start = false
    during_start = function()
      assert(async.current()):cancel()
      stopped_during_start = vim.tbl_contains(signals, "kill")
      error(limits.error("process_start", "execution acknowledgement aborted"), 0)
    end
    local run = async.run(function()
      return owner:run(helper.spec("unused"), { capture = false })
    end)
    assert.are.equal("cancelled", assert(helper.wait(run).error).kind)
    assert.is_true(stopped_during_start)
    assert.is_false(owner:is_settled())
    events.exited(0, 9)
    events.closed()
    assert.is_true(owner:is_settled())
    assert.are.equal(1, disposals)
  end)

  it("copies spec, observer, events, and snapshots at the ownership boundary", function()
    local spec = helper.spec("original")
    local observer = {
      on_output = function(event)
        event.data = "changed"
      end,
    }
    ---@type Neoagent.SubprocessSpec?
    local captured
    local original = pipe.new
    pipe.new = function(selected, env, callbacks)
      captured = selected
      return original(selected, env, callbacks)
    end
    local handle = spawn(observer, spec)
    spec.argv[3] = "mutated"
    spec.stdio.kind = "pty"
    observer.on_output = function()
      error("new observer must not be installed")
    end
    assert.are.equal("original", assert(captured).argv[3])
    assert.are.equal("pipes", assert(captured).stdio.kind)
    events.output("stdout", "data")
    assert.are.equal("running", handle:state().phase)
    events.exited(0, 0)
    events.closed()
  end)

  it("keeps a cleanup recipient when startup throws before returning a handle", function()
    attach_fails, close_fails = true, true
    local failure = helper.failure(function()
      owner:spawn(helper.spec("unused"))
    end)
    assert.are.equal("process_supervision", failure.code)
    assert.is_false(owner:is_settled())
    events.closed()
    local result = helper.complete(function()
      return owner:wait(500)
    end)
    local cleanup = assert(result.error)
    assert.are.equal("process_cleanup", cleanup.code)
    assert.are.same(failure, rawget(cleanup, "cause"))
    assert.is_true(owner:is_settled())
    assert.are.equal(1, disposals)
    events.closed()
    assert.are.equal(1, disposals)
    assert.are.equal(
      "process_cleanup",
      assert(helper.complete(function()
        return owner:wait(500)
      end).error).code
    )
  end)

  it("cleans startup failures without returning an unsupervised target", function()
    tree_fails = true
    assert.are.equal(
      "process_supervision",
      helper.failure(function()
        spawn()
      end).code
    )
    assert.are.equal(0, attachments)
    tree_fails, spawn_fails = false, true
    assert.are.equal(
      "process_start",
      helper.failure(function()
        spawn()
      end).code
    )
    assert.are.equal(0, disposals)
    spawn_fails, attach_fails = false, true
    local scope = subprocess.scope()
    assert.are.equal(
      "process_supervision",
      helper.failure(function()
        scope:spawn(helper.spec("unused"))
      end).code
    )
    assert.is_false(scope:is_settled())
    events.exited(0, 9)
    events.closed()
    assert.is_true(helper.complete(function()
      return scope:wait(1000)
    end))
    assert.is_true(vim.tbl_contains(signals, "kill"))
  end)

  it("keeps disposal separate from cleanup and preserves the first operation failure", function()
    local handle = spawn()
    local waiter = async.run(function()
      return handle:wait()
    end)
    local cleanup = async.run(function()
      return handle:wait_cleanup()
    end)
    events.failed("process_stream", "Could not read process stdout")
    events.failed("process_observer", "later failure")
    handle:dispose("owner finished")
    assert.are.equal("process_stream", assert(helper.wait(waiter).error).kind)
    assert.is_false(cleanup:is_done())
    events.exited(0, 9)
    events.closed()
    assert.is_true(helper.wait(cleanup))
    assert.are.equal("process_stream", assert(handle:state().failure).kind)
    assert.are.equal(137, assert(handle:state().terminal).code)
  end)

  it("does not let cancellation erase a cleanup error or close the driver twice", function()
    local handle = spawn()
    local cancelled = async.run(function()
      return handle:wait_cleanup()
    end)
    cancelled:cancel()
    assert.are.equal("cancelled", assert(helper.wait(cancelled).error).kind)
    close_fails = true
    handle:dispose("owner ended")
    events.exited(0, 9)
    events.closed()
    local failure = assert(helper.complete(function()
      return handle:wait_cleanup()
    end).error)
    assert.are.equal("process_cleanup", failure.kind)
    assert.are.equal("process_disposed", failure.cause.kind)
    assert.is_nil(failure.detail)
    assert.are.equal(137, assert(handle:state().terminal).code)
    assert.are.equal(1, disposals)
    events.closed()
    assert.are.equal(1, disposals)
  end)

  it("bounds detached cleanup and retains a scope failure after observation ends", function()
    local scope = subprocess.scope()
    local handle = scope:spawn(helper.spec("unused"))
    handles[#handles + 1] = handle
    handle:dispose("abandoned")
    local failure = assert(helper.complete(function()
      return handle:wait_cleanup()
    end).error)
    assert.are.equal("process_cleanup", failure.code)
    assert.is_true(scope:is_settled())
    assert.are.equal(
      "process_cleanup",
      assert(helper.complete(function()
        return scope:wait(1000)
      end).error).code
    )
  end)

  it("delivers queued completion before deciding that a native reap deadline failed", function()
    local handle = spawn()
    handle:dispose("finished")
    local ready = false
    vim.schedule(function()
      ready = true
    end)
    assert(vim.wait(1000, function()
      return ready
    end, 5))
    vim.schedule(function()
      events.exited(0, 9)
      events.closed()
    end)
    -- Poll only libuv events so the native deadline fires before editor work.
    assert(vim.wait(1000, function()
      return #signals >= 2
    end, 5, true))
    assert.is_true(helper.complete(function()
      return handle:wait_cleanup()
    end))
  end)

  it("keeps standalone run cleanup diagnostics after cancellation", function()
    local run = async.run(function()
      return subprocess.run(helper.spec("unused"), { capture = false })
    end)
    run:cancel()
    assert.are.equal("cancelled", assert(helper.wait(run).error).kind)
    assert(vim.wait(1000, function()
      return #run:diagnostics() > 0
    end, 5))
    assert.are.equal("dispose", assert(run:diagnostics()[1]).phase)
  end)

  it("retains cleanup reporting through nested cancelled Runs", function()
    local reports = {}
    local child = async.run(function()
      return subprocess.run(helper.spec("unused"), { capture = false })
    end)
    local middle = async.run(function()
      return child:await()
    end)
    local outer = async.run(function()
      return middle:await()
    end, {
      report = function(diagnostic)
        reports[#reports + 1] = diagnostic
      end,
    })
    outer:cancel()
    assert.are.equal("cancelled", assert(helper.wait(outer).error).kind)
    assert.is_true(child:is_done())
    assert(vim.wait(1000, function()
      return #child:diagnostics() > 0
    end, 5))
    assert.are.equal(1, #reports)
    assert.are.same(child:diagnostics(), outer:diagnostics())
    assert.is_nil((next(child._diagnostic_parents)))
    assert.is_nil((next(middle._diagnostic_parents)))
    assert.are.equal(0, outer._diagnostic_holds)
  end)

  it("reports detached cleanup once when one parent awaits the child again", function()
    local reports = {}
    local child = async.run(function()
      return subprocess.run(helper.spec("unused"), { capture = false })
    end)
    local parent = async.run(function()
      child:await()
      return child:await()
    end, {
      report = function(diagnostic)
        reports[#reports + 1] = diagnostic
      end,
    })
    child:cancel()
    assert.are.equal("cancelled", assert(helper.wait(parent).error).kind)
    assert(vim.wait(1000, function()
      return #child:diagnostics() > 0
    end, 5))
    assert.are.equal(1, #reports)
    assert.is_nil((next(child._diagnostic_parents)))
    assert.are.equal(0, parent._diagnostic_holds)
  end)

  it("records cleanup failure when cancellation wins over queued cleanup delivery", function()
    local run = async.run(function()
      return subprocess.run(helper.spec("unused"), { capture = false })
    end)
    close_fails = true
    events.exited(0, 0)
    events.closed()
    run:cancel()
    assert.are.equal("cancelled", assert(helper.wait(run).error).kind)
    assert.are.equal("dispose", assert(run:diagnostics()[1]).phase)
  end)
end)
