local assert = require("luassert")
local semantic_message = require("neoagent.semantic_message")

describe("neoagent semantic messages", function()
  it("validates complete local file identities and metadata without reading bytes", function()
    local id = string.rep("a", 64)
    local original = { type = "image", file_id = id, bytes = 9,
      mime_type = "IMAGE/PNG", filename = "sample.png" }
    local normalized = assert(semantic_message.normalize_image(original))
    assert.are.equal(id, normalized.file_id)
    assert.are.equal("image/png", normalized.mime_type)
    assert.are.equal("IMAGE/PNG", original.mime_type)
    assert.are.equal("sample.png", normalized.filename)
    for _, invalid in ipairs({ "", id:sub(2), id .. "a", id:upper(), "../" .. id, string.rep("g", 64) }) do
      local value = vim.tbl_extend("force", original, { file_id = invalid })
      local image, err = semantic_message.normalize_image(value)
      assert.is_nil(image)
      assert.matches("SHA%-256", assert(err))
    end
    for _, invalid in ipairs({ 0, -1, 0.5, math.huge, "9" }) do
      local image, err = semantic_message.normalize_image(vim.tbl_extend("force", original, { bytes = invalid }))
      assert.is_nil(image)
      assert.matches("positive integer", assert(err))
    end
    for key, value in pairs({ data = "YQ==", mimeType = "image/png", provider_file_id = "file-remote" }) do
      local image, err = semantic_message.normalize_image(vim.tbl_extend("force", original, { [key] = value }))
      assert.is_nil(image)
      assert.matches("unsupported field", assert(err))
    end
    local invalid = vim.tbl_extend("force", original, { filename = 1 })
    assert.is_nil((semantic_message.normalize_image(invalid)))
  end)

  it("copies local references and keeps occurrence metadata transient", function()
    local original = { type = "image", file_id = string.rep("b", 64), bytes = 3,
      mime_type = "IMAGE/PNG", id = "preview", revision = 2 }
    local retained = assert(semantic_message.normalize_image(original))
    assert.is_nil(retained.id)
    assert.is_nil(retained.revision)
    assert.are.equal(original.file_id, retained.file_id)
    retained.filename = "copied.png"
    assert.is_nil(original.filename)
    local invalid, err = semantic_message.normalize_image(vim.tbl_extend("force", original, { mime_type = "text/plain" }))
    assert.is_nil(invalid)
    assert.matches("image media type", assert(err))
    invalid, err = semantic_message.normalize_image(vim.tbl_extend("force", original, { revision = math.huge }))
    assert.is_nil(invalid)
    assert.matches("finite text or a number", assert(err))
  end)

  it("canonicalizes empty top-level Tool arguments as a JSON object", function()
    local message = assert(semantic_message.normalize({
      role = "assistant",
      content = { {
        type = "toolCall", id = "call", name = "tool", arguments = {},
      } },
    }))
    assert.is_false(require("neoagent.util").is_list(
      assert(message.content[1]).arguments))
    assert.are.equal("{}",
      require("neoagent.util").json_encode(assert(message.content[1]).arguments))
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
    assert.are.equal("protocol", assert(err).kind)
    assert.are.equal("missing_tool_call", rawget(assert(err), "code"))
    assert.matches("declared tool use without supplying a tool call", assert(err).message)
  end)

  it("normalizes one complete linked conversation without mutating input", function()
    local messages = {
      { role = "user", content = { {
        type = "image", file_id = string.rep("c", 64), bytes = 3, mime_type = "IMAGE/PNG",
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
          type = "image", file_id = string.rep("c", 64), bytes = 3, mime_type = "IMAGE/PNG",
          id = "preview", revision = 1,
        } }, isError = false,
        details = { changed_paths = {}, optional = vim.NIL }, timestamp = 3 },
    }

    local normalized = assert(semantic_message.normalize_list(messages))

    assert.are.equal("image/png", assert(assert(normalized[1]).content[1]).mime_type)
    assert.are.equal("image/png", assert(assert(normalized[3]).content[1]).mime_type)
    assert.are.equal("IMAGE/PNG", messages[1].content[1].mime_type)
    assert(assert(assert(normalized[2]).content[3]).arguments).path = "changed"
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
        pattern = "unsupported field",
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
      assert.matches(case.pattern, (assert(err)))
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
        type = "image", file_id = string.rep("c", 64), bytes = 3, mime_type = "text/plain",
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
      assert.matches(case.pattern, (assert(err)))
    end

    local normalized, err = semantic_message.normalize_image(false)
    assert.is_nil(normalized)
    assert.matches("image block is required", (assert(err)))
    local invalid_list, list_err = semantic_message.normalize_list(vim.empty_dict())
    assert.is_nil(invalid_list)
    assert.matches("messages must be a list", (assert(list_err)))
  end)

  it("retains meaningful partial assistant output with empty signatures", function()
    local normalized = assert(semantic_message.normalize_partial_assistant({
      role = "assistant",
      content = {
        { type = "thinking", thinking = "reason", thinkingSignature = "" },
        { type = "text", text = "answer", textSignature = "" },
      },
    }))
    assert.is_nil(assert(normalized.content[1]).thinkingSignature)
    assert.is_nil(assert(normalized.content[2]).textSignature)
    assert.is_nil(semantic_message.normalize_partial_assistant(false))
  end)

  it("rejects incomplete and ill-typed Tool results", function()
    for _, case in ipairs({
      { result = false, pattern = "content blocks" },
      { result = {}, pattern = "content blocks" },
      { result = { content = {}, is_error = "yes" },
        pattern = "error state must be a boolean" },
      { result = { content = {}, unsupported = true },
        pattern = "unsupported field" },
      { result = { content = {}, details = { text = "\255" } },
        pattern = "valid UTF%-8" },
      { result = { content = {}, usage = { output = -1 } },
        pattern = "non%-negative finite" },
    }) do
      local normalized, err = semantic_message.normalize_tool_result(case.result)
      assert.is_nil(normalized)
      assert.matches(case.pattern, (assert(err)))
    end
  end)

  it("separates transient image requirements from persistent images", function()
    local direct = assert(semantic_message.normalize_image({
      type = "image", file_id = string.rep("c", 64), bytes = 3, mime_type = "IMAGE/PNG",
    }))
    assert.are.equal("image/png", direct.mime_type)

    local final = assert(semantic_message.normalize_tool_result({
      content = { {
        type = "image", file_id = string.rep("c", 64), bytes = 3, mime_type = "IMAGE/PNG",
      } },
    }))
    assert.are.equal("image/png", assert(final.content[1]).mime_type)

    local transient, err = semantic_message.normalize_tool_result({
      content = { {
        type = "image", file_id = string.rep("c", 64), bytes = 3, mime_type = "image/png",
      } },
    }, { transient = true })
    assert.is_nil(transient)
    assert.matches("transient image id", (assert(err)))

    transient = assert(semantic_message.normalize_tool_result({
      content = { {
        type = "image", file_id = string.rep("c", 64), bytes = 3, mime_type = "IMAGE/PNG",
        id = "preview", revision = "frame-1",
      } },
    }, { transient = true }))
    assert.are.equal("image/png", assert(transient.content[1]).mime_type)
  end)
end)
