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

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@return Neoagent.Run<Neoagent.AuthResolution, nil>
local function bearer_auth()
  return async.run(function()
    return {
      ok = true,
      configured = true,
      method = "integration",
      credential_type = "api_key",
      request_opts = {
        headers = { Authorization = "Bearer integration-key" },
      },
    }
  end)
end

---@return Neoagent.Run<Neoagent.AuthResolution, nil>
local function anthropic_auth()
  return async.run(function()
    return {
      ok = true,
      configured = true,
      method = "integration",
      credential_type = "api_key",
      request_opts = { headers = { ["x-api-key"] = "integration-key" } },
    }
  end)
end

---@param service Neoagent.ProviderService
---@param id string
---@param resolve_auth fun(scope?: string): Neoagent.Run<Neoagent.AuthResolution, nil>
---@return Neoagent.ProviderOperationRun
local function operation(service, id, resolve_auth)
  return (assert(provider_service.run(service, id, {
    resolve_auth = resolve_auth,
  })))
end

---@param service Neoagent.ProviderService
---@return string?
local function status_text(service)
  local state = service:state()
  assert(state)
  for _, block in ipairs(state.blocks) do
    if block.type == "status" then return block.text end
  end
end

---@param service Neoagent.ProviderService
---@param label string
---@return string?
local function field_value(service, label)
  local state = service:state()
  assert(state)
  for _, block in ipairs(state.blocks) do
    if block.type == "field" and block.label == label then return block.value end
  end
end

---@param service Neoagent.ProviderService
---@param label string
---@return Neoagent.ProviderLimitBlock?
local function limit_block(service, label)
  local state = service:state()
  assert(state)
  for _, candidate in ipairs(state.blocks) do
    if candidate.type == "limit" and candidate.label == label then
      return candidate
    end
  end
end

