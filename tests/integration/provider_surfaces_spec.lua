local assert = require("luassert")
local auth = require("neoagent.auth")
local api_key = require("neoagent.auth.api_key")
local store = require("neoagent.auth.store")
local replay = require("tests.helpers.http_replay")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  local result = assert(run:result())
  assert(result.ok ~= false, (vim.inspect(result.error)))
  return result
end

describe("provider API surface replay", function()
  ---@type Neoagent.TestHttpReplay[]
  local scenarios = {}
  ---@type string[]
  local directories = {}
  before_each(function() scenarios, directories = {}, {} end)
  after_each(function()
    for _, value in ipairs(scenarios) do replay.finish(value) end
    for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
  end)
  ---@param exchanges (string|Neoagent.ReplayEntryOptions)[]
  ---@return Neoagent.TestHttpReplay
  local function open(exchanges)
    local value = replay.open(exchanges)
    scenarios[#scenarios + 1] = value
    return value
  end
  ---@param method Neoagent.AuthMethod<Neoagent.Credential>
  ---@param now? fun(): number
  ---@return Neoagent.AuthManager
  local function manager(method, now)
    local directory = vim.fn.tempname()
    directories[#directories + 1] = directory
    return auth.new({ methods = { test = method }, store = store.new(directory .. "/credentials.json"), now = now })
  end
  ---@param key string
  ---@param header? string
  ---@return Neoagent.ProviderAuthContext
  local function key_context(key, header)
    local value = manager(api_key.new({ name = "Test", request_opts = function(credential)
      return { headers = { [header or "Authorization"] = header and credential.key or "Bearer " .. credential.key } }
    end }))
    wait(value:login("test", { prompt = function(_, done) done.resolve(key) end }))
    return { resolve_auth = function() return value:resolve("test") end }
  end

  it("retrieves OpenAI organization usage and costs with real key authentication", function()
    local scenario = open({
      { path = "tests/recordings/openai/organization-01.yaml", headers_subset = true },
      { path = "tests/recordings/openai/organization-02.yaml", headers_subset = true },
    })
    local client = require("neoagent.providers.openai.client").new({
      base_url = scenario.url .. "/v1", transport = scenario, now = function() return 1787270400 end,
    })
    local result = wait(client:organization(key_context("admin-key")))
    assert.are.same({ requests = 5, input_tokens = 1000, cached_input_tokens = 400, output_tokens = 500 }, result.usage)
    assert.are.same({ { currency = "usd", value = 1.25 } }, result.costs)
  end)

  it("retrieves Anthropic organization usage and costs with its versioned auth headers", function()
    local scenario = open({
      { path = "tests/recordings/anthropic/organization-01.yaml", headers_subset = true },
      { path = "tests/recordings/anthropic/organization-02.yaml", headers_subset = true },
    })
    local client = require("neoagent.providers.anthropic.client").new({
      base_url = scenario.url .. "/v1", transport = scenario, now = function() return 1787270400 end,
    })
    local result = wait(client:organization(key_context("admin-key", "x-api-key")))
    assert.are.same({ uncached_input_tokens = 100, cache_read_input_tokens = 200,
      cache_creation_input_tokens = 75, output_tokens = 300 }, result.usage)
    assert.are.same({ { currency = "USD", value = 2 } }, result.costs)
  end)

  it("retrieves an adapted DeepSeek balance through real key authentication", function()
    local scenario = open({ {
      path = "tests/recordings/providers/management-02.yaml", headers_subset = true,
    } })
    local client = require("neoagent.providers.deepseek.client").new({
      base_url = scenario.url .. "/deepseek", transport = scenario,
    })
    local result = wait(client:balance(key_context("integration-key")))
    assert.are.same({
      is_available = true,
      currencies = { {
        currency = "USD", total = "12.75", granted = "2.25", topped_up = "10.50",
      } },
    }, result.balance)
  end)

  it("retrieves an adapted public OpenCode Go catalog and authenticated usage", function()
    local scenario = open({
      { path = "tests/recordings/opencode-go/management-01.yaml", headers_subset = true },
      { path = "tests/recordings/opencode-go/management-02.yaml", headers_subset = true },
    })
    local client = require("neoagent.providers.opencode_go.client").new({ base_url = scenario.url .. "/v1", transport = scenario })
    assert.are.same({ "synth-glm", "synth-minimax" }, wait(client:models()).models)
    assert.is_nil(rawget(assert(assert(scenario.requests[1]).headers), "Authorization"))
    local result = wait(client:usage(key_context("go-key")))
    assert.are.equal(0.55, assert(assert(result.usage).rolling).remaining)
    assert.are.equal(0.88, assert(assert(result.usage).weekly).remaining)
  end)

  it("uses subscription credentials for every Codex account operation and conditional inventory", function()
    local scenario = open({
      { path = "tests/recordings/openai/account-operations-01.yaml", headers_subset = true },
      { path = "tests/recordings/openai/account-operations-02.yaml", headers_subset = true },
      { path = "tests/recordings/openai/account-operations-03.yaml", headers_subset = true },
      { path = "tests/recordings/openai/account-operations-04.yaml", headers_subset = true },
      { path = "tests/recordings/openai/account-operations-05.yaml", headers_subset = true },
      { path = "tests/recordings/openai/account-operations-06.yaml", headers_subset = true },
    })
    local method = require("neoagent.auth.openai_codex").new({ http = scenario })
    local value = manager(method, function() return 0 end)
    assert(value.store:write("test", { type = "oauth", access = "secret-token", refresh = "refresh-token",
      expires = 9999999999999, accountId = "secret-account" }))
    local ctx = { resolve_auth = function() return value:resolve("test") end }
    local client = require("neoagent.providers.codex_management").new({ base_url = scenario.url .. "/backend-api", transport = scenario })
    assert.are.equal(3, assert(assert(wait(client:activity(ctx)).value).stats).active_days)
    assert.are.same({}, assert(wait(client:accounts(ctx)).value).accounts)
    assert.are.equal(1, assert(wait(client:reset_credits(ctx)).value).available_count)
    assert.are.equal(2, assert(wait(client:redeem(ctx, "stable-request", "credit-1")).value).windows_reset)
    ---@type Neoagent.CatalogDiscoveryContext<Neoagent.CatalogSourceProjection>
    local catalog_ctx = {
      provider_id = "openai-codex",
      provider = { base_url = scenario.url .. "/backend-api" },
      transport = scenario,
      resolve_auth = ctx.resolve_auth,
      resolve_api_key = function() return nil end,
      force = false,
      now = function() return 0 end,
    }
    local catalog = require("neoagent.providers.codex.catalog")
    local inventory = wait(catalog.discover(catalog_ctx))
    assert.are.equal("gpt-test", assert(assert(inventory.models)[1]).id)
    assert.are.equal("inventory-1", assert(inventory.validator).etag)
    catalog_ctx.validator = inventory.validator
    assert.is_true(wait(catalog.discover(catalog_ctx)).unchanged)
  end)

  it("searches and inspects gated Hugging Face models using the discovery token", function()
    local scenario = open({
      { path = "tests/recordings/llama/huggingface-01.yaml", headers_subset = true },
      { path = "tests/recordings/llama/huggingface-02.yaml", headers_subset = true },
    })
    local client = require("neoagent.providers.llama.huggingface").new({
      base_url = scenario.url, transport = scenario, token = "hf-synthetic",
    })
    assert.are.same({ { id = "owner/repo", downloads = 42 } }, wait(client:search("a b")))
    local result = wait(client:details("owner/repo"))
    assert.are.equal("auto", result.gated)
    assert.are.same({ { name = "Q4_K_M", size = 3000 } }, result.quantizations)
  end)

  it("probes llama.cpp anonymously, authenticates when required, and retains the credential scope", function()
    local scenario = open({
      { path = "tests/recordings/llama/authentication-01.yaml", headers_subset = true },
      { path = "tests/recordings/llama/authentication-02.yaml", headers_subset = true },
    })
    local method = require("neoagent.providers.llama.auth").new({ transport = scenario })
    local value = manager(method)
    wait(value:login("test", { prompt = function(prompt, done)
      done.resolve(prompt.type == "secret" and "router-key" or scenario.url)
    end }))
    local resolved = wait(value:resolve("test"))
    assert.are.equal("Bearer router-key", rawget(assert(assert(resolved.request_opts).headers), "Authorization"))
    local anonymous = open({
      { path = "tests/recordings/llama/anonymous-01.yaml", headers_subset = true },
    })
    value = manager(require("neoagent.providers.llama.auth").new({ transport = anonymous }))
    wait(value:login("test", { prompt = function(prompt, done)
      assert.are.equal("text", prompt.type); done.resolve(anonymous.url)
    end }))
    assert.is_nil(assert(wait(value:resolve("test")).request_opts).headers)
  end)

  it("performs device polling, slowdown and credential refresh through the real manager", function()
    local scenario = open({
      { path = "tests/recordings/openai/device-refresh-01.yaml", headers_subset = true },
      { path = "tests/recordings/openai/device-refresh-02.yaml", headers_subset = true },
      { path = "tests/recordings/openai/device-refresh-03.yaml", headers_subset = true },
      { path = "tests/recordings/openai/device-refresh-04.yaml", headers_subset = true },
      { path = "tests/recordings/openai/device-refresh-05.yaml", headers_subset = true },
      { path = "tests/recordings/openai/device-refresh-06.yaml", headers_subset = true },
      { path = "tests/recordings/openai/device-refresh-07.yaml", headers_subset = true },
      { path = "tests/recordings/openai/device-refresh-08.yaml", body_subset = true, headers_subset = true },
    })
    local now, sleeps = 10000, {}
    local method = require("neoagent.auth.openai_codex").new({
      auth_base_url = scenario.url, http = scenario, now = function() return now end,
      sleep = function(ms) sleeps[#sleeps + 1] = ms end,
    })
    local value = manager(method, function() return now end)
    ---@type Neoagent.AuthEvent[]
    local events = {}
    wait(value:login("test", {
      prompt = function(_, done) done.resolve("device_code") end,
      notify = function(event) events[#events + 1] = event end,
    }))
    assert.are.equal("ABCD", assert(events[1]).userCode)
    assert.are.same({ 0, 0, 0, 5000 }, sleeps)
    local first = wait(value:resolve("test"))
    assert.are.equal("device-account", rawget(assert(assert(first.request_opts).headers), "chatgpt-account-id"))
    now = 12000
    local first_refresh, second_refresh = value:resolve("test"), value:resolve("test")
    local refreshed = wait(first_refresh)
    assert.are.same(refreshed.request_opts, wait(second_refresh).request_opts)
    assert.are_not.equal(rawget(assert(assert(first.request_opts).headers), "Authorization"), rawget(assert(assert(refreshed.request_opts).headers), "Authorization"))
    assert.are.equal("device-account", rawget(assert(assert(refreshed.request_opts).headers), "chatgpt-account-id"))
    assert.are.equal("rotated-refresh", assert(value.store:read("test")).refresh)
    assert.are.equal(3612000, assert(value.store:read("test")).expires)
    local model = require("neoagent.api.openai_codex_responses").new({
      provider = "openai-codex", model = "gpt-test", base_url = scenario.url .. "/v1",
      transport = scenario, request_max_retries = 0,
    })
    local result = wait(value:wrap(model, "test"):stream({
      system_prompt = "Be useful.", messages = { { role = "user", content = "Hello" } },
    }))
    assert.are.equal("Codex works", result.text)
    assert.are.equal(8, #scenario.requests)
  end)
end)
