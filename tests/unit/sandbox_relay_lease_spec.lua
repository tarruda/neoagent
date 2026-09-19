local assert = require("luassert")
local async = require("neoagent.async")
local protocol = require("neoagent.sandbox.protocol")
local relay_lease = require("neoagent.sandbox.relay_lease")

---@return Neoagent.WorkerLease, table
local function base_child()
  local state = { writes = {}, terminated = {}, stdin_closed = false, closed = false }
  local child = {
    write = function(_, data)
      state.writes[#state.writes + 1] = data
      return true
    end,
    close_stdin = function()
      state.stdin_closed = true
      return true
    end,
    terminate = function(_, reason)
      state.terminated[#state.terminated + 1] = reason
    end,
    wait = function()
      return { code = 0, signal = 0, stderr = "" }
    end,
    dispose = function()
      state.closed = true
    end,
  }
  return child, state
end

local function ready()
  return protocol.encode({ v = 1, type = "ready" })
end

local function exited(code, signal)
  return protocol.encode({ v = 1, type = "exit", code = code or 0, signal = signal or 0 })
end

describe("neoagent native sandbox relay lease", function()
  it("waits for native admission independently of worker startup", function()
    local relay = relay_lease.new()
    local base = base_child()
    relay:attach(base)
    local admitted = async.run(function()
      return relay:wait_ready()
    end)
    assert.is_false(admitted:is_done())
    relay:feed(ready())
    assert(vim.wait(1000, function() return admitted:is_done() end))
    assert.is_true(assert(admitted:result()))
    assert.is_true(relay:wait_ready())
    relay:feed(exited())
    relay:host_exited({ code = 0, signal = 0, stderr = "" })

    local failed = relay_lease.new()
    local failed_base = base_child()
    failed:attach(failed_base)
    local awaiting_failure = async.run(function()
      return failed:wait_ready()
    end)
    failed:feed("\0\0\0\1\255")
    assert(vim.wait(1000, function() return awaiting_failure:is_done() end))
    local failure = assert(awaiting_failure:result())
    assert.is_false(failure.ok)
    assert.are.equal("sandbox_unavailable", assert(failure.error).kind)
    local repeated, repeated_err = pcall(failed.wait_ready, failed)
    assert.is_false(repeated)
    assert.are.equal(
      "Invalid native sandbox protocol",
      require("neoagent.util").normalize_error(repeated_err).message
    )
  end)

  it("bounds native admission independently of worker startup", function()
    local relay = relay_lease.new({ admission_timeout_ms = 10 })
    local base, state = base_child()
    relay:attach(base)
    local admitted = async.run(function()
      return relay:wait_ready()
    end)

    assert(vim.wait(1000, function() return admitted:is_done() end))
    local result = assert(admitted:result())
    assert.is_false(result.ok)
    local admission_error = assert(result.error)
    assert.are.equal("sandbox_unavailable", admission_error.kind)
    assert.matches("admission timed out", admission_error.message)
    assert.matches("native sandbox relay failed", state.terminated[1])
  end)

  it("relays binary streams and exposes one completed child result", function()
    local stdout, stderr, exits = {}, {}, {}
    local relay = relay_lease.new({
      on_stdout = function(data)
        stdout[#stdout + 1] = data
      end,
      on_stderr = function(data)
        stderr[#stderr + 1] = data
      end,
      on_exit = function(value)
        exits[#exits + 1] = value
      end,
    })
    local base, state = base_child()
    relay:attach(base)
    local wrote = relay:write("request\0")
    assert.is_true(wrote)
    local closed = relay:close_stdin()
    assert.is_true(closed)
    relay:terminate("caller cancelled")
    relay:feed(ready()
      .. protocol.encode({ v = 1, type = "output", stream = "stdout", seq = 1, data = "out\0" })
      .. protocol.encode({ v = 1, type = "output", stream = "stderr", seq = 2, data = "err" })
      .. exited())
    ---@type Neoagent.WorkerResult?
    local awaited
    local waiting = async.run(function()
      awaited = relay:wait()
    end)
    assert.is_false(waiting:is_done())
    relay:host_exited({ code = 0, signal = 0, stderr = "host stderr" })
    relay:host_exited({ code = 99, signal = 0, stderr = "ignored" })
    assert(vim.wait(1000, function()
      return waiting:is_done()
    end))
    assert.are.same({ "out\0" }, stdout)
    assert.are.same({ "err" }, stderr)
    assert.are.same({ "request\0" }, state.writes)
    assert.is_true(state.stdin_closed)
    assert.are.same({ "caller cancelled" }, state.terminated)
    local result = assert(awaited)
    assert.are.equal(0, result.code)
    assert.are.equal("err", result.stderr)
    assert.are.equal(1, #exits)
    assert.are.same(result, relay:wait())
    relay:feed("ignored after completion")
    relay:dispose("test complete")
    relay:dispose("test complete")
    assert.is_true(state.closed)
  end)

  it("fails closed for malformed setup, runtime, callback, and cleanup outcomes", function()
    local before_attach = relay_lease.new()
    before_attach:feed("\0\0\0\1\255")
    local base, state = base_child()
    before_attach:attach(base)
    assert.matches("before attachment", state.terminated[1])
    before_attach:host_exited({ code = 125, signal = 0, stderr = "runtime" })
    assert.are.equal("sandbox_unavailable", assert(before_attach:wait().error).kind)

    local truncated = relay_lease.new()
    truncated:feed("\0\0")
    truncated:host_exited({ code = 0, signal = 0, stderr = "" })
    assert.matches("Invalid native sandbox protocol", assert(truncated:wait().error).message)

    local setup = relay_lease.new()
    setup:feed(protocol.encode({ v = 1, type = "error", stage = "mount-root", errno = 1 }))
    setup:host_exited({ code = 125, signal = 0, stderr = "" })
    assert.matches("mount%-root", assert(setup:wait().error).message)

    local runtime = relay_lease.new()
    runtime:feed(ready() .. exited())
    runtime:host_exited({ code = 70, signal = 0, stderr = "runtime failed" })
    assert.matches("status 70", assert(runtime:wait().error).message)

    for _, cleanup in ipairs({
      function()
        error("cleanup exploded")
      end,
      function()
        return nil, "cleanup denied"
      end,
    }) do
      local relay = relay_lease.new({ cleanup = cleanup })
      relay:feed(ready() .. exited())
      relay:host_exited({ code = 0, signal = 0, stderr = "" })
      assert.matches("Could not clean", assert(relay:wait().error).message)
    end

    local callback = relay_lease.new({
      on_stderr = function()
        error("consumer exploded")
      end,
    })
    base, state = base_child()
    callback:attach(base)
    callback:feed(ready()
      .. protocol.encode({
        v = 1,
        type = "output",
        stream = "stderr",
        seq = 1,
        data = string.rep("e", 20000),
      })
      .. exited())
    callback:host_exited({ code = 0, signal = 0, stderr = "" })
    local callback_result = callback:wait()
    assert.are.equal("protocol", assert(callback_result.error).kind)
    assert.are.equal(16 * 1024, #callback_result.stderr)
    assert.matches("native sandbox relay failed", state.terminated[1])
  end)

  it("rejects detached I/O and propagates waiter cancellation", function()
    local relay = relay_lease.new()
    local written, write_err = relay:write("bytes")
    assert.is_nil(written)
    assert.matches("stdin is closed", assert(write_err).message)
    local closed, close_err = relay:close_stdin()
    assert.is_nil(closed)
    assert.matches("not attached", assert(close_err).message)

    local base, state = base_child()
    relay:attach(base)
    local admission = async.run(function()
      return relay:wait_ready()
    end)
    admission:cancel()
    assert(vim.wait(1000, function() return admission:is_done() end))
    local waiting = async.run(function()
      return relay:wait()
    end)
    waiting:cancel()
    assert(vim.wait(1000, function()
      return waiting:is_done()
    end))
    assert.are.same({}, state.terminated)
    relay:dispose("test complete")
    written, write_err = relay:write("late")
    assert.is_nil(written)
    assert.matches("stdin is closed", assert(write_err).message)
    relay:feed("ignored after close")

    local detached = relay_lease.new()
    detached:dispose("disposed before attachment")
    local detached_base, detached_state = base_child()
    detached:attach(detached_base)
    assert.is_true(detached_state.closed)
  end)
end)
