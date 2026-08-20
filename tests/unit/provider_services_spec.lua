local provider_services = require("neoagent.provider_services")
local neoagent = require("neoagent")

describe("neoagent provider service composition", function()
  local function controller_options(constructor)
    return {
      name = "ownership",
      default_registry = false,
      persistence = { enabled = false },
      providers = {
        owned = {
          api = "fake",
          models = {},
          service = constructor,
        },
      },
      apis = {},
      tools = {},
      agents = false,
      skills = false,
    }
  end

  it("constructs declared services with secret-free projections", function()
    local seen_projection
    local seen_options
    local service = {
      id = "dynamic",
      name = "Dynamic",
      state = function() return false end,
      operations = {},
      destroy = function() end,
    }
    local configured = {
      providers = {
        ["dynamic"] = {
          api = "openai-completions",
          base_url = "http://localhost/v1",
          auth_optional = true,
          api_key = "secret",
          request_opts = { headers = { Authorization = "Bearer secret" } },
          catalog_cache = { ttl_ms = 60000 },
          service_opts = { management_url = "http://localhost/manage", region = "local" },
          models = { one = {} },
          service = function(projection, options)
            seen_projection = projection
            seen_options = options
            return service
          end,
        },
        static = { api = "openai-completions", base_url = "http://localhost/v1", models = {} },
      },
    }
    local result = provider_services.compose(configured, { auth = { manager = true } })
    assert.are.equal(service, result.dynamic)
    assert.are.equal("openai-completions", seen_projection.api)
    assert.are.equal("http://localhost/v1", seen_projection.base_url)
    assert.are.same({ one = {} }, seen_projection.models)
    assert.are.same({ management_url = "http://localhost/manage", region = "local" },
      seen_projection.service_opts)
    assert.are.same({ ttl_ms = 60000 }, seen_projection.catalog_cache)
    assert.is_true(seen_projection.auth_optional)
    assert.is_nil(seen_projection.api_key)
    assert.is_nil(seen_projection.request_opts)
    assert.is_true(seen_options.auth.manager)
    assert.is_nil(result.static)

    configured.providers.dynamic.catalog_cache = false
    result = provider_services.compose(configured)
    assert.is_false(seen_projection.catalog_cache)
  end)

  it("reports constructor and identity failures", function()
    local configured = {
      providers = {
        broken = {
          api = "openai-completions",
          base_url = "http://localhost/v1",
          models = {},
          service = function() error("constructor boom") end,
        },
      },
    }
    local result, err = provider_services.compose(configured)
    assert.is_nil(result)
    assert.matches("constructor boom", err.detail)

    configured.providers.broken.service = function()
      return { id = "other", name = "Other", state = function() return false end, operations = {} }
    end
    result, err = provider_services.compose(configured)
    assert.is_nil(result)
    assert.matches("id", err.message)

    configured.providers.broken.service = function() return {} end
    result, err = provider_services.compose(configured)
    assert.is_nil(result)
    assert.are.equal("provider", err.kind)
  end)

  it("destroys constructed services when composition fails", function()
    local constructed = 0
    local destroyed = 0
    local function constructor(_, resources)
      constructed = constructed + 1
      if constructed == 2 then error("later constructor failed") end
      return {
        id = resources.provider_id,
        name = "Temporary",
        state = function() return false end,
        operations = {},
        destroy = function() destroyed = destroyed + 1 end,
      }
    end
    local result, err = provider_services.compose({
      providers = {
        first = { api = "fake", models = {}, service = constructor },
        second = { api = "fake", models = {}, service = constructor },
      },
    })
    assert.is_nil(result)
    assert.matches("later constructor failed", err.detail)
    assert.are.equal(1, destroyed)

    result, err = provider_services.compose({
      providers = {
        invalid = {
          api = "fake",
          models = {},
          service = function()
            return {
              id = "invalid",
              destroy = function() destroyed = destroyed + 1 end,
            }
          end,
        },
      },
    })
    assert.is_nil(result)
    assert.are.equal("provider", err.kind)
    assert.are.equal(2, destroyed)
  end)

  it("destroys every service with an idempotent callback", function()
    local destroyed = 0
    local service = {
      id = "dynamic",
      name = "Dynamic",
      state = function() return false end,
      operations = {},
      destroy = function() destroyed = destroyed + 1 end,
    }
    local configured = {
      providers = {
        dynamic = {
          api = "openai-completions",
          base_url = "http://localhost/v1",
          models = {},
          service = function() return service end,
        },
      },
    }
    local result = provider_services.compose(configured)
    provider_services.destroy(result)
    provider_services.destroy(result)
    assert.are.equal(2, destroyed)
    provider_services.destroy(nil)
  end)

  it("gives privately composed Controller services one destruction owner", function()
    local destroyed = 0
    local function constructor()
      return {
        id = "owned",
        name = "Owned",
        state = function() return false end,
        operations = {},
        destroy = function() destroyed = destroyed + 1 end,
      }
    end
    local controller = neoagent.new(controller_options(constructor))
    controller:destroy()
    controller:destroy()
    assert.are.equal(1, destroyed)

    local shared = constructor()
    local external = neoagent.new(controller_options(function()
      error("caller services should bypass composition")
    end), { providers = { owned = shared } })
    external:destroy()
    assert.are.equal(1, destroyed)
  end)

  it("destroys composed services when Controller construction fails", function()
    local destroyed = 0
    local options = controller_options(function()
      return {
        id = "owned",
        name = "Owned",
        state = function() return false end,
        operations = {},
        destroy = function() destroyed = destroyed + 1 end,
      }
    end)
    assert.has_error(function()
      neoagent.new(options, { workspace_trust = {} })
    end)
    assert.are.equal(1, destroyed)
  end)
end)
