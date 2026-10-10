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
    is_released = function() return true end,
    wait_release = function() return true end,
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
  it("keeps native release independent of completion and observer cancellation", function()
    local helper = require("tests.helpers.subprocess")
    local base = base_child()
    local released = false
    ---@type Neoagent.AwaitCallbacks<true>?
    local release
    base.is_released = function() return released end
    base.wait_release = function()
      return async.await(function(done) release = done end)
    end
    local relay = relay_lease.new()
    relay:attach(base)
    relay:feed(ready() .. exited())
    relay:host_exited({ code = 0, signal = 0, stderr = "" })
    assert.are.equal(0, relay:wait().code)
    assert.is_false(relay:is_released())
    local observing = async.run(function() return relay:wait_release() end)
    assert.is_false(observing:is_done())
    observing:cancel()
    assert.are.equal("cancelled", assert(helper.wait(observing).error).kind)
    observing = async.run(function() return relay:wait_release() end)
    released = true
    local observed = release or error("release observer was not installed")
    observed.resolve(true)
    assert.is_true(helper.wait(observing))
    assert.is_true(relay:is_released())
  end)

  it("does not report native release as successful staging cleanup", function()
    local helper = require("tests.helpers.subprocess")
    local relay = relay_lease.new({ cleanup = function() return nil, "staging remains" end })
    relay:attach(base_child())
    relay:feed(ready() .. exited())
    relay:host_exited({ code = 0, signal = 0, stderr = "" })
    assert.is_not_nil(relay:wait().cleanup_error)
    assert.is_false(relay:is_released())
    local observing = async.run(function() return relay:wait_release() end)
    local completed = observing:is_done()
    if not completed then observing:cancel() end
    local result = helper.wait(observing)
    assert.is_true(completed, "permanent staging failure must reject release observation")
    assert.matches("Could not clean native sandbox resources", assert(result.error).message, 1, true)
    assert.is_false(relay:is_released())
  end)

  for _, operation_failed in ipairs({ false, true }) do
    it("preserves native permission cleanup independently of operation failure=" .. tostring(operation_failed), function()
      local util = require("neoagent.util")
      local host_failure = util.error("worker_exit", "host reaping failed", "errno=10")
      local relay = relay_lease.new({ cleanup = function(_, terminal)
        if not terminal or not terminal.cleanup then return nil, "valid cleanup evidence is missing" end
        if terminal.cleanup.error then return nil, terminal.cleanup.error.stage end
        return terminal.cleanup.released and true or nil
      end })
      relay:attach(base_child())
      local terminal = operation_failed and { v = 1, type = "error", stage = "runner-start", errno = 2 }
        or { v = 1, type = "exit", code = 7, signal = 0 }
      terminal.cleanup = { released = false, error = { stage = "acl-write", errno = 5 } }
      relay:feed(ready() .. protocol.encode(terminal))
      relay:host_exited({ code = 0, signal = 0, stderr = "", cleanup_error = host_failure })
      local result = relay:wait()
      local failure = assert(result.cleanup_error)
      assert.are.equal("acl-write", failure.detail)
      assert.are.same(host_failure, rawget(failure, "cause"))
      assert.is_false(relay:is_released())
      local released, release_error = pcall(relay.wait_release, relay)
      assert.is_false(released)
      assert.are.same(failure, release_error)
      if operation_failed then
        assert.matches("runner-start", assert(result.error).message, 1, true)
      else
        assert.are.equal(7, result.code)
        assert.is_nil(result.error)
      end
    end)
  end

  it("releases native permission ownership after acknowledged cleanup of failed startup", function()
    local relay = relay_lease.new({ cleanup = function(_, terminal)
        if not terminal or not terminal.cleanup then return nil, "valid cleanup evidence is missing" end
        if terminal.cleanup.error then return nil, terminal.cleanup.error.stage end
        return terminal.cleanup.released and true or nil
      end })
    relay:attach(base_child())
    relay:feed(protocol.encode({ v = 1, type = "error", stage = "runner-start", errno = 2,
      cleanup = { released = true } }))
    relay:host_exited({ code = 125, signal = 0, stderr = "" })
    assert.is_not_nil(relay:wait().error)
    assert.is_nil(relay:wait().cleanup_error)
    assert.is_true(relay:wait_release())
    assert.is_true(relay:is_released())
  end)

  for _, stopped in ipairs({ "disposal", "output failure", "admission timeout" }) do
    it("observes native cleanup acknowledgement after " .. stopped, function()
      local output, failures = {}, {}
      local relay = relay_lease.new({
        admission_timeout_ms = 1,
        cleanup = function(_, terminal)
          assert.is_true(assert(assert(terminal).cleanup).released)
          return true
        end,
        on_stdout = function(data)
          output[#output + 1] = data
          if stopped == "output failure" then error("consumer failed") end
        end,
        on_failure = function(err) failures[#failures + 1] = err end,
      })
      relay:attach(base_child())
      if stopped == "admission timeout" then
        local observer = async.run(function() return relay:wait_ready() end)
        local completed = vim.wait(1000, function() return observer:is_done() end, 5)
        observer:cancel()
        assert.is_true(completed)
      end
      relay:feed(ready())
      if stopped == "disposal" then relay:dispose("observer no longer owns output") end
      relay:feed(protocol.encode({ v = 1, type = "output", stream = "stdout", seq = 1, data = "late" }))
      -- Cleanup is a separate native fact and can arrive in a later read even
      -- after publication has stopped or admission has failed.
      relay:feed(protocol.encode({ v = 1, type = "exit", code = 7, signal = 0, cleanup = { released = true } }))
      relay:host_exited({ code = 0, signal = 0, stderr = "" })
      local result = relay:wait()
      assert.is_nil(result.cleanup_error, "a valid native cleanup acknowledgement was discarded")
      assert.are.equal(7, result.code)
      assert.is_true(relay:is_released())
      assert.are.same(stopped == "output failure" and { "late" } or {}, output)
      assert.are.same(failures[1], result.error)
    end)
  end

  it("rejects malformed cleanup acknowledgements without releasing native ownership", function()
    for _, observation in ipairs({
      true, {}, { released = "true" }, { released = true, extra = true },
      { released = true, error = { stage = "acl-write", errno = 5 } },
      { released = false, error = false }, { released = false, error = {} },
      { released = false, error = { stage = "", errno = 5 } },
      { released = false, error = { stage = "acl-write", errno = -1 } },
    }) do
      local relay = relay_lease.new({ cleanup = function(_, terminal)
        if not terminal or not terminal.cleanup then return nil, "valid cleanup evidence is missing" end
        if terminal.cleanup.error then return nil, terminal.cleanup.error.stage end
        return terminal.cleanup.released and true or nil
      end })
      relay:attach(base_child())
      relay:feed(ready() .. protocol.encode({ v = 1, type = "exit", code = 0, signal = 0, cleanup = observation }))
      relay:feed(protocol.encode({ v = 1, type = "exit", code = 0, signal = 0, cleanup = { released = true } }))
      relay:host_exited({ code = 0, signal = 0, stderr = "" })
      assert.is_not_nil(relay:wait().error)
      assert.is_not_nil(relay:wait().cleanup_error)
      assert.is_false(relay:is_released())
    end
  end)

  for _, suffix in ipairs({ "\0", "\0\0\0\1\255", exited() }) do
    it("rejects a cached release acknowledgement when trailing protocol bytes are invalid: " .. #suffix, function()
      local relay = relay_lease.new({ cleanup = function(_, terminal)
        if not terminal or not terminal.cleanup then return nil, "valid cleanup evidence is missing" end
        if terminal.cleanup.error then return nil, terminal.cleanup.error.stage end
        return terminal.cleanup.released and true or nil
      end })
      relay:attach(base_child())
      relay:feed(ready() .. protocol.encode({ v = 1, type = "exit", code = 7, signal = 0,
        cleanup = { released = true } }))
      relay:feed(suffix)
      relay:host_exited({ code = 0, signal = 0, stderr = "" })
      local result = relay:wait()
      assert.is_not_nil(result.error)
      assert.is_not_nil(result.cleanup_error, "invalid protocol reused an earlier cleanup acknowledgement")
      assert.is_false(relay:is_released())
      local released, release_error = pcall(relay.wait_release, relay)
      assert.is_false(released)
      assert.are.same(result.cleanup_error, release_error)
    end)
  end

  it("preserves host cleanup separately from an earlier protocol failure", function()
    local util = require("neoagent.util")
    local relay = relay_lease.new({
      cleanup = function()
        return nil, "staging removal denied"
      end,
    })
    relay:attach(base_child())
    relay:feed("\0\0\0\1\255")
    local admitted, admission_error = pcall(relay.wait_ready, relay)
    assert.is_false(admitted)
    local native_error = util.error("worker_exit", "native child reap failed", "errno=10")
    relay:host_exited({ stderr = "", cleanup_error = native_error })
    local result = relay:wait()
    local cleanup = assert(result.cleanup_error)
    assert.are.same(native_error, rawget(cleanup, "cause"))
    assert.are.equal("staging removal denied", cleanup.detail)
    assert.are.same(admission_error, result.error)
  end)

  it("preserves unknown exit status when native cleanup fails", function()
    local relay = relay_lease.new()
    relay:feed(ready())
    relay:host_exited({ stderr = "", cleanup_error = require("neoagent.util").error("worker_exit", "Cleanup did not settle") })
    local result = relay:wait()
    assert.is_not_nil(result.cleanup_error)
    assert.is_nil(result.code)
    assert.is_nil(result.signal)
  end)

  it("preserves the observed target exit when later cleanup fails", function()
    local relay = relay_lease.new({ cleanup = function() return nil, "cleanup failed" end })
    relay:feed(ready() .. exited(143, 15))
    relay:host_exited({ code = 0, signal = 0, stderr = "" })
    local result = relay:wait()
    assert.is_not_nil(result.cleanup_error)
    assert.are.equal(143, result.code)
    assert.are.equal(15, result.signal)
  end)

  for _, throws in ipairs({ false, true }) do
    it("preserves cleanup failure after protocol failure with throwing=" .. tostring(throws), function()
      local failures, exits = {}, {}
      local relay = relay_lease.new({
        cleanup = function()
          if throws then
            error("staging cleanup denied", 0)
          end
          return nil, "staging cleanup denied"
        end,
        on_failure = function(err) failures[#failures + 1] = err end,
        on_exit = function(result) exits[#exits + 1] = result end,
      })
      relay:attach(base_child())
      relay:feed("\0\0\0\1\255")
      local ready, readiness_error = pcall(relay.wait_ready, relay)
      assert.is_false(ready)
      relay:host_exited({ code = 0, signal = 0, stderr = "" })
      local result = relay:wait()
      local failure = assert(result.cleanup_error)
      assert.are.equal("Could not clean native sandbox resources", failure.message)
      assert.are.equal("staging cleanup denied", failure.detail)
      assert.are.same(readiness_error, result.error)
      assert.are.same({ readiness_error }, failures)
      assert.are.same({ result }, exits)
      local still_failed, still_error = pcall(relay.wait_ready, relay)
      assert.is_false(still_failed)
      assert.are.same(readiness_error, still_error)
    end)
  end

  it("discards stdout when only a stderr observer is installed", function()
    local stderr = {}
    local relay = relay_lease.new({
      on_stderr = function(data) stderr[#stderr + 1] = data end,
    })
    relay:attach(base_child())
    relay:feed(ready()
      .. protocol.encode({ v = 1, type = "output", stream = "stdout", seq = 1, data = "binary\0output" })
      .. protocol.encode({ v = 1, type = "output", stream = "stderr", seq = 2, data = "diagnostic" })
      .. exited())
    relay:host_exited({ code = 0, signal = 0, stderr = "" })
    assert.are.same({ "diagnostic" }, stderr)
    assert.are.equal("diagnostic", relay:wait().stderr)
  end)

  it("frames binary input and closes worker stdin without dropping the owner channel", function()
    local chunks, ends = {}, 0
    local decoder = protocol.input_decoder(function(data) chunks[#chunks + 1] = data end,
      function() ends = ends + 1 end)
    local base, state = base_child()
    base.write = function(_, data) decoder:feed(data) return true end
    local relay = relay_lease.new({ framed_input = true })
    relay:attach(base)
    assert.is_false(pcall(relay.write, relay, ""))
    local data = string.rep("x\0\255", protocol.MAX_INPUT_CHUNK)
    assert.is_true((relay:write(data)))
    assert.are.equal(data, table.concat(chunks))
    assert.is_true(#chunks > 1)
    assert.is_true((relay:close_stdin()))
    assert.is_true((relay:close_stdin()))
    assert.are.equal(1, ends)
    assert.is_false(state.stdin_closed, "logical EOF closed the owner's control pipe")
    assert.is_nil((relay:write("late input")))
  end)

  it("reports failure to enqueue framed input or its logical EOF", function()
    local base = base_child()
    local failure = require("neoagent.util").error("protocol", "input queue failed")
    base.write = function() return nil, failure end
    local relay = relay_lease.new({ framed_input = true })
    relay:attach(base)
    local written, err = relay:write("input")
    assert.is_nil(written)
    assert.are.equal(failure, err)
    local closed, close_err = relay:close_stdin()
    assert.is_nil(closed)
    assert.are.equal(failure, close_err)
  end)

  it("rejects malformed input and every message after logical EOF", function()
    for _, message in ipairs({
      42,
      { v = 1, type = "stdin", data = "input", extra = true },
      { v = 2, type = "stdin", data = "input" },
      { v = 1, type = "stdin", data = "" },
      { v = 1, type = "stdin", data = string.rep("x", protocol.MAX_INPUT_CHUNK + 1) },
      { v = 1, type = "stdin-end", data = "input" },
      { v = 1, type = "unknown" },
    }) do
      local observed = false
      local decoder = protocol.input_decoder(function() observed = true end, function() observed = true end)
      assert.is_false(pcall(decoder.feed, decoder, protocol.encode(message)))
      assert.is_false(observed)
    end
    local ends = 0
    local decoder = protocol.input_decoder(function() error("input followed EOF") end,
      function() ends = ends + 1 end)
    local eof = protocol.encode({ v = 1, type = "stdin-end" })
    decoder:feed(eof)
    assert.is_false(pcall(decoder.feed, decoder, eof))
    assert.are.equal(1, ends)
  end)

  it("retains native cleanup after the worker exits and an observer cancels", function()
    local resume, exits
    exits = 0
    local relay = relay_lease.new({
      cleanup = function()
        return async.await(function(done) resume = function() done.resolve(true) end end)
      end,
      on_exit = function() exits = exits + 1 end,
    })
    relay:attach(base_child())
    relay:feed(ready() .. exited())
    local observer = async.run(function() return relay:wait() end)
    relay:host_exited({ code = 0, signal = 0, stderr = "" })
    local checked, failure = pcall(function()
      assert.are.equal(0, exits)
      assert.is_function(resume)
      observer:cancel()
      ---@cast resume fun()
      resume()
      local owner = async.run(function() return relay:wait() end)
      assert(vim.wait(1000, function() return owner:is_done() end))
      assert.is_nil(assert(owner:result()).error)
      assert.are.equal(1, exits)
    end)
    if resume then resume() end
    observer:cancel()
    assert.is_true(checked, tostring(failure))
  end)

  it("retains protocol failures received while native cleanup is pending", function()
    ---@type fun()?
    local resume
    local failures = {}
    local relay = relay_lease.new({
      cleanup = function()
        return async.await(function(done) resume = function() done.resolve(true) end end)
      end,
      on_failure = function(err) failures[#failures + 1] = err end,
    })
    relay:attach(base_child())
    relay:feed(ready() .. exited())
    relay:host_exited({ code = 0, signal = 0, stderr = "" })
    local checked, failure = pcall(function()
      assert.is_function(resume)
      relay:feed(ready())
      assert(resume)()
      assert.are.equal(1, #failures)
      local waiting = async.run(function() return relay:wait() end)
      assert(vim.wait(1000, function() return waiting:is_done() end))
      assert.are.same(failures[1], assert(waiting:result()).error)
    end)
    if resume then resume() end
    assert.is_true(checked, tostring(failure))
  end)

  it("stops publication and rejects writes after a native protocol failure", function()
    local output, failures = {}, {}
    local relay = relay_lease.new({
      on_stdout = function(data) output[#output + 1] = data end,
      on_failure = function(err) failures[#failures + 1] = err end,
    })
    local base, state = base_child()
    relay:attach(base)
    relay:feed(ready())
    relay:feed(ready())
    relay:feed(protocol.encode({ v = 1, type = "output", stream = "stdout", seq = 1, data = "late result" }))
    local written = relay:write("late request")
    relay:host_exited({ code = 0, signal = 0, stderr = "" })
    assert.are.same({}, output, "failed native traffic reached the RPC consumer")
    assert.is_nil(written, "a failed native channel accepted another request")
    assert.are.equal(1, #failures)
    assert.are.equal("sandbox_unavailable", failures[1].kind)
    assert.are.equal(1, #state.terminated)
    assert.is_not_nil(relay:wait().error)
  end)

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

  it("settles concurrent admission waiters with one timeout failure", function()
    local failures = {}
    local relay = relay_lease.new({
      admission_timeout_ms = 10,
      on_failure = function(err) failures[#failures + 1] = err end,
    })
    local base, state = base_child()
    relay:attach(base)
    local admitted = async.run(function()
      return relay:wait_ready()
    end)
    local observer = async.run(function()
      return relay:wait_ready()
    end)

    local settled = vim.wait(1000, function() return admitted:is_done() and observer:is_done() end)
    admitted:cancel()
    observer:cancel()
    assert(settled)
    local result = assert(admitted:result())
    assert.is_false(result.ok)
    local admission_error = assert(result.error)
    assert.are.equal("sandbox_unavailable", admission_error.kind)
    assert.matches("admission timed out", admission_error.message)
    assert.are.same(admission_error, assert(observer:result()).error)
    assert.are.same({ admission_error }, failures)
    assert.are.equal(1, #state.terminated)
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
      assert.matches("Could not clean", assert(relay:wait().cleanup_error).message)
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
