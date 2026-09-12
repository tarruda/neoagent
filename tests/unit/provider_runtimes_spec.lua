local assert = require("luassert")
local async = require("neoagent.async")
local provider_runtimes = require("neoagent.provider_runtimes")
local provider_service = require("neoagent.provider_service")

describe("neoagent provider runtime composition", function()
  ---@param id string
  ---@param constructor? fun(id: string, config: Neoagent.ProviderCompositionConfig, resources: Neoagent.ProviderCompositionResources): Neoagent.ProviderService
  ---@return Neoagent.ProviderDefinition
  local function provider(id, constructor)
    return {
      api = "fake",
      catalog = { seed = { { id = "model" } } },
      models = {},
      service = constructor and function(projection, resources)
        return constructor(id, projection, resources)
      end or nil,
    }
  end

  it("constructs one catalog and service per provider", function()
    ---@type Neoagent.ProviderCompositionConfig?
    local projection
    ---@type Neoagent.ProviderCompositionResources?
    local resources
    local configured = { providers = {
      managed = provider("managed", function(id, seen, supplied)
        projection, resources = seen, supplied
        return {
          id = id,
          name = "Managed",
          state = function() return false end,
          operations = {},
        }
      end),
      plain = provider("plain"),
    } }
    configured.providers.managed.api_key = "secret"
    configured.providers.managed.request_opts = {
      headers = { Authorization = "secret" },
    }
    configured.providers.managed.service_opts = { region = "local" }
    configured.providers.managed.auth_scopes = { dashboard = "dashboard" }
    local runtimes = assert(provider_runtimes.compose(configured, {
      startup = false,
    }))
    assert.are.equal("model",
      assert(runtimes.managed).catalog:snapshot().models.model.id)
    assert.are.equal("model", assert(runtimes.plain).catalog:snapshot().models.model.id)
    assert.are.equal("plain", assert(runtimes.plain).service.id)
    assert.are.equal("fake", assert(projection).api)
    assert.are.same({ region = "local" }, assert(projection).service_opts)
    assert.are.same({ dashboard = "dashboard" }, assert(projection).auth_scopes)
    assert.is_nil(rawget(assert(projection), "api_key"))
    assert.is_nil(rawget(assert(projection), "request_opts"))
    assert.are.equal(assert(runtimes.managed).catalog, assert(resources).catalog)
    assert.are.equal("secret", assert(assert(resources).ambient_api_key)())
    provider_runtimes.destroy(runtimes)
  end)

  it("shares explicit catalog additions with the owning Provider Service", function()
    local definition = assert(require("neoagent.registry").defaults()["llama.cpp"])
    definition.catalog.additions = {
      qwen = {
        hf_repo = "owner/repo",
        quantization = "Q4_0",
        context_window = 65536,
      },
    }
    local runtimes = assert(provider_runtimes.compose({ providers = {
      ["llama.cpp"] = definition,
    } }, { startup = false }))

    local runtime = assert(runtimes["llama.cpp"])
    assert.are.equal(65536,
      runtime.catalog:snapshot().models.qwen.context_window)
    assert.are.same({ "qwen" }, assert(assert(runtime.service.operations.download).complete)("", ""))
    provider_runtimes.destroy(runtimes)
  end)

  it("attributes model and shared provider HTTP transports", function()
    local catalog_context
    local service_context
    ---@param context? Neoagent.RequestIdentity
    ---@return Neoagent.ByteBackend
    local function contextual(context)
      local value = require("tests.helpers.fake_transport").new()
      local identity = vim.deepcopy(context or {})
      rawset(value, "context", identity)
      value.with_context = function(extra)
        return contextual(vim.tbl_extend(
          "force", vim.deepcopy(identity), vim.deepcopy(extra or {})))
      end
      return value
    end
    local configured = { providers = {
      managed = provider("managed", function(id, _, resources)
        service_context = rawget(assert(resources.transport), "context")
        return {
          id = id,
          name = "Managed",
          state = function() return false end,
          operations = {},
        }
      end),
    } }
    configured.providers.managed.catalog = {
      source_id = "managed-models",
      source_revision = 1,
      discover = function(resources)
        catalog_context = rawget(assert(resources.transport), "context")
        return async.run(function()
          return { ok = true, models = { { id = "model" } } }
        end)
      end,
    }
    local runtimes = assert(provider_runtimes.compose(configured, {
      startup = false,
      transport = contextual(),
    }))

    assert.are.same({
      provider = "managed", origin = "model",
    }, rawget(assert(assert(runtimes.managed).transport), "context"))
    assert.are.same({
      provider = "managed", origin = "provider-shell",
    }, service_context)
    local refresh = assert(runtimes.managed).catalog:refresh()
    assert(vim.wait(1000, function() return refresh:is_done() end))
    assert.is_true(assert(refresh:result()).ok)
    assert.are.same({
      provider = "managed", origin = "catalog",
    }, catalog_context)
    provider_runtimes.destroy(runtimes)
  end)

  it("enables every ambient API-key account catalog cache", function()
    local config = require("neoagent.config")
    local configured = config.setup({})
    local values = {
      OPENAI_API_KEY = "openai-secret",
      ANTHROPIC_API_KEY = "anthropic-secret",
      DEEPSEEK_API_KEY = "deepseek-secret",
      ZAI_API_KEY = "zai-secret",
    }
    for name, value in pairs(values) do vim.env[name] = value end
    local credential_store = {
      read = function() return nil end,
      write = function() return true end,
    }
    local manager = require("neoagent.auth").new({
      methods = configured.auth.methods,
      store = credential_store,
    })
    local catalog_store = {
      read = function() return nil end,
      write = function() return true end,
    }

    local ok, err = pcall(function()
      local runtimes = assert(provider_runtimes.compose(configured, {
        auth = manager,
        store = catalog_store,
        startup = false,
      }))
      for _, id in ipairs({
        "openai", "anthropic", "deepseek", "zai", "zai-coding-plan",
      }) do
        local persistence = assert(runtimes[id]).catalog:snapshot().persistence
        assert.is_true(persistence.configured, id)
        assert.is_true(persistence.enabled, id)
        assert.is_nil(persistence.error, id)
      end
      provider_runtimes.destroy(runtimes)
    end)
    for name in pairs(values) do vim.env[name] = nil end
    config._reset()
    assert(ok, err)
  end)

  it("scopes llama.cpp caches to stored server identity", function()
    local config = require("neoagent.config")
    local configured = config.setup({})
    ---@type Neoagent.ApiKeyCredential?
    local credential = {
      type = "api_key",
      key = "anonymous",
      env = {
        LLAMA_BASE_URL = "http://first.example.test",
        LLAMA_ANONYMOUS = "1",
      },
    }
    local credential_store = {
      read = function(_, id)
        return id == "llama" and require("neoagent.util").copy(credential) or nil
      end,
      write = function() return true end,
    }
    local manager = require("neoagent.auth").new({
      methods = configured.auth.methods,
      store = credential_store,
    })
    local provider = assert(configured.providers["llama.cpp"])
    local ProviderCredentials = require("neoagent.provider_credentials")
    local credentials = ProviderCredentials.new({
      provider_id = "llama.cpp",
      provider = provider,
      authentication = manager,
      method = configured.auth.methods.llama,
    })
    local first = assert(require("neoagent.model_catalog").source_fingerprint({
      provider_id = "llama.cpp",
      provider = provider,
      definition = provider.catalog,
      credentials = credentials,
    }))
    assert(assert(credential).env).LLAMA_BASE_URL = "http://second.example.test"
    local second = assert(require("neoagent.model_catalog").source_fingerprint({
      provider_id = "llama.cpp",
      provider = provider,
      definition = provider.catalog,
      credentials = credentials,
    }))
    assert.are_not.equal(first, second)

    credential = nil
    assert(require("neoagent.model_catalog").source_fingerprint({
      provider_id = "llama.cpp",
      provider = provider,
      definition = provider.catalog,
      credentials = credentials,
    }))
    config._reset()
  end)

  it("destroys partial compositions after constructor failures", function()
    local destroyed = 0
    local configured = { providers = {
      first = provider("first", function(id)
        return {
          id = id,
          name = "First",
          state = function() return false end,
          operations = {},
          destroy = function() destroyed = destroyed + 1 end,
        }
      end),
      second = provider("second", function()
        error("constructor failed")
      end),
    } }
    local runtimes, err = provider_runtimes.compose(configured, {
      startup = false,
    })
    assert.is_nil(runtimes)
    assert.matches("constructor failed", tostring(assert(err).detail))
    assert.are.equal(1, destroyed)
  end)

  it("rejects service identity and contract violations", function()
    local destroyed = 0
    local configured = { providers = {
      wrong = provider("wrong", function()
        return {
          id = "other",
          name = "Other",
          state = function() return false end,
          operations = {},
          destroy = function() destroyed = destroyed + 1 end,
        }
      end),
    } }
    local runtimes, err = provider_runtimes.compose(configured, {
      startup = false,
    })
    assert.is_nil(runtimes)
    assert.matches("id", assert(err).message)
    assert.are.equal(1, destroyed)

    configured.providers.wrong.service = function()
      return {
        id = "wrong",
        name = "Wrong",
        state = function() return false end,
        operations = {},
        inventory = {},
      }
    end
    runtimes, err = provider_runtimes.compose(configured, { startup = false })
    assert.is_nil(runtimes)
    assert.matches("unsupported Provider Service field", assert(err).message)
  end)

  it("disposes constructed Services when file-runtime construction fails", function()
    local uploads = require("neoagent.providers.file_uploads")
    local original, destroyed = uploads.new, 0
    uploads.new = function() error("synthetic file construction failure") end
    local ok, value, err = pcall(provider_runtimes.compose, {providers = {
      managed = provider("managed", function(id)
        return {id = id, name = "Managed", state = function() return false end, operations = {},
          destroy = function() destroyed = destroyed + 1 end}
      end),
    }}, {startup = false})
    uploads.new = original
    assert.is_true(ok)
    assert.is_nil(value)
    assert.matches("Failed to construct file uploads", assert(err).message)
    assert.are.equal(1, destroyed)
  end)

  it("declines file preparation for unsupported DeepSeek protocols", function()
    ---@type Neoagent.ProviderDefinition
    local definition = {
      api = "openai-responses",
      base_url = "https://api.deepseek.com",
      auth = "deepseek",
      catalog = { seed = {} },
      models = {},
    }
    ---@type Neoagent.ProviderService
    local service = {
      id = "deepseek",
      name = "DeepSeek",
      operations = {},
      state = function() return false end,
    }
    local uploads = assert(require("neoagent.providers.file_uploads").new(
      "deepseek",
      definition,
      service,
      { auth_type = "api_key" }
    ))

    assert.is_nil(uploads.bind("future-api", {
      id = "vision",
      input = { "text", "image" },
    }))
  end)

  it("owns idempotent runtime destruction", function()
    assert.is_nil(provider_runtimes.destroy(nil))
    local destroyed = 0
    local configured = { providers = {
      owned = provider("owned", function(id)
        return {
          id = id,
          name = "Owned",
          state = function() return false end,
          operations = {},
          destroy = function() destroyed = destroyed + 1 end,
        }
      end),
    } }
    local runtimes = assert(provider_runtimes.compose(configured, {
      startup = false,
    }))
    assert.is_true(provider_runtimes.destroy(runtimes))
    assert.is_false(provider_runtimes.destroy(runtimes))
    assert.are.equal(1, destroyed)
  end)

  it("destroys malformed Services retained by a partial runtime", function()
    local destroyed = 0
    local runtimes = {
      partial = {
        service = {
          destroy = function() destroyed = destroyed + 1 end,
        },
      },
    }

    assert.is_true(provider_runtimes.destroy(runtimes --[[@as Neoagent.ProviderRuntimes]]))
    assert.are.equal(1, destroyed)
  end)

  it("groups shared authentication Services and waits to destroy them", function()
    local destroyed = 0
    local configured = { providers = {
      first = provider("first", function(id)
        return {
          id = id,
          name = "First",
          state = function() return false end,
          operations = {},
          destroy = function() destroyed = destroyed + 1 end,
        }
      end),
      second = provider("second", function(id)
        return {
          id = id,
          name = "Second",
          state = function() return false end,
          operations = {},
          destroy = function() destroyed = destroyed + 1 end,
        }
      end),
    } }
    configured.providers.first.auth = "shared"
    configured.providers.second.auth = "shared"
    local runtimes = assert(provider_runtimes.compose(configured, {
      startup = false,
    }))
    assert.are.equal(assert(runtimes.first).auth_services.shared,
      assert(runtimes.second).auth_services.shared)
    assert.are.equal(2, #assert(runtimes.first).auth_services.shared)

    local lease = assert(provider_service.acquire_use(
      assert(runtimes.second).service))
    assert.is_true(provider_runtimes.destroy(runtimes))
    assert.are.equal(1, destroyed)
    assert.is_true(lease:release())
    assert.are.equal(2, destroyed)
  end)

  it("retires a Service after its cancelled catalog refresh settles", function()
    local cancelled = false
    local destroyed = 0
    local started = false
    local configured = { providers = {
      managed = provider("managed", function(id)
        return {
          id = id,
          name = "Managed",
          state = function() return false end,
          operations = {},
          destroy = function() destroyed = destroyed + 1 end,
        }
      end),
    } }
    configured.providers.managed.catalog = {
      source_id = "managed-test-models",
      source_revision = 1,
      seed = { { id = "model" } },
      discover = function()
        return async.run(function()
          return async.await(function(done)
            started = true
            return function()
              cancelled = true
              done.reject(async.cancelled_error)
            end
          end)
        end)
      end,
    }
    local runtimes = assert(provider_runtimes.compose(configured, {
      startup = false,
    }))
    local refresh = assert(runtimes.managed).catalog:refresh()
    assert(vim.wait(1000, function() return started end, 5))

    assert.is_true(provider_runtimes.destroy(runtimes))
    assert(vim.wait(1000, function()
      return refresh:is_done() and cancelled and destroyed == 1
    end, 5))
    assert.are.equal("cancelled", assert(assert(refresh:result()).error).kind)
  end)
end)
