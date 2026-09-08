local assert = require("luassert")
local async = require("neoagent.async")
local deepseek = require("neoagent.providers.deepseek")
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
      request_opts = { headers = {
        Authorization = "Bearer stored-key",
      } },
    }
  end)
end

---@param service Neoagent.ProviderService
---@param id string
---@return Neoagent.ProviderOperationRun
local function operation(service, id)
  return (assert(provider_service.run(service, id, {
    resolve_auth = resolve_auth,
  })))
end

describe("DeepSeek provider service", function()
  it("loads balance through refresh", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      is_available = true,
      balance_infos = { {
        currency = "USD", total_balance = "12.34",
        granted_balance = "2.34", topped_up_balance = "10.00",
      } },
    }) } }
    local service = deepseek.new({
      base_url = "https://example.test",
    }, { transport = transport, startup = false })

    assert.are.equal("deepseek", service.id)
    assert.are.equal("DeepSeek", service.name)
    assert.is_nil(block(service:state(), "status"))
    local operation_ids = vim.tbl_keys(service.operations)
    table.sort(operation_ids)
    assert.are.same({ "refresh" }, operation_ids)
    assert.is_nil(block(service:state(), "field", "Selected model"))
    local updates = 0
    local unsubscribe = assert(service.subscribe)(service, function() updates = updates + 1 end)

    local result = wait(operation(service, "refresh"))
    assert.is_true(result.ok)
    assert.are.equal(1, updates)
    unsubscribe()
    local snapshot = service:state()
    assert(snapshot)
    assert.is_nil(block(snapshot, "field", "Account"))
    assert.are.same({
      { label = "Total", detail = "$12.34" },
      { label = "Topped up", detail = "$10.00" },
      { label = "Granted", detail = "$2.34" },
    }, assert(block(snapshot, "list", "USD balance")).items)
    assert.is_nil(block(snapshot, "field", "Selected model"))
  end)

  it("reports refresh failures without losing balance", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ is_available = false, balance_infos = { {
        currency = "USD", total_balance = "1.28",
        granted_balance = "0.00", topped_up_balance = "1.28",
      } } }) },
      { status = 429, body = "private response" },
      { body = vim.json.encode({ is_available = true, balance_infos = { {
        currency = "USD", total_balance = "2.00",
        granted_balance = "0.50", topped_up_balance = "1.50",
      } } }) },
    }
    local service = deepseek.new({
      base_url = "https://example.test",
    }, { transport = transport, startup = false, now = function() return 50 end })

    assert.is_true(wait(operation(service, "refresh")).ok)
    assert.is_nil(block(service:state(), "field", "Account"))
    assert.is_nil(block(service:state(), "status"))
    assert.are.same({
      { label = "Total", detail = "$1.28" },
      { label = "Topped up", detail = "$1.28" },
      { label = "Granted", detail = "$0.00" },
    }, assert(block(service:state(), "list", "USD balance")).items)
    local failed = wait(operation(service, "refresh"))
    assert.is_false(failed.ok)
    local snapshot = service:state()
    assert(snapshot)
    assert.matches("Balance refresh failed", assert(block(snapshot, "status")).text)
    assert.is_nil(block(snapshot, "field", "Account"))
    assert.are.equal("$1.28",
      assert(assert(block(snapshot, "list", "USD balance")).items[1]).detail)
    assert.is_nil((vim.inspect(snapshot):find("private response", 1, true)))

    local recovered = wait(operation(service, "refresh"))
    assert.is_true(recovered.ok)
    snapshot = assert(service:state())
    assert.is_nil(block(snapshot, "status"))
    assert.are.equal("$2.00",
      assert(assert(block(snapshot, "list", "USD balance")).items[1]).detail)
    assert(service.destroy)(service)
    assert.are.same({}, service:state().blocks)
  end)

  it("rejects invalid service options", function()
    assert.has_error(function()
      deepseek.new({ service_opts = { unsupported = true } })
    end)
    assert.has_error(function()
      deepseek.new({ service_opts = { timeout_ms = 0 } })
    end)
  end)

  it("warns nonfatally when the API key cannot query balance", function()
    local transport = fake_transport.new()
    transport.fetches = { { status = 403, body = "private response" } }
    local service = deepseek.new({
      base_url = "https://example.test",
    }, { transport = transport, startup = false })

    local result = wait(operation(service, "refresh"))
    assert.is_true(result.ok)
    local snapshot = service:state()
    assert(snapshot)
    assert.are.equal("warn", assert(block(snapshot, "status")).level)
    assert.matches("balance reporting is unavailable",
      assert(block(snapshot, "status")).text)
    assert.is_nil((vim.inspect(snapshot):find("private response", 1, true)))
  end)

end)
