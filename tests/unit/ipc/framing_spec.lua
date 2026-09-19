local assert = require("luassert")
local framing = require("neoagent.ipc.framing")

describe("neoagent IPC framing", function()
  it("decodes fragmented, coalesced, and binary MessagePack frames", function()
    local observed = {}
    local decoder = framing.new({
      on_value = function(value)
        observed[#observed + 1] = value
      end,
    })
    local first = framing.encode({ value = "a\0b\255" })
    local second = framing.encode({ value = 42 })
    for index = 1, #first do
      decoder:feed(first:sub(index, index))
    end
    decoder:feed(second .. framing.encode({ value = false }))
    assert.is_true(decoder:finish())
    assert.are.same({
      { value = "a\0b\255" },
      { value = 42 },
      { value = false },
    }, observed)
  end)

  it("enforces exact frame bounds", function()
    local value = string.rep("x", 128)
    local payload = vim.mpack.encode(value)
    assert.is_string(framing.encode(value, #payload))
    local ok, err = pcall(framing.encode, value, #payload - 1)
    assert.is_false(ok)
    assert.matches("outside the configured bound", tostring(err))

    local decoder = framing.new({ max_frame = #payload - 1 })
    local frame = framing.encode(value, #payload) --[[@as string]]
    local feed_ok, feed_err = pcall(decoder.feed, decoder, frame)
    assert.is_false(feed_ok)
    assert.matches("invalid IPC frame length", tostring(feed_err))
  end)

  it("rejects invalid lengths, malformed payloads, and truncated input", function()
    local invalid_length = framing.new()
    local ok, err = pcall(invalid_length.feed, invalid_length, "\0\0\0\0")
    assert.is_false(ok)
    assert.matches("invalid IPC frame length", tostring(err))
    ok, err = pcall(invalid_length.feed, invalid_length, "ignored")
    assert.is_false(ok)
    assert.matches("invalid IPC frame length", tostring(err))
    local failed, failed_err = invalid_length:finish()
    assert.is_nil(failed)
    assert.are.equal("invalid IPC frame length", failed_err)

    local malformed = framing.new()
    ok, err = pcall(malformed.feed, malformed, "\0\0\0\1\193")
    assert.is_false(ok)
    assert.matches("invalid IPC MessagePack payload", tostring(err))

    local header = framing.new()
    header:feed("\0\0")
    local finished, finish_err = header:finish()
    assert.is_nil(finished)
    assert.are.equal("truncated IPC frame", finish_err)

    local payload = framing.new()
    payload:feed("\0\0\0\4ab")
    finished, finish_err = payload:finish()
    assert.is_nil(finished)
    assert.are.equal("truncated IPC frame", finish_err)
  end)
end)
