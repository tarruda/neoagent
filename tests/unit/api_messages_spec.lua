local assert = require("luassert")
local messages = require("neoagent.api.messages")

describe("neoagent.api.messages", function()
  it("validates the full request list after request overrides", function()
    local model = { api = "openai-codex-responses", provider = "codex", id = "gpt-test", input = { "text" } }
    local native = { role = "nativeCompaction", api = model.api, provider = model.provider,
      model = model.id, encrypted_content = "synthetic-ciphertext" }
    local ok, err = pcall(messages.for_model, { native, native }, model)
    assert.is_false(ok)
    assert.matches("only one native compaction", tostring(err))
    ok, err = pcall(messages.for_model, {
      { role = "assistant", content = {} }, native,
    }, model)
    assert.is_false(ok)
    assert.matches("only user messages may precede", tostring(err))
    ok, err = pcall(messages.for_model, { native }, { api = model.api, provider = model.provider, id = "other", input = { "text" } })
    assert.is_false(ok)
    assert.matches("Encrypted context", tostring(err))
  end)
  it("preserves image input for multimodal models", function()
    local original = { { role = "user", content = {
      { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" },
    } } }

    assert.are.same(original, messages.for_model(original, { input = { "text", "image" } }))
  end)

  it("adapts foreign assistant metadata while preserving text and tool linkage", function()
    local model = { api = "openai-responses", provider = "openai", id = "gpt-5.4", input = { "text", "image" } }
    local native = {
      role = "assistant", api = model.api, provider = model.provider, model = model.id,
      content = { { type = "thinking", thinking = "Native", thinkingSignature = "native" } },
    }
    local original = {
      native,
      { role = "assistant", api = "anthropic-messages", provider = "anthropic", model = "claude-sonnet-4-6",
        content = {
          { type = "thinking", thinking = "Visible thought", thinkingSignature = "signed" },
          { type = "thinking", thinking = "", thinkingSignature = "cipher", redacted = true },
          { type = "thinking", thinking = "" },
          { type = "text", text = "Answer", textSignature = "item", phase = "commentary" },
          { type = "toolCall", id = "call", name = "read_file", arguments = { path = "README.md" } },
        } },
      { role = "toolResult", toolCallId = "call", content = { { type = "text", text = "Read" } } },
      { role = "assistant", api = model.api, provider = model.provider, model = "another-model",
        content = { { type = "thinking", thinking = "Other model", thinkingSignature = "other" } } },
    }
    local before = vim.deepcopy(original)
    local transformed = messages.for_model(original, model)
    assert.are.same(native, transformed[1])
    assert.are.same({
      { type = "text", text = "Visible thought" },
      { type = "text", text = "Answer" },
      original[2].content[5],
    }, assert(transformed[2]).content)
    assert.are.same(original[3], transformed[3])
    assert.are.same({ { type = "text", text = "Other model" } }, assert(transformed[4]).content)
    assert.are.same(before, original)
  end)

  it("replaces unsupported user and tool images without mutating history", function()
    local original = {
      { role = "user", content = {
        { type = "text", text = "before" },
        { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" },
        { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/jpeg" },
        { type = "text", text = "after" },
      } },
      { role = "assistant", content = { {
        type = "toolCall", id = "call-1", name = "inspect", arguments = {},
      } } },
      { role = "toolResult", toolCallId = "call-1", content = {
        { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" },
        { type = "text", text = "details" },
      } },
      { role = "assistant", content = { { type = "text", text = "done" } } },
    }

    local transformed = messages.for_model(original, { input = { "text" } })

    assert.are.same({
      { type = "text", text = "before" },
      { type = "text", text = "(image omitted: model does not support images)" },
      { type = "text", text = "after" },
    }, assert(transformed[1]).content)
    assert.are.same({
      { type = "text", text = "(tool image omitted: model does not support images)" },
      { type = "text", text = "details" },
    }, assert(transformed[3]).content)
    assert.are.same(original[4], transformed[4])
    assert.are.equal("image", original[1].content[2].type)
    assert.are.equal("image", original[3].content[1].type)
  end)
end)
