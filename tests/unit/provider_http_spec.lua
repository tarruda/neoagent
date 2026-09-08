local assert = require("luassert")
local async = require("neoagent.async")
local http = require("neoagent.providers.http")
local util = require("neoagent.util")

---@param run Neoagent.Run<Neoagent.ProviderHttpResult, nil>
---@return Neoagent.ProviderHttpResult
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

-- Include malformed responses to exercise validation at the HTTP boundary.
---@param response unknown
---@return Neoagent.ByteBackend
local function transport(response)
  ---@cast response Neoagent.ByteFetchResult
  return {
    fetch = function()
      return async.run(function() return response end)
    end,
  }
end

describe("provider management HTTP", function()
  it("normalizes transport failures and rejects incomplete responses", function()
    local failure = http.new({
      name = "Test", base_url = "https://example.test",
      transport = transport({
        ok = false, error = util.error("transport", "connection failed"),
      }),
    })
    local result = wait(failure:get("/value", "value"))
    assert.is_false(result.ok)
    local failure_error = assert(result.error)
    assert.are.equal("transport", failure_error.kind)
    assert.matches("connection failed", failure_error.message)

    local missing_status = http.new({
      name = "Test", base_url = "https://example.test",
      transport = transport({ ok = true, body = "{}" }),
    })
    result = wait(missing_status:get("/value", "value"))
    assert.is_false(result.ok)
    local missing_status_error = assert(result.error)
    assert.matches("no HTTP status", missing_status_error.message)

    local nontext = http.new({
      name = "Test", base_url = "https://example.test",
      transport = transport({ ok = true, status = 200, body = {} }),
    })
    result = wait(nontext:get("/value", "value"))
    assert.is_false(result.ok)
    local nontext_error = assert(result.error)
    assert.matches("body must be text", nontext_error.message)
  end)

  it("rejects scalar JSON without exposing the response body", function()
    for _, body in ipairs({ "null", "true", "42", '"private response"' }) do
      local value = http.new({
        name = "Test", base_url = "https://example.test",
        transport = transport({ ok = true, status = 200, body = body }),
      })
      local result = wait(value:get("/value", "value"))
      assert.is_false(result.ok)
      assert.are.equal("provider", assert(result.error).kind)
      assert.matches("invalid JSON", assert(result.error).message)
      assert.is_nil((vim.inspect(result.error):find("private response", 1, true)))
    end
  end)

  it("bounds decoded response bodies before parsing them", function()
    local value = http.new({
      name = "Test", base_url = "https://example.test",
      max_response_bytes = 1024,
      transport = transport({
        ok = true, status = 200, body = string.rep("x", 1025),
      }),
    })
    local result = wait(value:get("/value", "value"))
    assert.is_false(result.ok)
    local size_error = assert(result.error)
    assert.matches("exceeds 1024 bytes", size_error.message)
  end)
end)
