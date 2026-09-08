local assert = require("luassert")
local async = require("neoagent.async")
local client = require("neoagent.providers.opencode_go.client")
local fake_transport = require("tests.helpers.fake_transport")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

local auth = require("tests.helpers.api_key_auth")

describe("OpenCode Go management client", function()
  it("loads and validates authoritative usage with a Bearer key", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ usage = {
      rolling = {
        status = "ok", percent = 45,
        resetsAt = "2026-08-20T17:30:00.000Z",
      },
      weekly = {
        status = "ok", percent = 12,
        resetsAt = "2026-08-24T00:00:00.000Z",
      },
      monthly = {
        status = "rate-limited", percent = 100,
        resetsAt = "2026-09-03T12:00:00.000Z",
      },
    } }) } }
    local value = client.new({
      base_url = "https://example.test/zen/go/v1/",
      transport = transport,
    })

    local result = wait(value:usage({
      resolve_auth = auth({ ["x-api-key"] = "stored-key" }),
    }))
    assert(result.ok)
    assert.are.equal(0.55, result.usage.rolling.remaining)
    assert.are.equal(1787247000, result.usage.rolling.resets_at)
    assert.are.equal(0, result.usage.monthly.remaining)
    assert.is_true(result.usage.monthly.rate_limited)
    assert.are.equal("https://example.test/zen/go/v1/usage",
      assert(transport.fetch_requests[1]).url)
    assert.are.equal("GET", assert(transport.fetch_requests[1]).method)
    assert.are.equal("Bearer stored-key",
      rawget(assert(assert(transport.fetch_requests[1]).headers), "Authorization"))
  end)

  it("derives the usage key from stored Authorization headers", function()
    local transport = fake_transport.new()
    transport.fetches = { { status = 401, body = "private response" } }
    local result = wait(client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    }):usage({
      resolve_auth = auth({ Authorization = "Bearer stored-key" }),
    }))

    assert.is_false(result.ok)
    assert.are.equal(401, rawget(assert(result.error), "status"))
    assert.are.equal("Bearer stored-key",
      rawget(assert(assert(transport.fetch_requests[1]).headers), "Authorization"))
    assert.is_nil((vim.inspect(result.error):find("private response", 1, true)))
  end)

  it("loads the public model list without sending credentials", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      object = "list",
      data = {
        { id = "glm-5.3", object = "model" },
        { id = "minimax-m3", object = "model" },
      },
    }) } }
    local result = wait(client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    }):models())
    assert(result.ok)
    assert.are.same({ "glm-5.3", "minimax-m3" }, result.models)
    assert.are.same({ Accept = "application/json" },
      assert(transport.fetch_requests[1]).headers)
  end)

  it("supports ambient keys and reports bounded body-free failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = "{}", status = 401 },
      { body = "not-json" },
      { body = vim.json.encode({ usage = {
        rolling = { status = "ok", percent = 101, resetsAt = "invalid" },
      } }) },
      { body = "{}" },
      { body = "{}" },
    }
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
      ambient_api_key = function() return "ambient-secret" end,
    })

    local unauthorized = wait(value:usage({ resolve_auth = auth(nil) }))
    assert.is_false(unauthorized.ok)
    assert.are.equal(401, rawget(assert(unauthorized.error), "status"))
    assert.is_nil((vim.inspect(unauthorized.error):find("{}", 1, true)))
    assert.is_nil((vim.inspect(unauthorized.error):find("ambient-secret", 1, true)))
    assert.are.equal("Bearer ambient-secret",
      rawget(assert(assert(transport.fetch_requests[1]).headers), "Authorization"))

    local malformed = wait(value:models())
    assert.is_false(malformed.ok)
    assert.matches("invalid JSON", assert(malformed.error).message)

    local invalid = wait(value:usage({ resolve_auth = auth(nil) }))
    assert.is_false(invalid.ok)
    assert.matches("invalid usage", assert(invalid.error).message)

    local missing_usage = wait(value:usage({ resolve_auth = auth(nil) }))
    assert.is_false(missing_usage.ok)
    assert.matches("invalid usage", assert(missing_usage.error).message)

    local missing_catalog = wait(value:models())
    assert.is_false(missing_catalog.ok)
    assert.matches("invalid model catalog", assert(missing_catalog.error).message)
  end)

  it("requires a key and validates client options", function()
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = fake_transport.new(),
      ambient_api_key = function() return nil end,
    })
    local result = wait(value:usage({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("Connect OpenCode Go", assert(result.error).message)

    local missing_options = {}
    assert.has_error(function() client.new(missing_options --[[@as Neoagent.OpenCodeClientOptions]]) end)
    assert.has_error(function()
      client.new({ base_url = "x", max_response_bytes = 1 })
    end)
  end)

  it("bounds transport, HTTP, body, and catalog failures", function()
    ---@param response? Neoagent.TestByteResponse
    ---@param options? { transport?: Neoagent.ByteBackend, maximum?: integer }
    ---@return Neoagent.OpenCodeModelsSuccess|Neoagent.AsyncFailure
    local function models(response, options)
      local transport = options and options.transport
      if not transport then
        local backend = fake_transport.new()
        backend.fetches = { (assert(response)) }
        transport = backend
      end
      return wait(client.new({
        base_url = "https://example.test/v1",
        transport = transport,
        max_response_bytes = options and options.maximum or nil,
      }):models())
    end

    local result = models({
      error = { kind = "transport", message = "network unavailable" },
    })
    assert.is_false(result.ok)
    assert.matches("network unavailable", assert(result.error).message)

    result = models(nil, { transport = {
      fetch = function()
        return async.run(function() return { ok = true, headers = {}, body = "{}" } end)
      end,
    } })
    assert.is_false(result.ok)
    assert.matches("HTTP status", assert(result.error).message)

    result = models({ body = {} --[[@as string]] })
    assert.is_false(result.ok)
    assert.matches("body must be text", assert(result.error).message)

    result = models({ body = string.rep("x", 1025) }, { maximum = 1024 })
    assert.is_false(result.ok)
    assert.matches("exceeds 1024 bytes", assert(result.error).message)

    for _, status in ipairs({ 403, 500 }) do
      result = models({ status = status, body = "private response" })
      assert.is_false(result.ok)
      assert.are.equal(status, rawget(assert(result.error), "status"))
      assert.is_nil((vim.inspect(result.error):find("private response", 1, true)))
    end

    result = models({ body = vim.json.encode({ data = {
      { id = "duplicate" }, { id = "duplicate" },
    } }) })
    assert.is_false(result.ok)
    assert.matches("invalid model catalog", assert(result.error).message)

    assert.is_nil(client.iso_timestamp("2026-02-31T12:00:00Z"))
  end)

  it("normalizes ambient key lookup failures", function()
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = fake_transport.new(),
      ambient_api_key = function() error("environment unavailable") end,
    })
    local result = wait(value:usage({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("Failed to resolve OPENCODE_API_KEY", assert(result.error).message)
  end)
end)
