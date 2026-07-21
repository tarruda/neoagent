local thinking = require("neoagent.thinking")

describe("neoagent thinking levels", function()
  local model = {
    thinking = {
      off = {},
      low = { body = { reasoning_effort = "low" } },
      medium = false,
      high = function() return { body = { reasoning_effort = "high" } } end,
    },
  }

  it("orders supported request profiles and cycles them", function()
    assert.are.same({ "off", "low", "high" }, thinking.levels(model))
    assert.are.equal("low", thinking.clamp(model, "minimal"))
    assert.are.equal("high", thinking.clamp(model, "medium"))
    assert.are.equal("high", thinking.clamp(model, "xhigh"))
    assert.are.equal("off", thinking.clamp(model, "unknown"))
    assert.are.equal("high", thinking.next(model, "low"))
    assert.are.equal("off", thinking.next(model, "high"))
  end)

  it("returns independent request options and handles unsupported models", function()
    local request_opts = thinking.request_opts(model, "low")
    request_opts.body.reasoning_effort = "changed"
    assert.are.equal("low", model.thinking.low.body.reasoning_effort)
    assert.is_function(thinking.request_opts(model, "high"))
    assert.is_nil(thinking.request_opts(model, "medium"))
    assert.are.same({}, thinking.levels({}))
    assert.is_nil(thinking.clamp({}, "high"))
    assert.is_nil(thinking.next({}, "high"))
    assert.is_nil(thinking.request_opts({}, "high"))
    assert.is_true(thinking.is_level("max"))
    assert.is_false(thinking.is_level("other"))
  end)
end)
