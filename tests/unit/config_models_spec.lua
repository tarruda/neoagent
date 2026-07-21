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

  it("resolves configured OpenAI Responses models", function()
    config.setup({
      default_model = { provider = "openai", model = "reasoning" },
      providers = {
        openai = {
          api = "openai-responses",
          base_url = "http://localhost:8080/v1",
          request_opts = { body = { metadata = { provider = true } } },
          models = { reasoning = {
            reasoning = true,
            reasoning_effort = "high",
            reasoning_summary = "detailed",
            max_output_tokens = 100,
            request_opts = { body = { metadata = { model = true } } },
          } },
        },
      },
    })
    local resolved = models.resolve()
    local request = resolved:_request({ messages = {}, tools = {} })
    assert.are.equal("openai-responses", resolved.api)
    assert.are.equal("http://localhost:8080/v1/responses", request.url)
    assert.are.same({ provider = true, model = true }, request.body.metadata)
    assert.are.same({ effort = "high", summary = "detailed" }, request.body.reasoning)
    assert.are.equal(100, request.body.max_output_tokens)
  end)

  it("resolves Codex Responses models through configured authentication", function()
    local path = vim.fn.tempname() .. "/auth.json"
    local method = {
      name = "Plan",
      login = function() end,
      refresh = function() end,
      request_opts = function(credential)
        return { headers = { Authorization = "Bearer " .. credential.access } }
      end,
    }
    config.setup({
      auth = { path = path, methods = { plan = method } },
      providers = { codex = {
        api = "openai-codex-responses",
        base_url = "https://chatgpt.com/backend-api",
        auth = "plan",
        models = { coder = { reasoning = true, text_verbosity = "low" } },
      } },
      default_model = { provider = "codex", model = "coder" },
    })
    assert(require("neoagent.auth.store").new(path):write("plan", {
      access = "token", refresh = "refresh", expires = 9999999999999,
    }))
    local resolved = models.resolve()
    assert.are.equal("openai-codex-responses", resolved.api)
    assert.are.equal("codex", resolved.provider)
    vim.fn.delete(vim.fs.dirname(path), "rf")
  end)

  it("validates geometry and configured identifiers", function()
    assert.has_error(function() config.setup({ ui = { width = 1.5 } }) end)
    assert.has_error(function()
      config.setup({ providers = { bad = { api = "custom", api_key = 42, models = {} } } })
    end)
    config.setup({ providers = {} })
    assert.has_error(function() models.resolve("missing", "model") end)

    local function invalid_model(model)
      return config.setup({ providers = { bad = {
        api = "openai-responses", base_url = "http://localhost/v1", models = { bad = model },
      } } })
    end
    assert.has_error(function() invalid_model({ reasoning = "yes" }) end)
    assert.has_error(function() invalid_model({ reasoning_effort = "" }) end)
    assert.has_error(function() invalid_model({ reasoning_summary = 1 }) end)
    assert.has_error(function()
      config.setup({ providers = { bad = {
        api = "openai-codex-responses", base_url = "http://localhost", models = {
          bad = { text_verbosity = false },
        },
      } } })
    end)
    assert.has_error(function()
      config.setup({ providers = { bad = {
        api = "custom", auth = "missing", models = {},
      } } })
    end)
  end)
end)
