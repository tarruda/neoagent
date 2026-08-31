local rules = require("neoagent.model_rules")
local efforts = require("neoagent.model_efforts")

describe("neoagent model rules", function()
  it("applies broad rules before family exceptions", function()
    local transform = rules.compile({
      {
        match = "^gpt%-5",
        defaults = { input = { "text", "image" }, nested = { broad = true } },
        set = { context_window = 400000 },
      },
      {
        match = "^gpt%-5%.6",
        set = {
          context_window = 1050000,
          nested = { specific = true },
        },
      },
    })
    local model = transform({ id = "gpt-5.6-sol", nested = { source = true } })
    assert.are.same({ "text", "image" }, model.input)
    assert.are.equal(1050000, model.context_window)
    assert.are.same({ source = true, broad = true, specific = true },
      model.nested)
  end)

  it("supports functional matches, field removal, and exclusion", function()
    local transform = rules.compile({
      {
        match = function(model, ctx)
          return ctx.provider_id == "example" and model.id == "keep"
        end,
        set = { obsolete = false, input = { "text" } },
      },
      {
        match = "^drop$",
        apply = function() return false end,
      },
    })
    local kept = transform({ id = "keep", obsolete = true }, {
      provider_id = "example",
    })
    assert.is_nil(kept.obsolete)
    assert.are.same({ "text" }, kept.input)
    assert.is_false(transform({ id = "drop" }, { provider_id = "example" }))
  end)

  it("returns owned values", function()
    local defaults = { nested = { value = true } }
    local transform = rules.compile({ {
      match = ".*",
      defaults = defaults,
    } })
    local first = transform({ id = "one" }, {})
    first.nested.value = false
    assert.is_true(transform({ id = "two" }, {}).nested.value)
    assert.is_true(defaults.nested.value)
  end)

  it("builds OpenAI Responses and Chat Completions effort layers", function()
    assert.are.same({
      off = { body = {
        reasoning = { effort = "none", summary = "detailed" },
        include = { "reasoning.encrypted_content" },
      } },
      high = { body = {
        reasoning = { effort = "high", summary = "detailed" },
        include = { "reasoning.encrypted_content" },
      } },
    }, efforts.openai_responses({ "off", "high" }, {
      summary = "detailed",
    }))
    assert.are.same({
      off = { body = { reasoning_effort = "disabled" } },
      high = { body = { reasoning_effort = "high" } },
    }, efforts.openai_completions({ "off", "high" }, {
      off = "disabled",
    }))
    assert.are.same({ body = { reasoning = { effort = "low" } } },
      efforts.openai_response("low", {
        summary = false,
        encrypted = false,
      }))
  end)

  it("builds thinking-completions and Anthropic effort layers", function()
    assert.are.same({
      off = { body = { thinking = { type = "disabled" } } },
      high = { body = {
        thinking = { type = "enabled" },
        reasoning_effort = "max",
      } },
    }, efforts.thinking_completions({ "off", "high" }, {
      high = "max",
    }))
    assert.are.same({ body = {
      thinking = { type = "adaptive", display = "summarized" },
      output_config = { effort = "xhigh" },
    } }, efforts.anthropic_adaptive({ "xhigh" }).xhigh)
  end)

  it("keeps effort values independently owned", function()
    local first = efforts.openai_responses({ "high" })
    first.high.body.reasoning.effort = "changed"
    first.high.body.include[1] = "changed"
    local second = efforts.openai_responses({ "high" })
    assert.are.equal("high", second.high.body.reasoning.effort)
    assert.are.equal("reasoning.encrypted_content",
      second.high.body.include[1])
    local copied = efforts.copy(second)
    copied.high.body.reasoning.summary = "changed"
    assert.are.equal("auto", second.high.body.reasoning.summary)
  end)
end)
