local async = require("neoagent.async")
local fake_transport = require("tests.helpers.fake_transport")
local model_catalog = require("neoagent.model_catalog")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function resolved_auth(credential_type)
  return function()
    return async.run(function()
      return {
        ok = true,
        configured = true,
        credential_type = credential_type or "api_key",
        request_opts = { headers = {
          Authorization = "Bearer stored-key",
          ["x-api-key"] = "stored-key",
        } },
      }
    end)
  end
end

local function context(provider, transport, credential_type)
  return {
    provider_id = "test",
    provider = provider,
    transport = transport,
    validator = nil,
    resolve_auth = resolved_auth(credential_type),
    resolve_api_key = function() return nil end,
  }
end

describe("bundled model catalog sources", function()
  it("discovers OpenAI IDs and enriches only conversational models", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ data = {
      { id = "gpt-5.6-sol" },
      { id = "text-embedding-4" },
    } }) } }
    local source = require("neoagent.providers.openai")
    local result = wait(source.discover_models(context({
      base_url = "https://example.test/v1",
    }, transport)))
    assert.is_true(result.ok)
    assert.are.same({
      { id = "gpt-5.6-sol" },
      { id = "text-embedding-4" },
    }, result.models)
    local transform = require("neoagent.registry.openai").transform_openai
    local model = transform(result.models[1], { provider_id = "openai" })
    assert.are.same({ "text", "image" }, model.input)
    assert.are.same({ "off", "low", "medium", "high", "xhigh", "max" },
      require("neoagent.thinking").levels(model))
    assert.is_false(transform(result.models[2], { provider_id = "openai" }))

  end)

  it("preserves Anthropic capability and effort metadata", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      data = { {
        id = "claude-future",
        type = "model",
        display_name = "Claude Future",
        max_input_tokens = 750000,
        max_tokens = 96000,
        capabilities = {
          image_input = { supported = true },
          thinking = { supported = true, types = {
            adaptive = { supported = true },
            enabled = { supported = true },
          } },
          effort = {
            supported = true,
            low = { supported = true },
            medium = { supported = false },
            high = { supported = true },
            xhigh = { supported = true },
            max = { supported = false },
          },
        },
      } },
      has_more = false,
    }) } }
    local result = wait(require("neoagent.providers.anthropic")
      .discover_models(context({
        base_url = "https://example.test/v1",
      }, transport)))
    assert.is_true(result.ok)
    assert.are.same({
      id = "claude-future",
      name = "Claude Future",
      input = { "text", "image" },
      context_window = 750000,
      max_output_tokens = 96000,
      thinking_type = "adaptive",
      reasoning_levels = { "low", "high", "xhigh" },
    }, result.models[1])
    local model = require("neoagent.registry.anthropic_common")
      .transform(result.models[1])
    assert.are.same({ "low", "high", "xhigh" },
      require("neoagent.thinking").levels(model))
    local enabled = require("neoagent.registry.anthropic_common").transform({
      id = "claude-enabled",
      thinking_type = "enabled",
      reasoning_levels = { "low", "high" },
    })
    assert.are.same({ "low", "high" },
      require("neoagent.thinking").levels(enabled))
    assert.are.equal("low", enabled.thinking.low.body.output_config.effort)
    assert.are.equal("interleaved-thinking-2025-05-14",
      enabled.request_opts.headers["anthropic-beta"])
  end)

  it("discovers DeepSeek and OpenCode Go through their distinct auth rules", function()
    local deepseek_transport = fake_transport.new()
    deepseek_transport.fetches = { { body = vim.json.encode({ data = {
      { id = "deepseek-v4-pro" },
      { id = "deepseek-v4-flash-vision-exp" },
    } }) } }
    local deepseek_result = wait(require("neoagent.providers.deepseek")
      .discover_models(context({
        base_url = "https://example.test",
      }, deepseek_transport)))
    assert.is_true(deepseek_result.ok)
    assert.are.equal("Bearer stored-key",
      deepseek_transport.fetch_requests[1].headers.Authorization)
    local deepseek_transform = require("neoagent.registry.deepseek")
      .catalog.transform_model
    local reported = deepseek_transform({
      id = "deepseek-v4-flash-vision-exp",
      input = { "text" },
      context_window = 123456,
      max_output_tokens = 23456,
    })
    assert.are.same({ "text" }, reported.input)
    assert.are.equal(123456, reported.context_window)
    assert.are.equal(23456, reported.max_output_tokens)

    local go_transport = fake_transport.new()
    go_transport.fetches = { { body = vim.json.encode({ data = {
      { id = "minimax-m3" },
    } }) } }
    local go_result = wait(require("neoagent.providers.opencode_go")
      .discover_models(context({
        base_url = "https://example.test/zen/go/v1",
      }, go_transport)))
    assert.is_true(go_result.ok)
    assert.is_nil(go_transport.fetch_requests[1].headers.Authorization)
    local transform = require("neoagent.registry.opencode_go")
      .catalog.transform_model
    assert.are.equal("anthropic-messages",
      transform(go_result.models[1]).api)

    local disconnected_transport = fake_transport.new()
    local disconnected = context({
      base_url = "https://example.test/zen/go/v1",
    }, disconnected_transport)
    disconnected.resolve_auth = function()
      return async.run(function()
        return { ok = true, configured = false }
      end)
    end
    local disconnected_result = wait(require("neoagent.providers.opencode_go")
      .discover_models(disconnected))
    assert.is_false(disconnected_result.ok)
    assert.are.equal("auth", disconnected_result.error.kind)
    assert.are.equal(0, #disconnected_transport.fetch_requests)
  end)

  it("discovers both Z.AI account catalogs", function()
    local source = require("neoagent.providers.zai")
    for _, candidate in ipairs({
      { id = "zai", base_url = "https://example.test/api/paas/v4" },
      {
        id = "zai-coding-plan",
        base_url = "https://example.test/api/coding/paas/v4",
      },
    }) do
      local transport = fake_transport.new()
      transport.fetches = { { body = vim.json.encode({
        object = "list",
        data = {
          { id = "glm-5.3", object = "model", owned_by = "z-ai" },
          { id = "glm-5.3-flash", object = "model", owned_by = "z-ai" },
        },
      }) } }
      local ctx = context({ base_url = candidate.base_url }, transport)
      ctx.provider_id = candidate.id
      local result = wait(source.discover_models(ctx))

      assert.is_true(result.ok)
      assert.are.same({
        { id = "glm-5.3" }, { id = "glm-5.3-flash" },
      }, result.models)
      assert.are.equal(candidate.base_url .. "/models",
        transport.fetch_requests[1].url)
      assert.are.equal("Bearer stored-key",
        transport.fetch_requests[1].headers.Authorization)

    end
  end)

  it("parses the account-scoped Codex catalog and revalidates with ETags", function()
    local transport = fake_transport.new()
    transport.fetches = {
      {
        headers = { ETag = "catalog-one" },
        body = vim.json.encode({ models = { {
          slug = "gpt-5.6-sol",
          display_name = "GPT-5.6 Sol",
          visibility = "list",
          input_modalities = { "text", "image" },
          context_window = 272000,
          use_responses_lite = true,
          default_verbosity = "medium",
          supported_reasoning_levels = {
            { effort = "low" }, { effort = "high" }, { effort = "max" },
            { effort = "ultra" },
            { effort = "future-effort" },
          },
          service_tiers = { "default", "priority" },
        } } }),
      },
      { status = 304, headers = { etag = "catalog-two" } },
    }
    local source = require("neoagent.providers.codex.catalog")
    local ctx = context({
      base_url = "https://chatgpt.com/backend-api",
    }, transport, "oauth")
    local result = wait(source.discover(ctx))
    assert.is_true(result.ok)
    assert.are.equal(
      "https://chatgpt.com/backend-api/codex/models?client_version=99.99.99",
      transport.fetch_requests[1].url)
    assert.are.same({ etag = "catalog-one" }, result.validator)
    assert.are.same({
      id = "gpt-5.6-sol",
      name = "GPT-5.6 Sol",
      input = { "text", "image" },
      context_window = 272000,
      responses_lite = true,
      text_verbosity = "medium",
      reasoning_levels = { "low", "high", "max", "ultra" },
      service_tiers = { "default", "priority" },
    }, result.models[1])
    local transformed = require("neoagent.registry.openai")
      .transform_codex(result.models[1])
    assert.are.same({ "low", "high", "max", "ultra" },
      require("neoagent.thinking").levels(transformed))
    ctx.validator = result.validator
    result = wait(source.discover(ctx))
    assert.is_true(result.ok)
    assert.is_true(result.unchanged)
    assert.are.same({ etag = "catalog-two" }, result.validator)
    assert.are.equal("catalog-one",
      transport.fetch_requests[2].headers["If-None-Match"])
  end)

  it("rejects malformed account-scoped Codex inventories", function()
    local source = require("neoagent.providers.codex.catalog")
    assert.is_nil(source.parse(nil))
    assert.is_nil(source.parse({ models = { 42 } }))
    assert.is_nil(source.parse({ models = { {
      slug = "invalid-visibility",
      visibility = "internal",
      supported_reasoning_levels = {},
    } } }))
    assert.is_nil(source.parse({ models = { {
      slug = "invalid-modality",
      visibility = "list",
      input_modalities = { "text", "video" },
      supported_reasoning_levels = {},
    } } }))
    assert.are.same({ {
      id = "hidden-model",
      hidden = true,
      reasoning_levels = {},
    } }, source.parse({ models = { {
      slug = "hidden-model",
      visibility = "hide",
      input_modalities = { "audio" },
      supported_reasoning_levels = {},
    } } }))

    local unauthorized = wait(source.discover(context({
      base_url = "https://chatgpt.com/backend-api",
    }, fake_transport.new(), "api_key")))
    assert.is_false(unauthorized.ok)
    assert.are.equal("auth", unauthorized.error.kind)
    assert.matches("subscription login", unauthorized.error.message)

    local cases = {
      {
        response = { status = 503, body = "unavailable" },
        message = "HTTP 503",
      },
      {
        response = { body = {} },
        message = "response is invalid",
      },
      {
        response = { body = "not json" },
        message = "invalid model catalog",
      },
    }
    for _, case in ipairs(cases) do
      local transport = fake_transport.new()
      transport.fetches = { case.response }
      local result = wait(source.discover(context({
        base_url = "https://chatgpt.com/backend-api",
      }, transport, "oauth")))
      assert.is_false(result.ok)
      assert.matches(case.message, result.error.message)
    end
  end)

  it("keeps the Codex cache when the account inventory is empty", function()
    local provider = {
      api = "openai-codex-responses",
      base_url = "https://chatgpt.com/backend-api",
      auth = "openai-codex",
    }
    local authentication = {
      resolve = resolved_auth("oauth"),
      cache_identity = function() return "safe-account-digest" end,
    }
    local definition = {
      source_id = "openai-codex-models",
      source_revision = 1,
      account_scoped = true,
      seed = { { id = "gpt-5.5" } },
      discover = require("neoagent.providers.codex.catalog").discover,
      transform_model = require("neoagent.registry.openai").transform_codex,
    }
    local cached = {
      version = 2,
      source_fingerprint = assert(model_catalog.source_fingerprint({
          provider_id = "openai-codex",
          provider = provider,
          authentication = authentication,
          definition = definition,
        })),
      validated_at = 1000,
      models = { { id = "gpt-5.5" } },
    }
    local state = { value = vim.deepcopy(cached), writes = {} }
    function state:read() return vim.deepcopy(self.value) end
    function state:write(_, value)
      self.value = vim.deepcopy(value)
      self.writes[#self.writes + 1] = vim.deepcopy(value)
      return true
    end
    local transport = fake_transport.new()
    transport.fetches = { {
      body = vim.json.encode({ models = {} }),
    } }
    local catalog = model_catalog.new({
      provider_id = "openai-codex",
      provider = provider,
      authentication = authentication,
      transport = transport,
      store = state,
      definition = definition,
    })

    local result = wait(catalog:refresh({ force = true }))
    assert.is_false(result.ok)
    assert.matches("empty", result.error.message)
    assert.are.equal("gpt-5.5", catalog:snapshot().models["gpt-5.5"].id)
    assert.are.same({}, state.writes)
    assert.are.same(cached, state.value)
    catalog:destroy()
  end)

  it("projects llama.cpp router metadata into effective Models", function()
    local transport = fake_transport.new()
    transport.fetches = { {
      body = vim.json.encode({ data = { {
        id = "local-vision",
        status = { value = "loaded" },
        meta = { n_ctx = 65536, size = 1024 },
        architecture = { input_modalities = { "text", "image" } },
      } } }),
    } }
    local source = require("neoagent.providers.llama.catalog")
    local ctx = context({
      base_url = "http://127.0.0.1:8080/v1",
      auth_optional = true,
    }, transport)
    ctx.resolve_auth = function()
      return async.run(function()
        return {
          ok = true,
          configured = true,
          metadata = { server_url = "http://router.test:9090/v1" },
        }
      end)
    end
    local result = wait(source.discover(ctx))
    assert.is_true(result.ok)
    assert.are.equal("http://router.test:9090/models",
      transport.fetch_requests[1].url)
    local model = source.transform(result.models[1])
    assert.are.equal("local-vision", model.id)
    assert.are.equal(65536, model.context_window)
    assert.are.same({ "text", "image" }, model.input)
    assert.is_nil(source.transform({
      id = "unreported",
      status = { value = "unloaded" },
    }).context_window)
    assert.is_nil(source.transform({
      id = "unreported",
      status = { value = "unloaded" },
    }).thinking)

    transport = fake_transport.new()
    transport.fetches = { {
      body = vim.json.encode({ data = {
        { id = "duplicate", status = { value = "loaded" } },
        { id = "duplicate", status = { value = "loaded" } },
      } }),
    } }
    result = wait(source.discover(context({
      base_url = "http://127.0.0.1:8080/v1",
      auth_optional = true,
    }, transport)))
    assert.is_false(result.ok)
    assert.matches("invalid model catalog", result.error.message)
  end)

  it("reloads the llama.cpp router inventory for forced discovery", function()
    local transport = fake_transport.new()
    transport.fetches = { {
      body = vim.json.encode({ data = { {
        id = "remaining-model",
        status = { value = "unloaded" },
      } } }),
    } }
    local ctx = context({
      base_url = "http://127.0.0.1:8080/v1",
      auth_optional = true,
    }, transport)
    ctx.force = true

    local result = wait(
      require("neoagent.providers.llama.catalog").discover(ctx))

    assert.is_true(result.ok)
    assert.are.same({ "remaining-model" }, vim.tbl_map(function(model)
      return model.id
    end, result.models))
    assert.are.equal("http://127.0.0.1:8080/models?reload=1",
      transport.fetch_requests[1].url)
  end)

  it("reports per-slot context for parallel llama.cpp router models", function()
    local source = require("neoagent.providers.llama.catalog")
    local function context(args)
      return source.transform({
        id = "qwen-3.6-35b",
        status = { value = "loading", args = args },
      }).context_window
    end
    assert.are.equal(262144, context({
      "llama-server", "--ctx-size", "524288", "--parallel", "2",
    }))
    assert.are.equal(524288, context({
      "llama-server", "--ctx-size=524288", "-np", "2", "--kv-unified",
    }))
    assert.are.equal(262144, context({
      "llama-server", "-c", "524288", "-np", "2", "-kvu", "-no-kvu",
    }))
    assert.are.equal(131072, context({
      "llama-server", "--kv-unified-per-slot=131072",
    }))
  end)
end)
