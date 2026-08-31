local async = require("neoagent.async")
local http = require("neoagent.providers.http")
local util = require("neoagent.util")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function transport(response)
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
    assert.are.equal("transport", result.error.kind)
    assert.matches("connection failed", result.error.message)

    local missing_status = http.new({
      name = "Test", base_url = "https://example.test",
      transport = transport({ ok = true, body = "{}" }),
    })
    result = wait(missing_status:get("/value", "value"))
    assert.is_false(result.ok)
    assert.matches("no HTTP status", result.error.message)

    local nontext = http.new({
      name = "Test", base_url = "https://example.test",
      transport = transport({ ok = true, status = 200, body = {} }),
    })
    result = wait(nontext:get("/value", "value"))
    assert.is_false(result.ok)
    assert.matches("body must be text", result.error.message)
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
    assert.matches("exceeds 1024 bytes", result.error.message)
  end)
end)
