local sse = require("neoagent.transport.sse")

describe("neoagent.transport.sse", function()
  it("parses fragmented CRLF and multiline data", function()
    local events = {}
    local parser = sse.new({ on_event = function(value) events[#events + 1] = value end })
    assert(parser:feed(": hello\r"))
    assert(parser:feed("\ndata: first\r\ndata: second\r"))
    assert(parser:feed("\n\r\n"))
    parser:finish()
    assert.are.same({ "first\nsecond" }, events)
  end)

  it("works at every byte split", function()
    local input = "data: one\n\ndata: two\r\n\r\n"
    for split = 0, #input do
      local events = {}
      local parser = sse.new({ on_event = function(value) events[#events + 1] = value end })
      assert(parser:feed(input:sub(1, split)))
      assert(parser:feed(input:sub(split + 1)))
      parser:finish()
      assert.are.same({ "one", "two" }, events)
    end
  end)

  it("bounds an unterminated line", function()
    local parser = sse.new({ on_event = function() end, max_buffer = 4 })
    local ok, err = parser:feed("12345")
    assert.is_nil(ok)
    assert.matches("exceeded", err)
  end)
end)
