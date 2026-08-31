local async = require("neoagent.async")
local deepseek = require("neoagent.providers.deepseek")
local fake_transport = require("tests.helpers.fake_transport")
local provider_service = require("neoagent.provider_service")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function block(snapshot, block_type, label)
  for _, candidate in ipairs(snapshot.blocks or {}) do
    if candidate.type == block_type
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
      request_opts = { headers = {
        Authorization = "Bearer stored-key",
      } },
    }
  end)
end

local function operation(service, id)
  return provider_service.run(service, id, {
    resolve_auth = resolve_auth,
  })
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
    local unsubscribe = service:subscribe(function() updates = updates + 1 end)

    local result = wait(operation(service, "refresh"))
    assert.is_true(result.ok)
    assert.are.equal(1, updates)
    unsubscribe()
    local snapshot = service:state()
    assert.is_nil(block(snapshot, "field", "Account"))
    assert.are.same({
      { label = "Total", detail = "$12.34" },
      { label = "Topped up", detail = "$10.00" },
      { label = "Granted", detail = "$2.34" },
    }, block(snapshot, "list", "USD balance").items)
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
    }, block(service:state(), "list", "USD balance").items)
    local failed = wait(operation(service, "refresh"))
    assert.is_false(failed.ok)
    local snapshot = service:state()
    assert.matches("Balance refresh failed", block(snapshot, "status").text)
    assert.is_nil(block(snapshot, "field", "Account"))
    assert.are.equal("$1.28",
      block(snapshot, "list", "USD balance").items[1].detail)
    assert.is_nil(vim.inspect(snapshot):find("private response", 1, true))

    local recovered = wait(operation(service, "refresh"))
    assert.is_true(recovered.ok)
    snapshot = service:state()
    assert.is_nil(block(snapshot, "status"))
    assert.are.equal("$2.00",
      block(snapshot, "list", "USD balance").items[1].detail)
    service:destroy()
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
    assert.are.equal("warn", block(snapshot, "status").level)
    assert.matches("balance reporting is unavailable",
      block(snapshot, "status").text)
    assert.is_nil(vim.inspect(snapshot):find("private response", 1, true))
  end)

end)
