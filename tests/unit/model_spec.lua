local assert = require("luassert")
local model_contract = require("neoagent.model")

describe("neoagent runtime Models", function()
  ---@param overrides? table<string, unknown>
  ---@return table<string, unknown>
  local function model(overrides)
    return vim.tbl_extend("force", {
      api = "fake",
      provider = "provider",
      id = "model",
      input = { "text" },
      context_window = 1000,
      max_output_tokens = 500,
      timeout_ms = 50,
      thinking = { high = { body = { effort = "high" } } },
      stream = function() end,
    }, overrides or {})
  end

  it("requires overflow evidence and honors an explicit provider classification", function()
    assert.is_false(model_contract.is_context_overflow(nil))
    assert.is_false(model_contract.is_context_overflow({ kind = "model", message = "Connection failed" }))
    assert.is_true(model_contract.is_context_overflow({ kind = "model", message = "Request rejected",
      code = "context_length_exceeded" }))
    assert.is_false(model_contract.is_context_overflow({ kind = "model", message = "request too large",
      context_overflow = false }))
  end)

  it("prioritizes structured rate limits over ambiguous context wording", function()
    assert.is_false(model_contract.is_context_overflow({ kind = "model", code = "rate_limit_exceeded",
      message = "Request too large for the token-per-minute budget" }))
    assert.is_false(model_contract.is_context_overflow({ kind = "model", code = "rate_limit_error",
      message = "Too many tokens requested this minute" }))
    assert.is_true(model_contract.is_context_overflow({ kind = "model", code = "rate_limit_exceeded",
      message = "Request too large", context_overflow = true }))
  end)

  it("validates and owns the complete capability projection", function()
    local source = model()
    local capabilities = assert(model_contract.capabilities(source))
    assert.are.equal(500, capabilities.max_output_tokens)
    capabilities.input[1] = "image"
    assert(assert(assert(capabilities.thinking).high).body).effort = "changed"
    assert.are.same({ "text" }, rawget(source, "input"))
    assert.are.equal("high", rawget(source, "thinking").high.body.effort)

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
      model({ compact = false }),
      model({ estimate_request = false }),
      model({ id = false }),
      model({ input = {} }),
      model({ input = { "image" } }),
      model({ input = { "text", "text" } }),
      model({ context_window = math.huge }),
      model({ timeout_ms = 0 }),
      model({ max_output_tokens = 0 }),
      model({ max_output_tokens = 1.5 }),
      model({ thinking = { {} } }),
      model({ thinking = { future = {} } }),
      model({ thinking = { high = "yes" } }),
    }) do
      local value, err = model_contract.validate(invalid)
      assert.is_nil(value)
      assert.are.equal("model", assert(err).kind)
    end
    local ok, err = pcall(model_contract.assert, {}, "broken factory")
    assert.is_false(ok)
    assert.matches("broken factory must return a complete Model", tostring(err))
  end)

  it("removes configured thinking tombstones from runtime values", function()
    local value = assert(model_contract.validate(model({
      thinking = { low = false, high = {} },
    })))
    assert.is_nil(assert(value.thinking).low)
    assert.are.same({}, assert(value.thinking).high)
  end)

  it("preserves a completed child's message when its parent cancels before awaiting", function()
    local original = require("tests.helpers.fake_model").assistant({ { type = "text", text = "completed output" } })
    local async = require("neoagent.async")
    local run = async.run(function(parent)
      local child = async.run(function() return original end)
      parent:cancel()
      return model_contract.await_result(child)
    end)
    assert(vim.wait(1000, function() return run:is_done() end))
    local result = assert(run:result())
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal("aborted", assert(result.message).stopReason)
    assert.are.equal("completed output", assert(assert(result.message).content[1]).text)
    assert.are.equal("stop", original.message.stopReason)
  end)
  it("does not treat context field validation as overflow", function()
    assert.is_false(require("neoagent.model").is_context_overflow({
      kind = "model",
      message = "Unsupported request parameter: context_window",
    }))
  end)

end)
