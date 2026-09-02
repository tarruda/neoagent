local async = require("neoagent.async")
local provider_runtimes = require("neoagent.provider_runtimes")
local provider_service = require("neoagent.provider_service")

describe("neoagent provider runtime composition", function()
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
    local projection
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
    local runtimes = assert(provider_runtimes.compose(configured, {
      startup = false,
    }))
    assert.are.equal("model",
      runtimes.managed.catalog:snapshot().models.model.id)
    assert.are.equal("model", runtimes.plain.catalog:snapshot().models.model.id)
    assert.are.equal("plain", runtimes.plain.service.id)
    assert.are.equal("fake", projection.api)
    assert.are.same({ region = "local" }, projection.service_opts)
    assert.is_nil(projection.api_key)
    assert.is_nil(projection.request_opts)
    assert.are.equal(runtimes.managed.catalog, resources.catalog)
    assert.are.equal("secret", resources.ambient_api_key())
    provider_runtimes.destroy(runtimes)
  end)

  it("attributes model, catalog, and Provider Shell HTTP transports", function()
    local catalog_context
    local service_context
    local function contextual(context)
      local value = { context = vim.deepcopy(context or {}) }
      value.with_context = function(extra)
        return contextual(vim.tbl_extend(
          "force", vim.deepcopy(value.context), vim.deepcopy(extra)))
      end
      return value
    end
    local configured = { providers = {
      managed = provider("managed", function(id, _, resources)
        service_context = resources.transport.context
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
        catalog_context = resources.transport.context
        return async.run(function()
          return { ok = true, models = { { id = "model" } } }
        end)
      end,
    }
    local runtimes = assert(provider_runtimes.compose(configured, {
      startup = false,
      transport = contextual({ workspace = "/workspace" }),
    }))

    assert.are.same({
      workspace = "/workspace", provider = "managed", origin = "model",
    }, runtimes.managed.transport.context)
    assert.are.same({
      workspace = "/workspace", provider = "managed",
      origin = "provider-shell",
    }, service_context)
    local refresh = runtimes.managed.catalog:refresh()
    assert(vim.wait(1000, function() return refresh:is_done() end))
    assert.is_true(refresh:result().ok)
    assert.are.same({
      workspace = "/workspace", provider = "managed", origin = "catalog",
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
        local persistence = runtimes[id].catalog:snapshot().persistence
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
        return id == "llama" and vim.deepcopy(credential) or nil
      end,
      write = function() return true end,
    }
    local manager = require("neoagent.auth").new({
      methods = configured.auth.methods,
      store = credential_store,
    })
    local provider = configured.providers["llama.cpp"]
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
    credential.env.LLAMA_BASE_URL = "http://second.example.test"
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
    assert.matches("constructor failed", err.detail)
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
    assert.matches("id", err.message)
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
    assert.matches("unsupported Provider Service field", err.message)
  end)

  it("owns idempotent runtime destruction", function()
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

    assert.is_true(provider_runtimes.destroy(runtimes))
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
    assert.are.equal(runtimes.first.auth_services,
      runtimes.second.auth_services)
    assert.are.equal(2, #runtimes.first.auth_services)

    local lease = assert(provider_service.acquire_use(
      runtimes.second.service))
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
    local refresh = runtimes.managed.catalog:refresh()
    assert(vim.wait(1000, function() return started end, 5))

    assert.is_true(provider_runtimes.destroy(runtimes))
    assert(vim.wait(1000, function()
      return refresh:is_done() and cancelled and destroyed == 1
    end, 5))
    assert.are.equal("cancelled", refresh:result().error.kind)
  end)
end)
