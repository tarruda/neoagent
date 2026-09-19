local assert = require("luassert")
local async = require("neoagent.async")
local codec = require("neoagent.rpc.codec")
local limits = require("neoagent.rpc.limits")
local protocol = require("neoagent.rpc.protocol")
local util = require("neoagent.util")

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
  return {
    workspace = { root = "/workspace", cwd = "/workspace" },
    on_update = function() end,
  }
end

---@param execute async fun(self: table, request: table, call: Neoagent.ToolOperationCall): Neoagent.ToolResult
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

---@param server Neoagent.RpcServer
local function open(server)
  server:receive({
    type = "open",
    call_id = "call-1",
    context = codec.encode_context(call()),
  })
end

---@param server Neoagent.RpcServer
---@param request_id? integer
local function request(server, request_id)
  server:receive({
    type = "request",
    call_id = "call-1",
    request_id = request_id or 1,
    method = "write_file",
    payload = { path = "file", content = "value" },
  })
end

---@param events table[]
---@param event_type string
---@param timeout? integer
local function wait_for(events, event_type, timeout)
  assert(vim.wait(timeout or 3000, function()
    return events[#events] and events[#events].type == event_type
  end), "server event did not arrive: " .. event_type)
end

describe("neoagent Tool RPC server edge cases", function()
  it("dispatches every fixed worker implementation and rejects unknown methods", function()
    local root = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(root, "p"))
    assert(require("neoagent.fs").write_all(root .. "/edit.txt", "old\n"))
    local events = {}
    local active_server = require("neoagent.rpc.server").new({
      send = function(message)
        events[#events + 1] = message
      end,
      dependencies = {
        process = function(argv, opts)
          local output = argv[1] == "rg" and "edit.txt:1:new\n" or "edit.txt\n"
          assert(opts and opts.on_output)(output, false, "", "", output)
          return {
            code = 0, signal = 0, stdout = "", stderr = "",
            output = "", timed_out = false,
          }
        end,
      },
    })
    active_server:receive({
      type = "open",
      call_id = "dispatch-call",
      context = {
        workspace = { root = root, cwd = root },
      },
    })

    local function dispatch(request_id, method, payload)
      active_server:receive({
        type = "request", call_id = "dispatch-call",
        request_id = request_id, method = method, payload = payload,
      })
      assert(vim.wait(3000, function()
        local last = events[#events]
        return last
          and last.request_id == request_id
          and (last.type == "response" or last.type == "request_error")
      end), "worker dispatch did not settle for " .. method)
      return events[#events]
    end

    local edited = dispatch(1, codec.methods.edit_file, {
      path = "edit.txt",
      edits = { { old_text = "old", new_text = "new" } },
    })
    assert.are.equal("response", edited.type)
    assert.are.equal("new\n", assert(require("neoagent.fs").read(root .. "/edit.txt")))

    local grep = dispatch(2, codec.methods.grep, {
      pattern = "new", path = ".", ignore_case = false, literal = false, limit = 10,
    })
    assert.are.equal("response", grep.type)
    assert.matches("edit.txt", assert(grep.value.result.content[1]).text, 1, true)

    local find = dispatch(3, codec.methods.find, {
      pattern = "*.txt", path = ".", limit = 10,
    })
    assert.are.equal("response", find.type)
    assert.matches("edit.txt", assert(find.value.result.content[1]).text, 1, true)

    local unknown = dispatch(4, "unknown", {})
    assert.are.equal("request_error", unknown.type)
    assert.matches("unknown Tool RPC method", unknown.error.message)
    vim.fn.delete(root, "rf")
  end)

  it("detects shell denial evidence across the complete private output stream", function()
    local root = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(root, "p"))
    local events = {}
    local active_server = require("neoagent.rpc.server").new({
      send = function(message)
        events[#events + 1] = message
      end,
      dependencies = {
        process = function(_, opts)
          local emit = assert(opts and opts.on_output)
          emit("credential=private-value\n" .. string.rep("a", 16 * 1024) .. "permission ", false, "", "", "")
          emit("denied\n", false, "", "", "")
          emit("x" .. string.rep("\255", 1000)
            .. string.rep("\195\169", 3500)
            .. string.rep("x", 128 * 1024), false, "", "", "")
          return {
            code = 1,
            signal = 0,
            stdout = "",
            stderr = "",
            output = "",
            timed_out = false,
          }
        end,
      },
    })
    active_server:receive({
      type = "open",
      call_id = "private-policy",
      context = {
        workspace = { root = root, cwd = root },
        denial_keywords = { "permission denied" },
      },
    })
    active_server:receive({
      type = "request",
      call_id = "private-policy",
      request_id = 1,
      method = codec.methods.shell,
      payload = { argv = { "sh", "-c", "ignored" }, timeout_ms = 1000 },
    })
    wait_for(events, "response")

    local response = assert(events[#events]) --[[@as {value: {policy?: Neoagent.ToolRpcPolicyEvidence, result: Neoagent.ToolResult}}]]
    local policy = assert(response.value.policy)
    local details = assert(response.value.result.details)
    assert.matches("permission denied", policy.denial_output, 1, true)
    assert.is_true(#policy.denial_output <= 8 * 1024)
    assert.is_true(util.is_valid_utf8(policy.denial_output))
    assert.is_nil(rawget(details, "diagnostic_output"))
    assert.is_nil(vim.inspect(response.value):find("private%-value"))
    local output_path = rawget(details, "output_path")
    if type(output_path) == "string" then
      vim.fn.delete(output_path)
    end
    vim.fn.delete(root, "rf")
  end)

  it("publishes worker artifacts and revokes stale file and update capabilities", function()
    local events = {}
    ---@type Neoagent.ToolArtifactPublisher?
    local publisher
    ---@type (fun(update: Neoagent.ToolResult))?
    local stale_update
    local active_server = server({
      send = function(message)
        events[#events + 1] = message
      end,
      local_api = function(options)
        local publisher_factory = options.artifact_publisher
          or error("artifact publisher factory is missing")
        return api(
          ---@async
          function(_, _, active_call)
            publisher = publisher_factory(active_call)
            assert.is_nil(active_call.artifacts)
            local active_publisher = publisher or error("artifact publisher is missing")
            local stored = assert(active_publisher.put("artifact"))
            active_call.on_update({ content = { { type = "text", text = "working" } } })
            stale_update = active_call.on_update
            return {
              content = { {
                type = "image",
                file_id = stored.file_id,
                bytes = stored.bytes,
                mime_type = "image/png",
              } },
            }
          end
        )
      end,
    })
    open(active_server)
    request(active_server)
    wait_for(events, "response")
    assert.are.same({
      "ready", "opened", "event", "event",
      "event", "event", "response",
    }, vim.tbl_map(function(event) return event.type end, events))
    assert.are.same({
      codec.events.artifact_begin,
      codec.events.artifact_chunk,
      codec.events.artifact_end,
      codec.events.update,
    }, vim.tbl_map(function(event) return event.name end, vim.list_slice(events, 3, 6)))

    local update = stale_update or error("stale update callback was not captured")
    update({ content = { { type = "text", text = "ignored" } } })
    assert.are.equal("response", events[#events].type)
    local active_publisher = publisher or error("artifact publisher was not captured")
    local stale = async.run(function()
      local stored = active_publisher.put("late")
      return stored
    end)
    assert(vim.wait(3000, function() return stale:is_done() end))
    local stale_result = assert(stale:result())
    assert.is_false(stale_result.ok)
    local stale_error = stale_result.error or error("stale artifact publication did not fail")
    assert.are.equal("cancelled", stale_error.kind)
  end)

  it("contains update encoding failures", function()
    local events = {}
    local active_server = server({
      send = function(message)
        events[#events + 1] = message
      end,
      local_api = function()
        return api(function(_, _, active_call)
          local original_encode = vim.mpack.encode
          vim.mpack.encode = function()
            error("encoding failed")
          end
          local ok, err = pcall(active_call.on_update, {
            content = { { type = "text", text = "working" } },
          })
          vim.mpack.encode = original_encode
          if not ok then
            error(err, 0)
          end
          return { content = { { type = "text", text = "done" } } }
        end)
      end,
    })
    open(active_server)
    request(active_server)
    wait_for(events, "request_error")
    assert.are.equal("tool", events[#events].error.kind)
  end)

  it("suppresses updates beyond aggregate budgets without losing the result", function()
    local original_count = limits.MAX_UPDATE_COUNT
    local original_bytes = limits.MAX_UPDATE_BYTES
    local update = { content = { { type = "text", text = "working" } } }
    local encoded_bytes = #vim.mpack.encode(update)
    local function run_case(max_count, max_bytes)
      limits.MAX_UPDATE_COUNT = max_count
      limits.MAX_UPDATE_BYTES = max_bytes
      local events = {}
      local server = server({
        send = function(message)
          events[#events + 1] = message
        end,
        local_api = function()
          return api(function(_, _, active_call)
            active_call.on_update(update)
            active_call.on_update(update)
            return { content = { { type = "text", text = "unreachable" } } }
          end)
        end,
      })
      open(server)
      request(server)
      wait_for(events, "response")
      local terminal = assert(events[#events]) --[[@as {value: {result: Neoagent.ToolResult}}]]
      local block = assert(terminal.value.result.content[1])
      assert.are.equal("unreachable", block.text)
      assert.are.equal(1, #vim.tbl_filter(function(event)
        return event.type == "event" and event.name == codec.events.update
      end, events))
    end
    local ok, err = pcall(function()
      run_case(1, original_bytes)
      run_case(original_count, encoded_bytes)
    end)
    limits.MAX_UPDATE_COUNT = original_count
    limits.MAX_UPDATE_BYTES = original_bytes
    assert(ok, err)
  end)

  it("retains a successful terminal result after sustained progress", function()
    local events = {}
    local server = server({
      send = function(message)
        events[#events + 1] = message
      end,
      local_api = function()
        return api(function(_, _, active_call)
          for index = 1, 300 do
            active_call.on_update({
              content = { { type = "text", text = "working " .. index } },
            })
          end
          return { content = { { type = "text", text = "done" } } }
        end)
      end,
    })
    open(server)
    request(server)
    wait_for(events, "response")

    local updates = vim.tbl_filter(function(event)
      return event.type == "event" and event.name == codec.events.update
    end, events)
    assert.are.equal(300, #updates)
    assert.are.equal("done", events[#events].value.result.content[1].text)
  end)

  it("reassembles streamed requests and rejects malformed request streams", function()
    local events = {}
    local received
    local stream_server = server({
      send = function(message)
        events[#events + 1] = message
      end,
      local_api = function()
        return api(function(_, value)
          received = value
          return { content = { { type = "text", text = "done" } } }
        end)
      end,
    })
    open(stream_server)
    local payload = vim.mpack.encode({ path = "file", content = string.rep("value", 20) })
    stream_server:receive({
      type = "request_begin",
      call_id = "call-1",
      request_id = 1,
      method = "write_file",
      bytes = #payload,
    })
    assert.is_false(stream_server:is_quiescent())
    stream_server:receive({
      type = "request_chunk",
      call_id = "call-1",
      request_id = 1,
      data = payload:sub(1, 5),
    })
    stream_server:receive({
      type = "request_chunk",
      call_id = "call-1",
      request_id = 1,
      data = payload:sub(6),
    })
    stream_server:receive({ type = "request_end", call_id = "call-1", request_id = 1 })
    wait_for(events, "response")
    assert.are.same({ path = "file", content = string.rep("value", 20) }, received)
    assert.is_true(stream_server:is_quiescent())

    local cases = {
      {
        messages = { {
          type = "request_begin", call_id = "call-1", request_id = 2,
          method = "write_file", bytes = 1,
        } },
        message = "request order is invalid",
      },
      {
        messages = { {
          type = "request_chunk", call_id = "call-1", request_id = 1, data = "x",
        } },
        message = "request stream is invalid",
      },
      {
        messages = {
          {
            type = "request_begin", call_id = "call-1", request_id = 1,
            method = "write_file", bytes = 1,
          },
          { type = "request_chunk", call_id = "call-1", request_id = 1, data = "xx" },
        },
        message = "request stream is invalid",
      },
      {
        messages = {
          {
            type = "request_begin", call_id = "call-1", request_id = 1,
            method = "write_file", bytes = 2,
          },
          { type = "request_chunk", call_id = "call-1", request_id = 1, data = "x" },
          { type = "request_end", call_id = "call-1", request_id = 1 },
        },
        message = "request stream is incomplete",
      },
      {
        messages = {
          {
            type = "request_begin", call_id = "call-1", request_id = 1,
            method = "write_file", bytes = 1,
          },
          {
            type = "request_chunk", call_id = "call-1", request_id = 1,
            data = string.char(0xd9),
          },
          { type = "request_end", call_id = "call-1", request_id = 1 },
        },
        message = "request stream payload is invalid",
      },
    }
    for _, case in ipairs(cases) do
      local invalid = server({ send = function() end })
      open(invalid)
      local ok, err = pcall(function()
        for _, message in ipairs(case.messages) do
          invalid:receive(message)
        end
      end)
      assert.is_false(ok)
      assert.matches(case.message, tostring(err))
      assert.is_true(invalid:is_terminal())
    end
  end)

  it("acknowledges explicit cancellation and rejects invalid cancellation and close races", function()
    local events = {}
    local cancelled = false
    local active_server = server({
      send = function(message)
        events[#events + 1] = message
      end,
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
    open(active_server)
    request(active_server)
    active_server:receive({ type = "cancel", call_id = "call-1", request_id = 1 })
    wait_for(events, "cancelled")
    assert.is_true(cancelled)

    local completed_events = {}
    local invalid = server({
      send = function(message)
        completed_events[#completed_events + 1] = message
      end,
      local_api = function()
        return api(function()
          return { content = { { type = "text", text = "done" } } }
        end)
      end,
    })
    open(invalid)
    request(invalid)
    wait_for(completed_events, "response")
    local completion_count = #completed_events
    invalid:receive({ type = "cancel", call_id = "call-1", request_id = 1 })
    assert.are.equal(completion_count, #completed_events)
    assert.has_error(function()
      invalid:receive({ type = "cancel", call_id = "call-1", request_id = 2 })
    end, "Tool RPC cancellation is invalid")

    local active = server({
      send = function() end,
      local_api = function()
        return api(
          ---@async
          function()
            return async.await(function() return function() end end)
          end
        )
      end,
    })
    open(active)
    request(active)
    assert.has_error(function()
      active:receive({ type = "close", call_id = "call-1" })
    end, "Tool RPC cannot close with an active request")
  end)

  it("fails closed for invalid opening and open-state messages", function()
    local waiting = server({ send = function() end })
    assert.has_error(function()
      waiting:receive({ type = "ready", marker = protocol.MARKER })
    end, "Tool RPC expected an open message")

    for _, message in ipairs({
      { type = "opened", call_id = "call-1" },
      { type = "cancel", call_id = "call-1", request_id = 1 },
    }) do
      local server = server({ send = function() end })
      open(server)
      local ok = pcall(server.receive, server, message)
      assert.is_false(ok)
      assert.is_true(server:is_terminal())
    end
  end)

  it("ignores stale completions and contains completion publication failures", function()
    ---@type (fun(value: Neoagent.ToolResult))?
    local finish
    local events = {}
    local stale = server({
      send = function(message)
        events[#events + 1] = message
      end,
      local_api = function()
        return api(
          ---@async
          function()
            return async.await(function(done)
              finish = done.resolve
            end)
          end
        )
      end,
    })
    open(stale)
    request(stale)
    local active = assert(stale._active)
    stale._active = nil
    local complete = finish or error("completion callback was not captured")
    complete({ content = { { type = "text", text = "late" } } })
    assert(vim.wait(3000, function()
      return assert(active.run):is_done()
    end))
    assert.are.equal("opened", events[#events].type)

    local sends = 0
    local failing = server({
      send = function(message)
        sends = sends + 1
        if message.type == "response" then
          error("publication failed")
        end
      end,
      local_api = function()
        return api(function()
          return { content = { { type = "text", text = "done" } } }
        end)
      end,
    })
    open(failing)
    request(failing)
    assert(vim.wait(3000, function() return failing:is_terminal() end))
    assert.matches("publication failed", assert(failing:failure()))
    assert.is_true(sends >= 3)
  end)

end)
