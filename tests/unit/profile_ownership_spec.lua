local assert = require("luassert")
local util = require("neoagent.util")
local fake = require("tests.helpers.fake_model")
local fs = require("neoagent.fs")
local profiles = require("neoagent.profiles")

describe("Profile composition ownership", function()
  ---@type (Neoagent.Agent|Neoagent.NeoagentApplet)[]
  local owners = {}
  ---@type string[]
  local roots = {}
  local platform = require("neoagent.sandbox.platform")
  local select_platform = platform.select

  before_each(function()
    owners, roots = {}, {}
  end)

  after_each(function()
    platform.select = select_platform
    for index = #owners, 1, -1 do
      owners[index]:destroy()
    end
    for _, root in ipairs(roots) do
      vim.fn.delete(root, "rf")
    end
  end)

  ---@param agent Neoagent.Agent
  ---@return Neoagent.Agent
  local function retain_agent(agent)
    owners[#owners + 1] = agent
    return agent
  end

  ---@param applet Neoagent.NeoagentApplet
  ---@return Neoagent.NeoagentApplet
  local function retain_applet(applet)
    owners[#owners + 1] = applet
    return applet
  end

  local function temporary()
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    assert(fs.mkdirp(root))
    return root
  end

  ---@generic R, E
  ---@param run Neoagent.Run<R, E>
  ---@return R
  local function finish(run)
    assert(vim.wait(5000, function()
      return run:is_done()
    end, 5))
    local result = run:result()
    assert(result)
    return result
  end

  ---@param model Neoagent.TestModel
  ---@param extra? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  ---@return Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  local function options(model, extra)
    local value = {
      default_registry = false,
      workspace_trust = false,
      persistence = { enabled = false },
      recording = { enabled = false },
      agent_instructions = false,
      skills = false,
      sandbox = { enabled = false },
      compaction = false,
      default_model = { provider = "fake", model = "base" },
      providers = { fake = { api = "fake-api", models = { base = {}, other = {} } } },
      _apis = {
        ["fake-api"] = function(resolved)
          model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
          return model
        end,
      },
    }
    return util.deep_merge(value, extra or {}) --[[@as Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>]]
  end

  ---@param opts Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  ---@return Neoagent.Profile
  local function recipe(opts)
    local defaults = require("neoagent.config").agent_options(opts)
    defaults.default_model = nil
    defaults.ui = defaults.ui or { style = "pi" }
    return {
      id = "custom",
      label = "Custom",
      defaults = defaults,
      sandbox_controls = true,
      create_tools = function()
        return { require("neoagent.tools.pi.read").new() }
      end,
      prepare_prompt = function(context)
        return { system_prompt = context.base_prompt or "recipe" }
      end,
      compaction = require("neoagent.compaction").for_config(false),
    }
  end

  for _, controls in ipairs({ false, true }) do
    it("supplies Tool dialogs with sandbox controls " .. tostring(controls), function()
      local observed
      local model = fake.new({
        { result = fake.assistant({ { type = "toolCall", id = "probe", name = "probe", arguments = {} } }, "toolUse") },
        { result = fake.assistant({}) },
      })
      local agent = retain_agent(require("neoagent").new(options(model, {
        profile = "custom",
        tools = { {
          name = "probe",
          description = "Observe the composed dialog dependency",
          input_schema = { type = "object", properties = {} },
          execute = function(_, ctx)
            observed = type(rawget(ctx, "dialog")) == "table"
            return { content = { { type = "text", text = "observed" } } }
          end,
        } },
      }), { profiles = { { id = "custom", label = "Custom", sandbox_controls = controls } } }))
      assert(agent:prepare())
      local run = agent:send("inspect the dialog capability")
      assert(run)
      assert(type(run) == "table")
      assert.is_true(finish(run).ok)
      assert.is_true(observed)
      assert.are.equal(controls, type(assert(agent:get_toolset().sandbox).set_enabled) == "function")
    end)
  end

  it("observes publication events and final changed paths once per Tool invocation", function()
    local root = temporary()
    local path = root .. "/file"
    local refreshed = {}
    local effects = util.shallow_copy(require("applet").host_effects)
    effects.refresh_file = function(changed)
      refreshed[#refreshed + 1] = changed
      return { refreshed = 0, modified = {}, failures = {} }
    end
    local model = fake.new({
      { result = fake.assistant({ { type = "toolCall", id = "first", name = "publish", arguments = {} } }, "toolUse") },
      { result = fake.assistant({ { type = "toolCall", id = "second", name = "publish", arguments = {} } }, "toolUse") },
      { result = fake.assistant({}) },
    })
    local count = 0
    local agent = retain_agent(require("neoagent").new(options(model, {
      tools = { {
        name = "publish",
        description = "Publish a file and report its completed effect",
        input_schema = { type = "object", properties = {} },
        execute = function(_, ctx)
          count = count + 1
          assert(fs.write_all(path, tostring(count)))
          assert(assert(ctx.context).file_changed)(path)
          return { content = {}, details = { changed_paths = { path } } }
        end,
      } },
    }), { workspace = root, host_effects = effects }))
    assert(agent:prepare())
    local run = agent:send("publish twice")
    assert(run)
    assert(type(run) == "table")
    assert.is_true(finish(run).ok)
    assert.are.same({ path, path }, refreshed)
    assert.are.equal("2", fs.read(path))
  end)

  it("rejects a raw executor in Agent configuration instead of replacing sandbox authority", function()
    local opts = options(fake.new({}), { sandbox = { enabled = true } })
    rawset(opts, "execute_tool", function(tool, arguments, ctx)
      return tool.execute(arguments, ctx)
    end)
    local ok, value = pcall(require("neoagent").new, opts)
    if ok then
      retain_agent(value)
    end
    assert.is_false(ok)
    assert.matches("execute_tool", tostring(value))
  end)

  it("decorates the selected sandbox authority and retains its toggle controls", function()
    platform.select = function()
      return nil, { ok = false, platform = "test", message = "synthetic unavailable" }
    end
    local root = temporary()
    assert(fs.write_all(root .. "/file", "host-only text\n"))
    local model = fake.new({
      { result = fake.assistant({ { type = "toolCall", id = "first", name = "read", arguments = { path = "file" } } }, "toolUse") },
      { result = fake.assistant({ { type = "text", text = "blocked" } }) },
      { result = fake.assistant({ { type = "toolCall", id = "second", name = "read", arguments = { path = "file" } } }, "toolUse") },
      { result = fake.assistant({ { type = "text", text = "read" } }) },
    })
    local observed = {}
    local opts = options(model, {
      profile = "neo",
      sandbox = { enabled = true },
      decorate_tool = function(execute)
        ---@async
        return function(tool, arguments, ctx)
          observed[#observed + 1] = tool.name
          return execute(tool, arguments, ctx)
        end
      end,
    })
    local agent = retain_agent(require("neoagent").new(opts, { workspace = root }))
    assert(agent:prepare())
    local controls = agent:get_toolset().sandbox
    assert(controls)
    assert.is_true(controls:status().enabled)
    local run = agent:send("read file")
    assert(type(run) == "table")
    assert.is_true(finish(run).ok)
    local denied = agent:get_session():messages()[3]
    assert(denied)
    assert.is_true(denied.isError)
    assert.is_nil((util.text_content(denied.content):find("host-only text", 1, true)))
    assert(assert(controls.set_enabled)(controls, false))
    run = agent:send("read file after disabling")
    assert(type(run) == "table")
    assert.is_true(finish(run).ok)
    local allowed = agent:get_session():messages()[7]
    assert(allowed)
    assert.is_false(allowed.isError)
    assert.matches("host%-only text", util.text_content(allowed.content))
    assert.are.same({ "read", "read" }, observed)
  end)

  it("uses the same provider resources for explicit and default supplied Profiles", function()
    local configured = options(fake.new({}))
    local definition = recipe(configured)
    for _, policy in ipairs({ "explicit", "string", "callback" }) do
      local caller = options(fake.new({}))
      if policy == "explicit" then
        caller.profile = "custom"
      else
        caller.default_profile = policy == "string" and "custom" or function() return "custom" end
      end
      local agent = retain_agent(require("neoagent").new(caller, { profiles = { definition }, workspace = temporary() }))
      assert(agent:prepare())
      assert.are.same(configured.default_model, agent:get_model_selection())
      assert(agent:set_model("fake", "base"))
      local owner = retain_applet(require("neoagent")._setup(caller, { profiles = { definition }, startup = false }))
      local applet = owner:draft(nil, temporary())
      assert(applet)
      local selected = assert(configured.default_model)
      assert.are.equal(selected.provider .. "/" .. selected.model, applet.draft_context.model)
      assert.are.same({}, owner:get_draft_options(applet))
      assert(assert(owner.resources).runtimes.fake)
    end
  end)

  it("rejects shared provider settings in Profile defaults in every selection path", function()
    for _, explicit in ipairs({ true, false }) do
      local opts = options(fake.new({}))
      opts.profile = explicit and "custom" or nil
      opts.default_profile = "custom"
      local definition = recipe(opts)
      assert(definition.defaults).providers = { hidden = { api = "fake-api", models = { test = {} } } }
      local ok, err = pcall(require("neoagent").new, opts, { profiles = { definition } })
      assert.is_false(ok)
      assert.matches("providers belongs to top%-level composition", tostring(err))
    end
  end)

  it("rejects conflicting Tools for Chat without accepting a draft update", function()
    local opts = options(fake.new({}), { profile = "chat", tools = { require("neoagent.tools.pi.read").new() } })
    local ok, err = pcall(require("neoagent").new, opts)
    assert.is_false(ok)
    assert.matches("Profile chat does not accept Tools", tostring(err))
    opts.tools = nil
    local agent = retain_agent(require("neoagent").new(opts))
    assert.are.same({}, agent:get_toolset().tools)
    assert.are.same({}, agent:config().tools)
    local owner = retain_applet(require("neoagent")._setup(opts, { startup = false }))
    local applet = owner:draft()
    assert(applet)
    local updated, update_err =
      owner:update_draft_options({ tools = { require("neoagent.tools.pi.write").new() } }, applet)
    assert.is_nil(updated)
    assert.matches("Profile chat does not accept Tools", assert(update_err).message)
    local draft = owner.drafts_by_applet[applet]
    assert(draft)
    assert.are.same({}, draft:snapshot().config.tools)
  end)

  it("rejects an invalid ordinary draft update without changing retained options", function()
    local owner = retain_applet(require("neoagent")._setup(options(fake.new({})), { startup = false }))
    local applet = owner:draft("neo", temporary())
    assert(applet)
    local before = assert(owner:get_draft_options(applet))
    local invalid = { sandbox = { enabled = "invalid" } } --[[@as unknown]]
    local updated, err = owner:update_draft_options(invalid --[[@as Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>]], applet)
    assert.is_nil(updated)
    assert.matches("sandbox.enabled must be boolean", assert(err).message)
    assert.are.same(before, owner:get_draft_options(applet))
    local retained = owner.drafts_by_applet[applet]
    assert(retained)
    assert(retained:snapshot())
  end)

  it("rejects shared resource changes on a retained draft", function()
    local owner = retain_applet(require("neoagent")._setup(options(fake.new({})), { startup = false }))
    local applet = owner:draft("neo", temporary())
    assert(applet)
    local before = assert(owner:get_draft_options(applet))
    local updated, err = owner:update_draft_options({ providers = { fake = false } }, applet)
    assert.is_nil(updated)
    assert.matches("providers belongs to top%-level composition", assert(err).message)
    assert.are.same(before, owner:get_draft_options(applet))
    assert(assert(owner.resources).runtimes.fake.catalog:snapshot().models.base)
  end)

  it("enforces sandbox settings independently of Profile controls", function()
    platform.select = function()
      return nil, { ok = false, platform = "test", message = "synthetic unavailable" }
    end
    for _, variant in ipairs({ "default", "override", "false-controls" }) do
      local opts = options(fake.new({}), { profile = "custom" })
      opts.sandbox = nil
      local definition = recipe(opts)
      definition.sandbox_controls = nil
      if variant == "false-controls" then
        definition.sandbox_controls = false
      end
      assert(definition.defaults).sandbox = { enabled = variant == "default" }
      if variant ~= "default" then
        opts.sandbox = { enabled = true }
      end
      local agent = retain_agent(require("neoagent").new(opts, { profiles = { definition }, workspace = temporary() }))
      assert.is_true(agent:config().sandbox.enabled)
      local toolset = agent:get_toolset()
      assert(toolset.execute_tool)
      local controls = toolset.sandbox
      assert(controls)
      assert.is_true(controls:status().enabled)
      assert.is_nil(controls.set_enabled)
      local facts = assert(toolset.execution_policy)(agent:get_workspace())
      assert.are.equal("blocked", facts.mode)
    end
  end)

  it("reports fixed sandbox policy before and after a draft binds without exposing toggles", function()
    platform.select = function()
      return nil, { ok = false, platform = "test", message = "synthetic unavailable" }
    end
    local opts = options(fake.new({ { result = fake.assistant({ { type = "text", text = "done" } }) } }),
      { profile = "custom" })
    opts.sandbox = nil
    local definition = recipe(opts)
    definition.sandbox_controls = false
    assert(definition.defaults).sandbox = { enabled = true }
    local neoagent = require("neoagent")
    local owner = retain_applet(neoagent._setup(opts, { profiles = { definition }, startup = false }))
    local draft = owner:draft()
    assert(draft)
    assert.is_true(neoagent.sandbox_info().enabled)
    local toggled, err = neoagent.set_sandbox_enabled(false)
    assert.is_nil(toggled)
    assert.matches("toggling is unavailable", assert(err).message)
    assert.is_true(neoagent.sandbox_info().enabled)
    local run = draft:send("work")
    assert(type(run) == "table")
    assert.is_true(finish(run).ok)
    assert.is_true(neoagent.sandbox_info().enabled)
    toggled, err = neoagent.set_sandbox_enabled(false)
    assert.is_nil(toggled)
    assert.matches("toggling is unavailable", assert(err).message)
    assert.is_true(neoagent.sandbox_info().enabled)
  end)

  it("rejects malformed direct Session bindings while allowing unassigned Sessions", function()
    for _, metadata in ipairs({
      { neoagent = { profileId = 42 } },
      { neoagent = "malformed" },
      { neoagent = { profileId = "chat", derivation = { kind = "invalid" } } },
    }) do
      local session = assert(require("neoagent.session").new({ metadata = metadata, workspace = temporary() }))
      local constructed, value = pcall(require("neoagent").new, options(fake.new({}), { profile = "neo" }), {
        session = session,
      })
      if constructed then
        retain_agent(value)
      end
      assert.is_false(constructed)
      assert.matches("Session metadata", require("neoagent.util").normalize_error(value, "profile").message)
    end
    local session = assert(require("neoagent.session").new({ workspace = temporary() }))
    local agent = retain_agent(require("neoagent").new(options(fake.new({}), { profile = "neo" }), { session = session }))
    assert.are.equal(session, agent:get_session())
  end)

  it("resolves Chat presentation consistently after automatic recomposition", function()
    local opts = options(fake.new({}), { default_profile = function(selected)
      return selected and selected.model == "other" and "chat" or "neo"
    end })
    local applet = retain_applet(require("neoagent")._setup(opts, { startup = false }))
    local draft = applet:draft()
    assert(draft)
    assert.are.equal("codex", draft.transcript_style)
    assert(applet:set_model("fake", "other"))
    assert.are.equal("chat", draft.profile)
    local fresh_opts = util.copy(opts)
    fresh_opts.profile = "chat"
    local fresh = retain_applet(require("neoagent")._setup(fresh_opts, { startup = false }))
    local expected = fresh:draft()
    assert(expected)
    assert.are.equal(expected.transcript_style, draft.transcript_style)
    assert.are.same(expected.renderer, draft.renderer)
  end)

  it("applies explicit direct options to supplied Profiles before selection and composition", function()
    local opts = options(fake.new({}), { system_prompt = "recipe" })
    local definition = recipe(opts)
    local caller = options(fake.new({}), {
      profile = "custom",
      tools = {},
      system_prompt = "CALLER",
      sandbox = { enabled = true },
      default_model = { provider = "fake", model = "other" },
    })
    local agent = retain_agent(require("neoagent").new(caller, { profiles = { definition } }))
    assert(agent:prepare())
    assert.are.same({}, agent:get_toolset().tools)
    assert.are.equal("CALLER", agent:config().system_prompt)
    assert.is_true(agent:config().sandbox.enabled)
    assert.are.same({ provider = "fake", model = "other" }, agent:get_model_selection())
    assert.are.equal("recipe", assert(definition.defaults).system_prompt)
    assert.is_false(assert(assert(definition.defaults).sandbox).enabled)
  end)

  it("applies caller options to supplied Profiles through UI construction", function()
    local model = fake.new({ { result = fake.assistant({ { type = "text", text = "done" } }) } })
    local definition = recipe(options(model, { system_prompt = "recipe" }))
    local caller = options(model, {
      profile = "custom",
      tools = {},
      system_prompt = "CALLER",
      default_model = { provider = "fake", model = "other" },
    })
    local applet = retain_applet(require("neoagent")._setup(caller, { profiles = { definition }, startup = false }))
    local run = applet:send("work")
    assert(type(run) == "table")
    assert.is_true(finish(run).ok)
    local agent = applet:target_agent()
    assert(agent)
    assert.are.same({}, agent:get_toolset().tools)
    assert.are.equal("CALLER", agent:config().system_prompt)
    assert.are.same({ provider = "fake", model = "other" }, agent:get_model_selection())
  end)

  it("reports the current Toolset sandbox after a composed Agent adopts host execution", function()
    platform.select = function()
      return nil, { ok = false, platform = "test", message = "synthetic unavailable" }
    end
    local agent = retain_agent(require("neoagent").new(options(fake.new({}), {
      profile = "neo",
      sandbox = { enabled = true },
    })))
    require("neoagent")._set_default(agent)
    retain_applet(require("neoagent").applet())
    assert.is_true(require("neoagent").sandbox_info().enabled)
    assert(agent:set_toolset({ tools = {} }))
    assert.is_false(require("neoagent").sandbox_info().enabled)
  end)

  it("surfaces workspace Model construction failures in its selected Profile", function()
    local root, directory = temporary(), temporary()
    assert(require("neoagent.workspace_settings").new({ root = root, directory = directory }):write({
      default_model = { provider = "anthropic", model = "saved" },
    }))
    local model = fake.new({})
    local opts = options(model, {
      persistence = { enabled = true, workspace_settings = true, directory = directory },
      providers = {
        openai = { api = "openai-responses", base_url = "https://example.test", models = { base = {} } },
        anthropic = { api = "broken-api", models = { saved = {} } },
      },
      _apis = {
        ["broken-api"] = function()
          error("saved model cannot resolve")
        end,
        ["openai-responses"] = function(resolved)
          model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
          return model
        end,
      },
    })
    opts.default_model = nil
    local agent = retain_agent(require("neoagent").new(opts, { workspace = root }))
    local prepared, err = agent:prepare()
    assert.is_nil(prepared)
    assert.matches("saved model cannot resolve", assert(err).message)
    assert.are.same({ provider = "anthropic", model = "saved" }, agent:config().default_model)
    assert.are.equal("neo", agent:profile_id())
    local snapshot = require("neoagent.config").snapshot(opts)
    local configured = snapshot.config
    local definitions, policy, resources = profiles.bundled(snapshot, { startup = false })
    local applet = retain_applet(require("neoagent.applet").new({
      profiles = definitions,
      default_profile = policy,
      resources = resources,
      snapshot = snapshot,
    }))
    local draft = applet:draft(nil, root)
    assert(draft)
    assert.are.equal("neo", draft.profile)
    assert.are.equal("anthropic/saved", draft.draft_context.model)
  end)

end)
