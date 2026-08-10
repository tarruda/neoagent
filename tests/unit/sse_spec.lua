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

  it("bounds a complete multiline event", function()
    local parser = sse.new({
      on_event = function() error("oversized event was dispatched") end,
      max_buffer = 1024,
      max_event_bytes = 7,
    })
    local ok, err = parser:feed("data: 1234\ndata: 5678\n")
    assert.is_nil(ok)
    assert.matches("event exceeded", err)
  end)

  it("resets the event byte limit after dispatch", function()
    local events = {}
    local parser = sse.new({
      on_event = function(value) events[#events + 1] = value end,
      max_event_bytes = 4,
    })
    assert(parser:feed("data: 1234\n\ndata: 5678\n\n"))
    assert.are.same({ "1234", "5678" }, events)
  end)

  it("flushes an unterminated event once and then remains closed", function()
    local events = {}
    local parser = sse.new({ on_event = function(value) events[#events + 1] = value end })
    assert(parser:feed("data: final"))
    assert(parser:finish())
    assert(parser:finish())
    local ok, err = parser:feed("data: late\n\n")
    assert.is_nil(ok)
    assert.matches("closed", err)
    assert.are.same({ "final" }, events)
  end)
end)
