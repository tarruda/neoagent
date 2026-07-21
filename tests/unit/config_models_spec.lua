local config = require("neoagent.config")
local models = require("neoagent.models")

describe("neoagent configuration and model resolution", function()
  before_each(function() config._reset() end)

  it("keeps setup out of direct core constructors", function()
    local model = require("neoagent.api.openai_completions").new({
      provider = "direct", model = "direct", base_url = "http://localhost/v1",
    })
    assert.are.equal("direct", model.id)
  end)

  it("resolves configured built-in models with separate request layers", function()
    config.setup({
      default_model = { provider = "local", model = "coder" },
      providers = {
        ["local"] = {
          api = "openai-completions",
          base_url = "http://localhost:8080/v1",
          request_opts = { body = { nested = { provider = true } } },
          models = {
            coder = {
              max_output_tokens = 10,
              request_opts = { body = { nested = { model = true } } },
            },
          },
        },
      },
    })
    local model = models.resolve()
    local request = model:_request({ messages = {}, tools = {} })
    assert.are.same({ provider = true, model = true }, request.body.nested)
    assert.are.equal(10, request.body.max_completion_tokens)
  end)

  it("supports ordinary custom API factories", function()
    local seen
    config.setup({
      default_model = { provider = "custom", model = "one" },
      providers = { custom = { api = "mine", models = { one = { value = 1 } } } },
      apis = { mine = function(resolved)
        seen = resolved
        return { stream = function() end }
      end },
    })
    local model = models.resolve("custom", "one")
    assert.is_function(model.stream)
    assert.are.equal(1, seen.model.value)
  end)

  it("validates geometry and configured identifiers", function()
    assert.has_error(function() config.setup({ ui = { width = 1.5 } }) end)
    assert.has_error(function()
      config.setup({ providers = { bad = { api = "custom", api_key = 42, models = {} } } })
    end)
    config.setup({ providers = {} })
    assert.has_error(function() models.resolve("missing", "model") end)
  end)
end)
