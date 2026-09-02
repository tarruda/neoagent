local model_contract = require("neoagent.model")

describe("neoagent runtime Models", function()
  local function model(overrides)
    return vim.tbl_extend("force", {
      api = "fake",
      provider = "provider",
      id = "model",
      input = { "text" },
      context_window = 1000,
      timeout_ms = 50,
      thinking = { high = { body = { effort = "high" } } },
      stream = function() end,
    }, overrides or {})
  end

  it("validates and owns the complete capability projection", function()
    local source = model()
    local capabilities = assert(model_contract.capabilities(source))
    capabilities.input[1] = "image"
    capabilities.thinking.high.body.effort = "changed"
    assert.are.same({ "text" }, source.input)
    assert.are.equal("high", source.thinking.high.body.effort)

    local validated = assert(model_contract.validate(source))
    assert.are.equal(source, validated)
    assert.are_not.equal(capabilities.input, validated.input)
    assert.are.equal(source, model_contract.assert(source, "test Model"))
  end)

  it("rejects incomplete and malformed capabilities", function()
    for _, invalid in ipairs({
      model({ api = "" }),
      model({ provider = "bad\nprovider" }),
      model({ id = "" }),
      model({ stream = false }),
      model({ input = {} }),
      model({ input = { "image" } }),
      model({ input = { "text", "text" } }),
      model({ context_window = math.huge }),
      model({ timeout_ms = 0 }),
      model({ thinking = { {} } }),
      model({ thinking = { future = {} } }),
      model({ thinking = { high = "yes" } }),
    }) do
      local value, err = model_contract.validate(invalid)
      assert.is_nil(value)
      assert.are.equal("model", err.kind)
    end
    local ok, err = pcall(model_contract.assert, {}, "broken factory")
    assert.is_false(ok)
    assert.matches("broken factory must return a complete Model", err)
  end)

  it("removes configured thinking tombstones from runtime values", function()
    local value = assert(model_contract.validate(model({
      thinking = { low = false, high = {} },
    })))
    assert.is_nil(value.thinking.low)
    assert.are.same({}, value.thinking.high)
  end)
end)
