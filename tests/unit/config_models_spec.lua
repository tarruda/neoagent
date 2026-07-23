local config = require("neoagent.config")
local models = require("neoagent.models")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

describe("neoagent configuration and model resolution", function()
  local original_openai_key
  local original_deepseek_key
  local original_zai_key
  local original_anthropic_key
  local original_anthropic_oauth_token

  before_each(function()
    config._reset()
    original_openai_key = vim.env.OPENAI_API_KEY
    original_deepseek_key = vim.env.DEEPSEEK_API_KEY
    original_zai_key = vim.env.ZAI_API_KEY
    original_anthropic_key = vim.env.ANTHROPIC_API_KEY
    original_anthropic_oauth_token = vim.env.ANTHROPIC_OAUTH_TOKEN
    vim.env.OPENAI_API_KEY = nil
    vim.env.DEEPSEEK_API_KEY = nil
    vim.env.ZAI_API_KEY = nil
    vim.env.ANTHROPIC_API_KEY = nil
    vim.env.ANTHROPIC_OAUTH_TOKEN = nil
  end)

  after_each(function()
    config._reset()
    vim.env.OPENAI_API_KEY = original_openai_key
    vim.env.DEEPSEEK_API_KEY = original_deepseek_key
    vim.env.ZAI_API_KEY = original_zai_key
    vim.env.ANTHROPIC_API_KEY = original_anthropic_key
    vim.env.ANTHROPIC_OAUTH_TOKEN = original_anthropic_oauth_token
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

  it("resolves configured Anthropic Messages models", function()
    config.setup({
      default_registry = false,
      default_model = { provider = "local-anthropic", model = "coder" },
      providers = {
        ["local-anthropic"] = {
          api = "anthropic-messages",
          base_url = "http://localhost:8080/v1",
          api_key = "local-key",
          request_opts = { body = { metadata = { provider = true } } },
          models = { coder = {
            context_window = 64000,
            max_output_tokens = 256,
            request_opts = { body = { metadata = { model = true } } },
          } },
        },
      },
    })

    local model = models.resolve()
    local request = model:_request({ messages = {}, tools = {} })
    assert.are.equal("anthropic-messages", model.api)
    assert.are.equal("http://localhost:8080/v1/messages", request.url)
    assert.are.equal("local-key", request.headers["x-api-key"])
    assert.are.equal(256, request.body.max_tokens)
    assert.are.same({ provider = true, model = true }, request.body.metadata)
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
    local request = resolved._model:_request({ messages = {}, tools = {} })
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
    assert.is_true(providers["openai-codex"].models["gpt-5.6-terra"].responses_lite)
    assert.is_nil(providers["openai-codex"].models["gpt-5.6-terra"].thinking.high.body.reasoning.context)
    assert.are.equal("auto", providers["openai-codex"].models["gpt-5.6-terra"].thinking.high.body.reasoning.summary)
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

  it("resolves the built-in DeepSeek catalog and request profile", function()
    vim.env.DEEPSEEK_API_KEY = "deepseek-key"
    config.setup({})

    local provider = config.get().providers.deepseek
    assert.are.equal("openai-completions", provider.api)
    assert.are.equal("deepseek", provider.auth)
    assert.are.equal("https://api.deepseek.com", provider.base_url)
    local available = assert(models.available())
    assert.is_true(vim.tbl_contains(available, "deepseek/deepseek-v4-flash"))
    assert.is_true(vim.tbl_contains(available, "deepseek/deepseek-v4-pro"))
    assert.are.equal(1000000, provider.models["deepseek-v4-flash"].context_window)
    assert.are.equal(384000, provider.models["deepseek-v4-pro"].max_output_tokens)
    assert.are.same({ "off", "high", "max" },
      require("neoagent.thinking").levels(models.resolve("deepseek", "deepseek-v4-flash")))

    local model = models.resolve("deepseek", "deepseek-v4-pro")
    local request = model._model:_request({
      messages = { { role = "assistant", content = {
        { type = "toolCall", id = "call-1", name = "inspect", arguments = { path = "x.lua" } },
      } } },
      tools = {},
      request_opts = model.thinking.max,
    })
    assert.are.equal("https://api.deepseek.com/chat/completions", request.url)
    assert.are.equal("Bearer deepseek-key", request.headers.Authorization)
    assert.are.equal(384000, request.body.max_completion_tokens)
    assert.is_true(request.body.stream_options.include_usage)
    assert.are.same({ type = "enabled" }, request.body.thinking)
    assert.are.equal("max", request.body.reasoning_effort)
    assert.are.equal("", request.body.messages[1].reasoning_content)
  end)

  it("resolves the built-in Z.AI API and Coding Plan catalogs", function()
    vim.env.ZAI_API_KEY = "zai-key"
    config.setup({})

    local provider = config.get().providers.zai
    assert.are.equal("openai-completions", provider.api)
    assert.are.equal("https://api.z.ai/api/paas/v4", provider.base_url)
    assert.are.equal("zai", provider.auth)
    local plan = config.get().providers["zai-coding-plan"]
    assert.are.equal("https://api.z.ai/api/coding/paas/v4", plan.base_url)
    assert.are.equal("zai", plan.auth)

    local available = assert(models.available())
    for _, id in ipairs({
      "glm-4.5", "glm-4.5-air", "glm-4.5-flash", "glm-4.5v", "glm-4.6",
      "glm-4.6v", "glm-4.7", "glm-4.7-flash", "glm-4.7-flashx", "glm-5",
      "glm-5-turbo", "glm-5.1", "glm-5.2", "glm-5v-turbo",
    }) do
      assert.is_true(vim.tbl_contains(available, "zai/" .. id))
    end
    for _, id in ipairs({
      "glm-4.5-air", "glm-4.7", "glm-5-turbo", "glm-5.1", "glm-5.2", "glm-5v-turbo",
    }) do
      assert.is_true(vim.tbl_contains(available, "zai-coding-plan/" .. id))
    end
    assert.is_false(vim.tbl_contains(available, "zai-coding-plan/glm-4.5"))

    local glm52 = models.resolve("zai-coding-plan", "glm-5.2")
    assert.are.same({ "off", "low", "medium", "high", "max" },
      require("neoagent.thinking").levels(glm52))
    local tools = { {
      name = "inspect",
      description = "Inspect a path",
      input_schema = { type = "object", properties = { path = { type = "string" } } },
    } }
    local request = glm52._model:_request({
      messages = { { role = "user", content = "Inspect it" } },
      tools = tools,
      request_opts = glm52.thinking.max,
    })
    assert.are.equal("https://api.z.ai/api/coding/paas/v4/chat/completions", request.url)
    assert.are.equal("Bearer zai-key", request.headers.Authorization)
    assert.are.equal(131072, request.body.max_completion_tokens)
    assert.is_true(request.body.stream_options.include_usage)
    assert.is_true(request.body.tool_stream)
    assert.are.same({ type = "enabled", clear_thinking = false }, request.body.thinking)
    assert.are.equal("max", request.body.reasoning_effort)

    request = glm52._model:_request({
      messages = {}, tools = {}, request_opts = glm52.thinking.off,
    })
    assert.is_nil(request.body.tool_stream)
    assert.are.same({ type = "disabled" }, request.body.thinking)
    assert.is_nil(request.body.reasoning_effort)

    local glm45 = models.resolve("zai", "glm-4.5")
    assert.are.same({ "off", "minimal", "low", "medium", "high" },
      require("neoagent.thinking").levels(glm45))
    request = glm45._model:_request({ messages = {}, tools = tools, request_opts = glm45.thinking.medium })
    assert.are.same({ type = "enabled", clear_thinking = false }, request.body.thinking)
    assert.is_nil(request.body.reasoning_effort)
    assert.is_nil(request.body.tool_stream)
    assert.are.equal(98304, request.body.max_completion_tokens)

    local glm46v = models.resolve("zai", "glm-4.6v")
    request = glm46v._model:_request({
      messages = {}, tools = tools, request_opts = glm46v.thinking.high,
    })
    assert.are.equal("https://api.z.ai/api/paas/v4/chat/completions", request.url)
    assert.is_true(request.body.tool_stream)
    assert.are.equal(32768, request.body.max_completion_tokens)
    assert.are.equal(128000, glm46v.context_window)
  end)

  it("resolves Anthropic API-key and Claude plan catalogs", function()
    local path = vim.fn.tempname() .. "/auth.json"
    vim.env.ANTHROPIC_API_KEY = "anthropic-key"
    config.setup({ auth = { path = path } })

    local configured = config.get()
    assert.are.equal("anthropic-messages", configured.providers.anthropic.api)
    assert.are.equal("https://api.anthropic.com/v1", configured.providers.anthropic.base_url)
    assert.are.equal("anthropic", configured.providers.anthropic.auth)
    assert.are.equal("anthropic-plan", configured.providers["anthropic-plan"].auth)
    local stored_key_opts = configured.auth.methods.anthropic.request_opts({
      type = "api_key", key = "stored-anthropic",
    })
    assert.are.equal("stored-anthropic", stored_key_opts.headers["x-api-key"])
    local available = assert(models.available())
    for _, id in ipairs({
      "claude-opus-4-1", "claude-opus-4-1-20250805",
      "claude-opus-4-5", "claude-opus-4-5-20251101",
      "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
      "claude-sonnet-4-5", "claude-sonnet-4-5-20250929",
      "claude-sonnet-4-6", "claude-sonnet-5",
      "claude-haiku-4-5", "claude-haiku-4-5-20251001", "claude-fable-5",
    }) do
      assert.is_true(vim.tbl_contains(available, "anthropic/" .. id))
    end
    assert.is_false(vim.tbl_contains(available, "anthropic-plan/claude-opus-4-8"))

    local opus = models.resolve("anthropic", "claude-opus-4-8")
    assert.are.same({ "low", "medium", "high", "xhigh", "max" },
      require("neoagent.thinking").levels(opus))
    local tools = { {
      name = "inspect",
      description = "Inspect a path",
      input_schema = { type = "object", properties = { path = { type = "string" } } },
    } }
    local request = opus._model:_request({
      system_prompt = "Be concise",
      messages = { { role = "user", content = "Inspect it" } },
      tools = tools,
      request_opts = opus.thinking.xhigh,
    })
    assert.are.equal("https://api.anthropic.com/v1/messages", request.url)
    assert.are.equal("anthropic-key", request.headers["x-api-key"])
    assert.are.equal(1000000, opus.context_window)
    assert.are.equal(128000, request.body.max_tokens)
    assert.are.same({ type = "adaptive", display = "summarized" }, request.body.thinking)
    assert.are.equal("xhigh", request.body.output_config.effort)
    assert.are.equal("Be concise", request.body.system[1].text)
    assert.are.equal("ephemeral", request.body.system[1].cache_control.type)
    assert.are.equal("ephemeral", request.body.messages[1].content[1].cache_control.type)
    assert.is_true(request.body.tools[1].eager_input_streaming)
    assert.are.equal("ephemeral", request.body.tools[1].cache_control.type)

    local haiku = models.resolve("anthropic", "claude-haiku-4-5")
    assert.are.same({ "off", "minimal", "low", "medium", "high" },
      require("neoagent.thinking").levels(haiku))
    request = haiku._model:_request({
      messages = { { role = "user", content = "Hello" } },
      tools = {},
      request_opts = haiku.thinking.medium,
    })
    assert.are.equal("interleaved-thinking-2025-05-14", request.headers["anthropic-beta"])
    assert.are.same({
      type = "enabled", budget_tokens = 8192, display = "summarized",
    }, request.body.thinking)
    assert.are.equal(64000, request.body.max_tokens)
    request = haiku._model:_request({
      messages = {}, tools = {}, request_opts = haiku.thinking.off,
    })
    assert.are.same({ type = "disabled" }, request.body.thinking)
    assert.are.equal("interleaved-thinking-2025-05-14", request.headers["anthropic-beta"])

    vim.env.ANTHROPIC_OAUTH_TOKEN = "sk-ant-oat-environment"
    available = assert(models.available())
    assert.is_true(vim.tbl_contains(available, "anthropic-plan/claude-opus-4-8"))
    local ambient_plan = models.resolve("anthropic-plan", "claude-haiku-4-5")
    request = ambient_plan._model:_request({
      messages = {}, tools = {}, request_opts = ambient_plan.thinking.medium,
    })
    assert.are.equal("Bearer sk-ant-oat-environment", request.headers.Authorization)
    assert.matches("oauth%-2025", request.headers["anthropic-beta"])
    vim.env.ANTHROPIC_OAUTH_TOKEN = nil

    assert(require("neoagent.auth.store").new(path):write("anthropic-plan", {
      type = "oauth", access = "plan-access", refresh = "plan-refresh", expires = 9999999999999,
    }))
    available = assert(models.available())
    assert.is_true(vim.tbl_contains(available, "anthropic-plan/claude-opus-4-8"))
    local plan = models.resolve("anthropic-plan", "claude-opus-4-8")
    request = plan._model:_request({
      system_prompt = "Use the project tools",
      messages = { { role = "user", content = {
        { type = "text", text = "Inspect it" },
      } } },
      tools = tools,
      request_opts = plan.thinking.high,
    })
    assert.are.equal("You are Claude Code, Anthropic's official CLI for Claude.",
      request.body.system[1].text)
    assert.are.equal("Use the project tools", request.body.system[2].text)
    assert.are.equal("ephemeral", request.body.messages[1].content[1].cache_control.type)
    assert.is_nil(request.headers["x-api-key"])
    vim.fn.delete(vim.fs.dirname(path), "rf")
  end)

  it("prefers stored API keys and resumes ambient keys after logout", function()
    local path = vim.fn.tempname() .. "/auth.json"
    local ambient_calls = 0
    local seen = {}
    local async = require("neoagent.async")
    local api_key = require("neoagent.auth.api_key").new({ name = "Mixed API key" })
    local configured = config.setup({
      default_registry = false,
      auth = { path = path, methods = { mixed = api_key } },
      providers = { mixed = {
        api = "fake",
        auth = "mixed",
        api_key = function() ambient_calls = ambient_calls + 1 return "ambient-key" end,
        models = { model = {} },
      } },
      apis = { fake = function(resolved)
        local model = { api = "fake", provider = resolved.provider_id, id = resolved.model_id }
        function model:stream(opts)
          return async.run(function()
            local key = resolved.provider.api_key()
            local request = { headers = {} }
            if key then request.headers.Authorization = "Bearer " .. key end
            if opts.request_opts then request = opts.request_opts({ request = request }) end
            seen[#seen + 1] = request.headers.Authorization
            return { ok = true, text = "done" }
          end)
        end
        return model
      end },
    })
    local store = require("neoagent.auth.store").new(path)
    assert(store:write("mixed", { type = "api_key", key = "stored-key" }))
    local manager = require("neoagent.auth").configured(configured)
    local model = models.resolve("mixed", "model", configured, manager)
    assert.is_true(wait(model:stream({})).ok)
    assert.are.same({ "Bearer stored-key" }, seen)
    assert.are.equal(0, ambient_calls)

    assert.is_true(wait(manager:logout("mixed")).ok)
    local ambient_result = wait(model:stream({}))
    assert.is_true(ambient_result.ok, vim.inspect(ambient_result))
    assert.are.same({ "Bearer stored-key", "Bearer ambient-key" }, seen)
    assert.are.equal(1, ambient_calls)
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
    assert.is_true(config.setup({}).ui.scroll_on_reopen)
    assert.are.same({ "files" }, config.setup({}).ui.completion.sources)
    assert.is_false(config.setup({ ui = { completion = false } }).ui.completion)
    assert.are.same({}, config.setup({ ui = { completion = { sources = {} } } }).ui.completion.sources)
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
    assert.has_error(function() config.setup({ ui = { scroll_on_reopen = "yes" } }) end)
    assert.has_error(function() config.setup({ ui = { completion = true } }) end)
    assert.has_error(function() config.setup({ ui = { completion = { sources = "files" } } }) end)
    assert.has_error(function() config.setup({ ui = { completion = { sources = { "buffers" } } } }) end)
    assert.has_error(function() config.setup({ compaction = true }) end)
    assert.has_error(function() config.setup({ compaction = { auto = "yes" } }) end)
    assert.has_error(function() config.setup({ compaction = { reserve_tokens = 0 } }) end)
    assert.has_error(function() config.setup({ compaction = { keep_recent_tokens = 1.5 } }) end)
    assert.has_error(function() config.setup({ compaction = { run = true } }) end)
    assert.has_error(function()
      config.setup({ providers = { bad = { api = "custom", api_key = 42, models = {} } } })
    end)
    assert.has_error(function()
      config.setup({ auth = { methods = { invalid = {
        type = "oauth", name = "Invalid", login = function() end, request_opts = function() return {} end,
      } } } })
    end)
    assert.has_error(function()
      config.setup({ auth = { methods = { invalid = {
        type = "api_key", name = "Invalid", login = function() end,
        refresh = true, request_opts = function() return {} end,
      } } } })
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
    assert.has_error(function() invalid_model({ reasoning_context = false }) end)
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
        api = "openai-codex-responses", base_url = "http://localhost", models = {
          bad = { responses_lite = "yes" },
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
