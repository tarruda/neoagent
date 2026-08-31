local async = require("neoagent.async")
local fake_transport = require("tests.helpers.fake_transport")
local provider_service = require("neoagent.provider_service")
local zai = require("neoagent.providers.zai")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function block(snapshot, kind, label)
  for _, candidate in ipairs(snapshot.blocks or {}) do
    if candidate.type == kind
        and (label == nil or candidate.label == label
          or candidate.title == label) then
      return candidate
    end
  end
end

local function resolve_auth()
  return async.run(function()
    return {
      ok = true,
      configured = true,
      request_opts = { headers = { Authorization = "Bearer api-key" } },
    }
  end)
end

local function operation(service, id)
  return provider_service.run(service, id, {
    resolve_auth = resolve_auth,
  })
end

describe("Z.AI provider services", function()
  it("loads the general API balance through refresh", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      data = {
        total_balance = 100,
        available_balance = 72.5,
        currency = "USD",
      },
    }) } }
    local service = zai.new({
      base_url = "https://api.example.test/api/paas/v4",
    }, { provider_id = "zai", transport = transport })

    assert.are.equal("zai", service.id)
    assert.are.equal("Z.AI API", service.name)
    assert.are.same({ "refresh" }, vim.tbl_keys(service.operations))
    local snapshot = service:state()
    assert.is_nil(block(snapshot, "status"))
    assert.are.equal("https://api.example.test/api/paas/v4",
      block(snapshot, "field", "Endpoint").value)
    assert.is_nil(block(snapshot, "field", "Models"))
    assert.is_nil(block(snapshot, "field", "Selected model"))

    assert.is_true(wait(operation(service, "refresh")).ok)
    snapshot = service:state()
    assert.is_nil(block(snapshot, "status"))
    assert.are.equal("$72.50",
      block(snapshot, "field", "Available balance").value)
    assert.are.equal("$100.00",
      block(snapshot, "field", "Total balance").value)
    assert.are.equal(
      "https://api.example.test/api/paas/v4/balance",
      transport.fetch_requests[1].url)
    assert.are.equal("Bearer api-key",
      transport.fetch_requests[1].headers.Authorization)
  end)

  it("warns nonfatally when the general API balance is unavailable", function()
    local transport = fake_transport.new()
    transport.fetches = { { status = 404, body = "private response" } }
    local service = zai.new({
      base_url = "https://api.example.test/api/paas/v4",
      models = {},
    }, { provider_id = "zai", transport = transport })

    local result = wait(operation(service, "refresh"))
    assert.is_true(result.ok)
    local status = block(service:state(), "status")
    assert.are.equal("warn", status.level)
    assert.matches("balance reporting is unavailable", status.text)
    assert.is_nil(vim.inspect(service:state()):find(
      "private response", 1, true))
  end)

  it("reports an exhausted balance and preserves it across later failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        data = {
          total_balance = 5, available_balance = 0, currency = "CNY",
        },
      }) },
      { status = 429, body = "private response" },
    }
    local service = zai.new({
      base_url = "https://api.example.test/api/paas/v4",
      models = {},
    }, { provider_id = "zai", transport = transport })

    assert.is_true(wait(operation(service, "refresh")).ok)
    local snapshot = service:state()
    assert.matches("balance is exhausted", block(snapshot, "status").text)
    assert.are.equal("CNY 0.00",
      block(snapshot, "field", "Available balance").value)

    local failed = wait(operation(service, "refresh"))
    assert.is_false(failed.ok)
    assert.are.equal(429, failed.error.status)
    snapshot = service:state()
    assert.matches("Balance refresh failed", block(snapshot, "status").text)
    assert.are.equal("CNY 0.00",
      block(snapshot, "field", "Available balance").value)
    assert.is_nil(vim.inspect(snapshot):find("private response", 1, true))
  end)

  it("loads plan quotas through refresh", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ data = {
      planName = "Max",
      limits = {
        { type = "TOKENS_LIMIT", percentage = 25,
          nextResetTime = 1787270400000, unit = 3, number = 5 },
        { type = "TIME_LIMIT", percentage = 50,
          currentValue = 5, usage = 10, unit = 5, number = 1 },
      },
    } }) } }
    local service = zai.new({
      base_url = "https://api.example.test/api/coding/paas/v4",
      service_opts = { management_url = "https://manage.example.test" },
    }, {
      provider_id = "zai-coding-plan",
      transport = transport,
    })

    assert.are.equal("Z.AI Plan", service.name)
    assert.are.same({ "refresh" }, vim.tbl_keys(service.operations))
    local initial = service:state()
    assert.is_nil(block(initial, "status"))
    assert.is_nil(block(initial, "field", "Selected model"))
    assert.is_nil(block(initial, "field", "Models"))
    local updates = 0
    local unsubscribe = service:subscribe(function() updates = updates + 1 end)
    assert.is_true(wait(operation(service, "refresh")).ok)
    assert.are.equal(1, updates)
    unsubscribe()
    local snapshot = service:state()
    assert.are.equal("Max", block(snapshot, "field", "Plan").value)
    local tokens = block(snapshot, "limit", "5-hour token limit")
    assert.are.equal(0.75, tokens.remaining)
    assert.are.equal(1787270400, tokens.resets_at)
    local tools = block(snapshot, "limit", "Monthly MCP limit")
    assert.are.equal(0.5, tools.remaining)
    assert.are.equal("5 of 10 uses consumed", tools.detail)
  end)

  it("renders current plan credit windows", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ success = true, data = {
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
    } }) } }
    local service = zai.new({
      base_url = "https://api.example.test/api/coding/paas/v4",
      models = {},
    }, {
      provider_id = "zai-coding-plan",
      transport = transport,
    })

    assert.is_true(wait(operation(service, "refresh")).ok)
    local snapshot = service:state()
    assert.are.equal("max", block(snapshot, "field", "Plan").value)
    local session = block(snapshot, "limit", "5-hour credit limit")
    assert.are.equal(0.75, session.remaining)
    assert.are.equal("7,000 of 28,000 credits consumed", session.detail)
    local weekly = block(snapshot, "limit", "Weekly credit limit")
    assert.are.equal(0.9, weekly.remaining)
    assert.are.equal(1787875200, weekly.resets_at)
  end)

  it("warns nonfatally when the configured key cannot query quotas", function()
    local transport = fake_transport.new()
    transport.fetches = { { status = 403, body = "private response" } }
    local service = zai.new({
      base_url = "https://api.example.test/api/coding/paas/v4",
      models = {},
      service_opts = { management_url = "https://manage.example.test" },
    }, {
      provider_id = "zai-coding-plan",
      transport = transport,
    })

    local result = wait(operation(service, "refresh"))
    assert.is_true(result.ok)
    local status = block(service:state(), "status")
    assert.are.equal("warn", status.level)
    assert.matches("quota reporting is unavailable", status.text)
    assert.is_nil(vim.inspect(service:state()):find("private response", 1, true))
  end)

  it("validates service options", function()
    assert.has_error(function()
      zai.new({ service_opts = { unsupported = true } })
    end)
    assert.has_error(function()
      zai.new({ service_opts = { management_url = "" } })
    end)
    assert.has_error(function()
      zai.new({ service_opts = { timeout_ms = 0 } })
    end)
  end)

  it("renders exhausted and low quotas and reports other refresh failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = { limits = {
        { type = "TOKENS_LIMIT", percentage = 100 },
        { type = "TIME_LIMIT", percentage = 90 },
      } } }) },
      { status = 429, body = "private response" },
    }
    local service = zai.new({
      base_url = "https://manage.example.test/api/coding/paas/v4",
      models = {},
    }, {
      provider_id = "zai-coding-plan",
      transport = transport,
    })
    assert.is_true(wait(operation(service, "refresh")).ok)
    local snapshot = service:state()
    assert.are.equal("error",
      block(snapshot, "limit", "5-hour token limit").level)
    assert.are.equal("warn",
      block(snapshot, "limit", "Monthly MCP limit").level)

    local result = wait(operation(service, "refresh"))
    assert.is_false(result.ok)
    assert.are.equal(429, result.error.status)
    assert.matches("Quota refresh failed", block(service:state(), "status").text)
    assert.are.equal("https://manage.example.test/api/monitor/usage/quota/limit",
      transport.fetch_requests[1].url)
    assert.is_nil(vim.inspect(service:state()):find("private response", 1, true))
  end)
end)
