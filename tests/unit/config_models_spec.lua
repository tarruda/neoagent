local it = require("tests.helpers.async_test")
local images = require("neoagent.api.images")
local attachments = require("tests.helpers.attachments").new()
local assert = require("luassert")
local config = require("neoagent.config")
local model_api = require("neoagent.models")
local provider_runtimes = require("neoagent.provider_runtimes")

---@type table<Neoagent.Config<Neoagent.AgentToolEnvironment>, Neoagent.ProviderRuntimes>
local runtime_sets = {}

---@param configured? Neoagent.Config<Neoagent.AgentToolEnvironment>
---@return Neoagent.ProviderRuntimes
local function runtimes_for(configured)
  configured = configured or config.get()
  local runtimes = runtime_sets[configured]
  if not runtimes then
    local err
    local composed
    composed, err = provider_runtimes.compose(configured, { startup = false })
    runtimes = assert(composed, err and err.message)
    runtime_sets[configured] = runtimes
  end
  return runtimes
end

local models = {}

---@param provider_id? string
---@param model_id? string
---@param configured? Neoagent.Config<Neoagent.AgentToolEnvironment>
---@param manager? Neoagent.AuthManager
---@param runtimes? Neoagent.ProviderRuntimes
---@return Neoagent.Model
function models.resolve(provider_id, model_id, configured, manager, runtimes)
  configured = configured or config.get()
  return model_api.resolve(provider_id, model_id, configured, manager,
    runtimes or runtimes_for(configured))
end

---@param configured? Neoagent.Config<Neoagent.AgentToolEnvironment>
---@param manager? Neoagent.AuthManager
---@param runtimes? Neoagent.ProviderRuntimes
function models.available(configured, manager, runtimes)
  configured = configured or config.get()
  return model_api.available(configured, manager,
    runtimes or runtimes_for(configured))
end

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@param resolved Neoagent.ResolvedApi
---@param overrides? {api?: string}
---@return Neoagent.Model
local function runtime_model(resolved, overrides)
  local value = {
    api = resolved.api,
    provider = resolved.provider_id,
    id = resolved.model_id,
    input = vim.deepcopy(resolved.model.input or { "text" }),
    context_window = resolved.model.context_window,
    thinking = resolved.model.thinking and vim.deepcopy(resolved.model.thinking) or nil,
    stream = function() error("unexpected model request") end,
  }
  return require("neoagent.model").assert(vim.tbl_extend("force", value, overrides or {}))
end

---@class Neoagent.TestConfiguredRequest: Neoagent.ApiRequest
---@field headers table<string, unknown>
---@field body Neoagent.JsonObject

---@async
---@param model Neoagent.Model
---@param opts Neoagent.StreamOptions
---@return Neoagent.TestConfiguredRequest
local function request_for(model, opts)
  local adapter = model
  while rawget(adapter, "_model") do adapter = rawget(adapter, "_model") end
  ---@cast adapter Neoagent.CompletionsModel|Neoagent.ResponsesModel|Neoagent.AnthropicModel
  local plan = adapter:_request(opts)
  local request = plan.request
  request.body = plan.encode(images.inline(plan.api, opts.files))
  assert(request.headers)
  assert(request.body)
  return request --[[@as Neoagent.TestConfiguredRequest]]
end

---@param invalid unknown
local function invalid_config(invalid)
  return config.setup(invalid --[[@as Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>]])
end

