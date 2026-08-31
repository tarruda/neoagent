local async = require("neoagent.async")
local fake_transport = require("tests.helpers.fake_transport")
local openai = require("neoagent.providers.openai")
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
        Authorization = "Bearer inference-key",
      } },
    }
  end)
end

local function operation(service)
  return provider_service.run(service, "refresh", {
    resolve_auth = resolve_auth,
  })
end

describe("OpenAI API provider service", function()
  it("loads organization reporting through refresh", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        object = "page", has_more = false, data = { {
          start_time = 1, end_time = 2, results = { {
            input_tokens = 1000, input_cached_tokens = 250,
            output_tokens = 500, num_model_requests = 4,
          } },
        } },
      }) },
      { body = vim.json.encode({
        object = "page", has_more = false, data = { {
          start_time = 1, end_time = 2, results = {
            { amount = { value = 3.5, currency = "usd" } },
            { amount = { value = 1.25, currency = "eur" } },
          },
        } },
      }) },
    }
    local service = openai.new({
      base_url = "https://example.test/v1",
    }, {
      transport = transport,
      now = function() return 1787270400 end,
    })

    assert.are.equal("openai", service.id)
    assert.are.equal("OpenAI API", service.name)
    assert.are.same({ "refresh" }, vim.tbl_keys(service.operations))
    local updates = 0
    local unsubscribe = service:subscribe(function() updates = updates + 1 end)
    assert.is_true(wait(operation(service)).ok)
    assert.are.equal(1, updates)
    unsubscribe()

    local snapshot = service:state()
    local costs = {}
    for _, item in ipairs(snapshot.blocks) do
      if item.type == "field" and item.label == "30-day cost" then
        costs[#costs + 1] = item.value
      end
    end
    assert.are.same({ "1.25 EUR", "$3.50" }, costs)
    assert.are.same({
      { label = "Requests", detail = "4" },
      { label = "Input tokens", detail = "1,000" },
      { label = "Cached input", detail = "250" },
      { label = "Output tokens", detail = "500" },
    }, block(snapshot, "list", "30-day completion usage").items)
    assert.are.equal("Bearer inference-key",
      transport.fetch_requests[1].headers.Authorization)
    assert.are.equal("Bearer inference-key",
      transport.fetch_requests[2].headers.Authorization)
  end)

  it("warns when the API key lacks report permission", function()
    local transport = fake_transport.new()
    transport.fetches = { { status = 403, body = "forbidden" } }
    local service = openai.new({
      base_url = "https://example.test/v1",
    }, { transport = transport })

    local result = wait(operation(service))
    assert.is_true(result.ok)
    assert.matches("organization reporting is unavailable",
      block(service:state(), "status").text)
  end)

  it("fails refreshes for reporting errors unrelated to permission", function()
    local transport = fake_transport.new()
    transport.fetches = { { status = 429, body = "private response" } }
    local service = openai.new({
      base_url = "https://example.test/v1",
    }, { transport = transport })

    local result = wait(operation(service))
    assert.is_false(result.ok)
    assert.are.equal(429, result.error.status)
    local snapshot = service:state()
    assert.matches("Organization refresh failed", block(snapshot, "status").text)
    assert.is_nil(vim.inspect(snapshot):find("private response", 1, true))
  end)

  it("uses OPENAI_API_KEY and validates service options", function()
    assert.has_error(function()
      openai.new({ service_opts = { unsupported = true } })
    end)
    assert.has_error(function()
      openai.new({ service_opts = { timeout_ms = 0 } })
    end)

    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ has_more = false, data = {} }) },
      { body = vim.json.encode({ has_more = false, data = {} }) },
    }
    local previous = vim.env.OPENAI_API_KEY
    vim.env.OPENAI_API_KEY = "environment-key"
    local service = openai.new({
      base_url = "https://example.test/v1",
    }, { transport = transport })
    local result = wait(provider_service.run(service, "refresh", {
      resolve_auth = function()
        return async.run(function()
          return { ok = true, configured = false }
        end)
      end,
    }))
    vim.env.OPENAI_API_KEY = previous
    assert.is_true(result.ok)
    assert.are.equal("Bearer environment-key",
      transport.fetch_requests[1].headers.Authorization)
  end)
end)
