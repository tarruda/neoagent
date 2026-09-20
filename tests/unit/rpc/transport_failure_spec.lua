local assert = require("luassert")
local async = require("neoagent.async")
local protocol = require("neoagent.rpc.protocol")

describe("RPC transport failures", function()
  ---@type Neoagent.RpcConnection[]
  local connections = {}

  after_each(function()
    for _, connection in ipairs(connections) do connection:abort() end
    connections = {}
  end)

  for _, phase in ipairs({ "open", "request", "close", "stdin" }) do
    it("reports a thrown " .. phase .. " failure once and rejects further work", function()
      local failures = {}
      local connection = require("neoagent.rpc.connection").new({
        on_failure = function(err) failures[#failures + 1] = err end,
      })
      connections[#connections + 1] = connection
      local function emit(message) connection:feed(protocol.encode(message)) end
      local decoder = protocol.decoder(function(message)
        if message.type == phase then error("synthetic transport failure", 0) end
        if message.type == "open" then
          emit({ type = "opened", call_id = message.call_id })
        elseif message.type == "close" then
          emit({ type = "closed", call_id = message.call_id })
        end
      end)
      connection:attach({
        write = function(_, bytes) decoder:feed(bytes) return true end,
        close_stdin = function()
          if phase == "stdin" then error("synthetic transport failure", 0) end
          return true
        end,
      })
      emit({ type = "ready", marker = protocol.MARKER })
      local run = async.run(function()
        connection:open({})
        if phase == "request" then
          return connection:request("probe", {})
        end
        return connection:close()
      end)
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      local result = assert(run:result())
      assert.is_false(result.ok)
      assert.is_true(connection:is_failed(), "transport failure did not fail the connection")
      assert.are.equal(1, #failures)
      assert.are.equal("protocol", failures[1].kind)
      assert.matches("synthetic transport failure", failures[1].message, 1, true)
      assert.is_false(pcall(connection.close, connection))
      assert.is_false(pcall(connection.start_request, connection, "later", {}))
      connection:abort()
      assert.are.equal(1, #failures)
    end)
  end
end)
