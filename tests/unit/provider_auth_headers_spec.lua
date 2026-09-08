local assert = require("luassert")
local async = require("neoagent.async")
local auth_headers = require("neoagent.providers.auth_headers")

---@param run Neoagent.Run<Neoagent.AuthHeadersResult, nil>
---@return Neoagent.AuthHeadersResult
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@param value Neoagent.AuthResolution
---@return Neoagent.ProviderAuthContext
local function resolved(value)
  return {
    resolve_auth = function()
      return async.run(function() return value end)
    end,
  }
end

describe("provider management authentication headers", function()
  it("rejects configured credentials without HTTP request headers", function()
    local result = wait(auth_headers.resolve(resolved({
      ok = true, configured = true, method = "test",
      credential_type = "api_key", request_opts = {},
    }), {
      name = "Test",
      ambient_api_key = function() return nil end,
    }))
    assert.is_false(result.ok)
    local failure = assert(result.error)
    assert.are.equal("auth", failure.kind)
    assert.matches("returned no request headers", failure.message)
  end)

  it("normalizes failures while resolving an ambient API key", function()
    local result = wait(auth_headers.resolve(resolved({
      ok = true, configured = false,
    }), {
      environment = "TEST_API_KEY",
      ambient_api_key = function() error("secret resolver failure") end,
    }))
    assert.is_false(result.ok)
    local failure = assert(result.error)
    assert.are.equal("auth", failure.kind)
    assert.matches("Failed to resolve TEST_API_KEY", failure.message)
  end)
end)
