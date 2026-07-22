local config = require("neoagent.config")
local models = require("neoagent.models")

describe("neoagent configuration and model resolution", function()
  local original_openai_key

  before_each(function()
    config._reset()
    original_openai_key = vim.env.OPENAI_API_KEY
    vim.env.OPENAI_API_KEY = nil
  end)

  after_each(function()
    config._reset()
    vim.env.OPENAI_API_KEY = original_openai_key
  end)

  it("keeps setup out of direct core constructors", function()
    local model = require("neoagent.api.openai_completions").new({
      provider = "direct", model = "direct", base_url = "http://localhost/v1",
      context_window = 128000,
    })
    assert.are.equal("direct", model.id)
    assert.are.equal(128000, model.context_window)
  end)

  it("resolves configured built-in models with separate request layers", function()
    config.setup({
      default_model = { provider = "local", model = "coder" },
      providers = {
        ["local"] = {
          api = "openai-completions",
          base_url = "http://localhost:8080/v1",
          request_opts = { body = { nested = { provider = true } } },
          models = {
            coder = {
              context_window = 64000,
              max_output_tokens = 10,
              request_opts = { body = { nested = { model = true } } },
            },
          },
        },
      },
    })
    local model = models.resolve()
    local request = model:_request({ messages = {}, tools = {} })
    assert.are.same({ provider = true, model = true }, request.body.nested)
    assert.are.equal(10, request.body.max_completion_tokens)
    assert.are.equal(64000, model.context_window)
  end)

  it("supports ordinary custom API factories", function()
    local seen
    config.setup({
      default_model = { provider = "custom", model = "one" },
      providers = { custom = { api = "mine", models = { one = { value = 1, context_window = 4096 } } } },
      apis = { mine = function(resolved)
        seen = resolved
        return { stream = function() end }
      end },
    })
    local model = models.resolve("custom", "one")
    assert.is_function(model.stream)
    assert.are.equal(1, seen.model.value)
    assert.are.equal(4096, model.context_window)
    assert.is_nil(model.thinking)
  end)

  it("resolves configured OpenAI Responses models", function()
    config.setup({
      default_model = { provider = "openai", model = "reasoning" },
      providers = {
        openai = {
          api = "openai-responses",
          base_url = "http://localhost:8080/v1",
          request_opts = { body = { metadata = { provider = true } } },
          models = { reasoning = {
            reasoning = true,
            reasoning_effort = "high",
            reasoning_summary = "detailed",
            max_output_tokens = 100,
            request_opts = { body = { metadata = { model = true } } },
          } },
        },
      },
    })
    local resolved = models.resolve()
    local request = resolved:_request({ messages = {}, tools = {} })
    assert.are.equal("openai-responses", resolved.api)
    assert.are.equal("http://localhost:8080/v1/responses", request.url)
    assert.are.same({ provider = true, model = true }, request.body.metadata)
    assert.are.same({ effort = "high", summary = "detailed" }, request.body.reasoning)
    assert.are.equal(100, request.body.max_output_tokens)
  end)

  it("resolves Codex Responses models through configured authentication", function()
    local path = vim.fn.tempname() .. "/auth.json"
    local method = {
      name = "Plan",
      login = function() end,
      refresh = function() end,
      request_opts = function(credential)
        return { headers = { Authorization = "Bearer " .. credential.access } }
      end,
    }
    config.setup({
      auth = { path = path, methods = { plan = method } },
      providers = { codex = {
        api = "openai-codex-responses",
        base_url = "https://chatgpt.com/backend-api",
        auth = "plan",
        models = { coder = { reasoning = true, text_verbosity = "low" } },
      } },
      default_model = { provider = "codex", model = "coder" },
    })
    assert(require("neoagent.auth.store").new(path):write("plan", {
      access = "token", refresh = "refresh", expires = 9999999999999,
    }))
    local resolved = models.resolve()
    assert.are.equal("openai-codex-responses", resolved.api)
    assert.are.equal("codex", resolved.provider)
    assert.is_nil(resolved.thinking)
    vim.fn.delete(vim.fs.dirname(path), "rf")
  end)

  it("composes and dynamically filters the default and user registries", function()
    local path = vim.fn.tempname() .. "/auth.json"
    config.setup({
      auth = { path = path },
      providers = {
        openai = { models = {
          ["gpt-4"] = false,
          ["gpt-5.4"] = { thinking = {
            minimal = false,
            high = { body = { reasoning = { effort = "custom-high" } } },
          } },
          custom = {},
        } },
        ["openai-codex"] = { models = {
          ["gpt-5.5"] = { thinking = {
            high = { body = { metadata = { user = true } } },
          } },
        } },
        local_provider = { api = "custom", models = { local_model = {} } },
      },
    })
    local providers = config.get().providers
    assert.is_nil(providers.openai.models["gpt-4"])
    assert.is_false(providers.openai.models["gpt-5.4"].thinking.minimal)
    assert.are.equal("custom-high", providers.openai.models["gpt-5.4"].thinking.high.body.reasoning.effort)
    assert.is_table(providers.openai.models.custom)
    assert.is_table(providers["openai-codex"].models["gpt-5.6-terra"])
    assert.are.equal(272000, providers["openai-codex"].models["gpt-5.6-terra"].context_window)
    assert.are.equal("high", providers["openai-codex"].models["gpt-5.5"].thinking.high.body.reasoning.effort)
    assert.is_true(providers["openai-codex"].models["gpt-5.5"].thinking.high.body.metadata.user)
    assert.are.same({ "local_provider/local_model" }, assert(models.available()))

    vim.env.OPENAI_API_KEY = "api-key"
    local available = assert(models.available())
    assert.is_true(vim.tbl_contains(available, "openai/custom"))
    assert.is_true(vim.tbl_contains(available, "openai/gpt-5.4"))
    assert.is_false(vim.tbl_contains(available, "openai/gpt-4"))
    assert.is_false(vim.tbl_contains(available, "openai-codex/gpt-5.5"))

    assert(require("neoagent.auth.store").new(path):write("openai-codex", {
      access = "access", refresh = "refresh", expires = 9999999999999,
    }))
    available = assert(models.available())
    assert.is_true(vim.tbl_contains(available, "openai-codex/gpt-5.5"))

    config.setup({ default_registry = false, providers = {
      only = { api = "custom", models = { model = {} } },
    } })
    assert.are.same({ "only/model" }, assert(models.available()))
    vim.fn.delete(vim.fs.dirname(path), "rf")
  end)

  it("allows default providers to be removed and reports API key failures", function()
    config.setup({ providers = { openai = false } })
    assert.is_nil(config.get().providers.openai)
    assert.is_table(config.get().providers["openai-codex"])

    config.setup({ default_registry = false, providers = { broken = {
      api = "custom",
      api_key = function() error("key failed") end,
      models = { model = {} },
    } } })
    local available, err = models.available()
    assert.is_nil(available)
    assert.are.equal("model", err.kind)
    assert.matches("key failed", err.detail)
  end)

  it("validates geometry and configured identifiers", function()
    assert.are.equal(7, config.setup({}).ui.input_height)
    assert.is_true(config.setup({}).ui.scroll_on_submit)
    assert.is_true(config.setup({}).ui.scroll_on_transcript_leave)
    assert.are.equal(16384, config.setup({}).compaction.reserve_tokens)
    assert.is_false(config.setup({ compaction = false }).compaction)
    assert.is_nil(config.setup({}).name)
    assert.has_error(function() config.setup({ name = "" }) end)
    assert.has_error(function() config.setup({ view = true }) end)
    assert.has_error(function() config.setup({ default_registry = "yes" }) end)
    assert.has_error(function() config.setup({ default_thinking_level = "extreme" }) end)
    assert.has_error(function() config.setup({ persistence = { workspace_settings = "yes" } }) end)
    assert.has_error(function() config.setup({ ui = { width = 1.5 } }) end)
    assert.has_error(function() config.setup({ ui = { scroll_on_submit = "yes" } }) end)
    assert.has_error(function() config.setup({ ui = { scroll_on_transcript_leave = "yes" } }) end)
    assert.has_error(function() config.setup({ compaction = true }) end)
    assert.has_error(function() config.setup({ compaction = { auto = "yes" } }) end)
    assert.has_error(function() config.setup({ compaction = { reserve_tokens = 0 } }) end)
    assert.has_error(function() config.setup({ compaction = { keep_recent_tokens = 1.5 } }) end)
    assert.has_error(function() config.setup({ compaction = { run = true } }) end)
    assert.has_error(function()
      config.setup({ providers = { bad = { api = "custom", api_key = 42, models = {} } } })
    end)
    config.setup({ providers = {} })
    assert.has_error(function() models.resolve("missing", "model") end)

    local function invalid_model(model)
      return config.setup({ providers = { bad = {
        api = "openai-responses", base_url = "http://localhost/v1", models = { bad = model },
      } } })
    end
    assert.has_error(function() invalid_model({ reasoning = "yes" }) end)
    assert.has_error(function() invalid_model({ reasoning_effort = "" }) end)
    assert.has_error(function() invalid_model({ reasoning_summary = 1 }) end)
    assert.has_error(function() invalid_model({ thinking = "high" }) end)
    assert.has_error(function() invalid_model({ thinking = { extreme = {} } }) end)
    assert.has_error(function() invalid_model({ thinking = { high = "yes" } }) end)
    assert.has_error(function() invalid_model({ reasoning = true, thinking = { high = {} } }) end)
    assert.has_error(function() invalid_model({ context_window = 0 }) end)
    assert.has_error(function()
      config.setup({ providers = { bad = {
        api = "openai-codex-responses", base_url = "http://localhost", models = {
          bad = { text_verbosity = false },
        },
      } } })
    end)
    assert.has_error(function()
      config.setup({ providers = { bad = {
        api = "openai-codex-responses", base_url = "http://localhost",
        diagnostics = true, models = {},
      } } })
    end)
    assert.has_error(function()
      config.setup({ providers = { bad = {
        api = "openai-codex-responses", base_url = "http://localhost",
        diagnostics = {}, models = {},
      } } })
    end)
    assert.has_error(function()
      config.setup({ providers = { bad = {
        api = "custom", auth = "missing", models = {},
      } } })
    end)
  end)

  it("configures or disables contextual resource locations", function()
    local configured = config.setup({
      agents = { global_files = { "/global/AGENTS.md" }, project_filenames = {} },
      skills = { global_dirs = {}, project_dirs = { "skills" } },
    })
    assert.are.same({ "/global/AGENTS.md" }, configured.agents.global_files)
    assert.are.same({}, configured.agents.project_filenames)
    assert.are.same({}, configured.skills.global_dirs)
    assert.are.same({ "skills" }, configured.skills.project_dirs)

    configured = config.setup({ agents = false, skills = false })
    assert.is_false(configured.agents)
    assert.is_false(configured.skills)
    assert.has_error(function() config.setup({ agents = "yes" }) end)
    assert.has_error(function() config.setup({ agents = { global_files = "AGENTS.md" } }) end)
    assert.has_error(function() config.setup({ agents = { project_filenames = { false } } }) end)
    assert.has_error(function() config.setup({ skills = "yes" }) end)
    assert.has_error(function() config.setup({ skills = { global_dirs = "skills" } }) end)
    assert.has_error(function() config.setup({ skills = { project_dirs = { "" } } }) end)
  end)
end)
