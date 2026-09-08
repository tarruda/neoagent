local assert = require("luassert")
local anthropic = require("neoagent.providers.anthropic")
local async = require("neoagent.async")
local fake_transport = require("tests.helpers.fake_transport")
local provider_service = require("neoagent.provider_service")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

local block = require("tests.helpers.provider_state").block

---@return Neoagent.Run<Neoagent.AuthResolution, nil>
local function resolve_auth()
  return async.run(function()
    return {
      ok = true,
      configured = true,
      method = "test",
      credential_type = "api_key",
      request_opts = { headers = { ["x-api-key"] = "api-key" } },
    }
  end)
end

---@param service Neoagent.ProviderService
---@return Neoagent.ProviderOperationRun
local function operation(service)
  return (assert(provider_service.run(service, "refresh", {
    resolve_auth = resolve_auth,
  })))
end

describe("Anthropic provider service", function()
  it("loads permitted organization reporting", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ has_more = false, data = { {
        results = { {
          uncached_input_tokens = 10, cache_read_input_tokens = 20,
          cache_creation = {
            ephemeral_5m_input_tokens = 30,
            ephemeral_1h_input_tokens = 40,
          },
          output_tokens = 50,
        } },
      } } }) },
      { body = vim.json.encode({ has_more = false, data = { {
        results = {
          { amount = "250.00", currency = "USD" },
          { amount = "125.00", currency = "EUR" },
        },
      } } }) },
    }
    local service = anthropic.new({
      base_url = "https://example.test/v1",
      auth = "anthropic",
    }, {
      provider_id = "anthropic",
      transport = transport,
      now = function() return 1787270400 end,
    })

    assert.are.equal("Anthropic API", service.name)
    assert.are.same({ "refresh" }, vim.tbl_keys(service.operations))
    local updates = 0
    local unsubscribe = assert(service.subscribe)(service, function() updates = updates + 1 end)
    assert.is_true(wait(operation(service)).ok)
    assert.are.equal(1, updates)
    unsubscribe()
    local snapshot = service:state()
    assert(snapshot)
    local costs = {}
    for _, item in ipairs(snapshot.blocks) do
      if item.type == "field" and item.label == "30-day cost" then
        costs[#costs + 1] = item.value
      end
    end
    assert.are.same({ "1.25 EUR", "$2.50" }, costs)
    assert.are.same({
      { label = "Uncached input", detail = "10" },
      { label = "Cache reads", detail = "20" },
      { label = "Cache writes", detail = "70" },
      { label = "Output", detail = "50" },
    }, assert(block(snapshot, "list", "30-day token usage")).items)
  end)

  it("warns on report permission and fails other reporting errors", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 401, body = "private permission response" },
      { status = 429, body = "private rate response" },
    }
    local service = anthropic.new({
      base_url = "https://example.test/v1",
      auth = "anthropic",
    }, {
      provider_id = "anthropic",
      transport = transport,
    })

    assert.is_true(wait(operation(service)).ok)
    local snapshot = service:state()
    assert(snapshot)
    assert.matches("organization reporting is unavailable",
      assert(block(snapshot, "status")).text)
    local failed = wait(operation(service))
    assert.is_false(failed.ok)
    assert.are.equal(429, rawget(assert(failed.error), "status"))
    snapshot = assert(service:state())
    assert.matches("Organization refresh failed", assert(block(snapshot, "status")).text)
    assert.is_nil((vim.inspect(snapshot):find("private", 1, true)))
  end)

  it("validates service options", function()
    assert.has_error(function()
      anthropic.new({ service_opts = { unsupported = true } })
    end)
    assert.has_error(function()
      anthropic.new({ service_opts = { timeout_ms = 0 } })
    end)
  end)
end)
