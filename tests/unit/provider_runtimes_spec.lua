local provider_runtimes = require("neoagent.provider_runtimes")

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
end)
