local assert = require("luassert")
local async = require("neoagent.async")
local protocol = require("neoagent.rpc.protocol")
local util = require("neoagent.util")
local peer = require("tests.helpers.rpc")
local wait = peer.wait
local fake_child = peer.transport
local codec = require("neoagent.rpc.codec")
local limits = require("neoagent.rpc.tool_limits")
local tool_client = require("neoagent.rpc.tool_client")

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

---@param handle? fun(message: table, emit: fun(message: table))
---@param active_call? Neoagent.ToolOperationCall
---@param opts? Neoagent.RpcConnectionOptions
---@return Neoagent.RpcConnection, Neoagent.WorkerLease, table, Neoagent.ToolOperationCall
local function opened(handle, active_call, opts)
  local connection, transport, state = peer.open(handle, opts)
  return connection, transport, state, active_call or call()
end

describe("Tool RPC client edge cases", function()
  for _, trailing in ipairs({ "duplicate acknowledgement", "truncated frame" }) do
    it("reports " .. trailing .. " arriving after close has returned", function()
      local failures = {}
      local call_id
      local remote = opened(function(message, emit)
        if message.type == "request" then
          emit({ type = "response", call_id = message.call_id, request_id = message.request_id,
            value = { content = { { type = "text", text = "completed" } } } })
        elseif message.type == "close" then
          call_id = message.call_id
          emit({ type = "closed", call_id = call_id })
        end
      end, nil, { on_failure = function(err) failures[#failures + 1] = err end })
      local completed = wait(async.run(function()
        local result = tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, call())
        remote:close()
        return result
      end))
      assert.are.equal("completed", completed.content[1].text)
      remote:feed("")
      assert.are.equal(0, #failures)
      remote:feed(trailing == "truncated frame" and "\0" or protocol.encode({ type = "closed", call_id = call_id }))
      remote:feed("ignored after failure")
      remote:eof({ code = 0, signal = 0, stderr = "" })
      assert.are.equal(1, #failures, "late trailing traffic was silently discarded")
      assert.are.equal("protocol", failures[1].kind)
      local closed = pcall(remote.close, remote)
      assert.is_false(closed, "the owner could not observe failed shutdown")
      assert.are.equal("completed", completed.content[1].text)
    end)
  end

  it("discards queued progress when the channel fails before a terminal response", function()
    local updates = {}
    local active_call = call()
    active_call.on_update = function(value)
      updates[#updates + 1] = value
    end
    ---@type Neoagent.RpcConnection?
    local remote
    remote = opened(function(message, emit)
      if message.type ~= "request" then
        return
      end
      emit({
        type = "event",
        call_id = message.call_id,
        request_id = message.request_id,
        sequence = 1,
        name = codec.events.update,
        value = { content = { { type = "text", text = "queued progress" } } },
      })
      assert(remote):feed("\0\0\0\0")
    end, active_call)
    local result = wait(async.run(function()
      return tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_call)
    end))
    assert.is_false(result.ok)
    assert.are.equal("protocol", assert(result.error).kind)
    assert.are.same({}, updates)
    assert.are.equal("failed", remote._state)
  end)

  for _, failure in ipairs({ "malformed frame", "late event", "duplicate response" }) do
    it("preserves a received Tool result before a " .. failure, function()
      local failures = {}
      ---@type Neoagent.RpcConnection?
      local remote
      remote = opened(
        function(message, emit)
          if message.type ~= "request" then
            return
          end
          local response = {
            type = "response",
            call_id = message.call_id,
            request_id = message.request_id,
            value = { content = { { type = "text", text = "write completed" } } },
          }
          emit(response)
          if failure == "malformed frame" then
            assert(remote):feed("\0\0\0\0")
          elseif failure == "late event" then
            emit({
              type = "event",
              call_id = message.call_id,
              request_id = message.request_id,
              sequence = 1,
              name = codec.events.update,
              value = { content = { { type = "text", text = "too late" } } },
            })
          else
            emit(response)
          end
        end,
        nil,
        {
          on_failure = function(err)
            failures[#failures + 1] = err
          end,
        }
      )
      local value = wait(async.run(function()
        return tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, call())
      end))
      assert.is_not.equal(false, value.ok)
      assert.are.equal("write completed", value.content[1].text)
      assert.are.equal("failed", remote._state)
      assert.are.equal(1, #failures)
      assert.is_false(pcall(remote.start_request, remote, "write_file", {}))
    end)
  end

  for _, invalid in ipairs({ "result", "artifact", "update" }) do
    it("validates a queued " .. invalid .. " when the connection fails after its response", function()
      ---@type Neoagent.RpcConnection?
      local remote
      remote = opened(function(message, emit)
        if message.type ~= "request" then
          return
        end
        if invalid == "update" then
          emit({
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = 1,
            name = codec.events.update,
            value = {},
          })
        end
        local result = invalid == "result" and {}
          or {
            content = {
              invalid == "artifact" and {
                type = "image",
                file_id = string.rep("a", 64),
                bytes = 1,
                mime_type = "image/png",
              } or { type = "text", text = "done" },
            },
          }
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = result,
        })
        assert(remote):feed("\0\0\0\0")
      end)
      local value = wait(async.run(function()
        return tool_client.invoke(remote, "read_file", {
          path = "file",
          resolved_path = "/workspace/file",
          offset = 1,
          max_image_input_bytes = 1024,
          max_image_pixels = 1024,
          max_image_output_bytes = 1024,
        }, call())
      end))
      assert.is_false(value.ok)
      assert.are.equal(invalid == "artifact" and "artifact" or "protocol", assert(value.error).kind)
      assert.are.equal("failed", remote._state)
    end)
  end

  it("reports cancellation enqueue failures without disposing the lease", function()
    for _, raises in ipairs({ false, true }) do
      local remote, child, state, active_call = opened()
      local pending = async.run(function()
        return tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_call)
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
      return tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_call)
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

  it("contains every detached cancellation race and bounded timeout", function()
    local idle, _, idle_state = opened(function(message, emit)
      if message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    idle:cancel()
    assert.are.equal("open", idle._state)
    assert.is_false(idle_state.closed_stdin)

    local starting = require("neoagent.rpc.connection").new()
    local starting_child, starting_state = fake_child(starting)
    starting:attach(starting_child)
    local opening = async.run(function()
      starting:open(codec.encode_context(call()))
      return true
    end)
    opening:cancel()
    assert.is_false(wait(opening).ok)
    assert.are.equal("failed", starting._state)
    assert.is_false(starting_state.terminated)

    local timing, _, timing_state, timing_call = opened()
    local timed = async.run(function()
      return tool_client.invoke(timing, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, timing_call)
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
      return tool_client.invoke(stale, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, stale_call)
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
      return tool_client.invoke(ignored, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, ignored_call)
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
      return tool_client.invoke(invalid, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, invalid_call)
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
      return tool_client.invoke(wrong, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, wrong_call)
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
      return tool_client.invoke(stdin_failure, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, stdin_call)
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
            value = { content = { { type = "text", text = "reused" } } },
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
          return require("neoagent.rpc.tool_client").invoke(remote, method, payload, operation_call)
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
          type = "event",
          name = codec.events.policy,
          call_id = message.call_id,
          request_id = message.request_id,
          sequence = 1,
          value = { denial_output = "permission denied" },
        })
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = { content = { { type = "text", text = "failed" } }, isError = true },
        })
      end
    end)
    local proxy = assert(require("neoagent.rpc.registry").proxy(
      require("neoagent.tools.write_file").new(),
      {
        call = active_call,
        invoke = function(method, payload, operation_call)
          return require("neoagent.rpc.tool_client").invoke(remote, method, payload, operation_call, function()
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

  it("rejects malformed Tool responses and malformed or duplicate private evidence", function()
    local result = { content = { { type = "text", text = "done" } } }
    for _, scenario in ipairs({
      { response = {} },
      { response = { content = result.content, extra = true } },
      { response = { content = result.content, execution = { sandbox = { cleanup_failed = false } } } },
      { evidence = {} },
      { evidence = { process_exit = false } },
      { evidence = { process_exit = { code = 159 } } },
      { evidence = { process_exit = { code = 159, signal = 31, extra = true } } },
      { evidence = { process_exit = { code = -1, signal = 0 } } },
      { evidence = { process_exit = { code = 4294967296, signal = 0 } } },
      { evidence = { process_exit = { code = 1, signal = 128 } } },
      { evidence = { process_exit = { code = 1, signal = 1.5 } } },
      { evidence = { denial_output = "permission denied", extra = true } },
      { evidence = { denial_output = "" } },
      { evidence = { denial_output = string.rep("x", 8 * 1024 + 1) } },
      { evidence = { denial_output = "permission denied" }, duplicate = true },
    }) do
      local remote, _, state, active_call = opened(function(message, emit)
        if message.type == "request" then
          if scenario.evidence then
            for sequence = 1, scenario.duplicate and 2 or 1 do
              emit({
                type = "event",
                call_id = message.call_id,
                request_id = message.request_id,
                sequence = sequence,
                name = codec.events.policy,
                value = scenario.evidence,
              })
            end
          end
          emit({ type = "response", call_id = message.call_id, request_id = message.request_id, value = scenario.response or result,
          })
        end
      end)
      local completed = wait(async.run(function()
        return tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_call)
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
        name = "update-execution-authority",
        event = function(message)
          return {
            type = "event", call_id = message.call_id, request_id = message.request_id,
            sequence = 1, name = codec.events.update,
            value = { content = {}, execution = { sandbox = { cleanup_failed = false } } },
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
            value = {},
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
              content = { {
                type = "image",
                file_id = digest,
                bytes = 1,
                mime_type = "image/png",
              },
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
        return tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_call)
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
      return tool_client.invoke(cancelled_remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_call)
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
          value = { content = { { type = "text", text = "done" } } },
        })
      end
    end, active_call)

    local result = wait(async.run(function()
      return tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, selected_call)
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
          value = { content = { { type = "text", text = "started" } } },
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
      return tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_call)
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
      return tool_client.invoke(remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_call)
    end))
    limits.MAX_UPDATE_COUNT = original_count
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)
    assert.matches("update", result.error.message)
    assert.is_false(state.terminated)

    local encoding, _, encoding_state, encoding_call = opened()
    local encoding_run = async.run(function()
      return tool_client.invoke(encoding, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, encoding_call)
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
      return tool_client.invoke(remote, "write_file", {
        path = "large.txt", resolved_path = "/workspace/large.txt",
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
    local unattached = require("neoagent.rpc.connection").new()
    local unattached_open = wait(async.run(function()
      unattached:open(codec.encode_context(call()))
      return true
    end))
    assert.is_false(unattached_open.ok)
    assert.matches("cannot be opened", unattached_open.error.message)
    local unattached_request = wait(async.run(function()
      return tool_client.invoke(unattached, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, call())
    end))
    assert.is_false(unattached_request.ok)
    assert.matches("not ready for a request", unattached_request.error.message)

    local encoding = require("neoagent.rpc.connection").new()
    local encoding_child, encoding_state = fake_child(encoding)
    encoding:attach(encoding_child)
    encoding:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local original_encode = protocol.encode
    protocol.encode = function() error("wire encoding failed") end
    local encoding_result = wait(async.run(function()
      encoding:open(codec.encode_context(call()))
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
      return request_encoding:request("write_file", {
        path = "file", resolved_path = "/workspace/file",
        content = "value",
      })
    end)
    local request_encoding_result = wait(request_encoding_run)
    vim.mpack.encode = original_mpack_encode
    assert.is_false(request_encoding_result.ok)
    assert.matches("could not be encoded", request_encoding_result.error.message)
    assert.is_false(request_encoding_state.terminated)

    local writing = require("neoagent.rpc.connection").new()
    local writing_child, writing_state = fake_child(writing)
    writing_child.write = function()
      return nil, util.error("protocol", "write failed")
    end
    writing:attach(writing_child)
    writing:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local writing_result = wait(async.run(function()
      writing:open(codec.encode_context(call()))
      return true
    end))
    assert.is_false(writing_result.ok)
    assert.is_false(writing_state.terminated)

    local wrong_open = require("neoagent.rpc.connection").new()
    local wrong_open_child = fake_child(wrong_open, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = "call-wrong" })
      end
    end)
    wrong_open:attach(wrong_open_child)
    wrong_open:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    assert.is_false(wait(async.run(function()
      wrong_open:open(codec.encode_context(call()))
      return true
    end)).ok)

    local remote, child, state, active_call = opened(function(message, emit)
      if message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    local repeated_open = wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      return true
    end))
    assert.is_false(repeated_open.ok)
    assert.matches("cannot be opened", repeated_open.error.message)
    assert.is_true(wait(async.run(function() return remote:close() end)))
    assert.is_true(wait(async.run(function() return remote:close() end)))
    assert.is_false(state.closed)

    local active, _, _, active_context = opened()
    local pending = async.run(function()
      return tool_client.invoke(active, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_context)
    end)
    local active_close = wait(async.run(function()
      return active:close()
    end))
    assert.is_false(active_close.ok)
    assert.matches("cannot close with an active request", active_close.error.message)
    active:abort()
    assert.is_false(wait(pending).ok)
    local requested = pcall(tool_client.invoke, active, "write_file",
      { path = "file", resolved_path = "/workspace/file", content = "value" }, active_context)
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
      local close_remote = require("neoagent.rpc.connection").new()
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
        close_remote:open(codec.encode_context(call()))
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

  it("classifies child exits in startup, cancellation, and open states", function()
    local starting = require("neoagent.rpc.connection").new()
    local starting_child, starting_state = fake_child(starting)
    starting:attach(starting_child)
    local opening = async.run(function()
      starting:open(codec.encode_context(call()))
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
      return tool_client.invoke(cancelling, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, cancelling_call)
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
    ---@type Neoagent.RpcConnection?
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
      return tool_client.invoke(active_remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, active_call)
    end))
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)

    ---@type Neoagent.RpcConnection?
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
      return tool_client.invoke(update_remote, "write_file", { path = "file", resolved_path = "/workspace/file", content = "value" }, update_call)
    end))
    assert.is_false(update_result.ok)
    assert.are.equal("protocol", update_result.error.kind)
  end)
end)
