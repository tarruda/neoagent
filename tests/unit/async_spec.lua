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
      local value = async.await(function(done) done.resolve("now") end)
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
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    local run = async.run(function() return { ok = true } end, {
      on_done = function() error("callback exploded") end,
    })
    assert(vim.wait(1000, function() return #notifications == 1 end))
    vim.notify = original_notify

    assert.is_true(run:result().ok)
    assert.matches("callback exploded", notifications[1].message)
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
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
