local assert = require("luassert")
local async = require("neoagent.async")
local protocol = require("neoagent.rpc.protocol")
local util = require("neoagent.util")
local peer = require("tests.helpers.rpc")
local wait = peer.wait
local fake_child = peer.transport
local opened = peer.open

---@param message table
---@param set_padding fun(value: string)
local function fit_frame(message, set_padding)
  local padding = ""
  for _ = 1, 8 do
    set_padding(padding)
    local difference = protocol.MAX_FRAME - #vim.mpack.encode(message)
    if difference == 0 then
      return
    end
    if difference > 0 then
      padding = padding .. string.rep("x", difference)
    else
      padding = padding:sub(1, #padding + difference)
    end
  end
  error("could not construct an exact RPC frame")
end

describe("neoagent RPC connection edge cases", function()
  it("reports a failed worker exit after orderly protocol shutdown", function()
    for _, failure in ipairs({
      { code = 7, signal = 0, stderr = "shutdown failed" },
      { code = 0, signal = 0, stderr = "", error = util.error("worker_exit", "cleanup failed") },
    }) do
      local failures = {}
      local remote = opened(function(message, emit)
        if message.type == "close" then
          emit({ type = "closed", call_id = message.call_id })
        end
      end, { on_failure = function(err) failures[#failures + 1] = err end })
      assert.is_true(wait(async.run(function() return remote:close() end)))
      remote:eof(failure)
      remote:eof(failure)
      assert.are.equal(1, #failures)
      local closed = wait(async.run(function() return remote:close() end))
      assert.is_false(closed.ok)
      assert.matches("failed", assert(closed.error).message)
    end
  end)

  it("preserves successful response objects with failure-shaped fields", function()
    local response = { ok = false, error = { kind = "domain", message = "not ready" } }
    local remote = opened(function(message, emit)
      if message.type == "request" then
        emit({ type = "response", call_id = message.call_id, request_id = message.request_id, value = response })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    local result = wait(async.run(function()
      local first = remote:request("status", {})
      local second = remote:request("status", {})
      remote:close()
      return { first = first, second = second }
    end))
    assert.are.same(response, result.first)
    assert.are.same(response, result.second)
  end)

  it("treats the frame limit as payload bytes in both directions", function()
    local remote
    local requests = 0
    remote = opened(function(message, emit)
      if message.type == "request" then
        requests = requests + 1
        local response = {
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = { padding = "" },
        }
        fit_frame(response, function(value)
          response.value.padding = value
        end)
        emit(response)
      elseif message.type == "request_end" then
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = { streamed = true },
        })
      end
    end)

    local exact = {
      type = "request",
      call_id = remote._call_id,
      request_id = 1,
      method = "boundary",
      payload = { padding = "" },
    }
    fit_frame(exact, function(value)
      exact.payload.padding = value
    end)
    local direct = wait(async.run(function()
      return remote:request(exact.method, exact.payload)
    end), 10000)
    assert.are.equal(protocol.MAX_FRAME, #vim.mpack.encode({
      type = "response",
      call_id = remote._call_id,
      request_id = 1,
      value = direct,
    }))
    assert.are.equal(1, requests)

    exact.payload.padding = exact.payload.padding .. "x"
    local streamed = wait(async.run(function()
      return remote:request(exact.method, exact.payload)
    end), 10000)
    assert.is_true(streamed.streamed)
  end)

  it("bounds queued frames and ignores later input after a terminal failure", function()
    local original_limit = protocol.MAX_QUEUED_BYTES
    local remote = require("neoagent.rpc.connection").new()
    local child, state = fake_child(remote)
    remote:attach(child)
    protocol.MAX_QUEUED_BYTES = 1
    remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    protocol.MAX_QUEUED_BYTES = original_limit
    assert.are.equal("failed", remote._state)
    remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    assert.is_false(state.terminated)

    local repeated = require("neoagent.rpc.connection").new()
    local repeated_child = fake_child(repeated)
    repeated:attach(repeated_child)
    local ready = protocol.encode({ type = "ready", marker = protocol.MARKER })
    repeated:feed(ready .. ready .. ready)
    assert.are.equal("failed", repeated._state)

    local malformed = require("neoagent.rpc.connection").new()
    local malformed_child, malformed_state = fake_child(malformed)
    malformed:attach(malformed_child)
    malformed:feed("\0\0\0\1\255")
    assert.are.equal("failed", malformed._state)
    assert.is_false(malformed_state.terminated)
  end)

  it("accounts for received frame bytes even when MessagePack has a shorter encoding", function()
    local remote = require("neoagent.rpc.connection").new()
    local child, state = fake_child(remote)
    remote:attach(child)
    local compact = protocol.encode({ type = "ready", marker = protocol.MARKER })
    assert.are.equal(0x82, compact:byte(5))
    -- map16 and fixmap encode the same envelope with different byte counts.
    local payload = "\222\0\2" .. compact:sub(6)
    local received = "\0\0\0" .. string.char(#payload) .. payload
    local original_limit = protocol.MAX_QUEUED_BYTES
    protocol.MAX_QUEUED_BYTES = #compact
    remote:feed(received)
    protocol.MAX_QUEUED_BYTES = original_limit
    assert.are.equal("failed", remote._state)
    assert.matches("queue limit", assert(remote._failure).message)
    assert.is_false(state.terminated)
  end)

  it("binds cancellation to its originating request", function()
    local cancellations = 0
    local request_count = 0
    local remote = opened(function(message, emit)
      if message.type == "request" then
        request_count = request_count + 1
        if request_count == 1 then
          emit({
            type = "response",
            call_id = message.call_id,
            request_id = message.request_id,
            value = { ordinal = 1 },
          })
        end
      elseif message.type == "cancel" then
        cancellations = cancellations + 1
        emit({
          type = "cancelled", call_id = message.call_id,
          request_id = message.request_id,
        })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    local first = remote:start_request("bound", {})
    local first_result = wait(async.run(function()
      return first:result()
    end))
    assert.are.equal(1, first_result.ordinal)

    local second = remote:start_request("bound", {})
    first:cancel()
    assert.are.equal("request", remote._state)
    assert.are.equal(0, cancellations)
    second:cancel()
    assert.are.equal(1, cancellations)
    assert.are.equal("open", remote._state)
    local cancelled = wait(async.run(function()
      return second:result()
    end))
    assert.is_false(cancelled.ok)
    assert.are.equal("cancelled", cancelled.error.kind)
    assert.is_true(wait(async.run(function()
      return remote:close()
    end)))
  end)

  it("keeps a repeated cancellation from reaching the next request before delivery", function()
    local cancellations = 0
    local remote = opened(function(message, emit)
      if message.type == "cancel" then
        cancellations = cancellations + 1
        emit({ type = "cancelled", call_id = message.call_id, request_id = message.request_id })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    local first = remote:start_request("first", {})
    first:cancel()
    local second = remote:start_request("second", {})
    first:cancel()
    assert.are.equal(1, cancellations)
    assert.are.equal("request", remote._state)
    second:cancel()
    assert.are.equal(2, cancellations)
    for _, request in ipairs({ first, second }) do
      local result = wait(async.run(function() return request:result() end))
      assert.is_false(result.ok)
      assert.are.equal("cancelled", assert(result.error).kind)
    end
    assert.is_true(wait(async.run(function() return remote:close() end)))
  end)

  it("rejects a shutdown acknowledgement received during an active request", function()
    local failures = 0
    local remote = opened(function(message, emit)
      if message.type == "request" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end, { on_failure = function() failures = failures + 1 end,
      })
    local value = wait(async.run(function() return remote:request("work", {}) end))
    assert.is_false(value.ok)
    assert.matches("invalid state", assert(value.error).message)
    assert.are.equal("failed", remote._state)
    assert.are.equal(1, failures)
  end)

  it("reports worker failures delivered while closing its input", function()
    for _, exit in ipairs({
      { code = 0, signal = 0, stderr = "", error = util.error("guardian", "guardian cleanup failed") },
      { code = 7, signal = 0, stderr = "worker cleanup failed" },
    }) do
      local failures = 0
      local remote, child = opened(function(message, emit)
        if message.type == "close" then emit({ type = "closed", call_id = message.call_id }) end
      end, { on_failure = function() failures = failures + 1 end,
        })
      child.close_stdin = function()
        remote:eof(exit)
        return true
      end
      local closed = wait(async.run(function() return remote:close() end))
      assert.is_false(closed.ok)
      assert.matches(exit.error and "guardian cleanup failed" or "failed during shutdown", assert(closed.error).message)
      assert.are.equal("failed", remote._state)
      assert.are.equal(1, failures)
    end
  end)

  it("reuses and closes a connection after cancellation races a queued response", function()
    local handler_started = false
    local raced, _, raced_state = opened(function(message, emit)
      if message.type == "request" then
        if message.method == "terminal" then
          emit({
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = 1,
            name = "pause",
            value = {},
          })
        end
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = { method = message.method },
        })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    local terminal = raced:start_request("terminal", {}, {
      on_event = function()
        handler_started = true
        async.await(function()
          return function() end
        end)
      end,
    })
    assert(vim.wait(1000, function() return handler_started end))
    terminal:cancel()
    assert(vim.wait(1000, function() return raced._state == "open" end))
    assert.are.same({ "open", "request" }, raced_state.messages)
    local cancelled = wait(async.run(function()
      return terminal:result()
    end))
    assert.is_false(cancelled.ok)
    assert.are.equal("cancelled", cancelled.error.kind)
    assert.is_true(wait(async.run(function()
      return raced:wait_cancelled()
    end)))
    local reused = wait(async.run(function()
      return raced:request("reused", {})
    end))
    assert.are.same({ method = "reused" }, reused)
    assert.is_true(wait(async.run(function()
      return raced:close()
    end)))
    assert.are.same({ "open", "request", "request", "close" }, raced_state.messages)
    assert.is_true(raced_state.closed_stdin)
    assert.is_false(raced_state.terminated)
    assert.is_false(raced_state.closed)
  end)

  it("rejects malformed or unhandled connection-scoped events once", function()
    local cases = {
      {
        label = "call",
        message = function(remote)
          return {
            type = "event",
            call_id = remote._call_id .. "-stale",
            sequence = 1,
            name = "output",
            value = {},
          }
        end,
        on_event = function() end,
        expected = "invalid state",
      },
      {
        label = "sequence",
        message = function(remote)
          return {
            type = "event",
            call_id = remote._call_id,
            sequence = 2,
            name = "output",
            value = {},
          }
        end,
        on_event = function() end,
        expected = "sequence",
      },
      {
        label = "unhandled",
        message = function(remote)
          return {
            type = "event",
            call_id = remote._call_id,
            sequence = 1,
            name = "output",
            value = {},
          }
        end,
        expected = "unhandled",
      },
      {
        label = "callback",
        message = function(remote)
          return {
            type = "event",
            call_id = remote._call_id,
            sequence = 1,
            name = "output",
            value = {},
          }
        end,
        on_event = function() error("event consumer failed") end,
        expected = "event consumer failed",
      },
    }
    for _, case in ipairs(cases) do
      local failures = {}
      local remote = opened(nil, {
        on_event = case.on_event,
        on_failure = function(err)
          failures[#failures + 1] = err
        end,
      })
      remote:feed(protocol.encode(case.message(remote)))
      assert.are.equal("failed", remote._state, case.label)
      assert.matches(case.expected, assert(remote._failure).message, 1, true)
      assert.are.equal(1, #failures)
      remote:abort()
      assert.are.equal(1, #failures)
    end
  end)

  it("rejects request events without a request-scoped consumer", function()
    local remote = opened(function(message, emit)
      if message.type == "request" then
        emit({
          type = "event",
          call_id = message.call_id,
          request_id = message.request_id,
          sequence = 1,
          name = "progress",
          value = { content = { { type = "text", text = "working" } } },
        })
      end
    end)
    local result = wait(async.run(function()
      return remote:request("write_file", {
        path = "file", resolved_path = "/workspace/file", content = "value",
      })
    end))
    assert.is_false(result.ok)
    assert.matches("unhandled event", result.error.message)
  end)

  it("waits for cooperative cancellation and contains cancelled waiters", function()
    ---@type fun()?
    local finish_cancel
    local remote = opened(function(message, emit)
      if message.type == "cancel" then
        finish_cancel = function()
          emit({
            type = "cancelled", call_id = message.call_id,
            request_id = message.request_id,
          })
        end
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    local request = remote:start_request("write_file", {
      path = "file", resolved_path = "/workspace/file", content = "value",
    })
    request:cancel()
    assert.are.equal("cancelling", remote._state)
    local cancellation = async.run(function()
      return remote:wait_cancelled()
    end)
    assert.is_false(cancellation:is_done())
    if not finish_cancel then
      error("RPC peer did not receive cancellation")
    end
    finish_cancel()
    assert.is_true(wait(cancellation))
    assert.is_true(wait(async.run(function()
      return remote:wait_cancelled()
    end)))
    assert.is_true(wait(async.run(function()
      return remote:close()
    end)))

    finish_cancel = nil
    local removed = opened(function(message, emit)
      if message.type == "cancel" then
        finish_cancel = function()
          emit({
            type = "cancelled", call_id = message.call_id,
            request_id = message.request_id,
          })
        end
      end
    end)
    local removed_request = removed:start_request("write_file", {
      path = "file", resolved_path = "/workspace/file", content = "value",
    })
    removed_request:cancel()
    local removed_waiter = async.run(function()
      return removed:wait_cancelled()
    end)
    removed_waiter:cancel()
    assert.is_false(wait(removed_waiter).ok)
    assert.are.equal(0, #removed._cancel_waiters)
    if not finish_cancel then
      error("RPC peer did not receive cancelled-waiter cancellation")
    end
    finish_cancel()

    local failures = {}
    local rejected = opened(nil, {
      on_failure = function(err) failures[#failures + 1] = err end,
    })
    local rejected_request = rejected:start_request("write_file", {
      path = "file", resolved_path = "/workspace/file", content = "value",
    })
    rejected_request:cancel()
    local rejected_waiter = async.run(function()
      return rejected:wait_cancelled()
    end)
    rejected:abort()
    local rejected_result = wait(rejected_waiter)
    assert.is_false(rejected_result.ok)
    assert.are.equal(1, #failures)
    local failed_wait = wait(async.run(function()
      return rejected:wait_cancelled()
    end))
    assert.is_false(failed_wait.ok)

    local idle = require("neoagent.rpc.connection").new()
    local idle_wait = wait(async.run(function()
      return idle:wait_cancelled()
    end))
    assert.is_false(idle_wait.ok)
    assert.matches("no cancelling request", idle_wait.error.message)

    local started, start_err = pcall(
      idle.start_request, idle, "write_file",
      { path = "file", resolved_path = "/workspace/file", content = "value" }
    )
    assert.is_false(started)
    assert.matches("not ready", util.normalize_error(start_err).message)
    idle:abort()
    started, start_err = pcall(
      idle.start_request, idle, "write_file",
      { path = "file", resolved_path = "/workspace/file", content = "value" }
    )
    assert.is_false(started)
    assert.matches("aborted", util.normalize_error(start_err).message)
  end)

  it("settles the active request when cancellation starts from the connection", function()
    local requests = 0
    local remote = opened(function(message, emit)
      if message.type == "request" then
        requests = requests + 1
        if requests == 2 then
          emit({
            type = "response", call_id = message.call_id,
            request_id = message.request_id, value = { request = requests },
          })
        end
      elseif message.type == "cancel" then
        emit({
          type = "cancelled", call_id = message.call_id,
          request_id = message.request_id,
        })
      end
    end)
    local first = remote:start_request("write_file", {
      path = "file", resolved_path = "/workspace/file", content = "value",
    })

    remote:cancel()

    assert(vim.wait(1000, function() return first._run:is_done() end, 5))
    local cancelled = wait(async.run(function() return first:result() end))
    assert.is_false(cancelled.ok)
    assert.are.equal("cancelled", cancelled.error.kind)
    local second = wait(async.run(function()
      return remote:request("write_file", {
        path = "second", resolved_path = "/workspace/second", content = "value",
      })
    end))
    assert.are.same({ request = 2 }, second)
  end)

  it("reports a late worker error during orderly connection close", function()
    ---@type Neoagent.RpcConnection?
    local remote
    remote = opened(function(message, emit)
      if message.type == "request" then
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = { content = { { type = "text", text = "complete" } } },
        })
        assert(remote):eof({
          code = 0, signal = 0, stderr = "",
          error = util.error("sandbox_unavailable", "guardian failed"),
        })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    local active = assert(remote)
    local result = wait(async.run(function()
      return active:request("write_file", {
        path = "file", resolved_path = "/workspace/file", content = "value",
      })
    end))
    assert.are.equal("complete", assert(result.content[1]).text)
    local closed = wait(async.run(function()
      return active:close()
    end))
    assert.is_false(closed.ok)
    assert.are.equal("sandbox_unavailable", closed.error.kind)
    assert.matches("guardian failed", closed.error.message)
  end)

  it("preserves a queued response while independently failing an exited connection", function()
    local failures = {}
    ---@type fun()?
    local release
    ---@type Neoagent.RpcConnection?
    local selected
    selected = opened(function(message, emit)
      if message.type == "request" then
        emit({
          type = "event", call_id = message.call_id,
          request_id = message.request_id, sequence = 1,
          name = "progress", value = {
            content = { { type = "text", text = "working" } },
          },
        })
        emit({
          type = "response", call_id = message.call_id,
          request_id = message.request_id, value = { completed = true },
        })
        assert(selected):eof({
          code = 0, signal = 0, stderr = "",
          error = util.error("sandbox_unavailable", "guardian exited"),
        })
      end
    end, {
      on_failure = function(err) failures[#failures + 1] = err end,
    })
    local remote = assert(selected)
    local request = remote:start_request("write_file", {
      path = "file", resolved_path = "/workspace/file", content = "value",
    }, {
      on_event = function()
        async.await(function(done)
          release = function() done.resolve(true) end
          return function() end
        end)
      end,
    })
    assert(vim.wait(1000, function()
      return release ~= nil and remote._state == "failed"
    end, 5))

    assert.are.equal("failed", remote._state)
    assert.are.equal(1, #failures)
    assert.are.equal("sandbox_unavailable", failures[1].kind)
    assert(release)()
    local value = wait(async.run(function() return request:result() end))
    assert.are.same({ completed = true }, value)
    local reused, reuse_err = pcall(remote.start_request, remote, "write_file", {
      path = "second", resolved_path = "/workspace/second", content = "value",
    })
    assert.is_false(reused)
    assert.matches("guardian exited", util.normalize_error(reuse_err).message)
  end)

  it("rejects an unencodable request before sending it to the worker", function()
    local remote, _, state = opened()
    local invalid = {}
    rawset(invalid, "content", function() end)
    local result = wait(async.run(function()
      return remote:request("write_file", invalid)
    end))
    assert.is_false(result.ok)
    assert.matches("could not be encoded", assert(result.error).message)
    assert.are.same({ "open" }, state.messages)
    assert.is_false(state.terminated)
  end)

  it("rejects failures racing each startup acknowledgement", function()
    local ready_race = require("neoagent.rpc.connection").new()
    local ready_child = fake_child(ready_race)
    ready_race:attach(ready_child)
    local opening = async.run(function()
      ready_race:open({})
      return true
    end)
    local ready = protocol.encode({ type = "ready", marker = protocol.MARKER })
    ready_race:feed(ready .. ready)
    assert.is_false(wait(opening).ok)

    local opened_race = require("neoagent.rpc.connection").new()
    local opened_child = fake_child(opened_race, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
        emit({ type = "opened", call_id = message.call_id })
      end
    end)
    opened_race:attach(opened_child)
    opened_race:feed(ready)
    local opened_result = wait(async.run(function()
      opened_race:open({})
      return true
    end))
    assert.is_false(opened_result.ok)
  end)

end)
