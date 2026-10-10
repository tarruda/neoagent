local assert = require("luassert")
local async = require("neoagent.async")
local invocation = require("neoagent.sandbox.invocation")
local util = require("neoagent.util")

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end, 5))
  return assert(run:result())
end

describe("sandbox invocation ownership", function()
  local function resources()
    local state = { starts = 0, stops = 0, closes = 0, reports = {} }
    local lease = {
      start = function() state.starts = state.starts + 1 end,
      wait_ready = function() return true end,
      write = function() return true end,
      close_stdin = function() return true end,
      terminate = function() state.stops = state.stops + 1 end,
      dispose = function() state.stops = state.stops + 1 end,
      wait = function() return { code = 0, signal = 0, stderr = "" } end,
      is_released = function() return true end,
      wait_release = function() return true end,
    }
    local connection = {
      attach = function() end,
      open = function() end,
      close = function() state.closes = state.closes + 1 end,
      cancel = function() end,
      wait_cancelled = function() return true end,
      abort = function() end,
      is_failed = function() return false end,
    }
    local owner = invocation.new(connection --[[@as Neoagent.RpcConnection]], lease, function(err)
      state.reports[#state.reports + 1] = { error = err }
    end, 10000)
    return owner, lease, connection, state
  end

  for _, late in ipairs({ "exit", "protocol" }) do
    it("publishes one final outcome including late " .. late .. " failure", function()
      local owner, lease, connection, state = resources()
      if late == "exit" then
        lease.wait = function() return { code = 70, signal = 0, stderr = "shutdown failed" } end
      else
        connection.close = function()
          state.closes = state.closes + 1
          if state.closes > 1 then error(util.error("protocol", "invalid trailing frame"), 0) end
        end
      end
      local result = wait(async.run(function()
        owner:open({})
        return { error = owner:close(false) }
      end))
      assert.is_not_nil(result.error)
      assert.are.equal(1, #state.reports)
      assert.are.same(result.error, state.reports[1].error)
      local repeated = wait(async.run(function() return { error = owner:close(false) } end))
      assert.are.same(result.error, repeated.error)
      assert.are.equal(1, #state.reports)
    end)
  end

  it("retains admission after its observer cancels and closes cooperatively", function()
    local owner, lease, _, state = resources()
    ---@type Neoagent.AwaitCallbacks<true>?
    local ready
    ---@async
    lease.wait_ready = function()
      return async.await(function(done) ready = done end)
    end
    local opening = async.run(function() owner:open({}) end)
    assert.is_not_nil(ready)
    opening:cancel()
    local closing = async.run(function() return { error = owner:close(true) } end)
    assert.are.equal(0, state.stops, "observer cancellation killed the admission owner")
    assert.is_false(closing:is_done())
    assert(ready).resolve(true)
    assert.are.equal("cancelled", assert(wait(opening).error).kind)
    assert.is_nil(wait(closing).error)
    assert.are.equal(0, state.stops)
    assert.are.equal(1, #state.reports)
  end)
end)
