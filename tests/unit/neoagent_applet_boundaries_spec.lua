local NeoagentApplet = require("neoagent.applet")
local AgentApplet = require("neoagent.agent_applet")
local fake_model = require("tests.helpers.fake_model")
local switcher_ui = require("tests.helpers.switcher")
local util = require("neoagent.util")

describe("Neoagent Applet boundaries", function()
  local applets
  local agents

  before_each(function()
    applets = {}
    agents = {}
  end)

  after_each(function()
    for _, applet in ipairs(applets) do
      if not applet:is_destroyed() then applet:destroy() end
    end
    for _, agent in ipairs(agents) do
      if not agent:is_destroyed() then agent:destroy() end
    end
  end)

  local function configuration(model)
    return {
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = {
        fake = { api = "fake-api", models = { test = {
          thinking = { off = {}, medium = {}, high = {} },
        } } },
      },
      _apis = { ["fake-api"] = function() return model end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    }
  end

  local function setup(model)
    local value = require("neoagent").setup(configuration(model))
    applets[#applets + 1] = value
    return value
  end

  local function agent(model)
    local value = require("neoagent").new(configuration(model))
    agents[#agents + 1] = value
    return value
  end

  local function assert_semantic_sources_usable(value)
    local presented
    local detach_presenter = value:presenter():attach({
      present = function(snapshot)
        presented = snapshot
        return true
      end,
    })
    local presentation = value:presenter():notice({
      prompt = "Usable Presenter",
      body = "ready",
    })
    assert.is_table(presented.active)
    assert(value:presenter():resolve(presented.active.id))
    assert(vim.wait(1000, function() return presentation:is_done() end, 5))
    assert.is_true(presentation:result().ok)
    detach_presenter()

    local dialog_snapshot
    local detach_dialog = value:dialogs():subscribe(function(snapshot)
      dialog_snapshot = snapshot
    end)
    local dialog = value:dialogs():show({
      placement = "float",
      title = "Usable Dialogs",
      body = "ready",
      actions = { { id = "done", label = "Done", key = "<CR>" } },
    })
    assert.is_table(dialog_snapshot.active)
    assert(value:dialogs():choose(dialog_snapshot.active.id, "done"))
    assert(vim.wait(1000, function() return dialog:is_done() end, 5))
    assert.is_true(dialog:result().ok)
    detach_dialog()
  end

  it("reports unknown, unowned, and destroyed targets", function()
    local empty = NeoagentApplet.new({ profiles = {} })
    applets[#applets + 1] = empty
    local created, create_err = empty:new("missing")
    assert.is_nil(created)
    assert.matches("Unknown Profile", create_err.message)
    assert.is_nil(empty:open())
    assert.is_nil(empty:get_draft_options())
    empty:destroy()
    assert.is_nil(empty:open())
    assert.is_nil(empty:show_agents())

    local owner = setup(fake_model.new({}))
    local profile = assert(owner:profile("neo"))
    local draft = assert(owner:draft("neo"))
    local bound, bind_err = owner:_bind_draft(profile, {})
    assert.is_nil(bound)
    assert.matches("not owned", bind_err.message)
    local selected, select_err = owner:_activate({
      is_destroyed = function() return true end,
    })
    assert.is_nil(selected)
    assert.matches("destroyed", select_err.message)
    owner:destroy()
    local destroyed, destroyed_err = owner:_bind_draft(profile, draft)
    assert.is_nil(destroyed)
    assert.matches("destroyed", destroyed_err.message)
    assert.is_nil(owner:_activate({}))
  end)

  it("rolls back every resource from failed draft construction", function()
    local owner = setup(fake_model.new({}))
    local profile = assert(owner:profile("neo"))
    local create_applet = profile.create_applet
    local rejected
    profile.create_applet = function(context)
      local candidate, options = create_applet(context)
      rejected = candidate
      options.default_model = { provider = "", model = "unsafe/model" }
      return candidate, options
    end

    local draft, err = owner:draft("neo")

    assert.is_nil(draft)
    assert.matches("provider", err.message)
    assert.is_true(rejected:is_destroyed())
    assert.is_nil(rejected:owner())
    assert.is_nil(owner:retained_draft("neo"))
    assert.is_nil(next(owner.drafts_by_key))
    assert.is_nil(next(owner.drafts_by_applet))

    profile.create_applet = create_applet
    local retried = assert(owner:draft("neo"))
    assert.are_not.equal(rejected, retried)
    assert.are.equal(owner, retried:owner())
  end)

  it("destroys an invalid Agent returned by a Profile", function()
    local owner = setup(fake_model.new({}))
    assert(owner:toggle())
    local profile = assert(owner:profile("neo"))
    local rejected = { destroyed = false }
    function rejected:destroy() self.destroyed = true end
    profile.create_agent = function() return rejected end

    local run, err = owner:foreground_applet():send("invalid")

    assert.is_nil(run)
    assert.matches("invalid Agent", err.message)
    assert.is_true(rejected.destroyed)
    assert.are.same({}, owner:agents())
  end)

  it("rolls back an Agent whose staged position raises", function()
    local owner = setup(fake_model.new({}))
    assert(owner:toggle())
    assert.are.equal("left", owner:set_position("left"))
    local profile = assert(owner:profile("neo"))
    local create_agent = profile.create_agent
    local rejected
    profile.create_agent = function(context)
      local value, metadata = create_agent(context)
      rejected = value
      value.set_ui_position = function() error("position failed") end
      return value, metadata
    end

    local run, err = owner:foreground_applet():send("positioned")

    assert.is_nil(run)
    assert.matches("position failed", err.message)
    assert.is_true(rejected:is_destroyed())
    assert.are.same({}, owner:agents())
  end)

  it("keeps an Agent when staged position persistence warns", function()
    local owner = setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } }))
    assert(owner:toggle())
    assert.are.equal("left", owner:set_position("left"))
    local profile = assert(owner:profile("neo"))
    local create_agent = profile.create_agent
    profile.create_agent = function(context)
      local value, metadata = create_agent(context)
      value.set_ui_position = function()
        return nil, util.error("settings", "position was not saved")
      end
      return value, metadata
    end
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end

    local run, err = owner:foreground_applet():send("positioned")
    vim.notify = original_notify

    assert(run, err and err.message)
    assert.are.equal(1, #owner:agents())
    assert.matches("workspace settings were not saved",
      notifications[#notifications][1])
  end)

  it("adopts a headless Agent and reuses its retained Applet", function()
    local headless = agent(fake_model.new({}))
    assert.is_nil(headless:applet())
    local owner = NeoagentApplet.new({ agents = { headless } })
    applets[#applets + 1] = owner

    assert.are.equal(headless, owner:default_agent())
    assert(headless:applet())
    assert(owner:open())
    assert(owner:show_agents())
    assert.are.equal(headless, owner:select(headless))
    assert.is_false(switcher_ui.is_open())
    assert.are.equal(headless, owner:active_agent())
  end)

  it("rolls back automatic Applet creation when activity registration fails", function()
    local headless = agent(fake_model.new({}))
    headless.subscribe_activity = function()
      error("activity registration failed")
    end

    local ok, err = pcall(NeoagentApplet._from_agents, {
      agents = { headless },
    })

    assert.is_false(ok)
    assert.matches("activity registration failed", err)
    assert.is_false(headless:is_destroyed())
    assert.is_nil(headless:applet())
    assert.is_false(headless:presenter().destroyed)
    assert_semantic_sources_usable(headless)
  end)

  it("restores a supplied unbound Applet after record validation fails", function()
    local headless = agent(fake_model.new({}))
    local configured = headless:config()
    local surface = AgentApplet.new({
      config = configured.ui,
      persistence = configured.persistence,
      label = "Supplied",
      presenter = headless:presenter(),
      dialogs = headless:dialogs(),
    })
    applets[#applets + 1] = surface
    local get_session = headless.get_session
    headless.get_session = function() return {} end

    local ok, err = pcall(NeoagentApplet.new, {
      agents = { { agent = headless, applet = surface } },
    })
    headless.get_session = get_session

    assert.is_false(ok)
    assert.matches("requires a Session", err)
    assert.is_false(headless:is_destroyed())
    assert.is_nil(headless:applet())
    assert.is_false(surface:is_destroyed())
    assert.is_nil(surface:agent())
    assert.is_nil(surface:owner())
  end)

  it("restores another owner's unbound Applet after claim rejection", function()
    local headless = agent(fake_model.new({}))
    local configured = headless:config()
    local surface = AgentApplet.new({
      config = configured.ui,
      persistence = configured.persistence,
      label = "Claimed",
      presenter = headless:presenter(),
      dialogs = headless:dialogs(),
    })
    applets[#applets + 1] = surface
    local existing_owner = {}
    assert.are.equal(surface, surface:claim(existing_owner, {}))

    local ok, err = pcall(NeoagentApplet.new, {
      agents = { { agent = headless, applet = surface } },
    })

    assert.is_false(ok)
    assert.matches("already has an owner", err)
    assert.is_false(headless:is_destroyed())
    assert.is_nil(headless:applet())
    assert.is_false(surface:is_destroyed())
    assert.is_nil(surface:agent())
    assert.are.equal(existing_owner, surface:owner())
  end)

  it("restores every adoption when a later Agent cannot be registered", function()
    local first = agent(fake_model.new({}))
    local failing = agent(fake_model.new({}))
    local unvisited = agent(fake_model.new({}))
    local first_config = first:config()
    local first_surface = AgentApplet.new({
      config = first_config.ui,
      persistence = first_config.persistence,
      label = "First",
      presenter = first:presenter(),
      dialogs = first:dialogs(),
    })
    applets[#applets + 1] = first_surface
    local unvisited_config = unvisited:config()
    local unvisited_surface = AgentApplet.new({
      config = unvisited_config.ui,
      persistence = unvisited_config.persistence,
      label = "Unvisited",
      presenter = unvisited:presenter(),
      dialogs = unvisited:dialogs(),
      agent = unvisited,
    })
    applets[#applets + 1] = unvisited_surface
    failing.subscribe_activity = function()
      error("later registration failed")
    end

    local ok, err = pcall(NeoagentApplet.new, { agents = {
      { agent = first, applet = first_surface },
      failing,
      unvisited,
    } })

    assert.is_false(ok)
    assert.matches("later registration failed", err)
    assert.is_false(first:is_destroyed())
    assert.is_nil(first:applet())
    assert.is_false(first_surface:is_destroyed())
    assert.is_nil(first_surface:agent())
    assert.is_nil(first_surface:owner())
    assert.is_false(failing:is_destroyed())
    assert.is_nil(failing:applet())
    assert.is_false(unvisited:is_destroyed())
    assert.are.equal(unvisited_surface, unvisited:applet())
    assert.are.equal(unvisited, unvisited_surface:agent())
    assert.is_nil(unvisited_surface:owner())
  end)

  it("restores a headless Agent after duplicate adoption is rejected", function()
    local headless = agent(fake_model.new({}))

    local ok, err = pcall(NeoagentApplet._from_agents, {
      agents = { headless, headless },
    })

    assert.is_false(ok)
    assert.matches("already registered", err)
    assert.is_false(headless:is_destroyed())
    assert.is_nil(headless:applet())
    assert_semantic_sources_usable(headless)
  end)

  it("rejects adoption while an Agent Applet has another owner", function()
    local headless = agent(fake_model.new({}))
    local first = NeoagentApplet.new({ agents = { headless } })
    applets[#applets + 1] = first

    local ok, value = pcall(NeoagentApplet.new, { agents = { headless } })
    if ok then applets[#applets + 1] = value end

    assert.is_false(ok)
    assert.matches("already has an owner", value)
    assert.are.equal(headless, first:default_agent())
    assert.are.equal(first, headless:applet():owner())
    assert.are.equal(headless, headless:applet():agent())
    assert.is_false(headless:is_destroyed())
  end)

  it("releases retained Agent Applets for a later owner", function()
    local headless = agent(fake_model.new({}))
    local first = NeoagentApplet.new({ agents = { headless } })
    applets[#applets + 1] = first
    local surface = assert(headless:applet())

    first:destroy()

    assert.is_false(headless:is_destroyed())
    assert.is_false(surface:is_destroyed())
    assert.is_nil(surface:owner())
    local second = NeoagentApplet.new({ agents = { headless } })
    applets[#applets + 1] = second
    assert.are.equal(second, surface:owner())
  end)

  it("destroys a bound Agent with its permanent Applet", function()
    local headless = agent(fake_model.new({}))
    local owner = NeoagentApplet.new({ agents = { headless } })
    applets[#applets + 1] = owner
    local surface = assert(headless:applet())

    surface:destroy()

    assert.is_true(headless:is_destroyed())
    assert.is_nil(headless:applet())
    assert.are.same({}, owner:agents())
  end)

  it("lazily stages every draft-facing facade", function()
    local renderer = require("neoagent.ui.renderers").pi
    local cases = {
      function(owner)
        assert.are.equal("left", owner:set_position("left"))
      end,
      function(owner)
        assert.are.equal(renderer, owner:set_renderer(renderer))
      end,
      function(owner)
        assert.are.equal("pi", owner:set_transcript_style("pi"))
      end,
      function(owner)
        assert.are.same({ provider = "fake", model = "test" },
          owner:set_model("fake", "test"))
      end,
      function(owner)
        assert.are.equal("high", owner:set_thinking_level("high"))
      end,
    }

    for _, stage in ipairs(cases) do
      local owner = setup(fake_model.new({}))
      assert.is_nil(owner:selected_applet())
      stage(owner)
      assert(owner:selected_applet())
      assert.is_nil(owner:target_agent())
    end
  end)

  it("routes draft model and resume actions through the selected Profile", function()
    local owner = setup(fake_model.new({}))
    assert(owner:new("chat"))
    local draft = assert(owner:foreground_applet())
    local view = assert(draft:view())

    assert.is_string(view.callbacks.on_cycle_thinking())
    assert.is_true(view.callbacks.on_select_model())
    local request = assert(draft:presenter():snapshot().active)
    local retained = assert(owner.drafts_by_applet[draft])
    retained.set_model = function()
      return nil, util.error("model", "draft selection failed")
    end
    assert(draft:presenter():resolve(request.id, request.items[1].id))
    assert(vim.wait(1000, function()
      return draft:presenter():snapshot().active == nil
    end, 5))
    assert.is_true(owner:select_model())
    request = assert(draft:presenter():snapshot().active)
    assert(draft:presenter():cancel(request.id, "test complete"))
    assert.is_false(view.callbacks.on_resume_session())
  end)

  it("adopts an explicitly supplied unbound Agent Applet", function()
    local headless = agent(fake_model.new({}))
    local configured = headless:config()
    local surface = AgentApplet.new({
      config = configured.ui,
      persistence = configured.persistence,
      label = "Explicit",
      presenter = headless:presenter(),
      dialogs = headless:dialogs(),
    })
    applets[#applets + 1] = surface
    local owner = NeoagentApplet.new({
      agents = {
        { agent = headless, applet = surface },
      },
    })
    applets[#applets + 1] = owner

    assert.are.equal(surface, headless:applet())
    assert.are.equal(headless, surface:agent())
    assert.are.equal(headless, owner:default_agent())
  end)

  it("keeps the module facade useful before an Agent exists", function()
    local neoagent = require("neoagent")
    local owner = setup(fake_model.new({}))
    assert.are.same({}, neoagent.dequeue_steering())
    assert.are.equal("high", owner:cycle_thinking_level())
    assert(owner:retained_draft("neo"))
    local selected, select_err = neoagent.select_agent("missing")
    assert.is_nil(selected)
    assert.matches("not owned", select_err.message)
    assert.is_nil(neoagent.new_session)

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local ok, err = pcall(function()
      local positioned, position_err = neoagent.set_position("diagonal")
      assert.is_nil(positioned)
      assert.matches("invalid window position", position_err.message)
      local styled, style_err = neoagent.set_transcript_style("missing")
      assert.is_nil(styled)
      assert.matches("invalid transcript style", style_err.message)
      local rendered, renderer_err = neoagent.set_renderer({})
      assert.is_nil(rendered)
      assert.matches("Renderer", renderer_err.message)
      assert.are.equal(require("neoagent.ui.renderers").pi,
        neoagent.set_renderer(require("neoagent.ui.renderers").pi))
      assert.is_boolean(neoagent.show_sandbox_info().enabled)
    end)
    vim.notify = original_notify
    assert(ok, err)
    assert.is_true(#notifications >= 4)

    owner:destroy()
    local lazy = neoagent.applet()
    applets[#applets + 1] = lazy
    assert.is_false(lazy:is_destroyed())

    local headless = agent(fake_model.new({}))
    assert.is_nil(neoagent._set_default(headless))
    local replacement = neoagent.applet()
    applets[#applets + 1] = replacement
    assert.are.equal(headless, neoagent.select_agent(headless))
  end)

  it("bounds draft defaults, provider shell ownership, and destruction", function()
    local owner = setup(fake_model.new({}))
    assert.is_string(owner:get_thinking_level())
    assert.is_true(#assert(owner:available_thinking_levels()) > 0)
    local invalid, invalid_err = owner:set_thinking_level("missing")
    assert.is_nil(invalid)
    assert.matches("thinking level", invalid_err.message)
    local profile = assert(owner:profile("neo"))
    local draft = assert(owner:retained_draft("neo"))
    local updated, update_err = owner:update_draft_options({ test = true }, {})
    assert.is_nil(updated)
    assert.matches("not owned", update_err.message)
    local selected_profile, selected_draft, selection_err =
      owner:_draft_selection_context({})
    assert.is_nil(selected_profile)
    assert.is_nil(selected_draft)
    assert.matches("not owned", selection_err.message)
    local unowned = agent(fake_model.new({}))
    assert.is_false(owner:_accept_draft_agent(profile, draft, unowned))
    assert.is_false(owner:_reject_draft_agent(profile, draft, unowned))

    local shell = {
      opened = false,
      active = false,
      open = function(self) self.opened = true return true end,
      close = function(self) self.opened = false return true end,
      is_open = function(self) return self.opened end,
      is_active = function(self) return self.active end,
      destroy = function(self) self.destroyed = true end,
    }
    local shell_owner = NeoagentApplet.new({
      profiles = {},
      provider_shell = shell,
    })
    applets[#applets + 1] = shell_owner
    assert.are.equal(shell, shell_owner:provider_shell())
    assert.is_false(shell_owner:provider_shell_open())
    assert.is_true(shell_owner:toggle_provider_shell())
    assert.is_true(shell_owner:provider_shell_open())
    assert.is_false(shell_owner:toggle_provider_shell())
    assert.is_true(shell_owner:set_provider_shell(true))
    assert.is_true(shell_owner:set_provider_shell(false))
    shell.active = true
    assert.is_true(shell_owner:any_running())
    shell.active = false

    local empty = NeoagentApplet.new({ profiles = {} })
    applets[#applets + 1] = empty
    local toggled, toggle_err = empty:toggle_provider_shell()
    assert.is_nil(toggled)
    assert.matches("no Provider Shell", toggle_err.message)
    toggled, toggle_err = empty:set_provider_shell(true)
    assert.is_nil(toggled)
    assert.matches("no Provider Shell", toggle_err.message)
    empty:destroy()
    toggled, toggle_err = empty:set_provider_shell(true)
    assert.is_nil(toggled)
    assert.matches("destroyed", toggle_err.message)

    owner:destroy()
    local constructed, construct_err = owner:_construct_agent(
      profile, draft, nil, {})
    assert.is_nil(constructed)
    assert.matches("destroyed", construct_err.message)
  end)

  it("contains Profile selection and provider alignment failures", function()
    local owner = setup(fake_model.new({}))
    assert(owner:new("neo"))
    local draft = assert(owner:foreground_applet())
    local retained = assert(owner.drafts_by_applet[draft])
    retained.cycle_thinking_level = function()
      return nil, util.error("model", "thinking cycle failed")
    end
    local level, level_err = owner:cycle_thinking_level()
    assert.is_nil(level)
    assert.matches("thinking cycle failed", level_err.message)

    assert(owner:_select_profile(
      draft, "Select Profile:", nil, function()
        return nil, util.error("profile", "selection callback failed")
      end))
    local request = assert(draft:presenter():snapshot().active)
    assert(draft:presenter():resolve(request.id, "profile:neo"))
    assert(vim.wait(1000, function()
      return draft:presenter():snapshot().active == nil
    end, 5))

    local empty = NeoagentApplet.new({ profiles = {} })
    applets[#applets + 1] = empty
    local profiled, profile_err = empty:_select_profile(
      draft, "Select Profile:", nil, function() return true end)
    assert.is_nil(profiled)
    assert.matches("No Profiles", profile_err.message)
    local forked, fork_err = empty:fork()
    assert.is_nil(forked)
    assert.matches("bound Agent", fork_err.message)

    local headless = agent(fake_model.new({}))
    headless.get_model_selection = function() return nil end
    local shell = {
      is_open = function() return false end,
      close = function() return true end,
      open = function() return true end,
      destroy = function() end,
    }
    local aligned = NeoagentApplet.new({
      agents = { headless },
      provider_shell = shell,
    })
    applets[#applets + 1] = aligned
    assert(aligned:open())
    assert.are.equal("fake", aligned:_provider_shell_provider())
    assert.are.equal(shell, aligned:provider_shell())
  end)

  it("reports unavailable model catalogs in Provider Shell feedback", function()
    local configured = configuration(fake_model.new({}))
    configured.default_model = nil
    configured.providers = { dynamic = {
      api = "fake-api",
      models = {},
      catalog = {
        source_id = "dynamic-test-models",
        source_revision = 1,
        discover = function() error("catalog unavailable") end,
      },
    } }
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local owner = require("neoagent").setup(configured)
    applets[#applets + 1] = owner

    local ok, draft = pcall(owner.new, owner, "neo")
    local shell = owner:provider_shell()
    local reported = vim.wait(1000, function()
      local info = shell:info()
      return info and vim.iter(info.state.blocks):any(function(block)
        return block.type == "status"
          and block.text:match("catalog unavailable") ~= nil
      end)
    end, 5)
    vim.notify = original_notify

    assert.is_true(ok)
    assert.is_table(draft)
    assert(reported)
    assert.are.same({}, notifications)
  end)

  it("applies staged recipe options when the draft becomes an Agent", function()
    local owner = setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } }))
    local draft = assert(owner:new("neo"))
    assert(owner:update_draft_options({ system_prompt = "Staged prompt" }, draft))

    local run, err = draft:send("Create the Agent")

    assert(run, err and err.message)
    local selected = assert(owner:target_agent())
    assert.are.equal("Staged prompt", selected:config().system_prompt)
  end)

  it("protects agent and skill resources in otherwise tool-free recipes", function()
    local variants = {
      {
        agent_instructions = {
          global_files = {}, project_filenames = { "AGENTS.md" },
        },
        skills = false,
      },
      {
        agent_instructions = false,
        skills = { global_dirs = {}, project_dirs = { ".agents/skills" } },
      },
    }
    for _, variant in ipairs(variants) do
      local configured = configuration(fake_model.new({}))
      configured.workspace_trust = { path = vim.fn.tempname() }
      configured.agent_instructions = variant.agent_instructions
      configured.skills = variant.skills
      local owner = require("neoagent").setup(configured)
      applets[#applets + 1] = owner
      local draft = assert(owner:new("neo"))

      local run, err = draft:send("Protected resources")

      assert.is_nil(run)
      assert.are.equal("workspace_trust", err.kind)
      local selected = assert(owner:target_agent())
      assert(owner:record(selected).metadata.sandbox.trust)
    end
  end)
end)
