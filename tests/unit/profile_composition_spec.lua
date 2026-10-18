local assert = require("luassert")
local selection = require("neoagent.profiles.selection")
local config = require("neoagent.config")
local util = require("neoagent.util")

describe("Profile coding environments", function()
  it("releases its provider resource bundle idempotently", function()
    local resources = require("neoagent.provider_resources").new(
      config.resolve({
        default_registry = false,
      }),
      {
        startup = false,
        report = function()
          error("unexpected provider report")
        end,
      }
    )
    resources:destroy()
    resources:destroy()
  end)
  ---@param extra? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  ---@return Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>, Neoagent.TestModel
  local function configuration(extra)
    local model = require("tests.helpers.fake_model").new({
      { result = require("tests.helpers.fake_model").assistant({ { type = "text", text = "done" } }) },
    })
    ---@type Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
    local options = {
      default_registry = false,
      workspace_trust = false,
      sandbox = { enabled = false },
      persistence = { enabled = false },
      agent_instructions = false,
      skills = false,
      compaction = false,
      default_model = { provider = "openai", model = "test" },
      providers = {
        openai = { api = "openai-responses", base_url = "https://example.test", models = { test = {} } },
        anthropic = { api = "anthropic-messages", base_url = "https://example.test", models = { test = {} } },
      },
      _apis = {
        ["openai-responses"] = function(resolved)
          model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
          return model
        end,
        ["anthropic-messages"] = function(resolved)
          local other = require("tests.helpers.fake_model").new({})
          other.api, other.provider, other.id = resolved.api, resolved.provider_id, resolved.model_id
          return other
        end,
      },
    }
    local configured = util.deep_merge(options, extra or {}) --[[@as Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>]]
    return configured, model
  end

  it("resolves an automatic Profile when its first Model arrives before submission", function()
    local options = configuration()
    options.sandbox, options.default_model = nil, nil
    local providers = assert(options.providers)
    providers.anthropic = nil
    assert(providers.openai).models = {}
    local applet = require("neoagent").setup(options)
    local ok, err = pcall(function()
      local draft = applet:draft()
      assert(draft)
      assert.are.equal("pi", draft.profile)
      assert.are.equal("no model", draft.draft_context.model)
      assert(assert(applet.resources).runtimes.openai.catalog:publish_discoveries({ { id = "test" } }))
      local run = draft:send("work")
      assert(type(run) == "table")
      assert(vim.wait(2000, function()
        return run:is_done()
      end))
      assert.is_true(assert(run:result()).ok)
      local agent = draft:agent()
      assert(agent)
      assert.are.equal("codex", agent:profile_id())
      assert.are.equal("codex", require("neoagent.profile_sessions").binding(agent:get_session()))
      assert.are.same({ provider = "openai", model = "test" }, agent:get_model_selection())
      assert.is_true(agent:config().sandbox.enabled)
    end)
    applet:destroy()
    assert(ok, err)
  end)

  it("rejects the same incompatible automatic selection in direct and UI construction", function()
    local options = configuration({
      default_model = { provider = "zprovider", model = "test" },
      default_profile = function()
        return "codex"
      end,
    })
    local providers = assert(options.providers)
    providers.zprovider, providers.anthropic = providers.anthropic, nil
    local constructed, direct = pcall(require("neoagent").new, options)
    if constructed then
      direct:destroy()
    end
    assert.is_false(constructed)
    assert.matches("incompatible with Profile codex", tostring(direct))
    local applet = require("neoagent").setup(options)
    local ok, err = pcall(function()
      local draft, failure = applet:draft()
      assert.is_nil(draft)
      assert.matches("incompatible with Profile codex", assert(failure).message)
    end)
    applet:destroy()
    assert(ok, err)
  end)

  it("describes the current executor after replacing a Toolset", function()
    local options, model = configuration({ profile = "pi" })
    local agent = require("neoagent").new(options)
    local ok, err = pcall(function()
      assert(agent:prepare())
      assert(agent:set_toolset({
        tools = { require("neoagent.tools.pi.read").new() },
        execute_tool = function()
          return { content = { { type = "text", text = "external executor" } } }
        end,
      }))
      local run = agent:send("work")
      assert(run and run ~= true)
      assert(vim.wait(2000, function()
        return run:is_done()
      end))
      assert.is_true(assert(run:result()).ok)
      local prompt = assert(assert(model.requests[1]).system_prompt)
      assert.matches("External executor", prompt)
      assert.is_nil((prompt:find("Host execution: sandboxing is disabled", 1, true)))
    end)
    agent:destroy()
    assert(ok, err)
  end)

  it("preserves the Profile environment across native compaction overflow retries", function()
    local options, model = configuration({
      profile = "codex",
      compaction = { auto = false, reserve_tokens = 512, keep_recent_tokens = 1 },
    })
    model.context_window = 32768
    ---@type Neoagent.NativeCompactionOptions[]
    local requests = {}
    model.compact = function(self, call)
      requests[#requests + 1] = util.copy(call)
      return require("neoagent.async").run(function()
        if #requests == 1 then
          return { ok = false, error = util.error("model", "Input exceeds the context window") }
        end
        return {
          ok = true,
          item = {
            role = "nativeCompaction",
            api = self.api,
            provider = self.provider,
            model = self.id,
            encrypted_content = "synthetic-ciphertext",
          },
        }
      end)
    end
    local agent = require("neoagent").new(options)
    local ok, err = pcall(function()
      assert(agent:prepare())
      assert(agent:get_session():append({ role = "user", content = string.rep("history ", 10000) }))
      local run = agent:compact()
      assert(run)
      assert(vim.wait(2000, function()
        return run:is_done()
      end))
      assert.is_true(assert(run:result()).ok)
      assert.are.equal(2, #requests)
      local initial, retry = assert(requests[1]), assert(requests[2])
      assert.are.equal("developer", assert(retry.messages[1]).role)
      assert.are.equal("userContext", assert(retry.messages[2]).role)
      assert.are.same(initial.messages[1], retry.messages[1])
      assert.are.same(initial.messages[2], retry.messages[2])
      assert.are.equal(initial.system_prompt, retry.system_prompt)
      assert.is_true(
        #util.text_content(assert(retry.messages[3]).content) < #util.text_content(assert(initial.messages[3]).content)
      )
    end)
    agent:destroy()
    assert(ok, err)
  end)

  it("composes headless Agents with the selected Profile and ephemeral request context", function()
    local options, model = configuration()
    local agent = require("neoagent").new(options)
    local ok, err = pcall(function()
      assert.are.equal("codex", agent:profile_id())
      assert.are.equal("codex", require("neoagent.profile_sessions").binding(agent:get_session()))
      assert(agent:prepare())
      local run = agent:send("work")
      assert(run and run ~= true)
      assert(vim.wait(2000, function()
        return run:is_done()
      end))
      assert.is_true(assert(run:result()).ok)
      local request = assert(model.requests[1])
      assert.are.equal("developer", assert(request.messages[1]).role)
      assert.matches(
        "<environment_context>",
        require("neoagent.util").text_content(assert(request.messages[2]).content)
      )
      local journal = agent:get_session():messages()
      assert.are.equal(2, #journal)
      assert.are.equal("work", assert(journal[1]).content)
      local changed, change_err = agent:set_model("anthropic", "test")
      assert.is_nil(changed)
      assert.matches("Profile requires", assert(change_err).message)
      assert.are.equal("codex", agent:profile_id())
    end)
    agent:destroy()
    assert(ok, err)
    local pi_options = configuration({ profile = "pi" })
    local pi = require("neoagent").new(pi_options)
    assert.are.equal("pi", pi:profile_id())
    assert.are.same(
      { "read", jit.os == "Windows" and "powershell" or "bash", "edit", "write" },
      vim.tbl_map(function(tool)
        return tool.name
      end, pi:get_toolset().tools)
    )
    pi:destroy()
  end)

  it("reselects automatic drafts and rolls back failed presentation while explicit drafts stay pinned", function()
    local options = configuration()
    local applet = require("neoagent").setup(options)
    local ok, err = pcall(function()
      local draft = applet:draft()
      assert(draft)
      draft:set_input("preserved input")
      assert.are.equal("codex", draft.profile)
      assert(applet:set_model("anthropic", "test"))
      assert.are.equal(draft, applet:selected_applet())
      assert.are.equal("pi", draft.profile)
      assert.are.equal("preserved input", draft:get_input())
      local renderer = draft.renderer
      local target = applet:profile("codex")
      assert(target)
      local defaults = assert(assert(target.defaults).ui)
      local original = defaults.style
      defaults.style = nil
      target.create_renderer = function()
        error("renderer failed", 0)
      end
      local changed, failure = applet:set_model("openai", "test")
      assert.is_nil(changed)
      assert.matches("renderer failed", assert(failure).message)
      assert.are.equal("pi", draft.profile)
      assert.are.equal(renderer, draft.renderer)
      assert.are.equal("preserved input", draft:get_input())
      target.create_renderer = nil
      defaults.style = original
      assert(applet:set_model("openai", "test"))
      assert.are.equal("codex", draft.profile)
      local explicit = applet:draft("pi")
      assert(explicit)
      applet.selected = explicit
      assert(applet:set_model("openai", "test"))
      assert.are.equal("pi", explicit.profile)
    end)
    applet:destroy()
    assert(ok, err)
  end)

  it("selects provider defaults while preserving explicit choices and caller identity", function()
    local policy = config.resolve({ default_registry = false }).default_profile
    assert.are.equal("pi", selection.choose(policy))
    assert.are.equal("pi", selection.choose(policy, { provider = "anthropic", model = "claude" }))
    for _, provider in ipairs({ "openai", "openai-codex" }) do
      assert.are.equal("codex", selection.choose(policy, { provider = provider, model = "gpt-test" }))
    end
    local original = { provider = "openai", model = "gpt-test" }
    assert.are.equal("pi", selection.choose("pi", original))
    assert.are.equal(
      "pi",
      selection.choose(function(value)
        assert(value).provider = "changed"
        return nil
      end, original)
    )
    assert.are.equal("openai", original.provider)
    assert.has_error(function()
      selection.choose(function()
        error("selector unavailable", 0)
      end, original)
    end, "default_profile failed: selector unavailable")
  end)

  it("uses explicit Profile Workspace preferences in headless composition", function()
    local root, directory = vim.fn.tempname(), vim.fn.tempname()
    assert(require("neoagent.fs").mkdirp(root))
    assert(require("neoagent.workspace_settings").new({ root = root, directory = directory }):write({
      default_model = { provider = "openai", model = "test" },
      agents = { pi = { default_model = { provider = "anthropic", model = "test" } } },
    }))
    local options = configuration({
      profile = "pi",
      persistence = {
        enabled = true,
        workspace_settings = true,
        directory = directory,
      },
    })
    options.default_model = nil
    local agent = require("neoagent").new(options, { workspace = root })
    local ok, err = pcall(function()
      assert(agent:prepare())
      assert.are.same({ provider = "anthropic", model = "test" }, agent:get_model_selection())
    end)
    agent:destroy()
    vim.fn.delete(root, "rf")
    vim.fn.delete(directory, "rf")
    assert(ok, err)
  end)

  it("selects the automatic Profile after discarding an unavailable Workspace Model", function()
    local root, directory = vim.fn.tempname(), vim.fn.tempname()
    assert(require("neoagent.fs").mkdirp(root))
    assert(require("neoagent.workspace_settings").new({ root = root, directory = directory }):write({
      default_model = { provider = "anthropic", model = "removed" },
    }))
    local options = configuration({
      persistence = { enabled = true, workspace_settings = true, directory = directory },
    })
    local agent = require("neoagent").new(options, { workspace = root })
    local applet = require("neoagent").setup(options)
    local ok, err = pcall(function()
      assert.are.equal("codex", agent:profile_id())
      assert(agent:prepare())
      assert.are.same({ provider = "openai", model = "test" }, agent:get_model_selection())
      local draft = applet:draft(nil, root)
      assert(draft)
      assert.are.equal("codex", draft.profile)
      assert.are.equal("openai/test", draft.draft_context.model)
    end)
    agent:destroy()
    applet:destroy()
    vim.fn.delete(root, "rf")
    vim.fn.delete(directory, "rf")
    assert(ok, err)
  end)

  it("composes a registered Profile's facets for direct and UI Agents", function()
    local options, model = configuration({ default_profile = "custom" })
    model.responses[2] = util.copy(model.responses[1])
    ---@type Neoagent.Profile
    local profile = {
      id = "custom",
      label = "Custom",
      compaction = require("neoagent.compaction").for_config(false),
      defaults = { ui = { style = "pi" } },
      create_tools = function()
        return { require("neoagent.tools.pi.read").new() }
      end,
      prepare_prompt = function(context)
        assert.are.equal("read", assert(context.tools[1]).name)
        assert.are.equal("host", assert(context.execution_policy).mode)
        return { system_prompt = "Custom Profile instructions" }
      end,
    }
    local applet = require("neoagent")._setup(options, { profiles = { profile }, startup = false })
    local resources = assert(applet.resources)
    local agent = require("neoagent").new(options, {
      profiles = { profile },
      runtimes = resources.runtimes,
      auth = resources.auth,
    })
    local ok, err = pcall(function()
      local direct_run = agent:send("work")
      assert(direct_run and direct_run ~= true)
      assert(vim.wait(2000, function()
        return direct_run:is_done()
      end))
      assert.is_true(assert(direct_run:result()).ok)
      agent:destroy()
      assert.is_false(resources.destroyed)

      local draft = applet:draft()
      assert(draft)
      assert.are.equal("pi", draft.config.style)
      local ui_run = draft:send("work")
      assert(type(ui_run) == "table")
      assert(vim.wait(2000, function()
        return ui_run:is_done()
      end))
      assert.is_true(assert(ui_run:result()).ok)
      assert.are.equal("custom", assert(draft:agent()):profile_id())
      assert.are.equal(2, #model.requests)
      for _, request in ipairs(model.requests) do
        assert.are.equal("Custom Profile instructions", request.system_prompt)
        assert.are.same(
          { "read" },
          vim.tbl_map(function(tool)
            return tool.name
          end, assert(request.tools))
        )
      end
    end)
    agent:destroy()
    applet:destroy()
    assert(ok, err)
  end)

  it("finds retained drafts pinned by configuration", function()
    local options = configuration({ profile = "pi" })
    local applet = require("neoagent").setup(options)
    local ok, err = pcall(function()
      local draft = applet:draft()
      assert(draft)
      assert.are.equal(draft, applet:retained_draft())
    end)
    applet:destroy()
    assert(ok, err)
  end)

  it("describes the actual execution owner in Profile request context", function()
    for _, external in ipairs({ false, true }) do
      local options, target = configuration({
      })
      local agent = require("neoagent").new(options)
      if external then
        assert(agent:set_toolset({ tools = agent:get_toolset().tools, execute_tool = function()
          error("unexpected Tool execution")
        end }))
      end
      local ok, err = pcall(function()
        assert(agent:prepare())
        local run = agent:send("work")
        assert(run and run ~= true)
        assert(vim.wait(2000, function()
          return run:is_done()
        end))
        assert.is_true(assert(run:result()).ok)
        local context = assert(assert(target.requests[1]).messages[1])
        assert.are.equal("developer", context.role)
        assert.matches(external and "External executor" or "Host execution", util.text_content(context.content))
      end)
      agent:destroy()
      assert(ok, err)
    end
  end)

  it("restores the draft context after a failed Model presentation", function()
    local options, target = configuration({ profile = "pi" })
    target.thinking = { off = {}, medium = {} }
    local applet = require("neoagent").setup(options)
    local ok, err = pcall(function()
      local draft = applet:draft()
      assert(draft)
      local before = util.copy(draft.draft_context)
      local view = require("neoagent.ui.applet_view").new({
        config = draft.config,
        renderer = draft.renderer,
        image_system = false,
      })
      view.set_context = function()
        error("context publication failed", 0)
      end
      draft.view_value = view
      local changed, failure = applet:set_model("anthropic", "test")
      assert.is_nil(changed)
      assert.matches("context publication failed", assert(failure).message)
      assert.is_true(view.destroyed)
      assert.are.same(before, draft.draft_context)
      assert.are.equal("medium", applet:get_thinking_level())
      assert.are.equal("openai/test", draft.draft_context.model)
      assert.are.same({}, applet:get_draft_options())
      assert.are.equal("off", applet:set_thinking_level("off"))
    end)
    applet:destroy()
    assert(ok, err)
  end)

  it("applies Model option updates through automatic selection and retains explicit rendering", function()
    local options = configuration()
    local applet = require("neoagent").setup(options)
    local ok, err = pcall(function()
      local draft = applet:draft()
      assert(draft)
      draft:set_input("keep this")
      assert(applet:set_transcript_style("codex"))
      local renderer = draft.renderer
      local selected = applet:update_draft_options({
        default_model = { provider = "anthropic", model = "test" },
        sandbox = { enabled = true },
      }, draft)
      assert(selected)
      assert.are.equal("pi", draft.profile)
      assert.are.equal(renderer, draft.renderer)
      assert.are.equal("codex", draft.transcript_style)
      assert.are.equal("keep this", draft:get_input())
      assert.is_true(assert(selected.sandbox).enabled)
      assert.are.equal("anthropic/test", draft.draft_context.model)
    end)
    applet:destroy()
    assert(ok, err)
  end)

  it("uses the shared Workspace Model before selecting an automatic Profile", function()
    local root, directory = vim.fn.tempname(), vim.fn.tempname()
    assert(require("neoagent.fs").mkdirp(root))
    local settings = require("neoagent.workspace_settings").new({ root = root, directory = directory })
    assert(settings:write({
      default_model = { provider = "openai", model = "test" },
      agents = { pi = { default_model = { provider = "anthropic", model = "test" } } },
    }))
    local options = configuration({
      default_model = { provider = "anthropic", model = "test" },
      persistence = { enabled = true, workspace_settings = true, directory = directory },
    })
    local applet = require("neoagent").setup(options)
    local ok, err = pcall(function()
      local automatic = applet:draft(nil, root)
      assert(automatic)
      assert.are.equal("codex", automatic.profile)
      assert.are.equal("openai/test", automatic.draft_context.model)
      local explicit = applet:draft("pi", root)
      assert(explicit)
      assert.are.equal("pi", explicit.profile)
      assert.are.equal("anthropic/test", explicit.draft_context.model)
    end)
    applet:destroy()
    vim.fn.delete(root, "rf")
    vim.fn.delete(directory, "rf")
    assert(ok, err)
  end)

  it("constructs exact, independent coding Toolsets without convenience Tools", function()
    local configured = config.snapshot({ default_registry = false })
    local bundled, _, resources = require("neoagent.profiles").bundled(configured, { startup = false })
    local pi, codex = assert(bundled[1]), assert(bundled[3])
    local pi_tools, codex_tools = pi.create_tools, codex.create_tools
    assert(type(pi_tools) == "function")
    assert(type(codex_tools) == "function")
    local settings = config.agent_settings(configured.config)
    local first = pi_tools(settings)
    local second = pi_tools(settings)
    assert.are.same(
      { "read", jit.os == "Windows" and "powershell" or "bash", "edit", "write" },
      vim.tbl_map(function(tool)
        return tool.name
      end, first)
    )
    assert.are.same(
      { "exec_command", "write_stdin", "apply_patch", "view_image" },
      vim.tbl_map(function(tool)
        return tool.name
      end, codex_tools(settings))
    )
    require("neoagent.agent_loop").validate_toolset(first)
    require("neoagent.agent_loop").validate_toolset(codex_tools(settings))
    assert(first[1]).description = "changed"
    assert.are_not.equal(assert(first[1]).description, assert(second[1]).description)
    for _, id in ipairs({ "pi", "chat" }) do
      local accepted = selection.resolve({ profiles = require("neoagent.profiles").index(bundled),
        snapshot = configured, profile_id = id, policy = id, auth = resources.auth, runtimes = resources.runtimes })
      assert.are.equal(require("neoagent.compaction.prefix").component, accepted.compaction)
    end
    resources:destroy()
  end)

  it("preserves custom base prompts while projecting each Profile's environment", function()
    local configured = config.snapshot({ default_registry = false })
    ---@type Neoagent.ProfilePromptContext
    local context = {
      workspace = { cwd = "/project", root = "/project" },
      prompt = "work",
      base_prompt = "Custom instructions",
      tools = require("neoagent.tools.pi").coding(),
      agent_instructions = { { path = "/project/AGENTS.md", content = "Project policy" } },
      skills = {},
      execution_guidance = "Execution policy",
    }
    context.tools[#context.tools + 1] = require("neoagent.tools.update_plan").new()
    local bundled, _, resources = require("neoagent.profiles").bundled(configured, { startup = false })
    local pi = assert(assert(bundled[1]).prepare_prompt)(context)
    assert.are.equal("Custom instructions", pi.system_prompt)
    local codex = assert(assert(bundled[3]).prepare_prompt)(context)
    assert.are.equal("Custom instructions", codex.system_prompt)
    local original = { { role = "user", content = "Work on the project" } }
    local snapshots = {}
    local run = require("neoagent.async").run(function()
      local projection = require("neoagent.api.request_preparation")
      local pi_request = projection.project(pi.prepare_request, {}, pi.system_prompt, context.tools)
      assert.matches("<project_context>", assert(pi_request.system_prompt))
      assert.matches("<cwd>\n/project\n</cwd>", assert(pi_request.system_prompt))
      snapshots[1] = projection.project(codex.prepare_request, original, codex.system_prompt, {}, nil)
      assert(snapshots[1].messages[1]).content = "changed"
      snapshots[2] = projection.project(codex.prepare_request, original, codex.system_prompt, {}, nil)
      return true
    end)
    assert(vim.wait(1000, function()
      return run:is_done()
    end))
    assert.is_true(run:result())
    local developer = assert(snapshots[2].messages[1])
    assert.are.equal("developer", developer.role)
    assert(type(developer.content) == "string")
    assert.matches("Execution policy", developer.content)
    assert.are.equal("userContext", assert(snapshots[2].messages[2]).role)
    assert.are.same(original, { { role = "user", content = "Work on the project" } })
    assert.is_nil(require("neoagent.semantic_message").normalize({ role = "developer", content = "ephemeral" }))
    resources:destroy()
  end)

  it("adds planning guidance to the bundled Codex base only when its Tool is available", function()
    local prompt = require("neoagent.profiles.codex.prompt")
    ---@type Neoagent.ProfilePromptContext
    local context = {
      workspace = { cwd = "/project", root = "/project" },
      prompt = "work",
      tools = { require("neoagent.tools.update_plan").new() },
      agent_instructions = {},
      skills = {},
    }
    assert.matches("Use update_plan", assert(prompt.prepare(context).system_prompt), 1, true)
    context.tools = {}
    assert.is_nil((assert(prompt.prepare(context).system_prompt):find("Use update_plan", 1, true)))
  end)

  for _, profile in ipairs({ "pi", "codex" }) do
    it("compacts with " .. profile .. " context and resumes without persisting prompt additions", function()
      local options, model = configuration({
        profile = profile,
        compaction = {
          auto = false,
          reserve_tokens = 512,
          keep_recent_tokens = 1,
        },
      })
      model.context_window = 32768
      model.responses = {
        {
          result = require("tests.helpers.fake_model").assistant({
            { type = "text", text = "Checkpoint: preserve the requirements" },
          }),
        },
      }
      local agent = require("neoagent").new(options)
      local ok, err = pcall(function()
        assert(agent:prepare())
        local session = agent:get_session()
        assert(session:append({ role = "user", content = "Original requirements" }))
        assert(session:append({ role = "assistant", content = { { type = "text", text = "Progress" } } }))
        local run = agent:compact("Keep requirements")
        assert(run)
        assert(vim.wait(2000, function()
          return run:is_done()
        end))
        assert.is_true(assert(run:result()).ok, vim.inspect(run:result()))
        local request = model.requests[1]
        assert(request)
        local focus = request.messages[#request.messages]
        assert(focus and focus.role == "user")
        assert.matches("Keep requirements", util.text_content(focus.content))
        if profile == "codex" then
          assert.are.equal("developer", assert(request.messages[1]).role)
          assert.matches("handoff summary", util.text_content(focus.content))
        else
          assert.matches("<tools>", (assert(request.system_prompt)))
        end
        assert.are.equal(3, #session:entries())
        assert.are.equal("Original requirements", assert(session:messages()[1]).content)
        model.responses =
          { { result = require("tests.helpers.fake_model").assistant({ { type = "text", text = "Resumed" } }) } }
        local resumed = agent:send("Continue")
        assert(resumed and resumed ~= true)
        assert(vim.wait(2000, function()
          return resumed:is_done()
        end))
        assert.is_true(assert(resumed:result()).ok)
        assert.are.equal(profile == "codex" and 1 or 0, #vim.tbl_filter(function(message)
          return message.role == "developer"
        end, assert(model.requests[2]).messages))
        for _, entry in ipairs(session:entries()) do
          if entry.type == "message" then
            assert.is_nil((util.text_content(entry.message.content):find("<environment_context>", 1, true)))
          end
        end
      end)
      agent:destroy()
      assert(ok, err)
    end)
  end

  require("tests.helpers.async_test")("publishes a complete contextual multi-file patch and reports verified effects", function()
    local root = vim.fn.tempname()
    local fs = require("neoagent.fs")
    assert(fs.mkdirp(root))
    assert(fs.write_all(root .. "/old.txt", "first\nlast\n"))
    local published = {}
    local call = {
      workspace = { root = root, cwd = root },
      on_update = function() end,
      on_file_changed = function(path)
        published[#published + 1] = path
      end,
    }
    local patch = require("neoagent.tools.codex.apply_patch")
    local input = {
      patch = "*** Begin Patch\n*** Update File: old.txt\n*** Move to: new.txt\n@@\n first\n-last\n+changed\n*** Add File: added.txt\n+added\n*** End Patch\n",
    }
    local ok, err = pcall(function()
      local request = patch.prepare(input, {}, call)
      assert.are.same({ root .. "/old.txt", root .. "/new.txt", root .. "/added.txt" }, request.paths)
      local result = patch.run(request, call, patch._dependencies())
      assert.is_not_true(result.isError)
      assert.are.equal("first\nchanged\n", fs.read(root .. "/new.txt"))
      assert.are.equal("added\n", fs.read(root .. "/added.txt"))
      assert.is_nil(fs.read(root .. "/old.txt"))
      assert.are.same({ root .. "/new.txt", root .. "/old.txt", root .. "/added.txt" }, published)
    end)
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end)
end)
