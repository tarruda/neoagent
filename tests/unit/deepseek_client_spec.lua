local async = require("neoagent.async")
local client = require("neoagent.providers.deepseek.client")
local fake_transport = require("tests.helpers.fake_transport")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function auth(headers)
  return function()
    return async.run(function()
      return {
        ok = true,
        configured = headers ~= nil,
        request_opts = headers and { headers = headers } or nil,
      }
    end)
  end
end

describe("DeepSeek management client", function()
  it("loads the authenticated model catalog", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      object = "list",
      data = {
        { id = "deepseek-v4-pro", object = "model", owned_by = "deepseek" },
        { id = "deepseek-v4-flash", object = "model", owned_by = "deepseek" },
      },
    }) } }
    local value = client.new({
      base_url = "https://example.test/",
      transport = transport,
    })

    local result = wait(value:models({
      resolve_auth = auth({ Authorization = "Bearer stored-key" }),
    }))
    assert.is_true(result.ok)
    assert.are.same({ "deepseek-v4-flash", "deepseek-v4-pro" }, result.models)
    assert.are.equal("https://example.test/models",
      transport.fetch_requests[1].url)
    assert.are.equal("Bearer stored-key",
      transport.fetch_requests[1].headers.Authorization)
  end)

  it("loads every currency in the account balance", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      is_available = true,
      balance_infos = {
        {
          currency = "USD", total_balance = "12.34",
          granted_balance = "2.34", topped_up_balance = "10.00",
        },
        {
          currency = "CNY", total_balance = "3.00",
          granted_balance = "0.00", topped_up_balance = "3.00",
        },
      },
    }) } }
    local value = client.new({
      base_url = "https://example.test",
      transport = transport,
    })
    local result = wait(value:balance({
      resolve_auth = auth({ ["x-api-key"] = "stored-key" }),
    }))

    assert.is_true(result.ok)
    assert.is_true(result.balance.is_available)
    assert.are.same({
      {
        currency = "CNY", total = "3.00", granted = "0.00",
        topped_up = "3.00",
      },
      {
        currency = "USD", total = "12.34", granted = "2.34",
        topped_up = "10.00",
      },
    }, result.balance.currencies)
    assert.are.equal("https://example.test/user/balance",
      transport.fetch_requests[1].url)
    assert.are.equal("stored-key",
      transport.fetch_requests[1].headers["x-api-key"])
  end)

  it("uses an ambient key and keeps response bodies and keys out of errors", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 401, body = "private response" },
      { body = "not-json" },
      { body = vim.json.encode({ is_available = true, balance_infos = {} }) },
      { body = vim.json.encode({ data = { { id = "bad\nmodel" } } }) },
    }
    local value = client.new({
      base_url = "https://example.test",
      transport = transport,
      ambient_api_key = function() return "ambient-secret" end,
    })

    local unauthorized = wait(value:balance({ resolve_auth = auth(nil) }))
    assert.is_false(unauthorized.ok)
    assert.are.equal(401, unauthorized.error.status)
    assert.is_nil(vim.inspect(unauthorized.error):find("private response", 1, true))
    assert.is_nil(vim.inspect(unauthorized.error):find("ambient-secret", 1, true))
    assert.are.equal("Bearer ambient-secret",
      transport.fetch_requests[1].headers.Authorization)

    local malformed = wait(value:models({ resolve_auth = auth(nil) }))
    assert.is_false(malformed.ok)
    assert.matches("invalid JSON", malformed.error.message)

    local invalid_balance = wait(value:balance({ resolve_auth = auth(nil) }))
    assert.is_false(invalid_balance.ok)
    assert.matches("invalid balance", invalid_balance.error.message)

    local invalid_models = wait(value:models({ resolve_auth = auth(nil) }))
    assert.is_false(invalid_models.ok)
    assert.matches("invalid model catalog", invalid_models.error.message)
  end)

  it("requires credentials and validates options", function()
    local value = client.new({
      base_url = "https://example.test",
      transport = fake_transport.new(),
      ambient_api_key = function() return nil end,
    })
    local result = wait(value:models({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("Connect DeepSeek", result.error.message)

    assert.has_error(function() client.new({}) end)
    assert.has_error(function()
      client.new({ base_url = "x", max_response_bytes = 1 })
    end)
    assert.has_error(function()
      client.new({ base_url = "x", timeout_ms = 0 })
    end)
  end)

  it("bounds catalogs, rejects malformed balance entries, and uses the default environment", function()
    local too_many = {}
    for index = 1, 101 do too_many[index] = { id = "model-" .. index } end
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = too_many }) },
      { body = vim.json.encode({
        is_available = true,
        balance_infos = { {
          currency = "EUR", total_balance = "1.00",
          granted_balance = "0.00", topped_up_balance = "1.00",
        } },
      }) },
      { body = vim.json.encode({ data = { { id = "environment-model" } } }) },
    }
    local value = client.new({
      base_url = "https://example.test",
      transport = transport,
      ambient_api_key = function() return "api-key" end,
    })
    local result = wait(value:models({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("invalid model catalog", result.error.message)
    result = wait(value:balance({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("invalid balance", result.error.message)

    local previous = vim.env.DEEPSEEK_API_KEY
    vim.env.DEEPSEEK_API_KEY = "environment-key"
    value = client.new({
      base_url = "https://example.test",
      transport = transport,
    })
    result = wait(value:models({ resolve_auth = auth(nil) }))
    vim.env.DEEPSEEK_API_KEY = previous
    assert.is_true(result.ok)
    assert.are.equal("Bearer environment-key",
      transport.fetch_requests[3].headers.Authorization)
  end)
end)
