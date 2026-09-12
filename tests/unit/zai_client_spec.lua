local assert = require("luassert")
local fake_transport = require("tests.helpers.fake_transport")
local client = require("neoagent.providers.zai.client")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

local auth = require("tests.helpers.api_key_auth")

describe("Z.AI client", function()
  it("loads the account model catalog with Bearer auth", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      object = "list",
      data = {
        { id = "glm-5.3-flash", object = "model", owned_by = "z-ai" },
        { id = "glm-5.3", object = "model", owned_by = "z-ai" },
      },
    }) } }
    local value = client.new({
      management_url = "https://example.test/api/paas/v4/",
      transport = transport,
    })
    local result = wait(value:models({ resolve_auth = auth({
      ["x-api-key"] = "api-key",
      ["X-Trace"] = "safe",
    }) }))

    assert(result.ok)
    assert.are.same({ "glm-5.3", "glm-5.3-flash" }, result.models)
    assert.are.equal("https://example.test/api/paas/v4/models",
      assert(transport.fetch_requests[1]).url)
    assert.are.equal("Bearer api-key",
      rawget(assert(assert(transport.fetch_requests[1]).headers), "Authorization"))
    assert.are.equal("safe", rawget(assert(assert(transport.fetch_requests[1]).headers), "X-Trace"))
  end)

  it("bounds and validates model catalogs", function()
    local too_many = {}
    for index = 1, 101 do too_many[index] = { id = "glm-" .. index } end
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = { { id = "bad\nmodel" } } }) },
      { body = vim.json.encode({ data = {
        { id = "duplicate" }, { id = "duplicate" },
      } }) },
      { body = vim.json.encode({ data = too_many }) },
    }
    local value = client.new({
      management_url = "https://example.test",
      transport = transport,
      ambient_api_key = function() return "api-secret" end,
    })

    for _ = 1, 3 do
      local result = wait(value:models({ resolve_auth = auth(nil) }))
      assert.is_false(result.ok)
      assert.matches("invalid model catalog", assert(result.error).message)
      assert.is_nil((vim.inspect(result.error):find("api-secret", 1, true)))
    end
  end)

  it("loads the current API balance endpoint with Bearer auth", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      success = true,
      data = {
        total_balance = "88.50",
        available_balance = 77.25,
        currency = "USD",
      },
    }) } }
    local value = client.new({
      management_url = "https://example.test",
      transport = transport,
    })
    local result = wait(value:balance({
      resolve_auth = auth({
        ["x-api-key"] = "api-key",
        ["X-Trace"] = "safe",
      }),
    }))

    assert(result.ok)
    assert.are.same({
      total = 88.5,
      available = 77.25,
      currency = "USD",
    }, result.balance)
    assert.are.equal(
      "https://example.test/api/paas/v4/balance",
      assert(transport.fetch_requests[1]).url)
    assert.are.equal("Bearer api-key",
      rawget(assert(assert(transport.fetch_requests[1]).headers), "Authorization"))
    assert.are.equal("safe", rawget(assert(assert(transport.fetch_requests[1]).headers), "X-Trace"))
  end)

  it("bounds balance fields and rejects malformed balance data", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = {
        available_balance = "12.50", currency = "CNY",
      } }) },
      { body = "[]" },
      { body = vim.json.encode({ data = {
        total_balance = 1, available_balance = -1, currency = "USD",
      } }) },
      { body = vim.json.encode({ data = {
        total_balance = 1, available_balance = 1,
        currency = "bad\ncurrency",
      } }) },
      { body = vim.json.encode({ data = {} }) },
    }
    local value = client.new({
      management_url = "https://example.test",
      transport = transport,
    })
    local context = { resolve_auth = auth({ Authorization = "api-key" }) }

    local result = wait(value:balance(context))
    assert(result.ok)
    assert.are.same({
      total = 12.5, available = 12.5, currency = "CNY",
    }, result.balance)

    for _ = 1, 4 do
      result = wait(value:balance(context))
      assert.is_false(result.ok)
      assert.matches("invalid balance data", assert(result.error).message)
    end
  end)

  it("loads bounded quota limits with the configured API key", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      code = 200,
      data = {
        planName = "Pro",
        limits = {
          {
            type = "TOKENS_LIMIT", percentage = 35,
            nextResetTime = 1787270400000, unit = 3, number = 5,
          },
          {
            type = "TOKENS_LIMIT", percentage = 15,
            nextResetTime = 1787875200000, unit = 6, number = 7,
          },
          {
            type = "TIME_LIMIT", percentage = 20,
            currentValue = 8, usage = 40, unit = 5, number = 1,
          },
        },
      },
    }) } }
    local value = client.new({
      management_url = "https://example.test",
      transport = transport,
    })
    local result = wait(value:quota({
      resolve_auth = auth({
        Authorization = "Bearer api-key",
        ["X-Trace"] = "safe",
      }),
    }))

    assert(result.ok)
    assert.are.equal("Pro", result.quota.plan)
    assert.are.same({
      {
        type = "TOKENS_LIMIT", remaining = 0.65,
        resets_at = 1787270400, window = "5-hour",
      },
      {
        type = "TOKENS_LIMIT", remaining = 0.85,
        resets_at = 1787875200, window = "Weekly",
      },
      {
        type = "TIME_LIMIT", remaining = 0.8,
        current = 8, maximum = 40, window = "Monthly",
      },
    }, result.quota.limits)
    assert.are.equal(
      "https://example.test/api/monitor/usage/quota/limit",
      assert(transport.fetch_requests[1]).url)
    assert.are.equal("api-key",
      rawget(assert(assert(transport.fetch_requests[1]).headers), "Authorization"))
    assert.are.equal("safe", rawget(assert(assert(transport.fetch_requests[1]).headers), "X-Trace"))
    assert.are.equal("en-US,en",
      rawget(assert(assert(transport.fetch_requests[1]).headers), "Accept-Language"))
  end)

  it("loads current credit-based plan windows", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      success = true,
      data = {
        level = "max",
        limits = {
          {
            type = "CREDIT_LIMIT", percentage = 25,
            currentValue = 7000, usage = 28000, remaining = 21000,
            nextResetTime = 1787270400000, unit = 3, number = 5,
          },
          {
            type = "CREDIT_LIMIT", percentage = 10,
            currentValue = 14000, usage = 140000, remaining = 126000,
            nextResetTime = 1787875200000, unit = 6, number = 7,
          },
        },
      },
    }) } }
    local value = client.new({
      management_url = "https://example.test",
      transport = transport,
    })
    local result = wait(value:quota({ resolve_auth = auth({
      ["x-api-key"] = "api-key",
    }) }))

    assert(result.ok)
    assert.are.equal("max", result.quota.plan)
    assert.are.same({
      {
        type = "CREDIT_LIMIT", remaining = 0.75,
        current = 7000, maximum = 28000,
        resets_at = 1787270400, window = "5-hour",
      },
      {
        type = "CREDIT_LIMIT", remaining = 0.9,
        current = 14000, maximum = 140000,
        resets_at = 1787875200, window = "Weekly",
      },
    }, result.quota.limits)
  end)

  it("normalizes quota durations and derives omitted percentages", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ data = { limits = {
      {
        type = "TOKENS_LIMIT", usage = 100, remaining = 80,
        unit = 3, number = 5,
      },
      {
        type = "TOKENS_LIMIT", percentage = 10,
        unit = 4, number = 1,
      },
      {
        type = "CREDIT_LIMIT", percentage = 20,
        unit = 99, number = 1,
      },
      {
        type = "TIME_LIMIT", usage = 100, currentValue = 30,
        unit = 5, number = 1,
      },
      { type = "FUTURE_LIMIT", percentage = 50 },
    } } }) } }
    local value = client.new({
      management_url = "https://example.test",
      transport = transport,
    })
    local result = wait(value:quota({ resolve_auth = auth({
      ["x-api-key"] = "api-key",
    }) }))

    assert(result.ok)
    assert.are.same({
      {
        type = "TOKENS_LIMIT", remaining = 0.8,
        current = 20, maximum = 100, window = "5-hour",
      },
      {
        type = "TOKENS_LIMIT", remaining = 0.9, window = "Daily",
      },
      {
        type = "CREDIT_LIMIT", remaining = 0.8, window = "Quota",
      },
      {
        type = "TIME_LIMIT", remaining = 0.7,
        current = 30, maximum = 100, window = "Monthly",
      },
    }, result.quota.limits)
  end)

  it("uses ZAI_API_KEY and rejects malformed or unauthorized data safely", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = { limits = {
        { type = "TOKENS_LIMIT", percentage = 101 },
      } } }) },
      { status = 403, body = "private account response" },
    }
    local value = client.new({
      management_url = "https://example.test/",
      transport = transport,
      ambient_api_key = function() return "api-secret" end,
    })
    local malformed = wait(value:quota({ resolve_auth = auth(nil) }))
    assert.is_false(malformed.ok)
    assert.matches("invalid quota data", assert(malformed.error).message)
    assert.is_nil((vim.inspect(malformed.error):find("api-secret", 1, true)))

    local forbidden = wait(value:quota({ resolve_auth = auth(nil) }))
    assert.is_false(forbidden.ok)
    assert.are.equal(403, rawget(assert(forbidden.error), "status"))
    assert.is_nil(vim.inspect(forbidden.error):find(
      "private account response", 1, true))

    value = client.new({
      management_url = "https://example.test",
      transport = fake_transport.new(),
      ambient_api_key = function() return nil end,
    })
    local missing = wait(value:quota({ resolve_auth = auth(nil) }))
    assert.is_false(missing.ok)
    assert.matches("ZAI_API_KEY", assert(missing.error).message)
  end)

  it("validates client construction", function()
    local missing_options = {}
    assert.has_error(function() client.new(missing_options --[[@as Neoagent.ZaiClientOptions]]) end)
    assert.has_error(function()
      client.new({ management_url = "x", timeout_ms = 0 })
    end)
  end)

  it("rejects malformed quota envelopes, usage totals, and auth headers", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = { limits = {} } }) },
      { body = vim.json.encode({ data = { limits = { {
        type = "TIME_LIMIT", percentage = 50,
        currentValue = -1, usage = 10,
      } } } }) },
      { body = vim.json.encode({ data = { limits = { {
        type = "TOKENS_LIMIT", percentage = 50, unit = 3, number = 0,
      } } } }) },
      { body = vim.json.encode({ data = { limits = { {
        type = "TOKENS_LIMIT", currentValue = 11, usage = 10,
      } } } }) },
      { body = vim.json.encode({ data = { limits = { {
        type = "TOKENS_LIMIT",
      } } } }) },
      { body = vim.json.encode({ data = { limits = { 7 } } }) },
      { body = vim.json.encode({ data = { limits = { {
        type = "TOKENS_LIMIT", percentage = 50, nextResetTime = 0,
      } } } }) },
      { body = vim.json.encode({ data = { limits = { {
        type = "TOKENS_LIMIT", percentage = 50, nextResetTime = 0.5,
      } } } }) },
      { body = vim.json.encode({ data = {
        planName = "bad\nplan",
        limits = { { type = "TOKENS_LIMIT", percentage = 50 } },
      } }) },
      { body = vim.json.encode({ data = { limits = { {
        type = "FUTURE_LIMIT", percentage = 50,
      } } } }) },
    }
    local value = client.new({
      management_url = "https://example.test",
      transport = transport,
    })
    local result
    for _ = 1, 10 do
      result = wait(value:quota({ resolve_auth = auth({
        Authorization = "Bearer api-key",
      }) }))
      assert.is_false(result.ok)
      assert.matches("invalid quota data", assert(result.error).message)
    end
    assert.are.equal("api-key",
      rawget(assert(assert(transport.fetch_requests[1]).headers), "Authorization"))

    result = wait(value:quota({ resolve_auth = auth({
      ["X-Trace"] = "trace-only",
    }) }))
    assert.is_false(result.ok)
    assert.matches("returned no API key header", assert(result.error).message)
  end)

  it("contains endpoint-specific credential and transport failures", function()
    local transport = fake_transport.new()
    transport.fetches = { {
      error = { kind = "transport", message = "connection reset" },
    } }
    local value = client.new({
      management_url = "https://example.test",
      transport = transport,
    })
    local rejected_context = {
      resolve_auth = function()
        return require("neoagent.async").run(function()
          return { ok = false, error = {
            kind = "auth",
            message = "credential resolution failed",
          } }
        end)
      end,
    }
    local rejected_models = wait(value:models(rejected_context))
    assert.is_false(rejected_models.ok)
    assert.matches("credential resolution failed", assert(rejected_models.error).message)
    local rejected_balance = wait(value:balance(rejected_context))
    assert.is_false(rejected_balance.ok)
    assert.matches("credential resolution failed", assert(rejected_balance.error).message)

    local missing_models = wait(value:models({
      resolve_auth = auth({ ["X-Trace"] = "trace-only" }),
    }))
    assert.is_false(missing_models.ok)
    assert.matches("no API key header", assert(missing_models.error).message)

    local failed_models = wait(value:models({
      resolve_auth = auth({ ["x-api-key"] = "api-key" }),
    }))
    assert.is_false(failed_models.ok)
    assert.matches("connection reset", assert(failed_models.error).message)

    local missing_balance = wait(value:balance({
      resolve_auth = auth({ ["X-Trace"] = "trace-only" }),
    }))
    assert.is_false(missing_balance.ok)
    assert.matches("no API key header", assert(missing_balance.error).message)
  end)

  it("reports authentication and rate-limit failures and reads ZAI_API_KEY", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 401, body = "private" },
      { status = 429, body = "private" },
      { body = vim.json.encode({ data = { limits = { {
        type = "TOKENS_LIMIT", percentage = 0,
      } } } }) },
    }
    local previous = vim.env.ZAI_API_KEY
    vim.env.ZAI_API_KEY = "environment-key"
    local value = client.new({
      management_url = "https://example.test",
      transport = transport,
    })
    local result = wait(value:quota({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("requires a valid API key", assert(result.error).message)
    result = wait(value:quota({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("rate limited", assert(result.error).message)
    result = wait(value:quota({ resolve_auth = auth(nil) }))
    vim.env.ZAI_API_KEY = previous
    assert(result.ok)
    assert.are.equal("environment-key",
      rawget(assert(assert(transport.fetch_requests[3]).headers), "Authorization"))
  end)
end)
