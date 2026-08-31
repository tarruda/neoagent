local async = require("neoagent.async")
local auth_headers = require("neoagent.providers.auth_headers")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

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
      ok = true, configured = true, request_opts = {},
    }), {
      name = "Test",
      ambient_api_key = function() return nil end,
    }))
    assert.is_false(result.ok)
    assert.are.equal("auth", result.error.kind)
    assert.matches("returned no request headers", result.error.message)
  end)

  it("normalizes failures while resolving an ambient API key", function()
    local result = wait(auth_headers.resolve(resolved({
      ok = true, configured = false,
    }), {
      environment = "TEST_API_KEY",
      ambient_api_key = function() error("secret resolver failure") end,
    }))
    assert.is_false(result.ok)
    assert.are.equal("auth", result.error.kind)
    assert.matches("Failed to resolve TEST_API_KEY", result.error.message)
  end)
end)
