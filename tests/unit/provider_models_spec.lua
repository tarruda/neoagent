local config = require("neoagent.config")
local fs = require("neoagent.fs")
local models = require("neoagent.models")
local provider_runtimes = require("neoagent.provider_runtimes")
local state_store = require("neoagent.state_store")

describe("neoagent provider model catalogs", function()
  before_each(function() config._reset() end)
  after_each(function() config._reset() end)

  local function api_factory(resolved)
    local model = {
      api = resolved.api,
      provider = resolved.provider_id,
      id = resolved.model_id,
      stream = function() end,
    }
    for key, value in pairs(resolved.model) do model[key] = value end
    return model
  end

  local function configured(provider)
    return config.setup({
      default_registry = false,
      default_model = { provider = "dynamic", model = "seed" },
      providers = { dynamic = provider },
      _apis = { fake = api_factory },
    })
  end

  local function runtime(provider, opts)
    local value = configured(provider)
    local runtimes, err = provider_runtimes.compose(value,
      vim.tbl_extend("force", { startup = false }, opts or {}))
    assert(runtimes, err and err.message)
    return value, runtimes
  end

  it("resolves exclusively from the composed catalog snapshot", function()
    local value, runtimes = runtime({
      api = "fake",
      catalog = { seed = { { id = "seed" } } },
      models = { seed = { context_window = 4000 } },
    })
    local model = models.resolve(nil, nil, value, nil, runtimes)
    assert.are.equal("seed", model.id)
    assert.are.equal(4000, model.context_window)
    assert.are.same({ "text" }, model.input)
    provider_runtimes.destroy(runtimes)
  end)

  it("restores cached OpenCode Go discoveries before the first selector read", function()
    local directory = vim.fn.tempname()
    local store = state_store.new({ directory = directory })
    assert(store:write("opencode-go", {
      version = 1,
      validated_at = 1000,
      models = { { id = "ox-alpha-free" } },
    }))
    local definition = require("neoagent.registry").defaults()["opencode-go"]
    local value = config.setup({
      default_registry = false,
      providers = { ["opencode-go"] = definition },
    })
    local runtimes = assert(provider_runtimes.compose(value, {
      startup = false,
      store = store,
    }))
    local available = assert(models.available(value, {
      has_credentials = function() return true end,
    }, runtimes))
    assert.is_true(vim.tbl_contains(available,
      "opencode-go/ox-alpha-free"))
    provider_runtimes.destroy(runtimes)
    vim.fn.delete(directory, "rf")
  end)

  it("transforms discoveries and applies exact overrides and removals last", function()
    local value, runtimes = runtime({
      api = "fake",
      catalog = {
        seed = {
          { id = "seed", context_window = 4000 },
          { id = "removed", context_window = 8000 },
        },
        transform_model = function(model)
          model.input = { "text", "image" }
          model.context_window = model.context_window or 16000
          return model
        end,
      },
      models = {
        seed = { context_window = 32000 },
        added = { max_output_tokens = 2000 },
        removed = false,
      },
    })
    assert.are.same({ "dynamic/added", "dynamic/seed" },
      models.available(value, nil, runtimes))
    local seed = models.resolve("dynamic", "seed", value, nil, runtimes)
    assert.are.equal(32000, seed.context_window)
    assert.are.same({ "text", "image" }, seed.input)
    local added = models.resolve("dynamic", "added", value, nil, runtimes)
    assert.are.equal(16000, added.context_window)
    assert.are.equal(2000, added.max_output_tokens)
    provider_runtimes.destroy(runtimes)
  end)

  it("hides catalog entries without removing explicit resolution", function()
    local value, runtimes = runtime({
      api = "fake",
      catalog = { seed = { { id = "seed" }, { id = "hidden" } } },
      models = { hidden = { hidden = true } },
    })
    assert.are.same({ "dynamic/seed" }, models.available(value, nil, runtimes))
    assert.are.equal("hidden",
      models.resolve("dynamic", "hidden", value, nil, runtimes).id)
    provider_runtimes.destroy(runtimes)
  end)

  it("wraps Models through the runtime service", function()
    local wrapped = {}
    local value, runtimes = runtime({
      api = "fake",
      catalog = { seed = { { id = "seed" } } },
      models = { seed = { request_timeout_ms = 30000 } },
      service = function()
        return {
          id = "dynamic",
          name = "Dynamic",
          operations = {},
          state = function() return false end,
          wrap_model = function(_, model)
            wrapped[#wrapped + 1] = model
            return model
          end,
        }
      end,
    })
    local resolved = models.resolve("dynamic", "seed", value, nil, runtimes)
    assert.are.equal(30000, resolved.request_timeout_ms)
    assert.are.equal(1, #wrapped)
    assert.are.equal(resolved, wrapped[1])
    provider_runtimes.destroy(runtimes)
  end)

  it("reports Codex diagnostic sink failures through its runtime", function()
    local path = vim.fn.tempname()
    assert(fs.write_all(path, "blocking file", "w"))
    local reports = {}
    local value, runtimes = runtime({
      api = "openai-codex-responses",
      base_url = "https://example.test",
      diagnostics = { path = path .. "/codex.log" },
      catalog = { seed = { { id = "seed" } } },
    }, {
      report = function(message, level)
        reports[#reports + 1] = { message = message, level = level }
      end,
    })
    local model = models.resolve("dynamic", "seed", value, nil, runtimes)

    model._on_diagnostic({
      type = "request_failed",
      detail = "private response body",
    })
    model._on_diagnostic({ type = "request_failed" })

    assert(vim.wait(1000, function() return #reports == 1 end))
    assert.matches("diagnostic log failed", reports[1].message)
    assert.not_matches("private response body", reports[1].message)
    assert.are.equal(vim.log.levels.WARN, reports[1].level)
    provider_runtimes.destroy(runtimes)
    vim.fn.delete(path)
  end)

  it("keeps resolved Models independent from later catalog revisions", function()
    local value, runtimes = runtime({
      api = "fake",
      catalog = { seed = { { id = "seed", context_window = 4000 } } },
      models = {},
    })
    local first = models.resolve("dynamic", "seed", value, nil, runtimes)
    assert(runtimes.dynamic.catalog:publish_discoveries({
      { id = "seed", context_window = 32000 },
      { id = "new" },
    }))
    local second = models.resolve("dynamic", "seed", value, nil, runtimes)
    assert.are.equal(4000, first.context_window)
    assert.are.equal(32000, second.context_window)
    assert.are.equal("new",
      models.resolve("dynamic", "new", value, nil, runtimes).id)
    provider_runtimes.destroy(runtimes)
  end)

  it("publishes changing available-model snapshots until unsubscribed", function()
    local value, runtimes = runtime({
      api = "fake",
      catalog = { seed = { { id = "seed" } } },
      models = {},
    })
    local publications = {}
    local unsubscribe = models.subscribe_available(
      value, nil, runtimes, function(choices, err)
        assert.is_nil(err)
        publications[#publications + 1] = choices
      end)
    assert.are.same({ "dynamic/seed" }, publications[1])
    assert(runtimes.dynamic.catalog:publish_discoveries({
      { id = "seed" }, { id = "new" },
    }))
    assert.are.same({ "dynamic/new", "dynamic/seed" }, publications[2])
    assert(runtimes.dynamic.catalog:publish_discoveries({
      { id = "new" }, { id = "seed" },
    }))
    assert.are.equal(2, #publications)
    assert.is_true(unsubscribe())
    assert.is_false(unsubscribe())
    assert(runtimes.dynamic.catalog:publish_discoveries({ { id = "later" } }))
    assert.are.equal(2, #publications)
    provider_runtimes.destroy(runtimes)
  end)

  it("rejects invalid candidates at the catalog boundary", function()
    local value = configured({
      api = "fake",
      catalog = { seed = { { id = "seed", input = {} } } },
      models = {},
    })
    local runtimes, err = provider_runtimes.compose(value, { startup = false })
    assert.is_nil(runtimes)
    assert.are.equal("provider", err.kind)
    assert.matches("input must be a non%-empty list", err.detail.message)

    value = configured({
      api = "fake",
      catalog = { seed = { {
        id = "seed",
        reasoning = true,
        thinking = { high = {} },
      } } },
      models = {},
    })
    runtimes, err = provider_runtimes.compose(value, { startup = false })
    assert.is_nil(runtimes)
    assert.matches("mutually exclusive", err.detail.message)
  end)

  it("retains exact removals and callback order across registry composition", function()
    local registry = require("neoagent.registry")
    local order = {}
    local first = registry.compose({
      openai = {
        models = { ["gpt-4"] = false },
        catalog = { transform_model = function(model)
          if model.id == "gpt-4" then
            assert.are.same({ "text" }, model.input)
          end
          order[#order + 1] = model.id
          return model
        end },
      },
    }, true)
    assert.is_false(first.openai.models["gpt-4"])
    assert.is_function(first.openai.catalog.transform_model)
    local value = config.setup({
      default_registry = false,
      providers = { openai = first.openai },
    })
    local runtimes = assert(provider_runtimes.compose(value, { startup = false }))
    assert.is_nil(runtimes.openai.catalog:snapshot().models["gpt-4"])
    assert.are.equal(vim.tbl_count(
      runtimes.openai.catalog:snapshot().models) + 1, #order)
    assert.is_true(vim.tbl_contains(order, "gpt-4"))
    provider_runtimes.destroy(runtimes)
  end)
end)
