local assert = require("luassert")
local async = require("neoagent.async")
local alibaba = require("neoagent.providers.alibaba_token_plan")
local alibaba_client = require("neoagent.providers.alibaba_token_plan.client")
local anthropic = require("neoagent.providers.anthropic")
local deepseek = require("neoagent.providers.deepseek")
local model_catalog = require("neoagent.model_catalog")
local http_replay = require("tests.helpers.http_replay")
local openai = require("neoagent.providers.openai")
local provider_service = require("neoagent.provider_service")
local zai = require("neoagent.providers.zai")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return run:result()
end

local function bearer_auth()
  return async.run(function()
    return {
      ok = true,
      configured = true,
      request_opts = {
        headers = { Authorization = "Bearer integration-key" },
      },
    }
  end)
end

local function anthropic_auth()
  return async.run(function()
    return {
      ok = true,
      configured = true,
      request_opts = { headers = { ["x-api-key"] = "integration-key" } },
    }
  end)
end

local function operation(service, id, resolve_auth)
  return provider_service.run(service, id, {
    resolve_auth = resolve_auth,
  })
end

local function status_text(service)
  for _, block in ipairs(service:state().blocks) do
    if block.type == "status" then return block.text end
  end
end

local function field_value(service, label)
  for _, block in ipairs(service:state().blocks) do
    if block.type == "field" and block.label == label then return block.value end
  end
end

local function block(service, block_type, label)
  for _, candidate in ipairs(service:state().blocks) do
    if candidate.type == block_type and candidate.label == label then
      return candidate
    end
  end
end

describe("provider management HTTP integration", function()
  local scenario
  local services
  local catalogs

  after_each(function()
    for _, service in ipairs(services or {}) do service:destroy() end
    for _, catalog in ipairs(catalogs or {}) do catalog:destroy() end
    services = nil
    catalogs = nil
    if scenario then http_replay.finish(scenario) scenario = nil end
  end)

  it("runs catalogs and reporting through recorded HTTP responses", function()
    scenario = http_replay.open({
      { path = "tests/recordings/providers/management-01.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-02.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-03.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-04.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-05.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-06.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-07.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-08.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-09.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-10.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-11.yaml", body_subset = true, headers_subset = true },
      { path = "tests/recordings/providers/management-12.yaml", body_subset = true, headers_subset = true },
    })
    local root = scenario.url
    local function catalog(id, provider, discover, resolve_auth)
      return model_catalog.new({
        provider_id = id,
        transport = scenario,
        provider = provider,
        definition = { discover = discover },
        models = {},
        authentication = { resolve = function() return resolve_auth() end },
      })
    end
    catalogs = {
      catalog("deepseek", {
        base_url = root .. "/deepseek",
        auth = "deepseek",
      }, deepseek.discover_models, bearer_auth),
      catalog("openai", {
        base_url = root .. "/openai",
        auth = "openai",
      }, openai.discover_models, bearer_auth),
      catalog("anthropic", {
        base_url = root .. "/anthropic",
        auth = "anthropic",
      }, anthropic.discover_models, anthropic_auth),
      catalog("zai", {
        base_url = root .. "/api/paas/v4",
        auth = "zai",
      }, zai.discover_models, bearer_auth),
      catalog("zai-coding-plan", {
        base_url = root .. "/api/coding/paas/v4",
        auth = "zai",
      }, zai.discover_models, bearer_auth),
    }
    services = {
      deepseek.new({ base_url = root .. "/deepseek" }, { transport = scenario }),
      openai.new({
        base_url = root .. "/openai",
      }, { transport = scenario, now = function() return 1787270400 end }),
      anthropic.new({
        base_url = root .. "/anthropic", auth = "anthropic",
      }, {
        provider_id = "anthropic",
        transport = scenario,
        now = function() return 1787270400 end,
      }),
      zai.new({
        base_url = root .. "/api/paas/v4", models = {},
        service_opts = { management_url = root },
      }, { provider_id = "zai", transport = scenario }),
      zai.new({
        base_url = root .. "/api/coding/paas/v4", models = {},
        service_opts = { management_url = root },
      }, { provider_id = "zai-coding-plan", transport = scenario }),
      alibaba.new(nil, {
        client = alibaba_client.new({
          gateway_url = root,
          transport = scenario,
        }),
      }),
    }

    assert.is_true(wait(catalogs[1]:refresh({ force = true })).ok)
    assert.is_true(wait(operation(services[1], "refresh", bearer_auth)).ok)
    assert.is_table(catalogs[1]:snapshot().models["deepseek-v5-preview"])

    assert.is_true(wait(catalogs[2]:refresh({ force = true })).ok)
    assert.is_true(wait(operation(services[2], "refresh", bearer_auth)).ok)
    assert.matches("organization reporting is unavailable",
      status_text(services[2]))

    assert.is_true(wait(catalogs[3]:refresh({ force = true })).ok)
    assert.is_true(wait(operation(services[3], "refresh", anthropic_auth)).ok)
    assert.are.same({
      id = "claude-test",
      input = { "text", "image" },
      context_window = 200000,
      max_output_tokens = 64000,
      thinking_type = "adaptive",
      reasoning_levels = { "low", "medium", "high" },
    }, catalogs[3]:snapshot().models["claude-test"])
    assert.is_table(catalogs[3]:snapshot().models["claude-second"])
    assert.matches("organization reporting is unavailable",
      status_text(services[3]))

    assert.is_true(wait(catalogs[4]:refresh({ force = true })).ok)
    assert.is_table(catalogs[4]:snapshot().models["glm-5.3-flash"])
    assert.is_true(wait(operation(services[4], "refresh", bearer_auth)).ok)
    assert.are.equal("$18.68", field_value(services[4], "Available balance"))
    assert.is_nil(status_text(services[4]))

    assert.is_true(wait(catalogs[5]:refresh({ force = true })).ok)
    assert.is_table(catalogs[5]:snapshot().models["glm-5.3-flash"])
    assert.is_true(wait(operation(services[5], "refresh", bearer_auth)).ok)
    assert.are.equal("max", field_value(services[5], "Plan"))
    assert.is_nil(status_text(services[5]))

    assert.is_true(wait(operation(services[6], "refresh", bearer_auth)).ok)
    assert.are.equal(0.4,
      block(services[6], "limit", "7-day quota").remaining)

    assert.are.equal(12, #scenario.requests)
  end)
end)