describe("neoagent configuration and model resolution", function()
  it("validates explicit prompt-cache policy without overriding disabled values", function()
    local configured = config.setup({ providers = {
      anthropic = { prompt_caching = false },
    } })
    assert.is_false(configured.providers.anthropic.prompt_caching)
    for _, field in ipairs({ "prompt_caching" }) do
      assert.has_error(function()
        invalid_config({ providers = { openai = { [field] = "disabled" } } })
      end)
    end
  end)
  ---@type string?
  local original_openai_key
  ---@type string?
  local original_deepseek_key
  ---@type string?
  local original_zai_key
  ---@type string?
  local original_anthropic_key
  ---@type string?
  local original_opencode_key
  ---@type string?
  local original_alibaba_token_plan_key

  before_each(function()
    config._reset()
    original_openai_key = vim.env.OPENAI_API_KEY
    original_deepseek_key = vim.env.DEEPSEEK_API_KEY
    original_zai_key = vim.env.ZAI_API_KEY
    original_anthropic_key = vim.env.ANTHROPIC_API_KEY
    original_opencode_key = vim.env.OPENCODE_API_KEY
    original_alibaba_token_plan_key = vim.env.BAILIAN_TOKEN_PLAN_API_KEY
    vim.env.OPENAI_API_KEY = nil
    vim.env.DEEPSEEK_API_KEY = nil
    vim.env.ZAI_API_KEY = nil
    vim.env.ANTHROPIC_API_KEY = nil
    vim.env.OPENCODE_API_KEY = nil
    vim.env.BAILIAN_TOKEN_PLAN_API_KEY = nil
  end)

  after_each(function()
    for _, runtimes in pairs(runtime_sets) do
      provider_runtimes.destroy(runtimes)
    end
    runtime_sets = {}
    config._reset()
    vim.env.OPENAI_API_KEY = original_openai_key
    vim.env.DEEPSEEK_API_KEY = original_deepseek_key
    vim.env.ZAI_API_KEY = original_zai_key
    vim.env.ANTHROPIC_API_KEY = original_anthropic_key
    vim.env.OPENCODE_API_KEY = original_opencode_key
    vim.env.BAILIAN_TOKEN_PLAN_API_KEY = original_alibaba_token_plan_key
  end)

  it("keeps setup out of direct core constructors", function()
    local model = require("neoagent.api.openai_completions").new({
      provider = "direct", model = "direct", base_url = "http://localhost/v1",
      context_window = 128000,
    })
    assert.are.equal("direct", model.id)
    assert.are.same({ "text", "image" }, model.input)
    assert.are.equal(128000, model.context_window)
  end)

  it("composes supported built-in providers through Provider Services", function()
    config.setup({})
    local configured = config.get()
    for _, id in ipairs({
      "openai", "openai-codex", "deepseek", "zai", "zai-coding-plan",
      "alibaba-token-plan", "anthropic", "opencode-go", "llama.cpp",
    }) do
      assert.is_function(configured.providers[id].service, id)
    end
    assert.is_nil(configured.providers["anthropic-plan"])
    assert.is_nil(configured.auth.methods["anthropic-plan"])
    assert.is_nil(configured.auth.methods["openai-admin"])
    assert.is_nil(configured.auth.methods["anthropic-admin"])
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
              context_window = 64000,
              max_output_tokens = 10,
              request_opts = { body = { nested = { model = true } } },
            },
          },
        },
      },
    })
    local model = models.resolve()
    local request = request_for(model, { messages = {}, tools = {} })
    assert.are.same({ provider = true, model = true }, assert(request.body).nested)
    assert.are.equal(10, assert(request.body).max_completion_tokens)
    assert.are.equal(64000, model.context_window)
  end)

  it("resolves models whose configuration explicitly disables thinking", function()
    for _, api in ipairs({
      "openai-completions", "openai-responses", "openai-codex-responses",
      "anthropic-messages", "custom",
    }) do
      local configured = config.setup({
        default_registry = false,
        providers = { local_model = {
          api = api, base_url = "http://localhost/v1", diagnostics = false,
          catalog = { seed = { { id = "plain", thinking = {
            high = { body = { reasoning_effort = "high" } },
          } } } },
          models = { plain = { thinking = false } },
        } },
        _apis = { custom = runtime_model },
      })
      local model = models.resolve("local_model", "plain", configured)
      assert.are.same({}, require("neoagent.thinking").levels(model), api)
      assert.is_nil(require("neoagent.thinking").clamp(model, "high"))
    end
  end)

  it("resolves configured Anthropic Messages models", function()
    config.setup({
      default_registry = false,
      default_model = { provider = "local-anthropic", model = "coder" },
      providers = {
        ["local-anthropic"] = {
          api = "anthropic-messages",
          base_url = "http://localhost:8080/v1",
          api_key = "local-key",
          request_opts = { body = { metadata = { provider = true } } },
          models = { coder = {
            context_window = 64000,
            max_output_tokens = 256,
            request_opts = { body = { metadata = { model = true } } },
          } },
        },
      },
    })

    local model = models.resolve()
    local request = request_for(model, { messages = {}, tools = {} })
    assert.are.same({ "local-anthropic/coder" }, assert(models.available()))
    assert.are.equal("anthropic-messages", model.api)
    assert.are.equal("http://localhost:8080/v1/messages", request.url)
    assert.are.equal("local-key", rawget(assert(request.headers), "x-api-key"))
    assert.are.equal(256, assert(request.body).max_tokens)
    assert.are.same({ provider = true, model = true }, assert(request.body).metadata)
    assert.are.equal(64000, model.context_window)
  end)

  it("resolves API factories from the internal factory map", function()
    ---@type Neoagent.ResolvedApi?
    local seen
    config.setup({
      default_model = { provider = "custom", model = "one" },
      providers = { custom = { api = "mine", models = { one = { value = 1, context_window = 4096 } } } },
      _apis = { mine = function(resolved)
        seen = resolved
        return runtime_model(resolved)
      end },
    })
    local model = models.resolve("custom", "one")
    assert.is_function(model.stream)
    assert.are.equal(1, rawget(assert(seen).model, "value"))
    assert.are.equal(4096, model.context_window)
    assert.are.same({ "text" }, model.input)
    assert.is_nil(model.thinking)
  end)

  it("lets one provider route models through different APIs", function()
    local selected = {}
    config.setup({
      default_registry = false,
      providers = {
        mixed = {
          api = "default-wire",
          models = {
            ordinary = {},
            alternate = { api = "alternate-wire" },
          },
        },
      },
      _apis = {
        ["default-wire"] = function(resolved)
          selected[#selected + 1] = resolved.api
          return runtime_model(resolved, { api = "default-wire" })
        end,
        ["alternate-wire"] = function(resolved)
          selected[#selected + 1] = resolved.api
          return runtime_model(resolved, { api = "alternate-wire" })
        end,
      },
    })

    assert.are.equal("default-wire",
      models.resolve("mixed", "ordinary").api)
    assert.are.equal("alternate-wire",
      models.resolve("mixed", "alternate").api)
    assert.are.same({ "default-wire", "alternate-wire" }, selected)
  end)

  it("supports providers whose authentication is optional", function()
    local method = require("neoagent.auth.api_key").new({ name = "Local" })
    local configured = config.setup({
      default_registry = false,
      providers = {
        local_server = {
          api = "mine",
          auth = "local-login",
          auth_optional = true,
          models = { model = {} },
        },
      },
      _apis = {
        mine = function(resolved)
          return runtime_model(resolved)
        end,
      },
      auth = { methods = {
        ["local-login"] = method,
      } },
    })
    local optional
    local manager = require("tests.helpers.auth_manager").new(configured.auth.methods)
    function manager:wrap(model, _, opts)
      optional = assert(opts).optional
      return model
    end
    assert.are.same({ "local_server/model" },
      models.available(configured, manager))
    assert(models.resolve("local_server", "model", configured, manager))
    assert.is_true(optional)
  end)

  it("resolves configured OpenAI Responses models", function()
    config.setup({
      default_registry = false,
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
    local request = request_for(resolved, { messages = {}, tools = {} })
    assert.are.equal("openai-responses", resolved.api)
    assert.are.equal("http://localhost:8080/v1/responses", request.url)
    assert.are.same({ provider = true, model = true }, assert(request.body).metadata)
    assert.are.same({ effort = "high", summary = "detailed" }, assert(request.body).reasoning)
    assert.are.equal(100, assert(request.body).max_output_tokens)
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
    assert.is_nil(resolved.thinking)
    vim.fn.delete(vim.fs.dirname(path), "rf")
  end)

  it("composes and dynamically filters the default and user registries", function()
    local path = vim.fn.tempname() .. "/auth.json"
    config.setup({
      auth = { path = path },
      providers = {
        openai = { models = {
          ["gpt-4"] = false,
          ["gpt-5.4"] = { thinking = {
            minimal = false,
            high = { body = { reasoning = { effort = "custom-high" } } },
          } },
          unlisted = {},
        }, catalog = { additions = { custom = {} } } },
        ["openai-codex"] = { models = {
          ["gpt-5.5"] = { thinking = {
            high = { body = { metadata = { user = true } } },
          } },
        }, catalog = { additions = { ["gpt-5.5"] = {} } } },
        local_provider = { api = "custom", models = { local_model = {} } },
      },
    })
    local configured = config.get()
    local providers = configured.providers
    assert.is_false(providers.openai.models["gpt-4"])
    assert.is_false(assert(providers.openai.models["gpt-5.4"].thinking).minimal)
    assert.are.equal("custom-high", assert(providers.openai.models["gpt-5.4"].thinking).high.body.reasoning.effort)
    assert.is_table(assert(providers.openai.catalog.additions).custom)
    assert.is_table(providers.openai.models.unlisted)
    local catalog_models = runtimes_for(configured)["openai-codex"]
      .catalog:snapshot().models
    assert.is_true(assert(assert(catalog_models["gpt-5.5"]
      .thinking).high.body).metadata.user)
    assert.are.same({ "local_provider/local_model" }, assert(models.available()))

    vim.env.OPENAI_API_KEY = "api-key"
    local available = assert(models.available())
    assert.is_true(vim.tbl_contains(available, "openai/custom"))
    assert.is_false(vim.tbl_contains(available, "openai/unlisted"))
    assert.is_true(vim.tbl_contains(available, "openai/gpt-5.4"))
    assert.is_false(vim.tbl_contains(available, "openai/gpt-4"))
    assert.is_false(vim.tbl_contains(available, "openai-codex/gpt-5.5"))

    assert(require("neoagent.auth.store").new(path):write("openai-codex", {
      access = "access", refresh = "refresh", expires = 9999999999999,
    }))
    available = assert(models.available())
    assert.is_true(vim.tbl_contains(available, "openai-codex/gpt-5.5"))

    config.setup({ default_registry = false, providers = {
      only = { api = "custom", models = { model = {} } },
    } })
    assert.are.same({ "only/model" }, assert(models.available()))
    vim.fn.delete(vim.fs.dirname(path), "rf")
  end)

  it("resolves the built-in DeepSeek catalog and request profile", function()
    vim.env.DEEPSEEK_API_KEY = "deepseek-key"
    config.setup({})

    local provider = config.get().providers.deepseek
    assert.are.equal("openai-completions", provider.api)
    assert.are.equal("deepseek", provider.auth)
    assert.are.equal("https://api.deepseek.com", provider.base_url)
    assert.is_function(provider.service)
    assert.are.equal(14 * 24 * 60 * 60 * 1000, provider.catalog.ttl_ms)
    local model = models.resolve("deepseek", "deepseek-v4-pro")
    local request = request_for(model, {
      messages = { { role = "assistant", content = {
        { type = "toolCall", id = "call-1", name = "inspect", arguments = { path = "x.lua" } },
      } } },
      tools = {},
      request_opts = assert(model.thinking).max,
    })
    assert.are.equal("https://api.deepseek.com/chat/completions", request.url)
    assert.are.equal("Bearer deepseek-key", rawget(assert(request.headers), "Authorization"))
    assert.are.equal(384000, assert(request.body).max_completion_tokens)
    assert.is_true(assert(request.body).stream_options.include_usage)
    assert.are.same({ type = "enabled" }, assert(request.body).thinking)
    assert.are.equal("max", assert(request.body).reasoning_effort)
    assert.are.equal("", assert(request.body).messages[1].reasoning_content)
  end)

  it("fills discovered DeepSeek metadata before applying user overrides", function()
    vim.env.DEEPSEEK_API_KEY = "deepseek-key"
    config.setup({ providers = { deepseek = { models = {
      ["deepseek-v4-flash-vision-exp"] = {
        thinking = {
          low = false,
          high = { body = {
            thinking = { type = "enabled" },
            reasoning_effort = "custom-high",
          } },
        },
      },
    } } } })
    local configured = config.get()
    local runtimes = runtimes_for(configured)
    assert(runtimes.deepseek.catalog:publish_discoveries({ {
      id = "deepseek-v4-flash-vision-exp",
      input = { "text" },
      thinking = {
        off = { body = { thinking = { type = "disabled" } } },
      },
    } }))
    local model = models.resolve("deepseek",
      "deepseek-v4-flash-vision-exp", configured, nil, runtimes)

    assert.are.same({ "text" }, model.input)
    assert.are.same({ "off", "high", "max" },
      require("neoagent.thinking").levels(model))
    local request = request_for(model, {
      messages = {}, tools = {}, request_opts = assert(model.thinking).high,
    })
    assert.are.equal("custom-high", assert(request.body).reasoning_effort)
    assert.are.same({ type = "enabled" }, assert(request.body).thinking)
  end)

  it("routes the built-in OpenCode Go catalog across its three APIs", function()
    vim.env.OPENCODE_API_KEY = "go-key"
    config.setup({})

    local provider = config.get().providers["opencode-go"]
    assert.are.equal("openai-completions", provider.api)
    assert.are.equal("https://opencode.ai/zen/go/v1", provider.base_url)
    assert.are.equal("opencode-go", provider.auth)
    assert.is_function(provider.service)

    local chat = models.resolve("opencode-go", "glm-5.3")
    local chat_request = request_for(chat, { messages = {}, tools = {} })
    assert.are.equal("openai-completions", chat.api)
    assert.are.equal("https://opencode.ai/zen/go/v1/chat/completions",
      chat_request.url)
    assert.are.equal("Bearer go-key", rawget(assert(chat_request.headers), "Authorization"))

    local responses = models.resolve("opencode-go", "gpt-5.6-luna")
    local responses_request = request_for(responses, {
      messages = {}, tools = {}, request_opts = assert(responses.thinking).high,
    })
    assert.are.equal("openai-responses", responses.api)
    assert.are.equal("https://opencode.ai/zen/go/v1/responses",
      responses_request.url)
    assert.are.equal("high", assert(responses_request.body).reasoning.effort)

    local messages = models.resolve("opencode-go", "minimax-m3")
    local messages_request = request_for(messages, {
      messages = {}, tools = {}, request_opts = assert(messages.thinking).high,
    })
    assert.are.equal("anthropic-messages", messages.api)
    assert.are.equal("https://opencode.ai/zen/go/v1/messages",
      messages_request.url)
    assert.are.equal("go-key", rawget(assert(messages_request.headers), "x-api-key"))
    assert.are.same({ type = "adaptive" }, assert(messages_request.body).thinking)

    local headers = config.get().auth.methods["opencode-go"]
      .request_opts({ type = "api_key", key = "stored-key" }).headers
    assert.are.equal("Bearer stored-key", rawget(assert(headers), "Authorization"))
    assert.are.equal("stored-key", rawget(assert(headers), "x-api-key"))
  end)

  it("downgrades images for DeepSeek text-only models", function()
    vim.env.DEEPSEEK_API_KEY = "deepseek-key"
    config.setup({})

    local model = models.resolve("deepseek", "deepseek-v4-pro")
    local request = request_for(model, {
      messages = {
        { role = "user", content = {
          { type = "text", text = "Inspect this" },
          attachments.image(vim.base64.decode("AAAA"), "image/png"),
        } },
        { role = "assistant", content = {
          { type = "toolCall", id = "call-1", name = "read_file",
            arguments = { path = "image.png" } },
        } },
        { role = "toolResult", toolCallId = "call-1", content = {
          { type = "text", text = "Read image file [image/png]" },
          attachments.image(vim.base64.decode("BBBB"), "image/png"),
        } },
      },
      tools = {},
    })

    assert.are.same({
      { type = "text", text = "Inspect this" },
      { type = "text", text = "(image omitted: model does not support images)" },
    }, assert(request.body).messages[1].content)
    assert.are.equal("tool", assert(request.body).messages[3].role)
    assert.are.equal("Read image file [image/png]\n"
      .. "(tool image omitted: model does not support images)",
      assert(request.body).messages[3].content)
    assert.are.equal(3, #assert(request.body).messages)
    assert.are.same({ "text" }, model.input)
  end)

  it("resolves the built-in Z.AI API and Plan catalogs", function()
    vim.env.ZAI_API_KEY = "zai-key"
    config.setup({})

    local provider = config.get().providers.zai
    assert.are.equal("openai-completions", provider.api)
    assert.are.equal("https://api.z.ai/api/paas/v4", provider.base_url)
    assert.are.equal("zai", provider.auth)
    assert.are.equal("Z.AI API and Plan key",
      config.get().auth.methods.zai.name)
    local plan = config.get().providers["zai-coding-plan"]
    assert.are.equal("https://api.z.ai/api/coding/paas/v4", plan.base_url)
    assert.are.equal("zai", plan.auth)

    local glm52 = models.resolve("zai-coding-plan", "glm-5.2")
    local tools = { {
      name = "inspect",
      description = "Inspect a path",
      input_schema = { type = "object", properties = { path = { type = "string" } } },
    } }
    local request = request_for(glm52, {
      messages = { { role = "user", content = "Inspect it" } },
      tools = tools,
      request_opts = assert(glm52.thinking).max,
    })
    assert.are.equal("https://api.z.ai/api/coding/paas/v4/chat/completions", request.url)
    assert.are.equal("Bearer zai-key", rawget(assert(request.headers), "Authorization"))
    assert.is_true(assert(request.body).stream_options.include_usage)
    assert.is_true(assert(request.body).tool_stream)
    assert.are.same({ type = "enabled", clear_thinking = false },
      assert(request.body).thinking)
    assert.are.equal("max", assert(request.body).reasoning_effort)

    request = request_for(glm52, {
      messages = {}, tools = {}, request_opts = assert(glm52.thinking).off,
    })
    assert.is_nil(assert(request.body).tool_stream)
    assert.are.same({ type = "disabled" }, assert(request.body).thinking)
    assert.is_nil(assert(request.body).reasoning_effort)

    local glm46v = models.resolve("zai", "glm-4.6v")
    request = request_for(glm46v, {
      messages = {}, tools = tools, request_opts = assert(glm46v.thinking).high,
    })
    assert.are.equal("https://api.z.ai/api/paas/v4/chat/completions", request.url)
    assert.is_true(assert(request.body).tool_stream)
  end)

  it("resolves the Alibaba Token Plan Personal profile", function()
    vim.env.BAILIAN_TOKEN_PLAN_API_KEY = "sk-sp-token-plan-key"
    config.setup({})

    local configured = config.get()
    local plan = assert(configured.providers["alibaba-token-plan"])
    assert.are.equal("openai-completions", plan.api)
    assert.are.equal(
      "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
      plan.base_url)
    assert.are.equal("alibaba-token-plan", plan.auth)
    assert.are.same({
      dashboard = "alibaba-token-plan-dashboard",
    }, plan.auth_scopes)
    assert.are.equal("Alibaba Cloud Token Plan API key",
      configured.auth.methods["alibaba-token-plan"].name)
    local dashboard =
      configured.auth.methods["alibaba-token-plan-dashboard"]
    assert.are.equal("Alibaba Cloud dashboard", dashboard.name)
    assert.are.equal("Login", configured.auth.methods["alibaba-token-plan"]
      .login_label)
    assert.are.equal("Logout", configured.auth.methods["alibaba-token-plan"]
      .logout_label)
    assert.are.equal("Login to dashboard (optional to see quotas)",
      dashboard.login_label)
    assert.are.equal("Logout from dashboard", dashboard.logout_label)
    assert.is_nil(configured.providers.alibaba)
    assert.is_nil(configured.providers["alibaba-coding-plan"])
    assert.is_nil(configured.auth.methods.alibaba)
    assert.is_nil(configured.auth.methods["alibaba-coding-plan"])
    assert.is_nil(plan.catalog.discover)

    local plan_models = vim.tbl_keys(
      runtimes_for(configured)["alibaba-token-plan"]
        .catalog:snapshot().models)
    table.sort(plan_models)
    assert.are.same({
      "deepseek-v4-flash-0731", "deepseek-v4-pro",
      "deepseek-v4-pro-0813", "glm-5.2", "qwen3.6-flash",
      "qwen3.7-max", "qwen3.7-plus", "qwen3.8-flash",
      "qwen3.8-max",
    }, plan_models)

    local tools = { {
      name = "inspect",
      description = "Inspect a path",
      input_schema = {
        type = "object", properties = { path = { type = "string" } },
      },
    } }
    local qwen = models.resolve("alibaba-token-plan", "qwen3.8-max")
    assert.are.same({ "off", "low", "medium", "xhigh" },
      require("neoagent.thinking").levels(qwen))
    local request = request_for(qwen, {
      messages = { { role = "assistant", content = { {
        type = "thinking", thinking = "prior reasoning",
        thinkingSignature = "reasoning_content",
      }, { type = "text", text = "prior answer" } } } },
      tools = tools,
      request_opts = assert(qwen.thinking).xhigh,
    })
    assert.are.equal(
      "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/chat/completions",
      request.url)
    assert.are.equal("Bearer sk-sp-token-plan-key",
      rawget(assert(request.headers), "Authorization"))
    assert.are.equal("neoagent", rawget(assert(request.headers), "User-Agent"))
    assert.are.same({ "text", "image" }, qwen.input)
    assert.are.equal(1000000, qwen.context_window)
    assert.are.equal(131072, assert(request.body).max_completion_tokens)
    assert.is_true(assert(request.body).enable_thinking)
    assert.are.equal("xhigh", assert(request.body).reasoning_effort)
    assert.is_true(assert(request.body).tool_stream)
    assert.is_true(assert(request.body).stream_options.include_usage)
    assert.are.equal("prior reasoning",
      assert(request.body).messages[1].reasoning_content)
    request = request_for(qwen, {
      messages = {}, tools = {}, request_opts = assert(qwen.thinking).off,
    })
    assert.is_false(assert(request.body).enable_thinking)
    assert.is_nil(assert(request.body).reasoning_effort)

    local qwen37 = models.resolve("alibaba-token-plan", "qwen3.7-plus")
    assert.are.same({ "off", "high" },
      require("neoagent.thinking").levels(qwen37))
    request = request_for(qwen37, {
      messages = {}, tools = {}, request_opts = assert(qwen37.thinking).high,
    })
    assert.is_true(assert(request.body).enable_thinking)
    assert.is_nil(assert(request.body).reasoning_effort)
    assert.is_nil(assert(request.body).tool_stream)
    request = request_for(qwen37, {
      messages = {}, tools = {}, request_opts = assert(qwen37.thinking).off,
    })
    assert.is_false(assert(request.body).enable_thinking)

    assert.are.same({ "text" },
      models.resolve("alibaba-token-plan", "qwen3.7-max").input)
    local qwen36 = models.resolve("alibaba-token-plan", "qwen3.6-flash")
    request = request_for(qwen36, { messages = {}, tools = {} })
    assert.are.equal(65536, assert(request.body).max_completion_tokens)

    local deepseek = models.resolve(
      "alibaba-token-plan", "deepseek-v4-pro-0813")
    assert.are.same({ "off", "low", "high", "max" },
      require("neoagent.thinking").levels(deepseek))
    request = request_for(deepseek, {
      messages = {}, tools = tools, request_opts = assert(deepseek.thinking).max,
    })
    assert.are.equal(393216, assert(request.body).max_completion_tokens)
    assert.are.equal("max", assert(request.body).reasoning_effort)
    assert.is_nil(assert(request.body).tool_stream)

    local current_deepseek = models.resolve(
      "alibaba-token-plan", "deepseek-v4-pro")
    assert.are.same({ "off", "high", "max" },
      require("neoagent.thinking").levels(current_deepseek))

    local flash = models.resolve(
      "alibaba-token-plan", "deepseek-v4-flash-0731")
    assert.are.same({ "off", "low", "high", "max" },
      require("neoagent.thinking").levels(flash))
    request = request_for(flash, {
      messages = {}, tools = {}, request_opts = assert(flash.thinking).low,
    })
    assert.is_true(assert(request.body).enable_thinking)
    assert.are.equal("low", assert(request.body).reasoning_effort)

    local glm = models.resolve("alibaba-token-plan", "glm-5.2")
    assert.are.equal(1048576, glm.context_window)
    request = request_for(glm, {
      messages = {}, tools = tools, request_opts = assert(glm.thinking).high,
    })
    assert.are.equal(131072, assert(request.body).max_completion_tokens)
    assert.is_true(assert(request.body).tool_stream)
    assert.are.equal("high", assert(request.body).reasoning_effort)
    request = request_for(glm, {
      messages = {}, tools = {}, request_opts = assert(glm.thinking).off,
    })
    assert.is_false(assert(request.body).enable_thinking)
    assert.is_nil(assert(request.body).reasoning_effort)
  end)

  it("applies discovered Anthropic capabilities to requests", function()
    vim.env.ANTHROPIC_API_KEY = "anthropic-key"
    config.setup({})

    local configured = config.get()
    assert.are.equal("anthropic-messages", configured.providers.anthropic.api)
    assert.are.equal("https://api.anthropic.com/v1", configured.providers.anthropic.base_url)
    assert.are.equal("anthropic", configured.providers.anthropic.auth)
    local stored_key_opts = configured.auth.methods.anthropic.request_opts({
      type = "api_key", key = "stored-anthropic",
    })
    assert.are.equal("stored-anthropic", rawget(assert(stored_key_opts.headers), "x-api-key"))
    local runtimes = runtimes_for(configured)
    assert(runtimes.anthropic.catalog:publish_discoveries({ {
      id = "claude-dynamic",
      input = { "text", "image" },
      context_window = 750000,
      max_output_tokens = 96000,
      thinking_type = "adaptive",
      reasoning_levels = { "low", "xhigh" },
    } }))

    local opus = models.resolve(
      "anthropic", "claude-dynamic", configured, nil, runtimes)
    assert.are.same({ "low", "xhigh" },
      require("neoagent.thinking").levels(opus))
    local tools = { {
      name = "inspect",
      description = "Inspect a path",
      input_schema = { type = "object", properties = { path = { type = "string" } } },
    } }
    local request = request_for(opus, {
      system_prompt = "Be concise",
      messages = { { role = "user", content = "Inspect it" } },
      tools = tools,
      request_opts = assert(opus.thinking).xhigh,
    })
    assert.are.equal("https://api.anthropic.com/v1/messages", request.url)
    assert.are.equal("anthropic-key", rawget(assert(request.headers), "x-api-key"))
    assert.are.equal(750000, opus.context_window)
    assert.are.equal(96000, assert(request.body).max_tokens)
    assert.are.same({ type = "adaptive", display = "summarized" }, assert(request.body).thinking)
    assert.are.equal("xhigh", assert(request.body).output_config.effort)
    assert.are.equal("Be concise", assert(request.body).system[1].text)
    assert.are.equal("ephemeral", assert(assert(request.body).system[1].cache_control).type)
    assert.are.equal("ephemeral", assert(assert(assert(assert(request.body).messages[1].content)[1]).cache_control).type)
    assert.is_true(assert(request.body).tools[1].eager_input_streaming)
    assert.are.equal("ephemeral", assert(assert(request.body).tools[1].cache_control).type)
    local rich_messages = { { role = "user", content = {
      { type = "text", text = "Inspect this" },
      attachments.image(vim.base64.decode("AA==")),
    } } }
    request = request_for(opus, {
      messages = rich_messages,
      files = attachments.files,
      tools = {},
      request_opts = assert(opus.thinking).low,
    })
    assert.are.equal("ephemeral",
      assert(assert(assert(assert(request.body).messages[1].content)[2]).cache_control).type)
    assert.is_nil(rawget(rich_messages[1].content[2], "cache_control"))
  end)

  it("prefers stored API keys and resumes ambient keys after logout", function()
    local path = vim.fn.tempname() .. "/auth.json"
    local ambient_calls = 0
    local seen = {}
    local async = require("neoagent.async")
    local api_key = require("neoagent.auth.api_key").new({ name = "Mixed API key" })
    local configured = config.setup({
      default_registry = false,
      auth = { path = path, methods = { mixed = api_key } },
      providers = { mixed = {
        api = "fake",
        auth = "mixed",
        api_key = function() ambient_calls = ambient_calls + 1 return "ambient-key" end,
        models = { model = {} },
      } },
      _apis = { fake = function(resolved)
        local model = runtime_model(resolved, { api = "fake" })
        function model:stream(opts)
          return async.run(function()
            local api_key = resolved.provider.api_key
            assert(type(api_key) == "function")
            local key = api_key()
            ---@type Neoagent.ApiRequest
            local request = { url = "https://provider.test", headers = {} }
            if key then request.headers = { Authorization = "Bearer " .. key } end
            request = require("neoagent.api.request_opts").apply(request, opts.request_opts, {
              model = model, messages = opts.messages, tools = opts.tools or {},
            })
            seen[#seen + 1] = rawget(assert(request.headers), "Authorization")
            return require("tests.helpers.fake_model").assistant({ { type = "text", text = "done" } })
          end)
        end
        return model
      end },
    })
    local store = require("neoagent.auth.store").new(path)
    assert(store:write("mixed", { type = "api_key", key = "stored-key" }))
    local manager = require("neoagent.auth").configured({ auth = configured.auth })
    local model = models.resolve("mixed", "model", configured, manager)
    assert.is_true(wait(model:stream({ messages = {} })).ok)
    assert.are.same({ "Bearer stored-key" }, seen)
    assert.are.equal(0, ambient_calls)

    assert.is_true(wait(manager:logout("mixed")).ok)
    local ambient_result = wait(model:stream({ messages = {} }))
    assert.is_true(ambient_result.ok, vim.inspect(ambient_result))
    assert.are.same({ "Bearer stored-key", "Bearer ambient-key" }, seen)
    assert.are.equal(1, ambient_calls)
    vim.fn.delete(vim.fs.dirname(path), "rf")
  end)

  it("uses literal API keys as optional authentication fallbacks", function()
    local path = vim.fn.tempname() .. "/auth.json"
    local configured = config.setup({
      default_registry = false,
      auth = { path = path },
      providers = { mixed = {
        api = "openai-completions",
        auth = "openai",
        api_key = "ambient-key",
        base_url = "https://example.test/v1",
        models = { model = {} },
      } },
    })

    local resolved = models.resolve("mixed", "model", configured)
    local request = request_for(resolved, { messages = {}, tools = {} })
    assert.are.equal("Bearer ambient-key", rawget(assert(request.headers), "Authorization"))
    vim.fn.delete(vim.fs.dirname(path), "rf")
  end)

  it("allows default providers to be removed and reports API key failures", function()
    config.setup({ providers = { openai = false } })
    assert.is_nil(config.get().providers.openai)
    assert.is_table(config.get().providers["openai-codex"])

    config.setup({ default_registry = false, providers = { broken = {
      api = "custom",
      api_key = function() error("key failed") end,
      models = { model = {} },
    } } })
    local available, err = models.available()
    assert.is_nil(available)
    assert.are.equal("auth", assert(err).kind)
    assert.matches("environment credential", assert(err).message)
    assert.is_not.matches("key failed", assert(err).message)
  end)

  it("validates geometry and configured identifiers", function()
    assert.are.equal(300, config.setup({}).shell_timeout)
    assert.are.equal(12.5, config.setup({ shell_timeout = 12.5 }).shell_timeout)
    assert.is_false(config.setup({ shell_timeout = false }).shell_timeout)
    assert.are.equal(7, config.setup({}).ui.input_height)
    assert.is_true(config.setup({}).ui.scroll_on_submit)
    assert.is_true(config.setup({}).ui.scroll_on_transcript_leave)
    assert.is_true(config.setup({}).ui.scroll_on_reopen)
    assert.is_nil(rawget(config.setup({}).ui.mappings, "newline"))
    assert.are.equal("<Down>", config.setup({}).ui.mappings.history_next)
    assert.are.equal("<CR>", config.setup({}).ui.mappings.card_details)
    assert.are.equal("r", config.setup({}).ui.mappings.card_raw)
    assert.are.equal("zz", config.setup({}).ui.mappings.card_center)
    assert.are.same({ "<A-k>", "<C-Up>" },
      config.setup({}).ui.mappings.card_previous)
    assert.are.same({ "<A-j>", "<C-Down>" },
      config.setup({}).ui.mappings.card_next)
    assert.are.equal("<C-w>j", config.setup({}).ui.mappings.focus_input)
    assert.are.equal("<C-w>k", config.setup({}).ui.mappings.focus_transcript)
    assert.are.equal("K", config.setup({}).ui.mappings.menu_previous)
    assert.are.equal("J", config.setup({}).ui.mappings.menu_next)
    assert.are.equal("<A-n>", config.setup({}).ui.mappings.agents)
    assert.is_nil(rawget(config.setup({}).ui.mappings, "toggle_focus"))
    assert.is_false(config.setup({}).ui.wrap_cards)
    assert.is_true(config.setup({}).ui.show_thinking)
    assert.is_true(config.setup({ ui = { wrap_cards = true } }).ui.wrap_cards)
    assert.is_false(config.setup({ ui = { show_thinking = false } }).ui.show_thinking)
    assert.are.equal("always", config.setup({}).ui.images.display)
    assert.are.equal("kitty", config.setup({
      ui = { images = { backend = "kitty" } },
    }).ui.images.backend)
    assert.is_false(config.setup({ ui = { images = false } }).ui.images)
    assert.is_true(config.setup({}).ui.completion)
    assert.is_false(config.setup({ ui = { completion = false } }).ui.completion)
    assert.are.equal(16384, config.setup({}).compaction.reserve_tokens)
    assert.are.same({ enabled = true, max_retries = 3, base_delay_ms = 2000 },
      config.setup({}).retry)
    assert.matches("/neoagent/trust.json$", (assert(config.setup({}).workspace_trust.path)))
    assert.is_false(config.setup({ workspace_trust = false }).workspace_trust)
    assert.are.equal("/tmp/custom-trust.json", config.setup({
      workspace_trust = { path = "/tmp/custom-trust.json" },
    }).workspace_trust.path)
    assert.is_false(config.setup({ compaction = false }).compaction)
    assert.are.equal(5 * 60 * 1000,
      config.setup({}).providers["llama.cpp"].catalog.ttl_ms)
    assert.are.equal(1000, config.setup({
      providers = { ["llama.cpp"] = {
        catalog = { ttl_ms = 1000 },
      } },
    }).providers["llama.cpp"].catalog.ttl_ms)
    assert.is_nil(config.setup({}).name)
    assert.has_error(function() invalid_config({ name = "" }) end)
    assert.has_error(function() invalid_config({ view = true }) end)
    assert.has_error(function() invalid_config({ default_registry = "yes" }) end)
    assert.has_error(function()
      invalid_config({ providers = { ["llama.cpp"] = {
        catalog = { ttl_ms = -1 },
      } } })
    end)
    assert.has_error(function()
      invalid_config({ providers = { ["llama.cpp"] = {
        catalog = { unknown = true },
      } } })
    end)
    assert.has_error(function()
      invalid_config({ providers = { openai = {
        catalog = { discover = function() end },
      } } })
    end)
    assert.has_error(function()
      invalid_config({ providers = { openai = {
        catalog = { source_id = "configured-models" },
      } } })
    end)
    assert.are.equal("configured-models", config.setup({
      providers = { openai = { catalog = {
        source_id = "configured-models",
        source_revision = 1,
        discover = function() error("unused discovery") end,
      } } },
    }).providers.openai.catalog.source_id)
    assert.has_error(function()
      invalid_config({ default_registry = false, providers = {
        ["../outside"] = { api = "custom", models = {} },
      } })
    end)
    assert.has_error(function() invalid_config({ shell_timeout = 0 }) end)
    assert.has_error(function() invalid_config({ shell_timeout = "slow" }) end)
    assert.has_error(function() invalid_config({ shell_timeout = math.huge }) end)
    assert.has_error(function() invalid_config({ default_thinking_level = "extreme" }) end)
    assert.has_error(function() invalid_config({ persistence = { workspace_settings = "yes" } }) end)
    assert.has_error(function() invalid_config({ workspace_trust = true }) end)
    assert.has_error(function() invalid_config({ workspace_trust = { path = "" } }) end)
    assert.has_error(function()
      invalid_config({ workspace_trust = { path = "/tmp/trust.json", extra = true } })
    end)
    ---@type Neoagent.Renderer<unknown>
    local renderer = {
      name = "custom",
      theme = require("applet").Theme.new(),
      render_block = function()
        return require("applet").Pane.nodes.text({ key = "custom", text = "custom" })
      end,
      render_details = function() end,
    }
    assert.are.equal("custom",
      assert(config.setup({ ui = { renderer = renderer } }).ui.renderer).name)
    assert.are.equal("custom", assert(config.setup({
      ui = { style = "custom", renderer = renderer },
    }).ui.renderer).name)
    assert.has_error(function()
      invalid_config({ ui = { renderer = { name = "incomplete" } } })
    end)
    assert.has_error(function() invalid_config({ ui = { style = "other" } }) end)
    assert.has_error(function() invalid_config({ ui = { width = 1.5 } }) end)
    assert.has_error(function() invalid_config({ ui = { scroll_on_submit = "yes" } }) end)
    assert.has_error(function() invalid_config({ ui = { scroll_on_transcript_leave = "yes" } }) end)
    assert.has_error(function() invalid_config({ ui = { scroll_on_reopen = "yes" } }) end)
    assert.has_error(function() invalid_config({ ui = { wrap_cards = "yes" } }) end)
    assert.has_error(function() invalid_config({ ui = { show_thinking = "yes" } }) end)
    for _, images in ipairs({
      true,
      { backend = "unknown" },
      { display = "sometimes" },
      { max_source_bytes = 1024 },
      { max_pixels = 1024 },
      { max_cache_bytes = 1024 },
      { kitty = { cell_width = 8 } },
      { unexpected = true },
      { max_source_bytes = 0 },
      { max_pixels = "many" },
      { max_cache_bytes = -1 },
      { kitty = true },
      { kitty = { cell_width = 0 } },
    }) do
      assert.has_error(function() invalid_config({ ui = { images = images } }) end)
    end
    assert.has_error(function() invalid_config({ ui = { completion = { sources = "files" } } }) end)
    assert.has_error(function() invalid_config({ ui = { completion = "files" } }) end)
    assert.has_error(function() invalid_config({ ui = { mappings = { submit = "" } } }) end)
    assert.has_error(function() invalid_config({ ui = { mappings = { submit = {} } } }) end)
    assert.has_error(function() invalid_config({ retry = false }) end)
    assert.has_error(function() invalid_config({ retry = { enabled = "yes" } }) end)
    assert.has_error(function() invalid_config({ retry = { max_retries = -1 } }) end)
    assert.has_error(function() invalid_config({ retry = { max_retries = 1.5 } }) end)
    assert.has_error(function() invalid_config({ retry = { base_delay_ms = 0 } }) end)
    assert.has_error(function() invalid_config({ compaction = true }) end)
    assert.has_error(function() invalid_config({ compaction = { auto = "yes" } }) end)
    assert.has_error(function() invalid_config({ compaction = { reserve_tokens = 0 } }) end)
    assert.has_error(function() invalid_config({ compaction = { keep_recent_tokens = 1.5 } }) end)
    assert.has_error(function() invalid_config({ compaction = { run = true } }) end)
    assert.has_error(function()
      invalid_config({ tools = { {
        name = "incomplete",
        description = "missing execution",
        input_schema = {},
      } } })
    end, "tool[1].execute must be a function")
    assert.has_error(function()
      invalid_config({ tools = {}, execute_tool = true })
    end, "execute_tool must be a function")
    assert.has_error(function()
      invalid_config({ providers = { bad = { api = "custom", api_key = 42, models = {} } } })
    end)
    assert.has_error(function()
      invalid_config({ auth = { methods = { invalid = {
        type = "oauth", name = "Invalid", login = function() end, request_opts = function() return {} end,
      } } } })
    end)
    assert.has_error(function()
      invalid_config({ auth = { methods = { invalid = {
        type = "api_key", name = "Invalid", login = function() end,
        refresh = true, request_opts = function() return {} end,
      } } } })
    end)
    assert.has_error(function()
      invalid_config({ auth = { methods = { invalid = {
        type = "api_key", name = "Invalid", login = function() end,
        login_with_ambient = "yes", request_opts = function() return {} end,
      } } } })
    end)
    assert.has_error(function()
      invalid_config({ auth = { methods = { invalid = {
        type = "api_key", name = "Invalid", login = function() end,
        validate_credential = true,
        request_opts = function() return {} end,
      } } } })
    end)
    for _, labels in ipairs({
      { login_label = true },
      { logout_label = "" },
      { login_label = "unsafe\nlabel" },
      { logout_label = string.rep("x", 129) },
    }) do
      assert.has_error(function()
        invalid_config({ auth = { methods = { invalid = {
          type = "api_key", name = "Invalid", login = function() end,
          login_label = labels.login_label,
          logout_label = labels.logout_label,
          request_opts = function() return {} end,
        } } } })
      end)
    end
    for _, auth_scopes in ipairs({
      true,
      { "key" },
      { [""] = "key" },
      { ["unsafe/scope"] = "key" },
      { inference = "key" },
      { dashboard = true },
      { dashboard = "missing" },
    }) do
      assert.has_error(function()
        invalid_config({ providers = { scoped = {
          api = "custom",
          models = {},
          auth_scopes = auth_scopes,
        } } })
      end)
    end
    config.setup({ providers = {} })
    assert.has_error(function() models.resolve("missing", "model") end)

    ---@param model unknown
    local function invalid_model(model)
      return config.setup({ providers = { bad = {
        api = "openai-responses", base_url = "http://localhost/v1", models = { bad = model --[[@as Neoagent.ModelConfigInput]] },
      } } })
    end
    assert.has_error(function() invalid_model({ reasoning = "yes" }) end)
    assert.has_error(function() invalid_model({ reasoning_effort = "" }) end)
    assert.has_error(function() invalid_model({ reasoning_summary = 1 }) end)
    assert.has_error(function() invalid_model({ reasoning_context = false }) end)
    assert.has_error(function() invalid_model({ thinking = "high" }) end)
    assert.has_error(function() invalid_model({ thinking = { extreme = {} } }) end)
    assert.has_error(function() invalid_model({ thinking = { high = "yes" } }) end)
    assert.has_error(function() invalid_model({ reasoning = true, thinking = { high = {} } }) end)
    assert.has_error(function() invalid_model({ context_window = 0 }) end)
    assert.has_error(function() invalid_model({ input = {} }) end)
    assert.has_error(function() invalid_model({ input = { "audio" } }) end)
    assert.has_error(function() invalid_model({ input = { "text", "text" } }) end)
    assert.has_error(function()
      invalid_config({ providers = { bad = {
        api = "openai-codex-responses", base_url = "http://localhost", models = {
          bad = { text_verbosity = false },
        },
      } } })
    end)
    assert.has_error(function()
      invalid_config({ providers = { bad = {
        api = "openai-codex-responses", base_url = "http://localhost", models = {
          bad = { responses_lite = "yes" },
        },
      } } })
    end)
    assert.has_error(function()
      invalid_config({ providers = { bad = {
        api = "openai-codex-responses", base_url = "http://localhost",
        diagnostics = true, models = {},
      } } })
    end)
    assert.has_error(function()
      invalid_config({ providers = { bad = {
        api = "openai-codex-responses", base_url = "http://localhost",
        diagnostics = {}, models = {},
      } } })
    end)
    assert.has_error(function()
      invalid_config({ providers = { bad = {
        api = "custom", auth = "missing", models = {},
      } } })
    end)
  end)

  it("configures or disables contextual resource locations", function()
    local configured = config.setup({
      agent_instructions = {
        global_files = { "/global/AGENTS.md" }, project_filenames = {},
      },
      skills = { global_dirs = {}, project_dirs = { "skills" } },
    })
    assert.are.same({ "/global/AGENTS.md" },
      configured.agent_instructions.global_files)
    assert.are.same({}, configured.agent_instructions.project_filenames)
    assert.are.same({}, configured.skills.global_dirs)
    assert.are.same({ "skills" }, configured.skills.project_dirs)

    configured = config.setup({ agent_instructions = false, skills = false })
    assert.is_false(configured.agent_instructions)
    assert.is_false(configured.skills)
    assert.has_error(function()
      invalid_config({ agent_instructions = "yes" })
    end)
    assert.has_error(function()
      invalid_config({ agent_instructions = { global_files = "AGENTS.md" } })
    end)
    assert.has_error(function()
      invalid_config({
        agent_instructions = { project_filenames = { false } },
      })
    end)
    assert.has_error(function() invalid_config({ skills = "yes" }) end)
    assert.has_error(function() invalid_config({ skills = { global_dirs = "skills" } }) end)
    assert.has_error(function() invalid_config({ skills = { project_dirs = { "" } } }) end)
  end)
end)
