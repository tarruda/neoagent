local assert = require("luassert")
local async = require("neoagent.async")
local codec = require("neoagent.rpc.codec")
local protocol = require("neoagent.rpc.protocol")

describe("RPC failure during event processing", function()
  ---@type Neoagent.Run<unknown, unknown>[]
  local runs = {}
  ---@type Neoagent.RpcConnection[]
  local connections = {}

  after_each(function()
    for _, run in ipairs(runs) do run:cancel() end
    for _, connection in ipairs(connections) do connection:abort() end
    for _, run in ipairs(runs) do
      assert(vim.wait(3000, function() return run:is_done() end, 5))
    end
    runs, connections = {}, {}
  end)

  ---@generic T
  ---@param run Neoagent.Run<T, unknown>
  ---@return Neoagent.RunResult<T>
  local function wait(run)
    runs[#runs + 1] = run
    assert(vim.wait(1000, function() return run:is_done() end, 5), "RPC call did not settle")
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

  local data = "synthetic image bytes"
  local file = { file_id = vim.fn.sha256(data), bytes = #data }

  ---@param message table
  ---@param emit fun(message: table)
  ---@param terminal boolean
  local function image_response(message, emit, terminal)
    local events = {
      { name = codec.events.artifact_begin, value = { artifact_id = 1, file_id = file.file_id, bytes = file.bytes } },
      { name = codec.events.artifact_chunk, value = { artifact_id = 1, data = data } },
      { name = codec.events.artifact_end, value = { artifact_id = 1 } },
      { name = codec.events.update, value = { content = { { type = "text", text = "image prepared" } } } },
    }
    for sequence, event in ipairs(events) do
      emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
        sequence = sequence, name = event.name, value = event.value })
    end
    if terminal then
      emit({ type = "response", call_id = message.call_id, request_id = message.request_id,
        value = codec.result({ content = { {
          type = "image", file_id = file.file_id, bytes = file.bytes, mime_type = "image/png",
        } } }),
      })
    end
  end

  for _, ending in ipairs({ "protocol", "exit", "abort" }) do
    it("interrupts pending artifact publication after " .. ending .. " before a response", function()
      local connection = connect(function(message, emit) image_response(message, emit, false) end)
      ---@type Neoagent.AwaitCallbacks<Neoagent.LocalFile>?
      local publisher
      local cancelled, updates = false, 0
      local owner = async.run(function()
        return require("neoagent.rpc.tool_client").invoke(connection, "read_file", {}, {
          workspace = { root = "/workspace", cwd = "/workspace" },
          artifacts = { put = function()
            return async.await(function(done)
              publisher = done
              return function() cancelled = true end
            end)
          end },
          on_update = function() updates = updates + 1 end,
        })
      end)
      runs[#runs + 1] = owner
      assert(vim.wait(1000, function() return publisher ~= nil end, 5))
      if ending == "protocol" then
        connection:feed("\0\0\0\0")
      elseif ending == "exit" then
        connection:eof({ code = 7, signal = 0, stderr = "worker failed" })
      else
        connection:abort()
      end
      local result = wait(owner)
      assert.is_false(result.ok)
      assert.are.equal("protocol", assert(result.error).kind)
      assert.is_false(owner:is_cancelled(), "channel failure cancelled its caller")
      assert.is_true(cancelled, "pending publication was not interrupted")
      assert.are.equal(0, updates)
      assert.is_false(assert(publisher).resolve(file), "stale publication was accepted")
      assert.are.same(result, owner:result())
    end)
  end

  it("finishes acknowledged artifact validation after failure without publishing progress", function()
    local connection = connect(function(message, emit) image_response(message, emit, true) end)
    ---@type Neoagent.AwaitCallbacks<Neoagent.LocalFile>?
    local publisher
    local cancelled, updates = false, 0
    local owner = async.run(function()
      return require("neoagent.rpc.tool_client").invoke(connection, "read_file", {}, {
        workspace = { root = "/workspace", cwd = "/workspace" },
        artifacts = { put = function()
          return async.await(function(done)
            publisher = done
            return function() cancelled = true end
          end)
        end },
        on_update = function() updates = updates + 1 end,
      })
    end)
    runs[#runs + 1] = owner
    assert(vim.wait(1000, function() return publisher ~= nil end, 5))
    connection:feed("\0\0\0\0")
    assert.is_false(cancelled, "received response validation was interrupted")
    assert.is_false(owner:is_done(), "result escaped before artifact publication")
    assert.is_true(assert(publisher).resolve(file))
    local result = wait(owner)
    assert.is_not_false(result.ok)
    assert.are.equal(file.file_id, result.content[1].file_id)
    assert.are.equal(0, updates, "failed channel published queued progress")
  end)
end)