describe("provider management HTTP integration", function()
  ---@type Neoagent.TestHttpReplay?
  local scenario
  ---@type Neoagent.ProviderService[]?
  local services
  ---@type Neoagent.ModelCatalog[]?
  local catalogs
  local directories = {}

  after_each(function()
    for _, service in ipairs(services or {}) do assert(service.destroy)(service) end
    for _, catalog in ipairs(catalogs or {}) do catalog:destroy() end
    services = nil
    catalogs = nil
    local completed = scenario
    scenario = nil
    if completed then completed.close() end
    for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
    directories = {}
    require("neoagent.config")._reset()
    if completed then completed.assert_consumed() end
  end)

  for _, case in ipairs({
    { id = "deepseek", module = deepseek, suffix = "/deepseek", captures = { 1, 2 } },
    { id = "openai", module = openai, suffix = "/openai", captures = { 3, 4 } },
    { id = "anthropic", module = anthropic, suffix = "/anthropic", captures = { 5, 6, 7 } },
    { id = "zai", module = zai, suffix = "/api/paas/v4", captures = { 8, 9 } },
    { id = "zai-coding-plan", auth = "zai", module = zai, suffix = "/api/coding/paas/v4", captures = { 10, 11 } },
  }) do
    it("recovers " .. case.id .. " discovery and reporting after local credential corruption is repaired", function()
      local fs = require("neoagent.fs")
      local directory = vim.fn.tempname()
      directories[#directories + 1] = directory
      assert(fs.mkdirp(directory))
      local path = directory .. "/auth.json"
      assert(fs.write_all(path, "[broken"))
      local configured = require("neoagent.config").setup({ default_registry = false })
      local store = require("neoagent.auth.store").new(path)
      local auth = require("neoagent.auth").new({ methods = configured.auth.methods, store = store })
      local entries = {}
      for _, index in ipairs(case.captures) do
        entries[#entries + 1] = { path = ("tests/recordings/providers/management-%02d.yaml"):format(index),
          body_subset = true, headers_subset = true }
      end
      scenario = http_replay.open(entries)
      local provider = { base_url = scenario.url .. case.suffix, auth = case.auth or case.id, models = {} }
      local function resolve_auth() return auth:resolve(provider.auth) end
      local catalog = model_catalog.new({ provider_id = case.id, provider = provider, transport = scenario,
        definition = { discover = case.module.discover_models }, models = {},
        authentication = { resolve = function() return resolve_auth() end } })
      catalogs = { catalog }
      local service = case.module.new({ base_url = provider.base_url, auth = provider.auth, models = {},
        service_opts = case.module == zai and { management_url = scenario.url } or nil },
        { provider_id = case.id, transport = scenario, now = function() return 1787270400 end })
      services = { service }

      local discovered = wait(catalog:refresh({ force = true }))
      assert.is_false(discovered.ok)
      assert.matches("Invalid credential file", assert(discovered.error).message)
      assert.are.same({}, catalog:snapshot().models)
      local refreshed = wait(operation(service, "refresh", resolve_auth))
      assert.is_false(refreshed.ok)
      assert.matches("Invalid credential file", assert(refreshed.error).message)
      assert.matches("Invalid credential file", assert(status_text(service)))
      assert.are.same({}, scenario.requests)
      assert.is_true(provider_service.operation_enabled(service, { mutating = true }))
      assert.are.equal("[broken", assert(fs.read(path)))

      assert(fs.write_all(path, "{}"))
      assert(store:write(provider.auth, { type = "api_key", key = "integration-key" }))
      assert.is_true(wait(catalog:refresh({ force = true })).ok)
      assert.is_not_nil((next(catalog:snapshot().models)))
      assert.is_true(wait(operation(service, "refresh", resolve_auth)).ok)
      assert.is_true(provider_service.operation_enabled(service, { mutating = true }))
      assert.are.equal(#case.captures, #scenario.requests)
    end)
  end

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
    ---@param id string
    ---@param provider Neoagent.CatalogSourceProvider
    ---@param discover Neoagent.CatalogDiscover
    ---@param resolve_auth fun(): Neoagent.Run<Neoagent.AuthResolution, nil>
    ---@return Neoagent.ModelCatalog
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

    assert.is_true(wait(assert(catalogs[1]):refresh({ force = true })).ok)
    assert.is_true(wait(operation(assert(services[1]), "refresh", bearer_auth)).ok)
    assert.is_table(assert(catalogs[1]):snapshot().models["deepseek-v5-preview"])

    assert.is_true(wait(assert(catalogs[2]):refresh({ force = true })).ok)
    assert.is_true(wait(operation(assert(services[2]), "refresh", bearer_auth)).ok)
    assert.matches("organization reporting is unavailable",
      assert(status_text(assert(services[2]))))

    assert.is_true(wait(assert(catalogs[3]):refresh({ force = true })).ok)
    assert.is_true(wait(operation(assert(services[3]), "refresh", anthropic_auth)).ok)
    assert.are.same({
      id = "claude-test",
      input = { "text", "image" },
      context_window = 200000,
      max_output_tokens = 64000,
      thinking_type = "adaptive",
      reasoning_levels = { "low", "medium", "high" },
    }, assert(catalogs[3]):snapshot().models["claude-test"])
    assert.is_table(assert(catalogs[3]):snapshot().models["claude-second"])
    assert.matches("organization reporting is unavailable",
      assert(status_text(assert(services[3]))))

    assert.is_true(wait(assert(catalogs[4]):refresh({ force = true })).ok)
    assert.is_table(assert(catalogs[4]):snapshot().models["glm-5.3-flash"])
    assert.is_true(wait(operation(assert(services[4]), "refresh", bearer_auth)).ok)
    assert.are.equal("$18.68", field_value(assert(services[4]), "Available balance"))
    assert.is_nil(status_text(assert(services[4])))

    assert.is_true(wait(assert(catalogs[5]):refresh({ force = true })).ok)
    assert.is_table(assert(catalogs[5]):snapshot().models["glm-5.3-flash"])
    assert.is_true(wait(operation(assert(services[5]), "refresh", bearer_auth)).ok)
    assert.are.equal("max", field_value(assert(services[5]), "Plan"))
    assert.is_nil(status_text(assert(services[5])))

    assert.is_true(wait(operation(assert(services[6]), "refresh", bearer_auth)).ok)
    assert.are.equal(0.4,
      assert(limit_block(assert(services[6]), "7-day quota")).remaining)

    assert.are.equal(12, #scenario.requests)
  end)
end)
