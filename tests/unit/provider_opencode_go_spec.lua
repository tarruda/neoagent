local async = require("neoagent.async")
local fake_transport = require("tests.helpers.fake_transport")
local opencode_go = require("neoagent.providers.opencode_go")
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
      credential_type = "api_key",
      request_opts = { headers = {
        Authorization = "Bearer stored-key",
        ["x-api-key"] = "stored-key",
      } },
    }
  end)
end

local function operation(service, id, interact)
  return provider_service.run(service, id, {
    resolve_auth = resolve_auth,
    interact = interact,
  })
end

describe("OpenCode Go provider service", function()
  it("loads shared quotas through refresh", function()
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
    }, { transport = transport })

    assert.are.equal("opencode-go", service.id)
    assert.are.equal("OpenCode Go", service.name)
    assert.are.same({ "refresh" }, vim.tbl_keys(service.operations))
    local progress
    local interact = provider_service.no_interact()
    interact.progress = function(value) progress = value end
    local result = wait(operation(service, "refresh", interact))
    assert.is_true(result.ok)
    assert.are.same({
      id = "refresh",
      label = "Refresh usage",
      state = "running",
      message = "Loading OpenCode Go usage",
    }, progress)
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
    assert.are.equal(1, #transport.fetch_requests)
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
      base_url = "https://example.test/v1",
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
      base_url = "https://example.test/v1",
    }, { transport = transport })
    local published
    local unsubscribe = service:subscribe(function(value) published = value end)
    assert.is_true(wait(operation(service, "refresh")).ok)
    assert.are.equal("A Go usage window is exhausted",
      block(service:state(), "status").text)
    assert.are.equal("error",
      block(service:state(), "limit", "5-hour limit").level)
    assert.is_table(published)
    unsubscribe()
    service:destroy()
    assert.are.same({}, service:state().blocks)
  end)

  it("rejects invalid service configuration", function()
    assert.has_error(function()
      opencode_go.new({ service_opts = { unsupported = 1 } })
    end)
    assert.has_error(function()
      opencode_go.new({ service_opts = { timeout_ms = 0 } })
    end)
  end)
end)
