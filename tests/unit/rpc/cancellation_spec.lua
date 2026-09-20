local assert = require("luassert")
local async = require("neoagent.async")
local protocol = require("neoagent.rpc.protocol")
local codec = require("neoagent.rpc.codec")
local fs = require("neoagent.fs")

describe("RPC cancellation boundaries", function()
  local roots = {}
  ---@type Neoagent.RpcConnection[]
  local connections = {}
  ---@type Neoagent.Run<unknown, unknown>[]
  local runs = {}

  after_each(function()
    for _, run in ipairs(runs) do run:cancel() end
    for _, connection in ipairs(connections) do connection:abort() end
    for _, run in ipairs(runs) do
      assert(vim.wait(3000, function() return run:is_done() end, 5))
    end
    for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
    roots, connections, runs = {}, {}, {}
  end)

  ---@generic T
  ---@param run Neoagent.Run<T, unknown>
  ---@return Neoagent.RunResult<T>
  local function wait(run)
    runs[#runs + 1] = run
    assert(vim.wait(3000, function() return run:is_done() end, 5))
    return (assert(run:result()))
  end

  ---@param handle fun(message: table, emit: fun(message: table))
  ---@return Neoagent.RpcConnection
  local function connect(handle)
    local connection = require("neoagent.rpc.connection").new()
    connections[#connections + 1] = connection
    local function emit(message) connection:feed(protocol.encode(message)) end
    local decoder = protocol.decoder(function(message)
      if message.type == "open" then
        emit({ type = "opened", call_id = message.call_id })
      elseif message.type == "close" then
        emit({ type = "closed", call_id = message.call_id })
      else
        handle(message, emit)
      end
    end)
    connection:attach({
      write = function(_, bytes) decoder:feed(bytes) return true end,
      close_stdin = function() return true end,
    })
    emit({ type = "ready", marker = protocol.MARKER })
    assert.is_true(wait(async.run(function() connection:open({}) return true end)))
    return connection
  end

  it("allows cleanup and relay delivery before requiring a cancellation acknowledgement", function()
    local timer = assert(vim.uv.new_timer())
    local connection = connect(function(message, emit)
      if message.type == "cancel" then
        -- The server can spend 500 ms cleaning commands before the relay
        -- delivers its acknowledgement. The connection must allow both.
        timer:start(650, 0, function()
          timer:stop()
          emit({ type = "cancelled", call_id = message.call_id, request_id = message.request_id })
        end)
      elseif message.type == "request" and message.method == "next" then
        emit({ type = "response", call_id = message.call_id, request_id = message.request_id,
          value = { reused = true },
        })
      end
    end)
    local completed, failure = pcall(function()
      local request = connection:start_request("pending", {})
      request:cancel()
      local cancelled = wait(async.run(function() return request:result() end))
      assert.is_false(cancelled.ok)
      local reused = wait(async.run(function()
        connection:wait_cancelled()
        local value = connection:request("next", {})
        connection:close()
        return value
      end))
      assert.is_not_false(reused.ok, vim.inspect(reused))
      assert.is_true(reused.reused)
    end)
    timer:stop()
    timer:close()
    assert.is_true(completed, tostring(failure))
  end)

  for _, progress in ipairs({ false, true }) do
    it("retains a received write result across cancellation with progress=" .. tostring(progress), function()
      local root = vim.fn.tempname()
      roots[#roots + 1] = root
      assert(fs.mkdirp(root))
      ---@type Neoagent.Run<Neoagent.ToolResult, unknown>?
      local owner
      local updates = 0
      local connection = connect(function(message, emit)
        if message.type ~= "request" then return end
        local implementation = require("neoagent.tools.write_file")
        local call = { workspace = { root = root, cwd = root }, on_update = function() end }
        local worker = async.run(function()
          return implementation.run(
            implementation.validate_request(message.payload), call, implementation._dependencies()
          )
        end, { on_done = function(result)
          if result.ok == false then error(result.error, 0) end
          if progress then
            emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
              sequence = 1, name = codec.events.update,
              value = { content = { { type = "text", text = "write finished" } } },
            })
          end
          emit({ type = "response", call_id = message.call_id, request_id = message.request_id,
            value = codec.result(result),
          })
          assert(owner):cancel()
        end })
        runs[#runs + 1] = worker
      end)
      owner = async.run(function()
        return require("neoagent.rpc.tool_client").invoke(connection, "write_file", {
          path = "written.txt", resolved_path = root .. "/written.txt", content = "written once",
        }, {
          workspace = { root = root, cwd = root },
          on_update = function() updates = updates + 1 end,
        })
      end)
      local result = wait(owner)
      assert.is_not_false(result.ok, vim.inspect(result))
      assert.are.equal("written once", fs.read(root .. "/written.txt"))
      assert.are.same({ root .. "/written.txt" }, assert(result.details).changed_paths)
      assert.are.equal(0, updates, "cancelled observers received queued progress")
      assert.is_true(wait(async.run(function() return connection:close() end)))
    end)
  end

  for _, next_sequence in ipairs({ 1, 3 }) do
    it("rejects sequence " .. next_sequence .. " after a queued event is cancelled", function()
      local calls = 0
      local connection = connect(function(message, emit)
        if message.type == "request" then
          emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
            sequence = 1, name = "progress", value = {},
          })
        elseif message.type == "cancel" then
          emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
            sequence = next_sequence, name = "progress", value = {},
          })
          emit({ type = "cancelled", call_id = message.call_id, request_id = message.request_id })
        end
      end)
      local request = connection:start_request("work", {}, {
        on_event = function()
          calls = calls + 1
          async.await(function() return function() end end)
        end,
      })
      assert.are.equal(1, calls)
      request:cancel()
      local result = wait(async.run(function() return request:result() end))
      assert.is_false(result.ok)
      local reused = wait(async.run(function() return connection:wait_cancelled() end))
      assert(type(reused) == "table", "an invalid event sequence left the connection reusable")
      assert.is_false(reused.ok)
      assert.are.equal("protocol", assert(reused.error).kind)
      assert.matches("sequence", reused.error.message, 1, true)
      assert.are.equal(1, calls)
    end)
  end

  for _, invalid in ipairs({ "update", "response" }) do
    it("validates a queued " .. invalid .. " before accepting a result after cancellation", function()
      ---@type Neoagent.Run<Neoagent.ToolResult, unknown>?
      local owner
      local connection = connect(function(message, emit)
        if message.type ~= "request" then return end
        vim.schedule(function()
          if invalid == "update" then
            emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
              sequence = 1, name = codec.events.update, value = { content = false },
            })
          end
          emit({ type = "response", call_id = message.call_id, request_id = message.request_id,
            value = invalid == "response" and {} or {
              content = { { type = "text", text = "completed" } },
            },
          })
          assert(owner):cancel()
        end)
      end)
      owner = async.run(function()
        return require("neoagent.rpc.tool_client").invoke(connection, "write_file", {}, {
          workspace = { root = "/workspace", cwd = "/workspace" },
          on_update = function() error("cancelled observer ran") end,
        })
      end)
      local result = wait(owner)
      assert.is_false(result.ok)
      assert.are.equal("protocol", assert(result.error).kind)
      assert.are.equal("failed", connection._state)
    end)
  end

  for _, observation_error in ipairs({ false, true }) do
    it("separates cancelled progress delivery from validation with error=" .. tostring(observation_error), function()
      local connection = connect(function(message, emit)
        if message.type ~= "request" then return end
        emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
          sequence = 1, name = codec.events.update,
          value = { content = { { type = "text", text = "progress" } } },
        })
        emit({ type = "response", call_id = message.call_id, request_id = message.request_id,
          value = { content = { { type = "text", text = "completed" } } },
        })
      end)
      local observing = false
      ---@async
      local function observe()
        observing = true
        local succeeded, err = pcall(async.await, function() return function() end end)
        if not succeeded then
          if observation_error then error("progress observer failed") end
          error(err, 0)
        end
      end
      local owner = async.run(function()
        return require("neoagent.rpc.tool_client").invoke(connection, "write_file", {}, {
          workspace = { root = "/workspace", cwd = "/workspace" },
          on_update = observe,
        })
      end)
      assert.is_true(observing)
      owner:cancel()
      local result = wait(owner)
      if observation_error then
        assert.is_false(result.ok)
        assert.matches("progress observer failed", assert(result.error).message, 1, true)
      else
        assert.is_not_false(result.ok, vim.inspect(result))
        assert.are.equal("completed", result.content[1].text)
        assert.is_true(wait(async.run(function() return connection:close() end)))
      end
    end)
  end

  it("waits for cancellation settlement while a received response is being validated", function()
    local connection = connect(function(message, emit)
      if message.type ~= "request" then return end
      emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
        sequence = 1, name = "progress", value = {},
      })
      emit({ type = "response", call_id = message.call_id, request_id = message.request_id, value = {} })
    end)
    local request = connection:start_request("work", {}, {
      on_event = function() async.await(function() return function() end end) end,
    })
    request:cancel()
    assert.is_true(wait(async.run(function() return connection:wait_cancelled() end)))
    assert.is_false(wait(async.run(function() return request:result() end)).ok)
    assert.is_true(wait(async.run(function() return connection:close() end)))
  end)

  it("cancels a pending request when its result observer is already cancelled", function()
    local connection = connect(function(message, emit)
      if message.type == "cancel" then
        emit({ type = "cancelled", call_id = message.call_id, request_id = message.request_id })
      end
    end)
    local request = connection:start_request("work", {})
    local cancelled = wait(async.run(function(owner)
      owner:cancel()
      return request:result()
    end))
    assert.is_false(cancelled.ok)
    assert.are.equal("cancelled", assert(cancelled.error).kind)
    assert.is_false(wait(async.run(function() return request:result() end)).ok)
    assert.is_true(wait(async.run(function() return connection:wait_cancelled() end)))
    assert.is_true(wait(async.run(function() return connection:close() end)))
  end)

  it("counts queued events when validating correctly ordered cancellation traffic", function()
    local calls = 0
    local connection = connect(function(message, emit)
      if message.type == "request" then
        for sequence = 1, 2 do
          emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
            sequence = sequence, name = "progress", value = {},
          })
        end
      elseif message.type == "cancel" then
        emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
          sequence = 3, name = "progress", value = {},
        })
        emit({ type = "cancelled", call_id = message.call_id, request_id = message.request_id })
      end
    end)
    local request = connection:start_request("work", {}, {
      on_event = function()
        calls = calls + 1
        async.await(function() return function() end end)
      end,
    })
    request:cancel()
    assert.is_false(wait(async.run(function() return request:result() end)).ok)
    assert.is_true(wait(async.run(function() return connection:wait_cancelled() end)))
    assert.are.equal(1, calls)
    assert.is_true(wait(async.run(function() return connection:close() end)))
  end)
end)
