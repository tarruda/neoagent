local assert = require("luassert")
local helper = require("tests.helpers.subprocess")

describe("retained process RPC admission and completion", function()
  if jit.os == "Windows" then
    pending("native Windows workers are exercised in tests/windows")
    return
  end
  ---@type Neoagent.RpcServer
  local server
  ---@type table[]
  local messages
  local fail_completion
  before_each(function()
    messages, fail_completion = {}, false
    server = require("neoagent.rpc.server").process({
      send = function(message)
        if fail_completion and message.type == "event" then error("completion transport failed") end
        messages[#messages + 1] = message
      end,
    })
    server:receive({ type = "open", call_id = "retained", context = {} })
  end)
  after_each(function()
    server:eof()
    assert(vim.wait(5000, function() return server:is_quiescent() end, 5))
  end)

  ---@param id integer
  ---@param method string
  ---@param payload table
  ---@return table
  local function request(id, method, payload)
    server:receive({ type = "request", call_id = "retained", request_id = id, method = method, payload = payload })
    ---@type table?
    local response
    assert(vim.wait(3000, function()
      for _, message in ipairs(messages) do
        if message.request_id == id and (message.type == "response" or message.type == "request_error") then
          response = message
          return true
        end
      end
      return false
    end, 5))
    return (assert(response))
  end

  it("rejects an unknown request while preserving the admitted target for later controls", function()
    assert.are.equal("response", request(1, "process_start", {
      spec = helper.spec("cat", { stdio = { kind = "pipes", stdin = "open" } }), output_bytes = 64,
    }).type)
    local rejected = request(2, "process_unknown", {})
    assert.are.equal("request_error", rejected.type)
    assert.matches("unknown process RPC method", rejected.error.message, 1, true)
    assert.are.equal("response", request(3, "process_control", { kind = "close_stdin" }).type)
    assert(vim.wait(3000, function() return server:is_quiescent() end, 5))
  end)

  it("fails the connection when its deferred failed-start completion cannot be sent", function()
    fail_completion = true
    local result = request(1, "process_start", { spec = helper.spec("exit 0"), output_bytes = 0 })
    assert.are.equal("request_error", result.type)
    assert(vim.wait(3000, function() return server:is_terminal() end, 5))
    assert.matches("completion transport failed", assert(server:failure()), 1, true)
    assert.is_true(server:is_quiescent())
  end)

  it("validates controls received from RPC before touching the retained target", function()
    assert.are.equal("response", request(1, "process_start", {
      spec = helper.spec("cat", { stdio = { kind = "pipes", stdin = "open" } }), output_bytes = 64,
    }).type)
    local rejected = request(2, "process_control", { kind = "write", data = string.rep("x", 65537) })
    assert.are.equal("request_error", rejected.type)
    assert.are.equal("process_validation", rejected.error.code)
    rejected = request(3, "process_control", { kind = "close_stdin", data = "unexpected" })
    assert.are.equal("request_error", rejected.type)
    assert.matches("unknown field", rejected.error.message, 1, true)
    assert.are.equal("response", request(4, "process_control", { kind = "write", data = "kept\n" }).type)
    local collected = request(5, "process_collect", { wait_ms = 1000, until_exit = false })
    local value = require("neoagent.rpc.process_codec").collection(collected.value, 64)
    assert.are.equal("kept\n", assert(value.events[1]).data)
    assert.is_false(value.done)
    assert.are.equal("response", request(6, "process_control", { kind = "close_stdin" }).type)
  end)
end)
