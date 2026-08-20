local async = require("neoagent.async")
local opencode_go = require("neoagent.providers.opencode_go")
local provider_service = require("neoagent.provider_service")
local fake_transport = require("tests.helpers.fake_transport")

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
      credential_type = "api_key",
      request_opts = { headers = {
        Authorization = "Bearer stored-key",
        ["x-api-key"] = "stored-key",
      } },
    }
  end)
end

local function operation(service, id, model)
  return provider_service.run(service, id, {
    resolve_auth = resolve_auth,
    model = model or { provider = "opencode-go", model = "kimi-k3" },
  })
end

describe("OpenCode Go provider service", function()
  it("loads shared quotas when its console first opens", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ usage = {
      rolling = {
        status = "ok", percent = 50,
        resetsAt = "2026-08-20T17:30:00.000Z",
      },
      weekly = {
        status = "ok", percent = 75,
        resetsAt = "2026-08-24T00:00:00.000Z",
      },
      monthly = {
        status = "ok", percent = 10,
        resetsAt = "2026-09-03T12:00:00.000Z",
      },
    } }) } }
    local service = opencode_go.new({
      base_url = "https://example.test/zen/go/v1",
      models = { ["kimi-k3"] = {}, ["glm-5.3"] = {} },
    }, { transport = transport })

    assert.are.equal("opencode-go", service.id)
    assert.are.equal("OpenCode Go", service.name)
    assert.are.equal("refresh", service.open_operation)
    assert.matches("loads when this console opens",
      block(service:state(), "status").text)
    local operation_ids = vim.tbl_keys(service.operations)
    table.sort(operation_ids)
    assert.are.same({ "models", "refresh" }, operation_ids)

    local result = wait(operation(service, "refresh"))
    assert.is_true(result.ok)
    local snapshot = service:state()
    assert.are.equal("Shared across all Go models",
      block(snapshot, "field", "Quota scope").value)
    assert.are.equal(0.5,
      block(snapshot, "limit", "5-hour limit").remaining)
    assert.are.equal("≈ $6.00 of $12 allowance remaining",
      block(snapshot, "limit", "5-hour limit").detail)
    assert.are.equal(0.25,
      block(snapshot, "limit", "Weekly limit").remaining)
    assert.are.equal(0.9,
      block(snapshot, "limit", "Monthly limit").remaining)
    assert.are.equal("kimi-k3",
      block(snapshot, "field", "Selected model").value)
    assert.are.same({
      { label = "5-hour", detail = "~55 of 110 typical requests" },
      { label = "Weekly", detail = "~62 of 250 typical requests" },
      { label = "Monthly", detail = "~441 of 490 typical requests" },
    }, block(snapshot, "list", "Selected-model estimate").items)

    snapshot = service:state({ model = {
      provider = "opencode-go", model = "glm-5.3",
    } })
    assert.are.equal("glm-5.3",
      block(snapshot, "field", "Selected model").value)
    assert.are.same({
      { label = "5-hour", detail = "~110 of 220 typical requests" },
      { label = "Weekly", detail = "~135 of 540 typical requests" },
      { label = "Monthly", detail = "~972 of 1,080 typical requests" },
    }, block(snapshot, "list", "Selected-model estimate").items)
    assert.are.equal("kimi-k3",
      block(service:state(), "field", "Selected model").value)
    assert.are.equal(1, #transport.fetch_requests)
  end)

  it("refreshes model discovery with protocol-safe entries", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ data = {
      { id = "gpt-5.6-luna" },
      { id = "minimax-m3" },
      { id = "future-chat-model" },
    } }) } }
    local service = opencode_go.new({
      base_url = "https://example.test/v1",
      models = {},
      catalog_cache = false,
    }, { transport = transport, startup = false })

    local result = wait(service:refresh_catalog({
      allow_network = true, force = true,
    }))
    assert.is_true(result.ok)
    assert.are.same({
      { id = "future-chat-model", input = { "text" } },
      {
        api = "openai-responses", id = "gpt-5.6-luna",
        input = { "text" },
      },
      {
        api = "anthropic-messages", id = "minimax-m3",
        input = { "text" },
      },
    }, service:get_models())

    transport.fetches = { { body = vim.json.encode({ data = {
      { id = "qwen3.5-plus" },
    } }) } }
    assert.is_true(wait(operation(service, "models")).ok)
    assert.are.same({
      {
        api = "anthropic-messages", id = "qwen3.5-plus",
        input = { "text" },
      },
    }, service:get_models())
  end)

  it("restores cached model ids without extending their freshness", function()
    local service = opencode_go.new({
      base_url = "https://example.test/v1",
      models = { ["static-model"] = {} },
      catalog_cache = { ttl_ms = 1000 },
    }, {
      transport = fake_transport.new(),
      startup = false,
      now = function() return 999 end,
    })
    local publication
    local result = wait(service:refresh_models({
      stored = {
        version = 1,
        checked_at = 123,
        models = { "cached-model" },
      },
      allow_network = false,
      publish = function(value)
        publication = value
        value.update()
        return true
      end,
    }))
    assert.is_true(result.ok)
    assert.are.equal(123, publication.persist.checked_at)
    assert.are.same({
      { id = "cached-model", input = { "text" } },
    }, service:get_models())
    assert.are.equal("2 available",
      block(service:state(), "field", "Models").value)
  end)

  it("refreshes explicit startup catalogs and reports startup failures", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ data = {
      { id = "grok-4.5" },
    } }) } }
    local service = opencode_go.new({
      base_url = "https://example.test/v1",
      models = {},
      catalog_cache = false,
    }, {
      transport = transport,
      explicit = true,
    })
    assert(vim.wait(3000, function() return #service:get_models() == 1 end))
    assert.are.same({ {
      api = "openai-responses",
      id = "grok-4.5",
      input = { "text" },
    } }, service:get_models())
    service:destroy()

    transport = fake_transport.new()
    transport.fetches = { {
      error = { kind = "transport", message = "catalog unavailable" },
    } }
    service = opencode_go.new({
      base_url = "https://example.test/v1",
      models = {},
      catalog_cache = false,
    }, {
      transport = transport,
      default_model = { provider = "opencode-go", model = "grok-4.5" },
    })
    assert(vim.wait(3000, function()
      local current = block(service:state(), "status")
      return current and current.text:find("catalog refresh failed", 1, true)
    end))
    assert.matches("catalog unavailable",
      block(service:state(), "status").text)
    service:destroy()
  end)

  it("rejects unusable cache and invalid service configuration", function()
    local service = opencode_go.new({
      base_url = "https://example.test/v1",
      models = {},
    }, { transport = fake_transport.new(), startup = false })
    local result = wait(service:refresh_models({
      stored = { version = 1, checked_at = 0, models = { "bad\nmodel" } },
      allow_network = false,
      publish = function() return true end,
    }))
    assert.is_false(result.ok)
    assert.matches("no usable cached", result.error.message)
    service:destroy()

    assert.has_error(function()
      opencode_go.new({ service_opts = { unsupported = 1 } })
    end)
    assert.has_error(function()
      opencode_go.new({ service_opts = { timeout_ms = 0 } })
    end)
    assert.has_error(function()
      opencode_go.new({ catalog_cache = { unsupported = true } })
    end)
    assert.has_error(function()
      opencode_go.new({ catalog_cache = { ttl_ms = -1 } })
    end)
  end)

  it("keeps prior quotas visible across refresh failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ usage = {
        rolling = { status = "ok", percent = 20,
          resetsAt = "2026-08-20T17:30:00.000Z" },
        weekly = { status = "ok", percent = 30,
          resetsAt = "2026-08-24T00:00:00.000Z" },
        monthly = { status = "ok", percent = 40,
          resetsAt = "2026-09-03T12:00:00.000Z" },
      } }) },
      { status = 429, body = "rate limited body" },
    }
    local service = opencode_go.new({
      base_url = "https://example.test/v1", models = {},
    }, { transport = transport })
    assert.is_true(wait(operation(service, "refresh")).ok)
    local result = wait(operation(service, "refresh"))
    assert.is_false(result.ok)
    local snapshot = service:state()
    assert.are.equal(0.8,
      block(snapshot, "limit", "5-hour limit").remaining)
    assert.matches("refresh failed", block(snapshot, "status").text)
    assert.is_nil(vim.inspect(snapshot):find("rate limited body", 1, true))
    assert.is_nil(vim.inspect(snapshot):find("stored-key", 1, true))
  end)

  it("publishes exhausted windows and destroys its state", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ usage = {
      rolling = { status = "rate-limited", percent = 100,
        resetsAt = "2026-08-20T17:30:00.000Z" },
      weekly = { status = "ok", percent = 1,
        resetsAt = "2026-08-24T00:00:00.000Z" },
      monthly = { status = "ok", percent = 2,
        resetsAt = "2026-09-03T12:00:00.000Z" },
    } }) } }
    local service = opencode_go.new({
      base_url = "https://example.test/v1", models = {},
    }, { transport = transport })
    local published
    local unsubscribe = service:subscribe(function(value) published = value end)
    assert.is_true(wait(operation(service, "refresh",
      { provider = "opencode-go", model = "unknown" })).ok)
    assert.are.equal("A Go usage window is exhausted",
      block(service:state(), "status").text)
    assert.are.equal("error",
      block(service:state(), "limit", "5-hour limit").level)
    assert.is_table(published)
    unsubscribe()
    service:destroy()
    assert.are.same({}, service:state().blocks)
  end)
end)
