local config = require("neoagent.config")
local async = require("neoagent.async")
local auth = require("neoagent.auth")
local models = require("neoagent.models")
local llama = require("neoagent.providers.llama")
local fake_transport = require("tests.helpers.fake_transport")

describe("neoagent dynamic model catalogs", function()
  before_each(function() config._reset() end)
  after_each(function() config._reset() end)

  local function service(models_list, get_models)
    return {
      id = "dynamic",
      name = "Dynamic",
      state = function() return false end,
      operations = {},
      get_models = get_models or function()
        return models_list
      end,
    }
  end

  local function configured(extra)
    local result = {
      default_registry = false,
      default_model = { provider = "dynamic", model = "seed" },
      providers = {
        dynamic = {
          api = "fake",
          models = { seed = { context_window = 4000 } },
        },
      },
      apis = {
        fake = function(resolved)
          local model = {
            api = "fake",
            provider = resolved.provider_id,
            id = resolved.model_id,
            stream = function() end,
          }
          for key, value in pairs(resolved.model or {}) do model[key] = value end
          return model
        end,
      },
    }
    for key, value in pairs(extra or {}) do result[key] = value end
    return result
  end

  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return run:result()
  end

  it("keeps static resolution unchanged without services", function()
    config.setup(configured())
    local model = models.resolve(nil, nil, nil, nil, {})
    assert.are.equal("seed", model.id)
    assert.are.equal(4000, model.context_window)
  end)

  it("merges discovered models under configured entries", function()
    config.setup(configured({
      providers = {
        dynamic = {
          api = "fake",
          models = {
            seed = { context_window = 4000 },
            discovered = { context_window = 32000 },
          },
        },
      },
    }))
    local services = {
      dynamic = service({
        { id = "discovered", context_window = 20000, max_output_tokens = 5 },
        { id = "extra", context_window = 8000 },
      }),
    }
    local resolved = models.resolve("dynamic", "discovered", nil, nil, services)
    assert.are.equal(32000, resolved.context_window)
    assert.are.equal(5, resolved.max_output_tokens)
    assert.are.equal("extra", models.resolve("dynamic", "extra", nil, nil, services).id)
    assert.are.same({
      "dynamic/discovered",
      "dynamic/extra",
      "dynamic/seed",
    }, models.available(nil, nil, services))
  end)

  it("applies provider service model wrappers and request timeouts", function()
    config.setup(configured({
      providers = {
        dynamic = {
          api = "openai-completions",
          base_url = "http://127.0.0.1:8080/v1",
          models = {
            seed = { context_window = 4000, request_timeout_ms = 30000 },
          },
        },
      },
    }))
    local wrapped = {}
    local value = service({})
    value.wrap_model = function(self, model)
      wrapped[#wrapped + 1] = model
      return model
    end
    local resolved = models.resolve("dynamic", "seed", nil, nil, {
      dynamic = value,
    })
    assert.are.equal(30000, resolved.timeout_ms)
    assert.are.equal(1, #wrapped)
    assert.are.equal(resolved, wrapped[1])
  end)

  it("applies authenticated llama timeouts from router state and calls", function()
    local transport = fake_transport.new()
    local function catalog(status)
      return vim.json.encode({ data = { {
        id = "owner/repo:Q4_K_M",
        status = { value = status },
        meta = { n_ctx = 32000 },
      } } })
    end
    transport.fetches = {
      { body = catalog("unloaded") },
      { body = catalog("loaded") },
    }
    local definitions = {
      qwen = {
        hf_repo = "owner/repo",
        quantization = "Q4_K_M",
        request_timeout_ms = 45000,
      },
    }
    local service = llama.new({
      api = "fake",
      base_url = "http://127.0.0.1:8080/v1",
      auth = "llama",
      auth_optional = true,
      models = definitions,
    }, { transport = transport, startup = false })
    assert(wait(service:refresh_catalog({ allow_network = true })).ok)
    local seen = {}
    config.setup({
      default_registry = false,
      default_model = { provider = "llama.cpp", model = "qwen" },
      providers = {
        ["llama.cpp"] = {
          api = "fake",
          base_url = "http://127.0.0.1:8080/v1",
          auth = "llama",
          auth_optional = true,
          models = definitions,
        },
      },
      apis = {
        fake = function(resolved)
          return {
            api = "fake",
            provider = resolved.provider_id,
            id = resolved.model_id,
            input = { "text" },
            timeout_ms = resolved.model.request_timeout_ms,
            stream = function(self, opts)
              seen[#seen + 1] = opts.timeout_ms == nil
                and self.timeout_ms or opts.timeout_ms
              return async.run(function() return { ok = true } end, {
                on_done = opts.on_done,
              })
            end,
          }
        end,
      },
    })
    local manager = auth.new({
      methods = {
        llama = {
          type = "api_key",
          name = "llama.cpp",
          login = function()
            return { ok = true, credential = { type = "api_key", key = "key" } }
          end,
          request_opts = function()
            return { headers = { Authorization = "Bearer key" } }
          end,
        },
      },
      store = {
        read = function() return { type = "api_key", key = "key" } end,
        write = function() return true end,
      },
    })
    local resolved = models.resolve(
      "llama.cpp", "qwen", nil, manager, { ["llama.cpp"] = service })
    assert.are.equal(45000, resolved.timeout_ms)
    assert(wait(resolved:stream({ messages = {} })).ok)
    assert.is_false(seen[1])
    assert(wait(resolved:stream({
      messages = {}, timeout_ms = 9000,
    })).ok)

    assert(wait(service:refresh_catalog({
      allow_network = true,
      force = true,
    })).ok)
    assert(wait(resolved:stream({ messages = {} })).ok)
    assert(wait(resolved:stream({ messages = {}, timeout_ms = 9000 })).ok)
    assert(wait(resolved:stream({ messages = {}, timeout_ms = false })).ok)
    assert.are.same({ false, 9000, 45000, 9000, false }, seen)
    service:destroy()
  end)

  it("honors user removals over discovered models", function()
    config.setup(configured({
      providers = {
        dynamic = {
          api = "fake",
          models = {
            seed = { context_window = 4000 },
            discovered = false,
          },
        },
      },
    }))
    local services = {
      dynamic = service({
        { id = "discovered", context_window = 20000 },
        { id = "extra", context_window = 8000 },
      }),
    }
    assert.has_error(function() models.resolve("dynamic", "discovered", nil, nil, services) end)
    assert.are.same({
      "dynamic/extra",
      "dynamic/seed",
    }, models.available(nil, nil, services))
  end)

  it("rejects failing or malformed discovered catalogs", function()
    config.setup(configured())
    for _, case in ipairs({
      {
        value = service({}, function() error("catalog boom") end),
        pattern = "model catalog failed",
      },
      {
        value = service({}, function() return "bad" end),
        pattern = "model catalog must be a list",
      },
      {
        value = service({ true, { id = 1 } }),
        pattern = "entries must be objects",
      },
    }) do
      local ok, err = pcall(models.resolve, "dynamic", "seed", nil, nil, {
        dynamic = case.value,
      })
      assert.is_false(ok)
      assert.are.equal("model", err.kind)
      assert.matches(case.pattern, err.message)
    end
  end)

  it("validates every dynamic model field and rejects duplicate ids", function()
    config.setup(configured())
    local cases = {
      {
        entries = { { id = "bad-input", input = {} } },
        pattern = "input must be a non%-empty list",
      },
      {
        entries = { { id = "bad-input", input = { "text", "text" } } },
        pattern = "input must contain unique text or image entries",
      },
      {
        entries = { { id = "bad-context", context_window = 1.5 } },
        pattern = "context_window must be a positive integer",
      },
      {
        entries = { { id = "bad-thinking", thinking = true } },
        pattern = "thinking must be a table or false",
      },
      {
        entries = { { id = "bad-api", api = "" } },
        pattern = "api must be safe non%-empty text",
      },
      {
        entries = { { id = "bad-options", request_opts = "invalid" } },
        pattern = "request_opts must be a table or function",
      },
      {
        entries = { { id = "same" }, { id = "same" } },
        pattern = "duplicate dynamic model id same",
      },
    }
    for _, case in ipairs(cases) do
      local available, err = models.available(nil, nil, {
        dynamic = service(case.entries),
      })
      assert.is_nil(available)
      assert.are.equal("model", err.kind)
      assert.matches(case.pattern, err.message)
    end
  end)

  it("retains removal sets across registry compositions", function()
    local registry = require("neoagent.registry")
    local first = registry.compose({
      openai = {
        api = "openai-responses",
        base_url = "https://api.openai.com/v1",
        models = { ["gpt-4"] = false },
      },
    }, true)
    assert.is_true(first.openai._model_removals["gpt-4"])
    local second = registry.compose(first, false)
    assert.is_true(second.openai._model_removals["gpt-4"])
    assert.is_not_nil(second.openai.models["gpt-4-turbo"])
  end)
end)
