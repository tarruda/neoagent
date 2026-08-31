local tool_schema = require("neoagent.api.tool_schema")

describe("neoagent.api.tool_schema", function()
  local schema = {
    type = "object",
    properties = {
      choice = { type = "string", enum = { "one", "two" } },
      count = { type = "number" },
      enabled = { type = "boolean" },
      entries = {
        type = "array",
        minItems = 2,
        maxItems = 3,
        items = {
          type = "object",
          properties = { name = { type = "string" } },
          required = { "name" },
          additionalProperties = false,
        },
      },
      extra_values = {
        type = "object",
        additionalProperties = { type = "integer" },
      },
      maybe = { type = { "string", "null" } },
      missing = { type = "boolean" },
    },
    required = { "choice", "missing" },
    additionalProperties = false,
  }

  it("accepts values matching the supported tool schema vocabulary", function()
    local valid, message = tool_schema.validate(schema, {
      choice = "one",
      count = 2.5,
      enabled = true,
      entries = { { name = "first" }, { name = "second" } },
      extra_values = { first = 1, second = 2 },
      maybe = vim.NIL,
      missing = true,
    })

    assert.is_true(valid)
    assert.is_nil(message)
  end)

  it("aggregates deterministic path-aware schema mismatches", function()
    local valid, message = tool_schema.validate(schema, {
      choice = "three",
      count = "many",
      enabled = 1,
      entries = {
        { name = 1, extra = true },
        {},
        { name = "third" },
        { name = "fourth" },
      },
      extra_values = { bad = 1.5, good = 1 },
      maybe = vim.NIL,
      ["bad-key"] = true,
      unexpected = true,
    })

    assert.is_false(valid)
    assert.are.equal(table.concat({
      "Tool call arguments do not match the declared schema:",
      "- missing is required",
      "- choice must be one of \"one\" or \"two\"",
      "- count must be a number",
      "- enabled must be a boolean",
      "- entries must contain at most 3 items",
      "- entries[1].name must be a string",
      "- entries[1].extra is not allowed",
      "- entries[2].name is required",
      "- extra_values.bad must be an integer",
      "- [\"bad-key\"] is not allowed",
      "- unexpected is not allowed",
    }, "\n"), message)
  end)

  it("disambiguates empty arrays and bounds issue lists", function()
    local valid, message = tool_schema.validate({
      type = "array",
      minItems = 2,
    }, {})
    assert.is_false(valid)
    assert.matches("arguments must contain at least 2 items", message)

    valid, message = tool_schema.validate({ enum = { true } }, false)
    assert.is_false(valid)
    assert.matches("arguments must be one of true", message)

    local required = {}
    for index = 1, 21 do required[index] = "field_" .. index end
    valid, message = tool_schema.validate({
      type = "object",
      required = required,
    }, {})
    assert.is_false(valid)
    assert.matches("field_20 is required", message)
    assert.is_nil(message:find("field_21 is required", 1, true))
    assert.matches("Further schema mismatches were omitted", message)
  end)
end)
