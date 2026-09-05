local semantic_message = require("neoagent.semantic_message")

describe("neoagent semantic messages", function()
  it("canonicalizes empty top-level Tool arguments as a JSON object", function()
    local message = assert(semantic_message.normalize({
      role = "assistant",
      content = { {
        type = "toolCall", id = "call", name = "tool", arguments = {},
      } },
    }))
    assert.is_false(require("neoagent.util").is_list(
      message.content[1].arguments))
    assert.are.equal("{}",
      require("neoagent.util").json_encode(message.content[1].arguments))
  end)

  it("requires tool-use completions to contain a Tool call", function()
    local message = {
      role = "assistant",
      content = { { type = "thinking", thinking = "I should inspect." } },
      stopReason = "toolUse",
    }
    assert(semantic_message.normalize(message))
    local normalized, err = semantic_message.normalize_model_response(message)

    assert.is_nil(normalized)
    assert.matches("declared tool use without supplying a tool call", err)
  end)

  it("normalizes one complete linked conversation without mutating input", function()
    local messages = {
      { role = "user", content = { {
        type = "image", data = "aW1hZ2U=", mimeType = "IMAGE/PNG",
      } }, timestamp = 1 },
      { role = "assistant", content = {
        { type = "thinking", thinking = "reason", thinkingSignature = "sig" },
        { type = "text", text = "calling" },
        { type = "toolCall", id = "call-1", name = "read",
          arguments = { path = "README.md", optional = vim.NIL } },
      }, provider = "fake", model = "test", stopReason = "toolUse",
        usage = { input = 1, output = 2, totalTokens = 3 }, timestamp = 2 },
      { role = "toolResult", toolCallId = "call-1", toolName = "read",
        content = { {
          type = "image", data = "cmVzdWx0", mimeType = "IMAGE/PNG",
          id = "preview", revision = 1,
        } }, isError = false,
        details = { changed_paths = {}, optional = vim.NIL }, timestamp = 3 },
    }

    local normalized = assert(semantic_message.normalize_list(messages))

    assert.are.equal("image/png", normalized[1].content[1].mimeType)
    assert.are.equal("image/png", normalized[3].content[1].mimeType)
    assert.are.equal("IMAGE/PNG", messages[1].content[1].mimeType)
    normalized[2].content[3].arguments.path = "changed"
    assert.are.equal("README.md", messages[2].content[3].arguments.path)
  end)

  it("rejects malformed persistent fields and conversation linkage", function()
    local cyclic = {}
    cyclic.self = cyclic
    local cases = {
      {
        messages = { { role = "user", content = "text", extra = true } },
        pattern = "unsupported field",
      },
      {
        messages = { { role = "user", content = { {
          type = "image", data = "not base64", mimeType = "image/png",
        } } } },
        pattern = "valid base64",
      },
      {
        messages = { { role = "assistant", content = {
          { type = "toolCall", id = "same", name = "one", arguments = {} },
          { type = "toolCall", id = "same", name = "two", arguments = {} },
        } } },
        pattern = "duplicate toolCall",
      },
      {
        messages = { { role = "toolResult", toolCallId = "missing",
          content = {} } },
        pattern = "unknown toolCall",
      },
      {
        messages = {
          { role = "assistant", content = { {
            type = "toolCall", id = "call", name = "one", arguments = {},
          } } },
          { role = "toolResult", toolCallId = "call", toolName = "two",
            content = {} },
        },
        pattern = "does not match",
      },
      {
        messages = { { role = "toolResult", toolCallId = "call",
          content = {}, details = cyclic } },
        pattern = "cycles",
      },
      {
        messages = { { role = "assistant", content = {},
          usage = { output = math.huge } } },
        pattern = "non%-negative finite",
      },
    }
    for _, case in ipairs(cases) do
      local normalized, err = semantic_message.normalize_list(case.messages)
      assert.is_nil(normalized)
      assert.matches(case.pattern, err)
    end
  end)

  it("rejects every malformed canonical scalar and JSON boundary", function()
    local cases = {
      { value = { role = "assistant", content = { {
        type = "text", text = "value", index = -1,
      } } }, pattern = "non%-negative integer" },
      { value = { role = "assistant", content = { {
        type = "thinking", thinking = "\255",
      } } }, pattern = "UTF%-8 string" },
      { value = { role = "assistant", content = { {
        type = "thinking", thinking = "value", redacted = "yes",
      } } }, pattern = "redacted must be a boolean" },
      { value = { role = "user", content = { {
        type = "image", data = "aW1hZ2U=", mimeType = "text/plain",
      } } }, pattern = "image media type" },
      { value = { role = "assistant", content = {}, timestamp = -1 },
        pattern = "timestamp must be a non%-negative integer" },
      { value = { role = "assistant", content = {}, errorMessage = false },
        pattern = "errorMessage must be a UTF%-8 string" },
      { value = { role = "assistant", content = {},
        usage = { cost = { input = -1 } } },
        pattern = "cost input must be a non%-negative finite number" },
      { value = { role = "toolResult", toolCallId = "call", content = {},
        isError = "yes" }, pattern = "isError must be a boolean" },
      { value = { role = "toolResult", toolCallId = "call", content = {},
        details = { text = "\255" } }, pattern = "valid UTF%-8" },
      { value = { role = "toolResult", toolCallId = "call", content = {},
        details = { [true] = "value" } }, pattern = "object keys" },
    }
    for _, case in ipairs(cases) do
      local normalized, err = semantic_message.normalize(case.value)
      assert.is_nil(normalized)
      assert.matches(case.pattern, err)
    end

    local normalized, err = semantic_message.normalize_image(false)
    assert.is_nil(normalized)
    assert.matches("image block is required", err)
    normalized, err = semantic_message.normalize_list(vim.empty_dict())
    assert.is_nil(normalized)
    assert.matches("messages must be a list", err)
  end)

  it("retains meaningful partial assistant output with empty signatures", function()
    local normalized = assert(semantic_message.normalize_partial_assistant({
      role = "assistant",
      content = {
        { type = "thinking", thinking = "reason", thinkingSignature = "" },
        { type = "text", text = "answer", textSignature = "" },
      },
    }))
    assert.is_nil(normalized.content[1].thinkingSignature)
    assert.is_nil(normalized.content[2].textSignature)
    assert.is_nil(semantic_message.normalize_partial_assistant(false))
  end)

  it("rejects incomplete and ill-typed Tool results", function()
    for _, case in ipairs({
      { result = false, pattern = "content blocks" },
      { result = {}, pattern = "content blocks" },
      { result = { content = {}, is_error = "yes" },
        pattern = "error state must be a boolean" },
    }) do
      local normalized, err = semantic_message.normalize_tool_result(case.result)
      assert.is_nil(normalized)
      assert.matches(case.pattern, err)
    end
  end)

  it("separates transient image requirements from persistent images", function()
    local direct = assert(semantic_message.normalize_image({
      type = "image", data = "ZGlyZWN0", mimeType = "IMAGE/PNG",
    }))
    assert.are.equal("image/png", direct.mimeType)

    local final = assert(semantic_message.normalize_tool_result({
      content = { {
        type = "image", data = "ZmluYWw=", mimeType = "IMAGE/PNG",
      } },
    }))
    assert.are.equal("image/png", final.content[1].mimeType)

    local transient, err = semantic_message.normalize_tool_result({
      content = { {
        type = "image", data = "ZnJhbWU=", mimeType = "image/png",
      } },
    }, { transient = true })
    assert.is_nil(transient)
    assert.matches("transient image id", err)

    transient = assert(semantic_message.normalize_tool_result({
      content = { {
        type = "image", data = "ZnJhbWU=", mimeType = "IMAGE/PNG",
        id = "preview", revision = "frame-1",
      } },
    }, { transient = true }))
    assert.are.equal("image/png", transient.content[1].mimeType)
  end)
end)
