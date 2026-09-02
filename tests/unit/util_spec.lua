local util = require("neoagent.util")

describe("neoagent.util", function()
  it("deep copies cyclic tables", function()
    local value = { nested = { one = 1 } }
    value.self = value
    local copy = util.copy(value)
    assert.are_not.equal(value, copy)
    assert.are_not.equal(value.nested, copy.nested)
    assert.are.equal(copy, copy.self)
  end)

  it("recursively merges maps and replaces lists", function()
    local base = { body = { nested = { a = 1 }, list = { 1, 2 } } }
    local override = { body = { nested = { b = 2 }, list = { 3 } } }
    assert.are.same({
      body = { nested = { a = 1, b = 2 }, list = { 3 } },
    }, util.deep_merge(base, override))
    assert.are.same({ 1, 2 }, base.body.list)
  end)

  it("can merge keys case insensitively", function()
    local result = util.deep_merge(
      { Authorization = "one", Accept = "json" },
      { authorization = "two" },
      string.lower
    )
    assert.are.equal("two", result.Authorization)
    assert.are.equal("json", result.Accept)
  end)

  it("encodes JSON objects canonically across persistence round trips", function()
    local value = vim.json.decode(
      [[{"zeta":true,"items":[{"d":4,"c":3}],"alpha":{"b":2,"a":1}}]]
    )
    local expected = [[{"alpha":{"a":1,"b":2},"items":[{"c":3,"d":4}],"zeta":true}]]
    assert.are.equal(expected, util.json_encode(value))
    assert.are.equal(expected, util.json_encode(vim.json.decode(vim.json.encode(value))))
    assert.are.equal("null", util.json_encode(vim.NIL))
    local cyclic = {}
    cyclic.self = cyclic
    assert.has_error(function() util.json_encode(cyclic) end, "cannot encode circular JSON value")
    assert.has_error(function() util.json_encode({ [0] = "invalid" }) end,
      "JSON object keys must be strings")
  end)

  it("validates UTF-8 and escapes bytes that are unsafe as text", function()
    assert.is_true(util.is_valid_utf8("plain\0\té😀"))
    for _, value in ipairs({
      "\224\160\128",
      "\226\130\172",
      "\237\159\191",
      "\238\128\128",
      "\240\159\152\128",
      "\241\128\128\128",
      "\244\143\191\191",
    }) do
      assert.is_true(util.is_valid_utf8(value))
    end
    assert.is_false(util.is_valid_utf8({}))
    for _, value in ipairs({
      "\128",
      "\192\175",
      "\224\128\128",
      "\237\160\128",
      "\240\128\128\128",
      "\244\144\128\128",
      "\245\128\128\128",
      "\195(",
    }) do
      assert.is_false(util.is_valid_utf8(value))
    end
    assert.are.same({ "plain\\x00\t\n\\x1B\\xC2\\x85\\xFF\\xC3(é", 6 }, {
      util.text_from_bytes("plain\0\t\n\27\194\133\255\195(é"),
    })
  end)

  it("renders and copies every error value safely within bounds", function()
    local unrenderable = setmetatable({}, {
      __tostring = function() error("render failed") end,
    })
    assert.are.equal("fallback", util.safe_message(unrenderable, {
      fallback = "fallback",
    }))

    local source = {
      kind = "provider",
      message = "failed\255" .. string.rep("x", 5000),
      status = 429,
      metadata = { retry = true },
    }
    local normalized = util.normalize_error(source, "other")
    assert.are_not.equal(source, normalized)
    assert.are_not.equal(source.metadata, normalized.metadata)
    assert.are.equal("provider", normalized.kind)
    assert.are.equal(429, normalized.status)
    assert.is_true(util.is_valid_utf8(normalized.message))
    assert.is_true(vim.fn.strchars(normalized.message) <= 1024)

    local hostile = setmetatable({
      kind = "hostile",
      message = "plain",
    }, {
      __pairs = function() error("copy failed") end,
    })
    assert.are.same({ kind = "hostile", message = "plain" },
      util.normalize_error(hostile))

    local nested = setmetatable({ value = "safe", closure = function() end }, {
      __pairs = function() error("nested pairs must not run") end,
    })
    local cyclic = { nested = nested }
    cyclic.self = cyclic
    local bounded = util.normalize_error(setmetatable({
      kind = "provider",
      message = "failed",
      metadata = cyclic,
      retryable = true,
      status = 429,
      retry_after_ms = 25,
      provider_status_details = {
        label = string.rep("x", util.MAX_ERROR_STRING_CHARACTERS + 100),
      },
    }, { __pairs = function() error("top-level pairs must not run") end }))
    assert.is_nil(getmetatable(bounded))
    assert.is_nil(getmetatable(bounded.metadata))
    assert.is_nil(getmetatable(bounded.metadata.nested))
    assert.are.equal("safe", bounded.metadata.nested.value)
    assert.is_nil(bounded.metadata.nested.closure)
    assert.is_nil(bounded.metadata.self)
    assert.is_true(bounded.retryable)
    assert.are.equal(429, bounded.status)
    assert.are.equal(25, bounded.retry_after_ms)
    assert.is_true(vim.fn.strchars(
      bounded.provider_status_details.label)
      <= util.MAX_ERROR_STRING_CHARACTERS)
  end)

  it("bounds error messages without calling Vimscript", function()
    local original_strchars = vim.fn.strchars
    vim.fn.strchars = function()
      error("Vimscript is unavailable in this callback")
    end

    local ok, message = pcall(
      util.safe_message, string.rep("é", 1025))
    vim.fn.strchars = original_strchars

    assert.is_true(ok, tostring(message))
    assert.are.equal(string.rep("é", 1023) .. "…", message)
  end)

  it("normalizes list and message content values", function()
    assert.is_false(util.is_list("not a table"))
    assert.is_true(util.is_list(util.list()))
    local islist = vim.islist
    local tbl_islist = vim.tbl_islist
    vim.islist = nil
    vim.tbl_islist = function(value) return value[1] ~= nil end
    assert.is_true(util.is_list({ "Neovim 0.10" }))
    vim.islist = islist
    vim.tbl_islist = tbl_islist
    assert.are.equal("plain", util.text_content("plain"))
    assert.are.same({ { type = "text", text = "plain" } }, util.content_blocks("plain"))
    local content = { { type = "text", text = "copied" } }
    local blocks = util.content_blocks(content)
    blocks[1].text = "changed"
    assert.are.equal("copied", content[1].text)
  end)
end)
