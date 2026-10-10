local assert = require("luassert")
local buffers = require("neoagent.process_sessions.buffer")

describe("retained process output", function()
  it("keeps the exact tail and stream order when a limit cuts an earlier event", function()
    local buffer = buffers.new(8)
    buffer.append({ stream = "stdout", data = "abcdef" })
    buffer.append({ stream = "stderr", data = "1234" })
    buffer.append({ stream = "pty", data = "" })
    local snapshot = buffer.snapshot()
    assert.are.same({
      { stream = "stdout", data = "cdef" },
      { stream = "stderr", data = "1234" },
    }, snapshot)
    local first = assert(snapshot[1])
    first.data = "changed"
    local events, dropped = buffer.take()
    assert.are.equal("cdef", assert(events[1]).data)
    assert.are.equal(2, dropped)
    assert.is_true(buffer.empty())
    local again, lost = buffer.take()
    assert.are.same({}, again)
    assert.are.equal(0, lost)
  end)

  it("bounds event overhead independently of the byte budget", function()
    local buffer = buffers.new(1024)
    for _ = 1, 130 do buffer.append({ stream = "stdout", data = "x" }) end
    local events, dropped = buffer.take()
    assert.are.equal(128, #events)
    assert.are.equal(2, dropped)
  end)
end)
