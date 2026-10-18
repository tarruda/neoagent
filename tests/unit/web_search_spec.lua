local assert = require("luassert")
local async = require("neoagent.async")
local config = require("neoagent.config")
local fs = require("neoagent.fs")
local fake = require("tests.helpers.fake_model")
local fake_transport = require("tests.helpers.fake_transport")
local provider_resources = require("neoagent.provider_resources")
local provider_service = require("neoagent.provider_service")
local search = require("neoagent.web_search")
local tools = require("neoagent.tools")
local util = require("neoagent.util")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function finish(run)
  assert(vim.wait(3000, function()
    return run:is_done()
  end, 5))
  return (assert(run:result()))
end

---@param query? string
---@return Neoagent.WebSearchRequest
local function request(query)
  return { query = query or "Neoagent", count = 10, include_content = false }
end

local function entry()
  return {
    title = "A search result",
    url = "https://example.test/article",
    summary = "A useful summary",
    snippet = "Short preview",
    content = "Full page text",
    date = "2026-01-02T03:04:05Z",
    site_name = "Example",
    rerank_score = 3,
    authority = 4,
  }
end

---@param owned Neoagent.ProviderResources
---@return Neoagent.WebSearch
local function capability_for(owned)
  return search.new({
    deepseek = function()
      return require("neoagent.web_search.deepseek").create({ auth = owned.auth, runtime = owned.runtimes.deepseek })
    end,
  })
end

---@param capability? Neoagent.WebSearch
---@param arguments Neoagent.JsonObject
---@param executor? Neoagent.ToolExecutor<Neoagent.WebSearchToolEnvironment>
---@return Neoagent.ToolResultMessage
local function invoke(capability, arguments, executor)
  local model = fake.new({
    {
      result = fake.assistant(
        { { type = "toolCall", id = "search", name = "web_search", arguments = arguments } },
        "toolUse"
      ),
    },
    { result = fake.assistant({ { type = "text", text = "Done" } }) },
  })
  local result = finish(require("neoagent.agent_loop").run({
    model = model,
    messages = {},
    tools = { tools.web_search() },
    context = { web_search = capability },
    execute_tool = executor,
    commit_message = function()
      return true
    end,
  }))
  assert(result.ok)
  local message = assert(assert(result.new_messages)[2])
  assert(message.role == "toolResult")
  return message
end

