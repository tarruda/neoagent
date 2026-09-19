local assert = require("luassert")
local async = require("neoagent.async")
local codec = require("neoagent.rpc.codec")
local limits = require("neoagent.rpc.limits")
local protocol = require("neoagent.rpc.protocol")
local util = require("neoagent.util")

---@param files? Neoagent.Files
---@return Neoagent.ToolOperationCall
local function call(files)
  local storage = files or require("neoagent.files.memory").new()
  return {
    workspace = { root = "/workspace", cwd = "/workspace" },
    artifacts = { put = storage.put },
    on_update = function() end,
  }
end

---@generic T
---@param run Neoagent.Run<T, unknown>
---@param timeout? integer
---@return Neoagent.RunResult<T>
local function wait(run, timeout)
  assert(vim.wait(timeout or 3000, function()
    return run:is_done()
  end), "remote edge-case Run did not settle")
  local result = run:result()
  if not result then error("remote edge-case Run returned no result") end
  return result
end

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

---@param remote Neoagent.TestToolRpcConnection
---@param handle? fun(message: table, emit: fun(message: table))
---@return Neoagent.WorkerLease, table
local function fake_child(remote, handle)
  ---@type {closed_stdin: boolean, terminated: boolean|string, closed: boolean, messages: string[]}
  local state = {
    closed_stdin = false,
    terminated = false,
    closed = false,
    messages = {},
  }
  local function emit(message)
    remote:feed(protocol.encode(message))
  end
  local decoder = protocol.decoder(function(message)
    state.messages[#state.messages + 1] = message.type
    if handle then
      handle(message, emit)
    end
  end)
  ---@type Neoagent.WorkerLease
  local child = {
    write = function(_, bytes)
      decoder:feed(bytes)
      return true
    end,
    close_stdin = function()
      state.closed_stdin = true
      return true
    end,
    terminate = function(_, reason)
      state.terminated = reason or true
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

---@param handle? fun(message: table, emit: fun(message: table))
---@param active_call? Neoagent.ToolOperationCall
---@param opts? table
---@return Neoagent.TestToolRpcConnection, Neoagent.WorkerLease, table, Neoagent.ToolOperationCall
local function opened(handle, active_call, opts)
  local remote = require("tests.helpers.tool_rpc").new(opts)
  local child, state = fake_child(remote, function(message, emit)
    if message.type == "open" then
      emit({ type = "opened", call_id = message.call_id })
    elseif handle then
      handle(message, emit)
    end
  end)
  remote:attach(child)
  remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
  active_call = active_call or call()
  local result = wait(async.run(function()
    remote:open_tool(active_call)
    return true
  end))
  assert.is_true(result)
  return remote, child, state, active_call
end

describe("neoagent RPC connection edge cases", function()
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

  it("reports cancellation enqueue failures without disposing the lease", function()
    for _, raises in ipairs({ false, true }) do
      local remote, child, state, active_call = opened()
      local pending = async.run(function()
        return remote:write_file({ path = "file", content = "value" }, active_call)
      end)
      child.write = function()
        if raises then error("cancellation enqueue failed") end
        return nil, util.error("protocol", "cancellation enqueue failed")
      end
      pending:cancel()
      wait(pending)
      local failure = remote._failure
      remote:abort()
      assert.is_not_nil(failure)
      assert.matches("cancellation enqueue failed", assert(failure).message, 1, true)
      assert.is_false(state.terminated)
      assert.is_false(state.closed)
    end
  end)

  it("reports a cancellation encoding failure without waiting for its deadline", function()
    local remote, _, state, active_call = opened()
    local pending = async.run(function()
      return remote:write_file({ path = "file", content = "value" }, active_call)
    end)
    local original_encode = protocol.encode
    protocol.encode = function() error("cancel encoding failed") end
    pending:cancel()
    protocol.encode = original_encode
    wait(pending)
    assert.are.equal("failed", remote._state)
    assert.matches("cancel encoding failed", assert(remote._failure).message, 1, true)
    assert.is_false(state.closed)
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
    local remote = require("tests.helpers.tool_rpc").new()
    local child, state = fake_child(remote)
    remote:attach(child)
    protocol.MAX_QUEUED_BYTES = 1
    remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    protocol.MAX_QUEUED_BYTES = original_limit
    assert.are.equal("failed", remote._state)
    remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    assert.is_false(state.terminated)

    local encoded = protocol.encode({ type = "ready", marker = protocol.MARKER })
    local encoding = require("tests.helpers.tool_rpc").new()
    local encoding_child, encoding_state = fake_child(encoding)
    encoding:attach(encoding_child)
    local original_encode = vim.mpack.encode
    vim.mpack.encode = function() error("cannot measure") end
    encoding:feed(encoded)
    vim.mpack.encode = original_encode
    assert.are.equal("failed", encoding._state)
    assert.is_false(encoding_state.terminated)

    local repeated = require("tests.helpers.tool_rpc").new()
    local repeated_child = fake_child(repeated)
    repeated:attach(repeated_child)
    local ready = protocol.encode({ type = "ready", marker = protocol.MARKER })
    repeated:feed(ready .. ready .. ready)
    assert.are.equal("failed", repeated._state)

    local malformed = require("tests.helpers.tool_rpc").new()
    local malformed_child, malformed_state = fake_child(malformed)
    malformed:attach(malformed_child)
    malformed:feed("\0\0\0\1\255")
    assert.are.equal("failed", malformed._state)
    assert.is_false(malformed_state.terminated)
  end)

  it("contains every detached cancellation race and bounded timeout", function()
    local idle, _, idle_state = opened(function(message, emit)
      if message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    idle:cancel()
    assert.are.equal("open", idle._state)
    assert.is_false(idle_state.closed_stdin)

    local starting = require("tests.helpers.tool_rpc").new()
    local starting_child, starting_state = fake_child(starting)
    starting:attach(starting_child)
    local opening = async.run(function()
      starting:open_tool(call())
      return true
    end)
    opening:cancel()
    assert.is_false(wait(opening).ok)
    assert.are.equal("failed", starting._state)
    assert.is_false(starting_state.terminated)

    local timing, _, timing_state, timing_call = opened()
    local timed = async.run(function()
      return timing:write_file({ path = "file", content = "value" }, timing_call)
    end)
    timed:cancel()
    assert.is_false(wait(timed).ok)
    assert(vim.wait(1500, function()
      return timing._state == "failed"
    end))
    assert.matches("cancellation timed out", assert(timing._failure).message)
    assert.is_false(timing_state.terminated)

    local stale, _, stale_state, stale_call = opened()
    local stale_run = async.run(function()
      return stale:write_file({ path = "file", content = "value" }, stale_call)
    end)
    stale_run:cancel()
    wait(stale_run)
    stale:feed(protocol.encode({
      type = "cancelled",
      call_id = stale._call_id,
      request_id = assert(stale._active).id + 1,
    }))
    assert.are.equal("failed", stale._state)
    assert.is_false(stale_state.terminated)

    local ignored, _, _, ignored_call = opened()
    local ignored_run = async.run(function()
      return ignored:write_file({ path = "file", content = "value" }, ignored_call)
    end)
    ignored_run:cancel()
    wait(ignored_run)
    local request_id = assert(ignored._active).id
    ignored:feed(protocol.encode({
      type = "event",
      call_id = ignored._call_id,
      request_id = request_id,
      sequence = 1,
      name = codec.events.update,
      value = { content = { { type = "text", text = "late" } } },
    }))
    assert.are.equal("cancelling", ignored._state)
    ignored:feed(protocol.encode({
      type = "response",
      call_id = ignored._call_id,
      request_id = request_id,
      value = { content = { { type = "text", text = "late" } } },
    }))
    assert.are.equal("open", ignored._state)

    local invalid, _, invalid_state, invalid_call = opened()
    local invalid_run = async.run(function()
      return invalid:write_file({ path = "file", content = "value" }, invalid_call)
    end)
    invalid_run:cancel()
    wait(invalid_run)
    invalid:feed(protocol.encode({
      type = "cancel",
      call_id = invalid._call_id,
      request_id = assert(invalid._active).id,
    }))
    assert.are.equal("failed", invalid._state)
    assert.is_false(invalid_state.terminated)

    local wrong, _, wrong_state, wrong_call = opened()
    local wrong_run = async.run(function()
      return wrong:write_file({ path = "file", content = "value" }, wrong_call)
    end)
    wrong_run:cancel()
    wait(wrong_run)
    local request_id = assert(wrong._active).id
    wrong:feed(protocol.encode({
      type = "cancelled",
      call_id = wrong._call_id,
      request_id = request_id,
    }))
    wrong:feed(protocol.encode({ type = "closed", call_id = "call-wrong" }))
    assert.are.equal("failed", wrong._state)
    assert.is_false(wrong_state.terminated)

    local stdin_failure, stdin_child, stdin_state, stdin_call = opened(function(message, emit)
      if message.type == "cancel" then
        emit({
          type = "cancelled",
          call_id = message.call_id,
          request_id = message.request_id,
        })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    stdin_child.close_stdin = function()
      return nil, util.error("protocol", "stdin close failed")
    end
    local stdin_run = async.run(function()
      return stdin_failure:write_file({ path = "file", content = "value" }, stdin_call)
    end)
    stdin_run:cancel()
    assert.is_false(wait(stdin_run).ok)
    assert.are.equal("open", stdin_failure._state)
    local close_result = wait(async.run(function()
      return stdin_failure:close()
    end))
    assert.is_false(close_result.ok)
    assert.are.equal("failed", stdin_failure._state)
    assert.matches("stdin close failed", assert(stdin_failure._failure).message)
    assert.is_false(stdin_state.terminated)
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
    assert.are.equal("open", raced._state)
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

  it("discards queued request events after cooperative cancellation", function()
    local remote = require("neoagent.rpc.connection").new()
    local requests = 0
    local child = fake_child(remote, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
      elseif message.type == "request" then
        requests = requests + 1
        if requests == 1 then
          emit({
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = 1,
            name = codec.events.update,
            value = { content = { { type = "text", text = "first" } } },
          })
          emit({
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = 2,
            name = codec.events.update,
            value = { content = { { type = "text", text = "queued" } } },
          })
        else
          emit({
            type = "response",
            call_id = message.call_id,
            request_id = message.request_id,
            value = {
              result = { content = { { type = "text", text = "reused" } } },
            },
          })
        end
      elseif message.type == "cancel" then
        emit({
          type = "cancelled",
          call_id = message.call_id,
          request_id = message.request_id,
        })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    remote:attach(child)
    remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local files = require("neoagent.files.memory").new()
    local active_call = call(files)
    local update_started = false
    ---@async
    local function on_update()
      update_started = true
      async.await(function()
        return function() end
      end)
    end
    active_call.on_update = on_update
    assert.is_true(wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      return true
    end)))
    local proxy = assert(require("neoagent.rpc.registry").proxy(
      require("neoagent.tools.write_file").new(),
      {
        call = active_call,
        invoke = function(method, payload, operation_call)
          return require("neoagent.rpc.registry").invoke(remote, method, payload, operation_call)
        end,
      }
    ))
    local ctx = {
      context = { workspace = active_call.workspace, files = files },
      on_update = active_call.on_update,
    } --[[@as Neoagent.ToolContext<unknown>]]
    local cancelled = async.run(function()
      return proxy.execute({ path = "file", content = "value" }, ctx)
    end)
    assert(vim.wait(1000, function() return update_started end))
    cancelled:cancel()
    local cancelled_result = wait(cancelled)
    assert.is_false(cancelled_result.ok)
    assert.are.equal("cancelled", assert(cancelled_result.error).kind)
    assert.are.equal("open", remote._state)
    assert.are.same({}, remote._queue)
    assert.are.equal(0, remote._queued_bytes)

    local reused = wait(async.run(function()
      return proxy.execute({ path = "file", content = "again" }, ctx)
    end))
    assert.are.equal("reused", assert(reused.content[1]).text)
    assert.is_true(wait(async.run(function()
      return remote:close()
    end)))
  end)

  it("contains failures from private response policy observers", function()
    local remote, _, _, active_call = opened(function(message, emit)
      if message.type == "request" then
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = {
            result = { content = { { type = "text", text = "failed" } }, isError = true },
            policy = { denial_output = "permission denied" },
          },
        })
      end
    end)
    local proxy = assert(require("neoagent.rpc.registry").proxy(
      require("neoagent.tools.write_file").new(),
      {
        call = active_call,
        invoke = function(method, payload, operation_call)
          return require("neoagent.rpc.registry").invoke(remote, method, payload, operation_call, function()
            error("observer failed")
          end)
        end,
      }
    ))
    local ctx = {
      context = { workspace = active_call.workspace },
      on_update = active_call.on_update,
    } --[[@as Neoagent.ToolContext<unknown>]]
    local result = wait(async.run(function()
      return proxy.execute({ path = "file", content = "value" }, ctx)
    end))
    assert.is_false(result.ok)
    assert.are.equal("protocol", assert(result.error).kind)
    assert.matches("observer failed", assert(result.error).message)
    assert.are.equal("failed", remote._state)
  end)

  it("rejects malformed Tool response envelopes and private evidence", function()
    local result = { content = { { type = "text", text = "done" } } }
    for _, value in ipairs({
      {},
      { result = result, extra = true },
      { result = result, policy = false },
      { result = result, policy = {} },
      { result = result, policy = { denial_output = "permission denied", extra = true } },
      { result = result, policy = { denial_output = "" } },
      { result = result, policy = { denial_output = string.rep("x", 8 * 1024 + 1) } },
    }) do
      local remote, _, state, active_call = opened(function(message, emit)
        if message.type == "request" then
          emit({ type = "response", call_id = message.call_id, request_id = message.request_id, value = value })
        end
      end)
      local completed = wait(async.run(function()
        return remote:write_file({ path = "file", content = "value" }, active_call)
      end))
      assert.is_false(completed.ok)
      assert.are.equal("protocol", assert(completed.error).kind)
      assert.are.equal("failed", remote._state)
      assert.is_false(state.closed)
    end
  end)

  it("rejects malformed artifacts, updates, terminal values, and worker errors", function()
    local digest = string.rep("a", 64)
    local scenarios = {
      {
        name = "artifact-order",
        event = function(message)
          return {
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = 1,
            name = codec.events.artifact_chunk,
            value = {
              artifact_id = 1,
              data = "x",
            },
          }
        end,
        kind = "artifact",
      },
      {
        name = "update-validation",
        event = function(message)
          return {
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = 1,
            name = codec.events.update,
            value = {},
          }
        end,
        kind = "protocol",
      },
      {
        name = "update-artifact",
        event = function(message)
          return {
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = 1,
            name = codec.events.update,
            value = {
              content = {
                {
                  type = "image",
                  file_id = digest,
                  bytes = 1,
                  mime_type = "image/png",
                  id = "preview",
                  revision = 1,
                },
              },
            },
          }
        end,
        kind = "artifact",
      },
      {
        name = "result-validation",
        event = function(message)
          return {
            type = "response",
            call_id = message.call_id,
            request_id = message.request_id,
            value = {
              result = {},
            },
          }
        end,
        kind = "protocol",
      },
      {
        name = "result-artifact",
        event = function(message)
          return {
            type = "response",
            call_id = message.call_id,
            request_id = message.request_id,
            value = {
              result = {
                content = { {
                  type = "image",
                  file_id = digest,
                  bytes = 1,
                  mime_type = "image/png",
                } },
              },
            },
          }
        end,
        kind = "artifact",
      },
      {
        name = "cancelled",
        event = function(message)
          return {
            type = "cancelled", call_id = message.call_id,
            request_id = message.request_id,
          }
        end,
        kind = "cancelled",
      },
      {
        name = "coded-error",
        event = function(message)
          return {
            type = "request_error",
            call_id = message.call_id,
            request_id = message.request_id,
            error = { kind = "tool", code = "bounded_code", message = "failed" },
          }
        end,
        kind = "tool",
        code = "bounded_code",
      },
    }
    for _, scenario in ipairs(scenarios) do
      local remote, _, _, active_call = opened(function(message, emit)
        if message.type == "request" then
          emit(scenario.event(message))
        end
      end)
      local result = wait(async.run(function()
        return remote:write_file({ path = "file", content = "value" }, active_call)
      end))
      assert.is_false(result.ok, scenario.name)
      assert.are.equal(scenario.kind, result.error.kind, scenario.name)
      if scenario.code then
        assert.are.equal(scenario.code, rawget(result.error, "code"))
      end
    end

    local cancelled_files = require("neoagent.files.memory").new()
    cancelled_files.put = function()
      error(async.cancelled_error, 0)
    end
    local cancelled_call = call(cancelled_files)
    local cancelled_remote, _, _, active_call = opened(function(message, emit)
      if message.type == "request" then
        emit({
          type = "event",
          call_id = message.call_id,
          request_id = message.request_id,
          sequence = 1,
          name = codec.events.artifact_begin,
          value = {
            artifact_id = 1,
            file_id = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881",
            bytes = 1,
          },
        })
        emit({
          type = "event",
          call_id = message.call_id,
          request_id = message.request_id,
          sequence = 2,
          name = codec.events.artifact_chunk,
          value = {
            artifact_id = 1,
            data = "x",
          },
        })
        emit({
          type = "event",
          call_id = message.call_id,
          request_id = message.request_id,
          sequence = 3,
          name = codec.events.artifact_end,
          value = {
            artifact_id = 1,
          },
        })
      end
    end, cancelled_call)
    local cancelled_result = wait(async.run(function()
      return cancelled_remote:write_file({ path = "file", content = "value" }, active_call)
    end))
    assert.is_false(cancelled_result.ok)
    assert.are.equal("cancelled", cancelled_result.error.kind)
  end)

  it("accepts sustained ordered progress before a terminal result", function()
    local updates = 0
    local active_call = call()
    active_call.on_update = function()
      updates = updates + 1
    end
    local remote, _, _, selected_call = opened(function(message, emit)
      if message.type == "request" then
        for sequence = 1, 300 do
          emit({
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = sequence,
            name = codec.events.update,
            value = { content = { { type = "text", text = "working" } } },
          })
        end
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = {
            result = { content = { { type = "text", text = "done" } } },
          },
        })
      end
    end, active_call)

    local result = wait(async.run(function()
      return remote:write_file({ path = "file", content = "value" }, selected_call)
    end))
    assert.are.equal("done", result.content[1].text)
    assert.are.equal(300, updates)
  end)

  it("delivers connection events after a request settles and before owner shutdown", function()
    local events = {}
    local remote, _, _, active_call = opened(function(message, emit)
      if message.type == "request" then
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = {
            result = { content = { { type = "text", text = "started" } } },
          },
        })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end, nil, {
      on_event = function(message)
        events[#events + 1] = message
      end,
    })
    local result = wait(async.run(function()
      return remote:write_file({ path = "file", content = "value" }, active_call)
    end))
    assert.are.equal("started", assert(result.content[1]).text)
    assert.are.equal("open", remote._state)
    remote:feed(protocol.encode({
      type = "event",
      call_id = remote._call_id,
      sequence = 1,
      name = "process_output",
      value = { data = "after start" },
    }))
    assert.are.equal("after start", events[1].value.data)
    assert.are.equal("open", remote._state)
    assert.is_true(wait(async.run(function()
      return remote:close()
    end)))
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
      local remote = opened(nil, nil, {
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
          name = codec.events.update,
          value = { content = { { type = "text", text = "working" } } },
        })
      end
    end)
    local result = wait(async.run(function()
      return remote:request(codec.methods.write_file, {
        path = "file", content = "value",
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
    local request = remote:start_request(codec.methods.write_file, {
      path = "file", content = "value",
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
    local removed_request = removed:start_request(codec.methods.write_file, {
      path = "file", content = "value",
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
    local rejected = opened(nil, nil, {
      on_failure = function(err) failures[#failures + 1] = err end,
    })
    local rejected_request = rejected:start_request(codec.methods.write_file, {
      path = "file", content = "value",
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

    local idle = require("tests.helpers.tool_rpc").new()
    local idle_wait = wait(async.run(function()
      return idle:wait_cancelled()
    end))
    assert.is_false(idle_wait.ok)
    assert.matches("no cancelling request", idle_wait.error.message)

    local started, start_err = pcall(
      idle.start_request, idle, codec.methods.write_file,
      { path = "file", content = "value" }
    )
    assert.is_false(started)
    assert.matches("not ready", util.normalize_error(start_err).message)
    idle:abort()
    started, start_err = pcall(
      idle.start_request, idle, codec.methods.write_file,
      { path = "file", content = "value" }
    )
    assert.is_false(started)
    assert.matches("aborted", util.normalize_error(start_err).message)
  end)

  it("reports a late worker error during orderly connection close", function()
    ---@type Neoagent.TestToolRpcConnection?
    local remote
    remote = opened(function(message, emit)
      if message.type == "request" then
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = {
            result = { content = { { type = "text", text = "complete" } } },
          },
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
      return active:request(codec.methods.write_file, {
        path = "file", content = "value",
      })
    end))
    assert.are.equal("complete", assert(result.result.content[1]).text)
    local closed = wait(async.run(function()
      return active:close()
    end))
    assert.is_false(closed.ok)
    assert.are.equal("sandbox_unavailable", closed.error.kind)
    assert.matches("guardian failed", closed.error.message)
  end)

  it("rejects a worker that exceeds the aggregate update contract", function()
    local original_count = limits.MAX_UPDATE_COUNT
    limits.MAX_UPDATE_COUNT = 1
    local remote, _, state, active_call = opened(function(message, emit)
      if message.type == "request" then
        for sequence = 1, 2 do
          emit({
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = sequence,
            name = codec.events.update,
            value = { content = { { type = "text", text = "working" } } },
          })
        end
      end
    end)
    local result = wait(async.run(function()
      return remote:write_file({ path = "file", content = "value" }, active_call)
    end))
    limits.MAX_UPDATE_COUNT = original_count
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)
    assert.matches("update", result.error.message)
    assert.is_false(state.terminated)

    local encoding, _, encoding_state, encoding_call = opened()
    local encoding_run = async.run(function()
      return encoding:write_file({ path = "file", content = "value" }, encoding_call)
    end)
    local frame = protocol.encode({
      type = "event",
      call_id = encoding._call_id,
      request_id = assert(encoding._active).id,
      sequence = 1,
      name = codec.events.update,
      value = { content = { { type = "text", text = "working" } } },
    })
    local original_encode = vim.mpack.encode
    vim.mpack.encode = function(value)
      if type(value) == "table" and value.type then
        return original_encode(value)
      end
      error("cannot measure update")
    end
    encoding:feed(frame)
    local settled = vim.wait(3000, function()
      return encoding_run:is_done()
    end)
    vim.mpack.encode = original_encode
    assert(settled, "RPC update encoding failure did not settle")
    local encoding_result = wait(encoding_run)
    assert.is_false(encoding_result.ok)
    assert.is_false(encoding_state.terminated)
  end)

  it("rejects an outbound request above the aggregate byte limit", function()
    local original_limit = protocol.MAX_REQUEST
    protocol.MAX_REQUEST = protocol.MAX_FRAME
    local remote, _, state, active_call = opened()
    local result = wait(async.run(function()
      return remote:write_file({
        path = "large.txt",
        content = string.rep("x", protocol.MAX_FRAME * 2),
      }, active_call)
    end))
    protocol.MAX_REQUEST = original_limit
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)
    assert.matches("aggregate protocol limit", result.error.message)
    assert.is_false(state.terminated)
  end)

  it("contains send, open, close, lease, and decoder failures", function()
    local unattached = require("tests.helpers.tool_rpc").new()
    local unattached_open = wait(async.run(function()
      unattached:open_tool(call())
      return true
    end))
    assert.is_false(unattached_open.ok)
    assert.matches("cannot be opened", unattached_open.error.message)
    local unattached_request = wait(async.run(function()
      return unattached:write_file({ path = "file", content = "value" }, call())
    end))
    assert.is_false(unattached_request.ok)
    assert.matches("not ready for a request", unattached_request.error.message)

    local encoding = require("tests.helpers.tool_rpc").new()
    local encoding_child, encoding_state = fake_child(encoding)
    encoding:attach(encoding_child)
    encoding:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local original_encode = protocol.encode
    protocol.encode = function() error("wire encoding failed") end
    local encoding_result = wait(async.run(function()
      encoding:open_tool(call())
      return true
    end))
    protocol.encode = original_encode
    assert.is_false(encoding_result.ok)
    assert.is_false(encoding_state.terminated)

    local request_encoding, _, request_encoding_state = opened()
    local original_mpack_encode = vim.mpack.encode
    vim.mpack.encode = function(value)
      if type(value) == "table" and value.type == "request" then
        return string.rep("x", protocol.MAX_FRAME + 1)
      end
      error("payload encoding failed")
    end
    local request_encoding_run = async.run(function()
      return request_encoding:request(codec.methods.write_file, {
        path = "file",
        content = "value",
      })
    end)
    local request_encoding_result = wait(request_encoding_run)
    vim.mpack.encode = original_mpack_encode
    assert.is_false(request_encoding_result.ok)
    assert.matches("could not be encoded", request_encoding_result.error.message)
    assert.is_false(request_encoding_state.terminated)

    local writing = require("tests.helpers.tool_rpc").new()
    local writing_child, writing_state = fake_child(writing)
    writing_child.write = function()
      return nil, util.error("protocol", "write failed")
    end
    writing:attach(writing_child)
    writing:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local writing_result = wait(async.run(function()
      writing:open_tool(call())
      return true
    end))
    assert.is_false(writing_result.ok)
    assert.is_false(writing_state.terminated)

    local wrong_open = require("tests.helpers.tool_rpc").new()
    local wrong_open_child = fake_child(wrong_open, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = "call-wrong" })
      end
    end)
    wrong_open:attach(wrong_open_child)
    wrong_open:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    assert.is_false(wait(async.run(function()
      wrong_open:open_tool(call())
      return true
    end)).ok)

    local remote, child, state, active_call = opened(function(message, emit)
      if message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    local repeated_open = wait(async.run(function()
      remote:open_tool(active_call)
      return true
    end))
    assert.is_false(repeated_open.ok)
    assert.matches("cannot be opened", repeated_open.error.message)
    assert.is_true(wait(async.run(function() return remote:close() end)))
    assert.is_true(wait(async.run(function() return remote:close() end)))
    assert.is_false(state.closed)

    local active, _, _, active_context = opened()
    local pending = async.run(function()
      return active:write_file({ path = "file", content = "value" }, active_context)
    end)
    local active_close = wait(async.run(function()
      return active:close()
    end))
    assert.is_false(active_close.ok)
    assert.matches("cannot close with an active request", active_close.error.message)
    active:abort()
    assert.is_false(wait(pending).ok)
    local requested = pcall(active.write_file, active,
      { path = "file", content = "value" }, active_context)
    assert.is_false(requested)
    local closed = pcall(active.close, active)
    assert.is_false(closed)

    local close_cases = {
      {
        name = "stdin",
        fails = true,
        change = function(close_child)
          close_child.close_stdin = function()
            return nil, util.error("protocol", "stdin failed")
          end
        end,
      },
      {
        name = "lease-wait",
        change = function(close_child)
          close_child.wait = function()
            error("RPC connection must not wait for its WorkerLease")
          end
        end,
      },
      {
        name = "truncated",
        fails = true,
        after_closed = function(close_remote)
          close_remote:feed("\0")
        end,
      },
    }
    for _, case in ipairs(close_cases) do
      local close_remote = require("tests.helpers.tool_rpc").new()
      local close_child = fake_child(close_remote, function(message, emit)
        if message.type == "open" then
          emit({ type = "opened", call_id = message.call_id })
        elseif message.type == "close" then
          emit({ type = "closed", call_id = message.call_id })
          if case.after_closed then case.after_closed(close_remote) end
        end
      end)
      if case.change then case.change(close_child) end
      close_remote:attach(close_child)
      close_remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
      local result = wait(async.run(function()
        close_remote:open_tool(call())
        return close_remote:close()
      end))
      if case.fails then
        assert.is_false(result.ok, case.name)
      else
        assert.is_true(result, case.name)
      end
    end

    local wrong_close = opened(function(message, emit)
      if message.type == "close" then
        emit({ type = "closed", call_id = "call-wrong" })
      end
    end)
    assert.is_false(wait(async.run(function()
      return wrong_close:close()
    end)).ok)

    child:dispose("test complete")
  end)

  it("rejects failures racing each startup acknowledgement", function()
    local ready_race = require("tests.helpers.tool_rpc").new()
    local ready_child = fake_child(ready_race)
    ready_race:attach(ready_child)
    local opening = async.run(function()
      ready_race:open_tool(call())
      return true
    end)
    local ready = protocol.encode({ type = "ready", marker = protocol.MARKER })
    ready_race:feed(ready .. ready)
    assert.is_false(wait(opening).ok)

    local opened_race = require("tests.helpers.tool_rpc").new()
    local opened_child = fake_child(opened_race, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
        emit({ type = "opened", call_id = message.call_id })
      end
    end)
    opened_race:attach(opened_child)
    opened_race:feed(ready)
    local opened_result = wait(async.run(function()
      opened_race:open_tool(call())
      return true
    end))
    assert.is_false(opened_result.ok)
  end)

  it("classifies child exits in startup, cancellation, and open states", function()
    local starting = require("tests.helpers.tool_rpc").new()
    local starting_child, starting_state = fake_child(starting)
    starting:attach(starting_child)
    local opening = async.run(function()
      starting:open_tool(call())
      return true
    end)
    starting:eof({
      code = 125, signal = 0, stderr = "",
      error = util.error("sandbox_unavailable", "startup relay failed"),
    })
    local starting_result = wait(opening)
    assert.is_false(starting_result.ok)
    assert.are.equal("sandbox_unavailable", starting_result.error.kind)
    assert.is_false(starting_state.closed)
    starting:eof({ code = 0, signal = 0, stderr = "" })

    local cancelling, _, cancelling_state, cancelling_call = opened()
    local pending = async.run(function()
      return cancelling:write_file({ path = "file", content = "value" }, cancelling_call)
    end)
    pending:cancel()
    wait(pending)
    cancelling:eof({
      code = 125, signal = 0, stderr = "",
      error = util.error("sandbox_unavailable", "cancel relay failed"),
    })
    assert.are.equal("cancelled", assert(cancelling._failure).kind)
    assert.is_false(cancelling_state.closed)

    local opened_remote, _, opened_state = opened()
    opened_remote:eof({
      code = 125, signal = 0, stderr = "",
      error = util.error("sandbox_unavailable", "late relay failed"),
    })
    assert.are.equal("protocol", assert(opened_remote._failure).kind)
    assert.is_false(opened_state.closed)
  end)

  it("preserves the first failure when callbacks race worker termination", function()
    ---@type Neoagent.TestToolRpcConnection?
    local remote
    local active_call = call()
    active_call.on_update = function()
      local selected = remote or error("remote not initialized")
      selected:eof({ code = 9, signal = 0, stderr = "worker failed" })
      error("consumer failed")
    end
    remote = opened(function(message, emit)
      if message.type == "request" then
        emit({
          type = "event",
          call_id = message.call_id,
          request_id = message.request_id,
          sequence = 1,
          name = codec.events.update,
          value = { content = { { type = "text", text = "value" } } },
        })
      end
    end, active_call)
    local active_remote = remote or error("remote not opened")
    local result = wait(async.run(function()
      return active_remote:write_file({ path = "file", content = "value" }, active_call)
    end))
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)

    ---@type Neoagent.TestToolRpcConnection?
    local failed_during_update
    local update_call = call()
    update_call.on_update = function()
      local selected = failed_during_update or error("remote not initialized")
      selected:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    end
    failed_during_update = opened(function(message, emit)
      if message.type == "request" then
        emit({
          type = "event",
          call_id = message.call_id,
          request_id = message.request_id,
          sequence = 1,
          name = codec.events.update,
          value = { content = { { type = "text", text = "value" } } },
        })
      end
    end, update_call)
    local update_remote = failed_during_update or error("remote not opened")
    local update_result = wait(async.run(function()
      return update_remote:write_file({ path = "file", content = "value" }, update_call)
    end))
    assert.is_false(update_result.ok)
    assert.are.equal("protocol", update_result.error.kind)
  end)
end)
