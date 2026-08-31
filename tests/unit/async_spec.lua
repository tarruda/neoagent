local async = require("neoagent.async")

describe("neoagent.async", function()
  it("awaits callbacks and schedules ordered completion", function()
    local calls = {}
    local run = async.run(function(self)
      local value = async.await(function(done)
        vim.schedule(function() done.resolve("ready") end)
      end)
      self:emit({ type = "value", value = value })
      return { ok = true, value = value }
    end, {
      on_event = function(event) calls[#calls + 1] = event.value end,
      on_done = function(result) calls[#calls + 1] = result.value end,
    })
    assert(vim.wait(1000, function() return run:is_done() and #calls == 2 end))
    assert.are.same({ "ready", "ready" }, calls)
  end)

  it("cancels an awaited operation exactly once", function()
    local cancelled = 0
    local done_result
    local run = async.run(function()
      async.await(function()
        return function() cancelled = cancelled + 1 end
      end)
    end, { on_done = function(result) done_result = result end })
    run:cancel()
    run:cancel()
    assert(vim.wait(1000, function() return done_result ~= nil end))
    assert.are.equal(1, cancelled)
    assert.is_false(done_result.ok)
    assert.are.equal("cancelled", done_result.error.kind)
  end)

  it("registers and cancels awaited child runs", function()
    local child_cancelled = false
    local child = async.run(function()
      async.await(function()
        return function() child_cancelled = true end
      end)
    end)
    local parent = async.run(function()
      return child:await()
    end)
    parent:cancel()
    assert(vim.wait(1000, function() return parent:is_done() end))
    assert.is_true(child_cancelled)
  end)

  it("rejects await outside a managed coroutine", function()
    assert.has_error(function()
      async.await(function() end)
    end)
  end)

  it("supports synchronous settlement and reports startup failures", function()
    local resolved = async.run(function()
      local value = async.await(function(done)
        done.resolve("now")
        done.reject({ kind = "late", message = "too late" })
      end)
      return { ok = true, value = value }
    end)
    assert.is_true(resolved:is_done())
    assert.are.equal("now", resolved:result().value)

    local failed = async.run(function()
      async.await(function() error("could not start") end)
    end)
    assert.is_true(failed:is_done())
    assert.is_false(failed:result().ok)
    assert.matches("could not start", failed:result().error.message)
  end)

  it("reports callback failures without changing the completed Run", function()
    local notifications = {}
    local failure = "callback exploded\255" .. string.rep("x", 4096)
    local run = async.run(function() return { ok = true } end, {
      on_done = function() error(failure, 0) end,
      report = function(diagnostic)
        notifications[#notifications + 1] = diagnostic
      end,
    })
    assert(vim.wait(1000, function() return #notifications == 1 end))

    assert.is_true(run:result().ok)
    assert.are.equal("callback", notifications[1].kind)
    assert.are.equal("done", notifications[1].phase)
    assert.matches("callback exploded", notifications[1].message)
    assert.is_true(require("neoagent.util").is_valid_utf8(
      notifications[1].message))
    assert.is_true(vim.fn.strchars(notifications[1].message) <= 1024)
    assert.are.same(run:diagnostics()[1], notifications[1])

    local copy = run:diagnostics()
    copy[1].message = "changed"
    notifications[1].message = "reported value changed"
    assert.matches("callback exploded", run:diagnostics()[1].message)

    local bounded = async.run(function(self)
      for index = 1, 40 do self:emit(index) end
    end, {
      on_event = function(index) error("event " .. index) end,
    })
    assert(vim.wait(1000, function()
      return #bounded:diagnostics() == 32
    end))
    assert.matches("event 9", bounded:diagnostics()[1].message)
  end)

  it("bounds unrenderable callback failures", function()
    local diagnostics = {}
    local failure = setmetatable({}, {
      __tostring = function() error("render failed") end,
    })
    local run = async.run(function() return { ok = true } end, {
      on_done = function() error(failure, 0) end,
      report = function(diagnostic)
        diagnostics[#diagnostics + 1] = diagnostic
      end,
    })

    assert(vim.wait(1000, function() return #diagnostics == 1 end))
    assert.is_true(run:result().ok)
    assert.are.equal("Callback failure could not be rendered",
      diagnostics[1].message)
  end)

  it("replays a child's callback diagnostics to a later awaiting parent", function()
    local child = async.run(function(self)
      self:emit("value")
      async.await(function() end)
    end, {
      on_event = function() error("child event failed") end,
    })
    assert(vim.wait(1000, function() return #child:diagnostics() == 1 end))

    local parent = async.run(function() return child:await() end)
    assert.are.equal("event", parent:diagnostics()[1].phase)
    assert.matches("child event failed", parent:diagnostics()[1].message)

    parent:cancel()
    assert(vim.wait(1000, function() return parent:is_done() end))
    assert.is_false(parent:result().ok)
    assert.are.equal("cancelled", parent:result().error.kind)
  end)

  it("honors cancellation before awaiting and ignores late handlers", function()
    local run = async.run(function(self)
      self:cancel()
      async.await(function() end)
    end)
    assert.is_true(run:is_done())
    assert.is_false(run:result().ok)
    assert.are.equal("cancelled", run:result().error.kind)

    local called = false
    local remove = run:on_cancel(function() called = true end)
    remove()
    assert.is_false(called)
  end)

  it("retains cancellation callback diagnostics without a reporter", function()
    local run = async.run(function(self)
      self:on_cancel(function() error("cancel callback exploded") end)
      async.await(function() end)
    end)
    run:cancel()
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.equal("cancel", run:diagnostics()[1].phase)
    assert.matches("cancel callback exploded", run:diagnostics()[1].message)
  end)

  it("provides stable behavior after completion", function()
    local run = async.run(function() end)
    assert.is_true(run:is_done())
    assert.is_true(run:result().ok)
    assert.is_false(run:emit({ type = "late" }))
    run:cancel()
    assert.is_true(run:result().ok)
    assert.has_error(function() run:await() end)
  end)
end)