describe("opt-in web search", function()
  ---@type Neoagent.ProviderResources[]
  local resources
  ---@type Neoagent.Agent[]
  local agents
  ---@type string[]
  local roots
  local previous_key
  local platform = require("neoagent.sandbox.platform")
  local select_platform = platform.select

  before_each(function()
    resources, agents, roots = {}, {}, {}
    previous_key = vim.env.DEEPSEEK_API_KEY
    vim.env.DEEPSEEK_API_KEY = nil
  end)

  after_each(function()
    platform.select = select_platform
    for _, agent in ipairs(agents) do
      agent:destroy()
    end
    for _, resource in ipairs(resources) do
      resource:destroy()
    end
    for _, root in ipairs(roots) do
      vim.fn.delete(root, "rf")
    end
    vim.env.DEEPSEEK_API_KEY = previous_key
  end)

  ---@param extra? {base_url?: string, service_opts?: Neoagent.ProviderHttpServiceOptions}
  ---@param ambient_only? boolean
  ---@return Neoagent.ProviderResources, Neoagent.TestByteBackend, Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>, string
  local function compose(extra, ambient_only)
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    assert(fs.mkdirp(root))
    local provider = util.copy(require("neoagent.registry.deepseek"))
    provider.catalog = nil
    if ambient_only then
      provider.auth = nil
    end
    provider.models = { search_model = {} }
    provider.base_url = extra and extra.base_url or provider.base_url
    provider.service_opts = extra and extra.service_opts or provider.service_opts
    ---@type Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
    local options = {
      default_registry = false,
      providers = { deepseek = provider },
      auth = { path = root .. "/auth.json" },
      recording = { enabled = false },
      persistence = { enabled = false },
      workspace_trust = false,
      agent_instructions = false,
      skills = false,
      compaction = false,
      sandbox = { enabled = false },
    }
    local transport = fake_transport.new()
    local owned = provider_resources.new(config.resolve(options), {
      transport = transport,
      startup = false,
      report = function() end,
    })
    resources[#resources + 1] = owned
    return owned, transport, options, root
  end

  it("routes independent backends without provider resources or a shared authentication policy", function()
    local constructions, received = 0, {}
    local credential
    local capability = search.new({
      standalone = function()
        constructions = constructions + 1
        return function(query)
          received[#received + 1] = util.copy(query)
          query.query = "backend-local edit"
          return async.run(function()
            if credential == nil then
              return { ok = false, error = util.error("auth", "Standalone search needs its own key") }
            end
            return {
              ok = true,
              results = { { title = "Independent result", url = "https://example.test", summary = "Found" } },
            }
          end)
        end
      end,
      lan = function()
        return function()
          return async.run(function()
            return { ok = true, results = {} }
          end)
        end
      end,
    })
    local query = request()
    local missing = finish(capability("standalone", query))
    assert.is_false(missing.ok)
    assert.are.equal("auth", assert(missing.error).kind)
    assert.matches("Standalone search needs its own key", assert(missing.error).message)
    assert.is_true(finish(capability("lan", query)).ok)
    credential = "backend-owned-key"
    local found = finish(capability("standalone", query))
    assert(found.ok)
    assert.are.equal("Independent result", assert(found.results[1]).title)
    assert.are.equal(1, constructions)
    assert.are.same({ request(), request() }, received)
    assert.are.equal("Neoagent", query.query)
  end)

  it("reports missing or failed backend construction without assuming a provider", function()
    local attempts = 0
    local capability = search.new({
      standalone = function()
        attempts = attempts + 1
        assert(attempts > 1, "Search backend could not initialize")
        return function()
          return async.run(function()
            return { ok = true, results = {} }
          end)
        end
      end,
    })
    local missing = finish(capability("unconfigured", request()))
    assert.is_false(missing.ok)
    assert.are.equal("tool", assert(missing.error).kind)
    assert.matches("Web search backend is not configured: unconfigured", assert(missing.error).message)
    local failed = finish(capability("standalone", request()))
    assert.is_false(failed.ok)
    assert.are.equal("tool", assert(failed.error).kind)
    assert.matches("Search backend could not initialize", assert(failed.error).message)
    assert.is_true(finish(capability("standalone", request())).ok)
  end)

  it("requires opt-in and rejects unsupported backends", function()
    for _, preset in ipairs({ tools.coding(), tools.codex(), tools.read_only(), tools.all() }) do
      for _, tool in ipairs(preset) do
        assert.are_not.equal("web_search", tool.name)
      end
    end
    assert.are.equal("web_search", tools.web_search({ backend = "deepseek" }).name)
    assert.has_error(function()
      tools.web_search({ backend = "unavailable" })
    end, "Unknown web search backend: unavailable")
    local result = invoke(nil, { query = "test" })
    assert.is_true(result.isError)
    assert.matches("composed search capability", util.text_content(result.content))
  end)

  it("validates the same options in setup and explicit Tool construction", function()
    assert.is_false(config.resolve({ default_registry = false }).web_search)
    for _, invalid in ipairs({
      true,
      "deepseek",
      { "deepseek" },
      { enabled = true },
      { backend = false },
      { backend = "" },
      { backend = "unavailable" },
    }) do
      local options = { default_registry = false, web_search = invalid } --[[@as unknown]]
      assert.has_error(function()
        config.resolve(options --[[@as Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>]])
      end)
      assert.has_error(function()
        tools.web_search(invalid --[[@as Neoagent.WebSearchOptions]])
      end)
    end
  end)

  it("sends a bounded authenticated POST and normalizes backend fields", function()
    local owned, transport = compose({ base_url = "https://example.test/v1/" })
    local identity
    transport.with_context = function(context)
      identity = context
      return transport
    end
    vim.env.DEEPSEEK_API_KEY = "environment-key"
    transport.fetches = { { body = vim.json.encode({ results = { entry() } }) } }
    local query = 'site:example.test "quoted phrase" after:2025-01-01'
    local result = finish(capability_for(owned)("deepseek", request(query)))
    assert(result.ok)
    assert.are.same({
      {
        title = "A search result",
        url = "https://example.test/article",
        summary = "A useful summary",
        published_at = "2026-01-02T03:04:05Z",
      },
    }, result.results)
    local sent = assert(transport.fetch_requests[1])
    assert.are.equal("POST", sent.method)
    assert.are.equal("https://example.test/v1/tools/search", sent.url)
    assert.are.same({ query = query, count = 10, need_content = false }, vim.json.decode((assert(sent.body))))
    assert.are.equal("Bearer environment-key", rawget(assert(sent.headers), "Authorization"))
    assert.are.equal("application/json", rawget(assert(sent.headers), "Content-Type"))
    assert.are.equal(30000, sent.timeout_ms)
    assert.are.equal(2 * 1024 * 1024, sent.max_response_bytes)
    assert.are.same({ provider = "deepseek", origin = "web-search" }, identity)
  end)

  it("reads auth.json on each call and gives stored credentials precedence", function()
    local owned, transport = compose()
    local capability = capability_for(owned)
    local missing = invoke(capability, { query = "test" })
    assert.is_true(missing.isError)
    assert.matches("Log in to the DeepSeek provider", util.text_content(missing.content))
    assert.are.equal(0, #transport.fetch_requests)
    vim.env.DEEPSEEK_API_KEY = "ambient-key"
    for _, key in ipairs({ "stored-key", "rotated-key" }) do
      assert(owned.auth.store:write("deepseek", { type = "api_key", key = key }))
      transport.fetches = { { body = '{"results":[]}' } }
      assert.is_true(finish(capability("deepseek", request())).ok)
      assert.are.equal(
        "Bearer " .. key,
        rawget(assert(assert(transport.fetch_requests[#transport.fetch_requests]).headers), "Authorization")
      )
    end
    assert(owned.auth.store:write("deepseek", { type = "api_key", key = "" }))
    local invalid = finish(capability("deepseek", request()))
    assert.is_false(invalid.ok)
    assert.are.equal("auth", assert(invalid.error).kind)
    assert.are.equal(2, #transport.fetch_requests)
  end)

  it("supports ambient-only provider configuration and reports a missing provider", function()
    local owned, transport = compose({ base_url = "https://example.test/anthropic" }, true)
    vim.env.DEEPSEEK_API_KEY = "ambient-key"
    transport.fetches = { { body = '{"results":[]}' } }
    assert.is_true(finish(capability_for(owned)("deepseek", request())).ok)
    assert.are.equal("https://example.test/v1/tools/search", assert(transport.fetch_requests[1]).url)
    local missing = finish(search.new({
      deepseek = function()
        return require("neoagent.web_search.deepseek").create({ auth = owned.auth })
      end,
    })("deepseek", request()))
    assert.is_false(missing.ok)
    assert.matches("DeepSeek provider must be configured", assert(missing.error).message)
  end)

  it("formats URLs, dates, previews, optional content, and empty results", function()
    local owned, transport = compose()
    vim.env.DEEPSEEK_API_KEY = "key"
    local value = entry()
    value.summary = ""
    transport.fetches = {
      { body = vim.json.encode({ results = { value } }) },
      { body = '{"results":[]}' },
    }
    local capability = capability_for(owned)
    local result = invoke(capability, { query = "test", count = 1, include_content = true })
    assert.is_not_true(result.isError)
    local text = util.text_content(result.content)
    for _, part in ipairs({ value.title, value.url, value.date, value.snippet, value.content }) do
      assert.is_truthy((text:find(part, 1, true)))
    end
    assert.are.same(
      { query = "test", count = 1, need_content = true },
      vim.json.decode((assert(assert(transport.fetch_requests[1]).body)))
    )
    local empty = invoke(capability, { query = "not found" })
    assert.matches("No results found", util.text_content(empty.content))
  end)

  it("validates query characters and counts before starting a request", function()
    local owned, transport = compose()
    vim.env.DEEPSEEK_API_KEY = "key"
    local capability = capability_for(owned)
    for _, args in ipairs({
      {},
      { query = " \t\n" },
      { query = string.rep("é", 129) },
      { query = "test", count = 0 },
      { query = "test", count = 51 },
      { query = "test", count = 1.5 },
      { query = "test", include_content = "yes" },
      { query = "test", unknown = true },
    }) do
      assert.is_true(invoke(capability, args).isError)
    end
    assert.are.equal(0, #transport.fetch_requests)
    transport.fetches = { { body = '{"results":[]}' } }
    assert.is_not_true(invoke(capability, { query = string.rep("é", 128), count = 50 }).isError)
    assert.are.equal(1, #transport.fetch_requests)
  end)

  it("bounds Tool output while retaining result count and truncation metadata", function()
    local owned, transport = compose()
    vim.env.DEEPSEEK_API_KEY = "key"
    local value = entry()
    value.content = string.rep("content line\n", 6000)
    transport.fetches = { { body = vim.json.encode({ results = { value } }) } }
    local result = invoke(capability_for(owned), { query = "test", include_content = true })
    assert.is_not_true(result.isError)
    local text = util.text_content(result.content)
    assert.is_true(#text < 52 * 1024)
    assert.matches("Search output truncated", text)
    assert.are.equal(true, assert(result.details).truncated)
    assert.are.equal(1, assert(result.details).result_count)
  end)

  it("rejects malformed responses without exposing their contents", function()
    local owned, transport = compose()
    vim.env.DEEPSEEK_API_KEY = "private-key"
    local capability = capability_for(owned)
    for _, body in ipairs({
      "private response",
      "{}",
      '{"results":false}',
      '{"results":[{}]}',
      vim.json.encode({ results = { { title = "private response", url = "file:///tmp/test" } } }),
    }) do
      transport.fetches = { { body = body } }
      local result = finish(capability("deepseek", request()))
      assert.is_false(result.ok)
      assert.is_nil((vim.inspect(result.error):find("private response", 1, true)))
      assert.is_nil((vim.inspect(result.error):find("private-key", 1, true)))
    end
    transport.fetches = { { body = vim.json.encode({ results = { entry(), entry() } }) } }
    local one = request()
    one.count = 1
    assert.is_false(finish(capability("deepseek", one)).ok)
  end)

  it("reports authentication, quota, rate, server, and transport failures", function()
    local owned, transport = compose()
    vim.env.DEEPSEEK_API_KEY = "key"
    local capability = capability_for(owned)
    for status, message in pairs({
      [401] = "valid API key",
      [402] = "balance is exhausted",
      [429] = "rate limited",
      [500] = "HTTP 500",
    }) do
      transport.fetches = { { status = status, body = "private response" } }
      local result = finish(capability("deepseek", request()))
      assert.is_false(result.ok)
      assert.matches(message, assert(result.error).message)
      assert.are.equal(status, rawget(assert(result.error), "status"))
      assert.is_nil((vim.inspect(result.error):find("private response", 1, true)))
    end
    transport.fetches = { { error = util.error("transport", "Timed out") } }
    local result = finish(capability("deepseek", request()))
    assert.is_false(result.ok)
    assert.matches("Timed out", assert(result.error).message)
  end)

  it("honors provider response and timeout limits", function()
    local owned, transport = compose({ service_opts = { max_response_bytes = 1024, timeout_ms = 750 } })
    vim.env.DEEPSEEK_API_KEY = "key"
    transport.fetches = { { body = string.rep("x", 1025) } }
    local result = finish(capability_for(owned)("deepseek", request()))
    assert.is_false(result.ok)
    assert.matches("exceeds 1024 bytes", assert(result.error).message)
    assert.are.equal(750, assert(transport.fetch_requests[1]).timeout_ms)
  end)

  it("cancels HTTP work and releases provider use before retirement", function()
    local owned, transport = compose()
    vim.env.DEEPSEEK_API_KEY = "key"
    local started, cancelled, retired = false, false, false
    transport.fetch = function()
      return async.run(function()
        return async.await(function()
          started = true
          return function()
            cancelled = true
          end
        end)
      end)
    end
    local capability = capability_for(owned)
    local run = capability("deepseek", request())
    assert(vim.wait(3000, function()
      return started
    end, 5))
    local service = owned.runtimes.deepseek.service
    provider_service.retire(service, function()
      retired = true
      if service.destroy then
        service:destroy()
      end
    end)
    assert.is_false(retired)
    run:cancel()
    assert.are.equal("cancelled", assert(finish(run).error).kind)
    assert(vim.wait(3000, function()
      return cancelled and retired
    end, 5))
    local retry = finish(capability("deepseek", request()))
    assert.is_false(retry.ok)
    assert.matches("retiring", assert(retry.error).message)
  end)

  it("composes search for a non-DeepSeek Model as an explicit parent capability", function()
    local owned, transport, options, root = compose()
    vim.env.DEEPSEEK_API_KEY = "key"
    platform.select = function()
      return nil, { ok = false, platform = "test", message = "synthetic unavailable sandbox" }
    end
    local model = fake.new({
      {
        result = fake.assistant(
          { { type = "toolCall", id = "web", name = "web_search", arguments = { query = "test" } } },
          "toolUse"
        ),
      },
      { result = fake.assistant({ { type = "text", text = "Found it" } }) },
    })
    options.profile = "pi"
    options.sandbox = { enabled = true }
    options.web_search = { backend = "deepseek" }
    options.default_model = { provider = "fake", model = "fake" }
    assert(options.providers).fake = { api = "fake-api", models = { fake = {} } }
    options._apis = {
      ["fake-api"] = function()
        return model
      end,
    }
    transport.fetches = { { body = vim.json.encode({ results = { entry() } }) } }
    owned = provider_resources.new(config.resolve(options), {
      transport = transport,
      startup = false,
      report = function() end,
    })
    resources[#resources + 1] = owned
    local agent = require("neoagent").new(options, {
      auth = owned.auth,
      runtimes = owned.runtimes,
      workspace = root,
    })
    agents[#agents + 1] = agent
    assert(agent:prepare())
    local run = agent:send("search the web")
    assert(type(run) == "table")
    assert.is_true(finish(run).ok)
    assert.are.equal(1, #transport.fetch_requests)
    local response = assert(model.requests[2])
    local tool_result = assert(response.messages[#response.messages])
    assert(tool_result.role == "toolResult")
    assert.is_not_true(tool_result.isError)
    assert.matches("A useful summary", util.text_content(tool_result.content))
  end)
end)
