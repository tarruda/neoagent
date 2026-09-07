local ProviderCredentials = require("neoagent.provider_credentials")

describe("neoagent provider credential ownership", function()
  local function authentication(value)
    return {
      has_credentials = function()
        if type(value) == "table" and value.error then
          return nil, { kind = "auth", message = value.error }
        end
        if type(value) == "table" and value.throw then error(value.throw) end
        return value == true
      end,
    }
  end

  local function credentials(provider, stored)
    return ProviderCredentials.new({
      provider_id = "example",
      provider = provider,
      authentication = authentication(stored),
      method = provider.auth and { name = "Example login" } or nil,
    })
  end

  it("applies stored, configured, and environment precedence", function()
    local ambient_calls = 0
    local provider = {
      auth = "key",
      api_key = function()
        ambient_calls = ambient_calls + 1
        return " environment-secret "
      end,
    }
    local stored = credentials(provider, true)
    assert.are.same({
      usable = true,
      source = "stored",
      method_id = "key",
      method_name = "Example login",
    }, stored:state())
    assert.is_nil(stored:ambient_api_key())
    assert.are.equal(0, ambient_calls)

    local environment = credentials(provider, false)
    assert.are.equal("environment", environment:state().source)
    assert.are.equal("environment-secret", environment:ambient_api_key())
    assert.are.equal(2, ambient_calls)

    local configured = credentials({ auth = "key", api_key = " literal " }, false)
    assert.are.equal("configured", configured:state().source)
    assert.are.equal("literal", configured:ambient_api_key())
  end)

  it("projects optional, absent, unavailable, and failed sources", function()
    assert.are.same({ usable = true, source = "none" },
      credentials({}, false):state())
    assert.are.equal("optional",
      credentials({ auth = "key", auth_optional = true }, false):state().source)
    assert.are.equal("logged_out",
      credentials({ auth = "key" }, false):state().source)
    assert.are.equal("logged_out",
      credentials({ api_key = function() end }, false):state().source)

    local failed = credentials({ auth = "key" }, {
      error = "credential store failed",
    }):state()
    assert.is_false(failed.usable)
    assert.are.equal("error", failed.source)
    assert.are.equal("credential store failed", failed.error.message)

    failed = credentials({
      auth = "key",
      api_key = function() error("ambient-secret") end,
    }, false):state()
    assert.are.equal("error", failed.source)
    assert.not_matches("ambient%-secret", failed.error.message)
  end)

  it("fails ambient resolution closed and identifies shared methods", function()
    local value = credentials({
      auth = "shared",
      api_key = function() error("resolver failed") end,
    }, false)
    assert.is_true(value:uses_method("shared"))
    assert.is_false(value:uses_method("other"))
    local ok, err = pcall(value.ambient_api_key, value)
    assert.is_false(ok)
    assert.matches("environment credential", err.message)
  end)

  it("resolves named authentication independently from inference", function()
    local inspected
    local provider = {
      auth = "inference",
      auth_optional = true,
      auth_scopes = { dashboard = "dashboard" },
      api_key = "ambient-inference",
    }
    local value = ProviderCredentials.new({
      provider_id = "example",
      provider = provider,
      authentication = {
        has_credentials = function(_, method)
          inspected = method
          return method == "dashboard"
        end,
      },
      method = { name = "Dashboard authorization" },
      scope = "dashboard",
    })

    assert.are.same({
      usable = true,
      source = "stored",
      method_id = "dashboard",
      method_name = "Dashboard authorization",
    }, value:state())
    assert.are.equal("dashboard", inspected)
    assert.is_nil(value:ambient_api_key())
    assert.is_true(value:uses_method("inference"))
    assert.is_true(value:uses_method("dashboard"))

    value.authentication.has_credentials = function() return false end
    local state = value:state()
    assert.is_false(state.usable)
    assert.are.equal("logged_out", state.source)
  end)

  it("fails closed when stored credential inspection is unavailable", function()
    local unavailable = ProviderCredentials.new({
      provider_id = "example",
      provider = { auth = "key" },
    }):state()
    assert.is_false(unavailable.usable)
    assert.matches("Authentication is unavailable", unavailable.error.message)

    local thrown = credentials({ auth = "key" }, {
      throw = "private credential failure",
    }):state()
    assert.is_false(thrown.usable)
    assert.matches("Failed to inspect stored credentials", thrown.error.message)
    assert.not_matches("private credential failure", thrown.error.message)
  end)

  it("derives account cache identities from every effective source", function()
    local function value(provider, manager)
      return ProviderCredentials.new({
        provider_id = "example",
        provider = provider,
        authentication = manager,
      })
    end
    local identity, err = value({}, {}):cache_identity()
    assert.is_nil(identity)
    assert.matches("identity is unavailable", err.message)

    identity, err = value({ auth = "key" }, nil):cache_identity()
    assert.is_nil(identity)
    assert.matches("identity is unavailable", err.message)

    local stored = { has_credentials = function() return true end }
    identity, err = value({ auth = "key" }, stored):cache_identity()
    assert.is_nil(identity)
    assert.matches("identity is unavailable", err.message)

    stored.cache_identity = function() error("private identity failure") end
    identity, err = value({ auth = "key" }, stored):cache_identity()
    assert.is_nil(identity)
    assert.matches("identity failed", err.message)
    assert.not_matches("private identity failure", err.message)

    stored.cache_identity = function()
      return nil, { kind = "auth", message = "explicit identity failure" }
    end
    identity, err = value({ auth = "key" }, stored):cache_identity()
    assert.is_nil(identity)
    assert.are.equal("explicit identity failure", err.message)

    local ambient = {
      has_credentials = function() return false end,
      derive_cache_identity = function(_, method_id, credential)
        assert.are.equal("key", method_id)
        assert.are.equal("ambient", credential.key)
        return "derived-identity"
      end,
    }
    identity = assert(value({ auth = "key", api_key = "ambient" },
      ambient):cache_identity())
    assert.are.equal("derived-identity", identity)
    assert.is_string(assert(value({ auth = "key", auth_optional = true },
      ambient):cache_identity()))

    ambient.derive_cache_identity = function()
      error("private derivation failure")
    end
    identity, err = value({ auth = "key", api_key = "ambient" },
      ambient):cache_identity()
    assert.is_nil(identity)
    assert.matches("identity failed", err.message)
    assert.not_matches("private derivation failure", err.message)

    ambient.derive_cache_identity = function()
      return nil, { kind = "auth", message = "explicit derivation failure" }
    end
    identity, err = value({ auth = "key", api_key = "ambient" },
      ambient):cache_identity()
    assert.is_nil(identity)
    assert.are.equal("explicit derivation failure", err.message)
  end)
end)
