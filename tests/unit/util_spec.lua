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
