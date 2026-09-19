local assert = require("luassert")
local async = require("neoagent.async")
local codec = require("neoagent.rpc.codec")
local protocol = require("neoagent.rpc.protocol")

---@param options table
---@return Neoagent.RpcServer
local function server(options)
  local factory = options.local_api
  local selected_options = vim.tbl_extend("force", {}, options)
  selected_options.local_api = nil
  local selected = selected_options --[[@as Neoagent.RpcServerOptions]]
  if not factory then
    return require("neoagent.rpc.server").new(selected)
  end
  return require("neoagent.rpc.server")._new(
    selected,
    function(name, payload, active_call, dependencies)
      local implementation = factory({
        artifact_publisher = dependencies.artifact_publisher,
      })
      return implementation[name](implementation, codec.decode_request(name, payload), active_call)
    end
  )
end

---@return Neoagent.ToolOperationCall
local function call()
  local files = require("neoagent.files.memory").new()
  return {
    workspace = { root = "/workspace", cwd = "/workspace" },
    artifacts = { put = files.put },
    on_update = function() end,
  }
end

---@generic T
---@param run Neoagent.Run<T, unknown>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function()
    return run:is_done()
  end), "async protocol test did not settle")
  local result = assert(run:result())
  return result
end

---@param remote Neoagent.TestToolRpcConnection
---@param handle fun(message: table, emit: fun(message: table))
---@return Neoagent.WorkerLease, table
local function fake_child(remote, handle)
  local state = {
    closed_stdin = false,
    terminated = false,
    closed = false,
  }
  local function emit(message)
    remote:feed(protocol.encode(message))
  end
  local decoder = protocol.decoder(function(message)
    handle(message, emit)
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
    terminate = function()
      state.terminated = true
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

describe("neoagent Tool RPC protocol", function()
  it("preserves omitted and explicit zero grep context", function()
    local codec = require("neoagent.rpc.codec")
    ---@type Neoagent.GrepRequest
    local request = {
      pattern = "needle",
      ignore_case = false,
      literal = false,
      limit = 10,
    }
    local omitted = codec.decode_request("grep", codec.encode_request("grep", request))
    assert.is_nil(omitted.context)
    request.context = 0
    local explicit = codec.decode_request("grep", codec.encode_request("grep", request))
    assert.are.equal(0, explicit.context)
  end)

  it("validates exact messages and copied call context", function()
    local source = call()
    local wire = codec.encode_context(source)
    local decoded = codec.decode_context(wire)
    source.workspace.cwd = "/changed"
    assert.are.equal("/workspace", decoded.workspace.cwd)

    local value = protocol.validate({
      type = "request",
      call_id = "call-1",
      request_id = 1,
      method = "write_file",
      payload = { path = "a", content = "b" },
    })
    assert.are.equal("write_file", value.method)
    local response = protocol.validate({
      type = "response",
      call_id = "call-1",
      request_id = 1,
      value = {
        result = { content = { { type = "text", text = "denied" } }, isError = true },
        policy = { denial_output = "permission denied" },
      },
    })
    local result, private_policy = codec.decode_result(response.value)
    assert.is_true(result.isError)
    assert.are.equal("permission denied", assert(private_policy).denial_output)
    assert.are.same({
      kind = "tool",
      code = "process_start",
      message = "Failed to start process",
      detail = "EPERM: operation not permitted",
    }, protocol.error({
      kind = "tool",
      code = "process_start",
      message = "Failed to start process",
      detail = "EPERM: operation not permitted",
    }))

    for _, invalid in ipairs({
      { type = "request", call_id = "call-1", request_id = 1, method = "not valid", payload = {} },
      { type = "opened", call_id = "call-1", extra = true },
      {
        type = "event",
        call_id = "call-1",
        request_id = 0,
        sequence = 1,
        name = "progress",
        value = {},
      },
      {
        type = "event",
        call_id = "call-1",
        request_id = 1,
        sequence = 1,
        name = "",
        value = {},
      },
    }) do
      local ok = pcall(protocol.validate, invalid)
      assert.is_false(ok)
    end
  end)

  it("rejects malformed protocol fields at every wire boundary", function()
    local invalid_messages = {
      { value = nil, message = "invalid RPC message" },
      { value = { type = "opened" }, message = "missing call_id" },
      { value = { type = "ready", marker = string.rep("x", 257) }, message = "bounded UTF%-8" },
      { value = { type = "opened", call_id = "bad call" }, message = "call ID is invalid" },
      {
        value = { type = "request", call_id = "call-1", request_id = 1, method = "write_file", payload = {} },
        mutate = function(value)
          value.payload = { "not", "an", "object" }
        end,
        message = "payload must be an object",
      },
      {
        value = { type = "request_chunk", call_id = "call-1", request_id = 1, data = "" },
        message = "request chunk is invalid",
      },
      {
        value = {
          type = "request_begin",
          call_id = "call-1",
          request_id = 1,
          method = "write_file",
          bytes = protocol.MAX_REQUEST + 1,
        },
        message = "request exceeds the byte limit",
      },
      {
        value = {
          type = "event",
          call_id = "call-1",
          request_id = 1,
          sequence = 1,
          name = "progress",
          value = { "not", "an", "object" },
        },
        message = "event value must be an object",
      },
      {
        value = { type = "response", call_id = "call-1", request_id = 1, value = { "not", "an", "object" } },
        message = "response value must be an object",
      },
      {
        value = {
          type = "response",
          call_id = "call-1",
          request_id = 1,
          value = {},
          policy = { denial_output = "", extra = true },
        },
        message = "response has an unknown field",
      },
    }
    for _, case in ipairs(invalid_messages) do
      if case.mutate then
        case.mutate(case.value)
      end
      local ok, err = pcall(protocol.validate, case.value)
      assert.is_false(ok)
      assert.matches(case.message, tostring(err))
    end

    for _, case in ipairs({
      { value = { "not", "an", "object" }, message = "error must be an object" },
      { value = { kind = "not valid", message = "bad" }, message = "error kind is invalid" },
    }) do
      local ok, err = pcall(protocol.error, case.value)
      assert.is_false(ok)
      assert.matches(case.message, tostring(err))
    end

    for _, case in ipairs({
      { value = { "not", "an", "object" }, message = "context must be an object" },
      { value = { workspace = { "bad" } }, message = "workspace must be an object" },
      {
        value = { workspace = { root = "/workspace", cwd = "/workspace" }, model = {} },
        message = "context has an unknown field",
      },
      {
        value = { workspace = { root = "/workspace" } },
        message = "workspace is missing cwd",
      },
    }) do
      local ok, err = pcall(codec.decode_context, case.value)
      assert.is_false(ok)
      assert.matches(case.message, tostring(err))
    end
  end)

  it("rejects marker mismatch and terminates the channel", function()
    local remote = require("tests.helpers.tool_rpc").new()
    local child, state = fake_child(remote, function() end)
    remote:attach(child)
    remote:feed(protocol.encode({ type = "ready", marker = "wrong-source" }))
    local value = wait(async.run(function()
      remote:open_tool(call())
      return true
    end))
    assert.is_false(value.ok)
    assert.are.equal("protocol", value.error.kind)
    assert.is_false(state.terminated)
  end)

  it("rejects premature handshake and duplicate terminal events", function()
    local premature = require("tests.helpers.tool_rpc").new()
    local premature_child, premature_state = fake_child(premature, function() end)
    premature:attach(premature_child)
    premature:feed(protocol.encode({ type = "ready", marker = protocol.MARKER })
      .. protocol.encode({ type = "opened", call_id = premature._call_id }))
    local premature_result = wait(async.run(function()
      premature:open_tool(call())
      return true
    end))
    assert.is_false(premature_result.ok)
    assert.are.equal("protocol", premature_result.error.kind)
    assert.is_false(premature_state.terminated)

    local duplicate = require("tests.helpers.tool_rpc").new()
    local duplicate_child, duplicate_state = fake_child(duplicate, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
      elseif message.type == "request" then
        local terminal = {
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = {
            result = { content = { { type = "text", text = "done" } } },
          },
        }
        emit(terminal)
        emit(terminal)
      end
    end)
    duplicate:attach(duplicate_child)
    duplicate:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local active_call = call()
    local duplicate_result = wait(async.run(function()
      duplicate:open_tool(active_call)
      return duplicate:write_file({ path = "file", content = "content" }, active_call)
    end))
    assert.is_false(duplicate_result.ok)
    assert.are.equal("protocol", duplicate_result.error.kind)
    assert.is_false(duplicate_state.terminated)
  end)

  it("preserves ordered updates and orderly shutdown", function()
    local remote = require("tests.helpers.tool_rpc").new()
    local updates = {}
    local active_call = call()
    active_call.on_update = function(update)
      updates[#updates + 1] = update
    end
    local child, state = fake_child(remote, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
      elseif message.type == "request" then
        emit({
          type = "event",
          call_id = message.call_id,
          request_id = message.request_id,
          sequence = 1,
          name = codec.events.update,
          value = { content = { { type = "text", text = "working" } } },
        })
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = {
            result = { content = { { type = "text", text = "done" } } },
          },
        })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    remote:attach(child)
    remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local value = wait(async.run(function()
      remote:open_tool(active_call)
      local result = remote:write_file({ path = "file", content = "content" }, active_call)
      remote:close()
      return result
    end))
    assert.are.equal("done", value.content[1].text)
    assert.are.equal("working", updates[1].content[1].text)
    assert.is_true(state.closed_stdin)
    assert.is_false(state.closed)
  end)

  it("keeps parent-only methods out of the remote protocol", function()
    local remote = require("tests.helpers.tool_rpc").new()
    assert.is_nil(rawget(remote --[[@as table]], "read_agent_documentation"))
    assert.is_nil(rawget(remote --[[@as table]], "update_plan"))
    for _, method in ipairs({ "read_agent_documentation", "update_plan" }) do
      assert.has_error(function()
        codec.method(method)
      end, "unknown Tool RPC method")
    end
  end)

  it("handles worker exit racing the orderly close acknowledgement", function()
    for _, code in ipairs({ 0, 70 }) do
      local remote = require("tests.helpers.tool_rpc").new()
      local child, state = fake_child(remote, function(message, emit)
        if message.type == "open" then
          emit({ type = "opened", call_id = message.call_id })
        elseif message.type == "close" then
          emit({ type = "closed", call_id = message.call_id })
          remote:eof({
            code = code,
            signal = 0,
            stderr = code == 0 and "" or "shutdown failed",
          })
        end
      end)
      remote:attach(child)
      remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
      local value = wait(async.run(function()
        remote:open_tool(call())
        return remote:close()
      end))
      if code == 0 then
        assert.is_true(value)
        assert.is_nil(remote._failure)
        assert.is_false(state.closed_stdin)
      else
        assert.is_false(value.ok)
        assert.are.equal("protocol", value.error.kind)
        assert.is_false(state.terminated)
      end
      assert.is_false(state.closed)
    end
  end)

  it("fails skipped update sequences and callback failures", function()
    for _, scenario in ipairs({ "sequence", "callback" }) do
      local remote = require("tests.helpers.tool_rpc").new()
      local active_call = call()
      if scenario == "callback" then
        active_call.on_update = function()
          error("consumer failed")
        end
      end
      local child, state = fake_child(remote, function(message, emit)
        if message.type == "open" then
          emit({ type = "opened", call_id = message.call_id })
        elseif message.type == "request" then
          emit({
            type = "event",
            call_id = message.call_id,
            request_id = message.request_id,
            sequence = scenario == "sequence" and 2 or 1,
            name = codec.events.update,
            value = { content = { { type = "text", text = "update" } } },
          })
        end
      end)
      remote:attach(child)
      remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
      local value = wait(async.run(function()
        remote:open_tool(active_call)
        return remote:write_file({ path = "file", content = "content" }, active_call)
      end))
      assert.is_false(value.ok, scenario)
      assert.are.equal("protocol", value.error.kind)
      assert.is_false(state.terminated)
    end
  end)

  it("rejects stale and cross-call request events", function()
    for _, identity in ipairs({ "call", "request" }) do
      local remote = require("tests.helpers.tool_rpc").new()
      local child, state = fake_child(remote, function(message, emit)
        if message.type == "open" then
          emit({ type = "opened", call_id = message.call_id })
        elseif message.type == "request" then
          emit({
            type = "response",
            call_id = identity == "call" and "another-call" or message.call_id,
            request_id = identity == "request" and message.request_id + 1 or message.request_id,
            value = {
              result = { content = { { type = "text", text = "stale" } } },
            },
          })
        end
      end)
      remote:attach(child)
      remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
      local active_call = call()
      local value = wait(async.run(function()
        remote:open_tool(active_call)
        return remote:write_file({ path = "file", content = "content" }, active_call)
      end))
      assert.is_false(value.ok, identity)
      assert.are.equal("protocol", value.error.kind)
      assert.is_false(state.terminated)
    end
  end)

  it("pins workspace authority in the fixed Tool proxy", function()
    local remote = require("tests.helpers.tool_rpc").new()
    local messages = {}
    local child = fake_child(remote, function(message, emit)
      messages[#messages + 1] = message.type
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    remote:attach(child)
    remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local active_call = call()
    local ctx = {
      context = {
        workspace = { root = active_call.workspace.root, cwd = "/another-workspace" },
      },
      on_update = function() end,
    } --[[@as Neoagent.ToolContext<unknown>]]
    local value = wait(async.run(function()
      remote:open_tool(active_call)
      local proxy = assert(require("neoagent.rpc.registry").proxy(
        require("neoagent.tools.write_file").new(),
        {
          call = active_call,
          invoke = function(method, payload, operation_call)
            return require("neoagent.rpc.registry").invoke(remote, method, payload, operation_call)
          end,
        }
      ))
      return proxy.execute({ path = "file", content = "content" }, ctx)
    end))
    assert.is_false(value.ok)
    assert.matches("Tool operation context changed", value.error.message)
    wait(async.run(function()
      return remote:close()
    end))
    assert.are.same({ "open", "close" }, messages)
  end)

  it("classifies worker exits without taking over lease disposal", function()
    local before_ready = require("tests.helpers.tool_rpc").new()
    local starting_child, starting_state = fake_child(before_ready, function() end)
    before_ready:attach(starting_child)
    local starting = async.run(function()
      before_ready:open_tool(call())
      return true
    end)
    before_ready:eof({ code = 70, signal = 0, stderr = "startup failed" })
    local starting_result = wait(starting)
    assert.is_false(starting_result.ok)
    assert.are.equal("worker_start", starting_result.error.kind)
    assert.is_false(starting_state.closed)

    local active = require("tests.helpers.tool_rpc").new()
    local active_child, active_state = fake_child(active, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
      end
    end)
    active:attach(active_child)
    active:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local active_call = call()
    local pending = async.run(function()
      active:open_tool(active_call)
      return active:write_file({ path = "file", content = "content" }, active_call)
    end)
    assert.are.equal("request", active._state)
    active:eof({
      code = 125,
      signal = 0,
      stderr = "",
      error = require("neoagent.util").error("sandbox_unavailable", "relay failed"),
    })
    local pending_result = wait(pending)
    assert.is_false(pending_result.ok)
    assert.are.equal("protocol", pending_result.error.kind)
    assert.is_false(active_state.closed)

    local settled = require("tests.helpers.tool_rpc").new()
    local settled_child, settled_state = fake_child(settled, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
      elseif message.type == "request" then
        emit({
          type = "response",
          call_id = message.call_id,
          request_id = message.request_id,
          value = {
            result = { content = { { type = "text", text = "complete" } } },
          },
        })
        settled:eof({ code = 70, signal = 0, stderr = "late crash" })
      end
    end)
    settled:attach(settled_child)
    settled:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local settled_call = call()
    local settled_result = wait(async.run(function()
      settled:open_tool(settled_call)
      return settled:write_file({ path = "file", content = "content" }, settled_call)
    end))
    assert.are.equal("complete", assert(settled_result.content[1]).text)
    assert.are.equal(70, assert(settled._exit).code)
    assert.is_false(settled_state.closed)
  end)

  it("bounds worker startup and orderly shutdown waits", function()
    local starting = require("tests.helpers.tool_rpc").new({ start_grace_ms = 10 })
    local starting_child, starting_state = fake_child(starting, function() end)
    starting:attach(starting_child)
    local starting_result = wait(async.run(function()
      starting:open_tool(call())
      return true
    end))
    assert.is_false(starting_result.ok)
    assert.are.equal("worker_start", starting_result.error.kind)
    assert.is_false(starting_state.terminated)

    local closing = require("tests.helpers.tool_rpc").new({ shutdown_grace_ms = 10 })
    local closing_child, closing_state = fake_child(closing, function(message, emit)
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    closing_child.wait = function()
      return async.await(function()
        return function()
          closing_state.wait_cancelled = true
        end
      end)
    end
    closing:attach(closing_child)
    closing:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local closing_result = wait(async.run(function()
      closing:open_tool(call())
      return closing:close()
    end))
    assert.is_true(closing_result)
    assert.is_nil(closing_state.wait_cancelled)
    assert.is_false(closing_state.terminated)
    assert.is_false(closing_state.closed)
  end)

  it("propagates cancellation through request and close acknowledgements", function()
    local remote = require("tests.helpers.tool_rpc").new()
    local messages = {}
    local child, state = fake_child(remote, function(message, emit)
      messages[#messages + 1] = message.type
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
      elseif message.type == "cancel" then
        emit({ type = "cancelled", call_id = message.call_id, request_id = message.request_id })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      end
    end)
    remote:attach(child)
    remote:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
    local active_call = call()
    local run = async.run(function()
      remote:open_tool(active_call)
      return remote:shell({ argv = { "sh", "-c", "wait" } }, active_call)
    end)
    assert.is_false(run:is_done())
    run:cancel()
    local value = wait(run)
    assert.is_false(value.ok)
    assert.are.equal("cancelled", value.error.kind)
    assert.are.same({ "open", "request", "cancel" }, messages)
    assert.are.equal("open", remote._state)
    assert.is_false(state.closed_stdin)
    assert.is_true(wait(async.run(function()
      return remote:close()
    end)))
    assert.are.same({ "open", "request", "cancel", "close" }, messages)
    assert.are.equal("closed", remote._state)
    assert.is_true(state.closed_stdin)
  end)
end)

describe("neoagent Tool RPC server", function()
  ---@return table
  local function api(execute)
    return {
      read_file = execute,
      write_file = execute,
      edit_file = execute,
      shell = execute,
      grep = execute,
      find = execute,
    }
  end

  it("dispatches fixed methods and emits monotonic updates", function()
    local events = {}
    local server = server({
      send = function(message)
        events[#events + 1] = message
      end,
      local_api = function()
        return api(
          ---@async
          function(_, _, active_call)
            active_call.on_update({ content = { { type = "text", text = "one" } } })
            active_call.on_update({ content = { { type = "text", text = "two" } } })
            return { content = { { type = "text", text = "done" } } }
          end
        )
      end,
    })
    server:receive({ type = "open", call_id = "call-1", context = codec.encode_context(call()) })
    server:receive({
      type = "request",
      call_id = "call-1",
      request_id = 1,
      method = "write_file",
      payload = { path = "file", content = "content" },
    })
    assert(vim.wait(1000, function()
      return events[#events] and events[#events].type == "response"
    end))
    assert.are.same({ "ready", "opened", "event", "event", "response" }, vim.tbl_map(function(event)
      return event.type
    end, events))
    assert.are.equal(1, events[3].sequence)
    assert.are.equal(2, events[4].sequence)
    assert.are.equal(codec.events.update, events[3].name)
    assert.are.equal(codec.events.update, events[4].name)
  end)

  it("dispatches every fixed typed method without exposing a generic API", function()
    local cases = {
      { method = "read_file", payload = {
        path = "file", offset = 1, max_image_input_bytes = 1,
        max_image_pixels = 1, max_image_output_bytes = 1,
      } },
      { method = "write_file", payload = { path = "file", content = "content" } },
      { method = "edit_file", payload = {
        path = "file", edits = { { old_text = "old", new_text = "new" } },
      } },
      { method = "shell", payload = { argv = { "true" } } },
      { method = "grep", payload = {
        pattern = "value", ignore_case = false, literal = false, context = 0, limit = 1,
      } },
      { method = "find", payload = { pattern = "*", limit = 1 } },
    }
    for _, case in ipairs(cases) do
      local events = {}
      local selected
      local server = server({
        send = function(message)
          events[#events + 1] = message
        end,
        local_api = function()
          return api(function(_, request)
            selected = { method = case.method, request = request }
            return { content = { { type = "text", text = case.method } } }
          end)
        end,
      })
      server:receive({ type = "open", call_id = "call-1", context = codec.encode_context(call()) })
      server:receive({
        type = "request",
        call_id = "call-1",
        request_id = 1,
        method = case.method,
        payload = case.payload,
      })
      assert(vim.wait(1000, function()
        return events[#events] and events[#events].type == "response"
      end), case.method)
      local selected_value = selected or error("request was not dispatched")
      assert.are.equal(case.method, selected_value.method)
      assert.are.equal(case.method, events[#events].value.result.content[1].text)
    end
  end)

  it("preserves bounded stable codes in tool errors", function()
    local events = {}
    local server = server({
      send = function(message)
        events[#events + 1] = message
      end,
      local_api = function()
        return api(function()
          local err = require("neoagent.util").error("tool", "Process output was too large")
          rawset(err, "code", "output_limit")
          error(err, 0)
        end)
      end,
    })
    server:receive({ type = "open", call_id = "call-1", context = codec.encode_context(call()) })
    server:receive({
      type = "request",
      call_id = "call-1",
      request_id = 1,
      method = "write_file",
      payload = { path = "file", content = "content" },
    })
    assert(vim.wait(1000, function()
      return events[#events] and events[#events].type == "request_error"
    end))
    assert.are.same({
      kind = "tool",
      code = "output_limit",
      message = "Process output was too large",
    }, events[#events].error)
  end)

  it("cancels active work and becomes quiescent on EOF", function()
    local cancelled = false
    local server = server({
      send = function() end,
      local_api = function()
        return api(
          ---@async
          function()
            return async.await(function()
              return function()
                cancelled = true
              end
            end)
          end
        )
      end,
    })
    server:receive({ type = "open", call_id = "call-1", context = codec.encode_context(call()) })
    server:receive({
      type = "request",
      call_id = "call-1",
      request_id = 1,
      method = "write_file",
      payload = { path = "file", content = "content" },
    })
    server:eof()
    assert(vim.wait(1000, function()
      return server:is_quiescent()
    end))
    assert.is_true(cancelled)
    assert.matches("orderly shutdown", assert(server:failure()))
  end)

  it("rejects duplicate, skipped, and cross-call request identities", function()
    for _, scenario in ipairs({ "duplicate", "skipped", "call" }) do
      local events = {}
      local server = server({
        send = function(message)
          events[#events + 1] = message
        end,
        local_api = function()
          return api(function()
            return { content = { { type = "text", text = "done" } } }
          end)
        end,
      })
      server:receive({ type = "open", call_id = "call-1", context = codec.encode_context(call()) })
      server:receive({
        type = "request",
        call_id = "call-1",
        request_id = 1,
        method = "write_file",
        payload = { path = "file", content = "content" },
      })
      assert(vim.wait(1000, function()
        return events[#events] and events[#events].type == "response"
      end))
      local ok, err = pcall(server.receive, server, {
        type = "request",
        call_id = scenario == "call" and "call-2" or "call-1",
        request_id = scenario == "skipped" and 3 or 1,
        method = "write_file",
        payload = { path = "file", content = "content" },
      })
      assert.is_false(ok, scenario)
      assert.is_truthy(tostring(err):match("state") or tostring(err):match("order"))
      assert.is_true(server:is_terminal())
    end
  end)
end)
