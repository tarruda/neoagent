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
end)
