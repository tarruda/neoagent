local messages = require("neoagent.api.messages")

describe("neoagent.api.messages", function()
  it("preserves image input for multimodal models", function()
    local original = { { role = "user", content = {
      { type = "image", mimeType = "image/png", data = "AAAA" },
    } } }

    assert.are.equal(original, messages.for_model(original, { input = { "text", "image" } }))
  end)

  it("replaces unsupported user and tool images without mutating history", function()
    local original = {
      { role = "user", content = {
        { type = "text", text = "before" },
        { type = "image", mimeType = "image/png", data = "AAAA" },
        { type = "image", mimeType = "image/jpeg", data = "BBBB" },
        { type = "text", text = "after" },
      } },
      { role = "toolResult", toolCallId = "call-1", content = {
        { type = "image", mimeType = "image/png", data = "CCCC" },
        { type = "text", text = "details" },
      } },
      { role = "assistant", content = { { type = "text", text = "done" } } },
    }

    local transformed = messages.for_model(original, { input = { "text" } })

    assert.are.same({
      { type = "text", text = "before" },
      { type = "text", text = "(image omitted: model does not support images)" },
      { type = "text", text = "after" },
    }, transformed[1].content)
    assert.are.same({
      { type = "text", text = "(tool image omitted: model does not support images)" },
      { type = "text", text = "details" },
    }, transformed[2].content)
    assert.are.equal(original[3], transformed[3])
    assert.are.equal("image", original[1].content[2].type)
    assert.are.equal("image", original[2].content[1].type)
  end)
end)
