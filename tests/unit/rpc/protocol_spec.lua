local assert = require("luassert")
local protocol = require("neoagent.rpc.protocol")

describe("RPC envelopes", function()
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

  end)
end)
