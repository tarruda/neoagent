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

  it("normalizes list and message content values", function()
    assert.is_false(util.is_list("not a table"))
    assert.is_true(util.is_list(util.list()))
    assert.are.equal("plain", util.text_content("plain"))
    assert.are.same({ { type = "text", text = "plain" } }, util.content_blocks("plain"))
    local content = { { type = "text", text = "copied" } }
    local blocks = util.content_blocks(content)
    blocks[1].text = "changed"
    assert.are.equal("copied", content[1].text)
  end)
end)
