local assert = require("luassert")
local NeoagentApplet = require("neoagent.applet")
local AgentApplet = require("neoagent.agent_applet")
local async = require("neoagent.async")
local fake_model = require("tests.helpers.fake_model")
local switcher_ui = require("tests.helpers.switcher")
local util = require("neoagent.util")

describe("Neoagent Applet boundaries", function()
  ---@type (Neoagent.NeoagentApplet|Neoagent.AgentApplet)[]
  local applets
  ---@type Neoagent.Agent[]
  local agents
  ---@type Neoagent.ProviderRuntimes[]
  local runtime_sets = {}
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
    for _, runtimes in ipairs(runtime_sets) do require("neoagent.provider_runtimes").destroy(runtimes) end
    runtime_sets = {}
  end)

  ---@param model Neoagent.Model
  ---@return Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
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

  ---@param model Neoagent.Model
  local function setup(model)
    local value = require("neoagent").setup(configuration(model))
    applets[#applets + 1] = value
    return value
  end

  ---@param model Neoagent.Model
  local function agent(model)
    local value = require("neoagent").new(configuration(model))
    agents[#agents + 1] = value
    return value
  end

  ---@param value Neoagent.Agent
  local function assert_semantic_sources_usable(value)
    ---@type Neoagent.PresentationSnapshot?
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
    assert.is_table(assert(presented).active)
    assert(value:presenter():resolve(assert(assert(presented).active).id))
    assert(vim.wait(1000, function() return presentation:is_done() end, 5))
    assert.is_true((assert(presentation:result())).ok)
    detach_presenter()

    ---@type Neoagent.DialogSnapshot?
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
    assert.is_table(assert(dialog_snapshot).active)
    assert(value:dialogs():choose(assert(assert(dialog_snapshot).active).id, "done"))
    assert(vim.wait(1000, function() return dialog:is_done() end, 5))
    assert.is_true((assert(dialog:result())).ok)
    detach_dialog()
  end

  local function unbound_applet()
    local value = AgentApplet.new({ config = require("neoagent.config").get().ui })
    applets[#applets + 1] = value
    return value
  end

  local function provider_shell()
    local configured = require("neoagent.config").get()
    local auth = require("tests.helpers.auth_manager").new()
    local runtimes = assert(require("neoagent.provider_runtimes").compose(configured, {
      auth = auth, startup = false,
    }))
    runtime_sets[#runtime_sets + 1] = runtimes
    return require("neoagent.provider_shell").new({ config = configured, auth = auth, runtimes = runtimes })
  end

  it("reports unknown, unowned, and destroyed targets", function()
    local empty = NeoagentApplet.new({ profiles = {} })
    applets[#applets + 1] = empty
    local created, create_err = empty:new("missing")
    assert.is_nil(created)
    assert.matches("Unknown Profile", assert(create_err).message)
    assert.is_nil((empty:open()))
    assert.is_nil(((empty:get_draft_options())))
    empty:destroy()
    assert.is_nil((empty:open()))
    assert.is_nil((empty:show_agents()))

    local owner = setup(fake_model.new({}))
    local profile = assert(owner:profile("neo"))
    local draft = assert(owner:draft("neo"))
    local bound, bind_err = owner:_bind_draft(profile, unbound_applet())
    assert.is_nil(bound)
    assert.matches("not owned", assert(bind_err).message)
    local destroyed_applet = AgentApplet.new({ config = require("neoagent.config").get().ui })
    destroyed_applet:destroy()
    local selected, select_err = owner:_activate(destroyed_applet)
    assert.is_nil(selected)
    assert.matches("destroyed", assert(select_err).message)
    owner:destroy()
    local destroyed, destroyed_err = owner:_bind_draft(profile, draft)
    assert.is_nil(destroyed)
    assert.matches("destroyed", assert(destroyed_err).message)
    assert.is_nil(((owner:_activate(unbound_applet()))))
  end)

  it("rolls back every resource from failed draft construction", function()
    local owner = setup(fake_model.new({}))
    local profile = assert(owner:profile("neo"))
    local create_applet = profile.create_applet
    ---@type Neoagent.AgentApplet?
    local rejected
    profile.create_applet = function(context)
      local candidate, options = create_applet(context)
      rejected = candidate
      assert(options).default_model = { provider = "", model = "unsafe/model" }
      return candidate, options
    end

    local draft, err = owner:draft("neo")

    assert.is_nil(draft)
    assert.matches("provider", assert(err).message)
    assert.is_true((assert(rejected):is_destroyed()))
    assert.is_nil((assert(rejected):owner()))
    assert.is_nil(((owner:retained_draft("neo"))))
    assert.is_nil((next(owner.drafts_by_key)))
    assert.is_nil((next(owner.drafts_by_applet)))

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
    profile.create_agent = function() return rejected --[[@as Neoagent.Agent]] end

    local run, err = assert(owner:foreground_applet()):send("invalid")

    assert.is_nil(run)
    assert.matches("invalid Agent", assert(err).message)
    assert.is_true(rejected.destroyed)
    assert.are.same({}, owner:agents())
  end)

  it("rolls back an Agent whose staged position raises", function()
    local owner = setup(fake_model.new({}))
    assert(owner:toggle())
    assert.are.equal("left", owner:set_position("left"))
    local profile = assert(owner:profile("neo"))
    local create_agent = profile.create_agent
    ---@type Neoagent.Agent?
    local rejected
    profile.create_agent = function(context)
      local value, metadata = create_agent(context)
      rejected = value
      value.set_ui_position = function() error("position failed") end
      return value, metadata
    end

    local run, err = assert(owner:foreground_applet()):send("positioned")

    assert.is_nil(run)
    assert.matches("position failed", assert(err).message)
    assert.is_true((assert(rejected):is_destroyed()))
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

    local run, err = assert(owner:foreground_applet()):send("positioned")
    vim.notify = original_notify

    assert(run, err and err.message)
    assert.are.equal(1, #owner:agents())
    assert.matches("workspace settings were not saved",
      notifications[#notifications][1])
  end)

  it("adopts a headless Agent and reuses its retained Applet", function()
    local headless = agent(fake_model.new({}))
    assert.is_nil((headless:applet()))
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
    assert.matches("activity registration failed", tostring(err))
    assert.is_false((headless:is_destroyed()))
    assert.is_nil((headless:applet()))
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
    headless.get_session = function() return {} --[[@as Neoagent.Session]] end

    local ok, err = pcall(NeoagentApplet.new, {
      agents = { { agent = headless, applet = surface } },
    })
    headless.get_session = get_session

    assert.is_false(ok)
    assert.matches("requires a Session", tostring(err))
    assert.is_false((headless:is_destroyed()))
    assert.is_nil((headless:applet()))
    assert.is_false((surface:is_destroyed()))
    assert.is_nil((surface:agent()))
    assert.is_nil((surface:owner()))
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
    assert.matches("already has an owner", tostring(err))
    assert.is_false((headless:is_destroyed()))
    assert.is_nil((headless:applet()))
    assert.is_false((surface:is_destroyed()))
    assert.is_nil((surface:agent()))
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
    assert.matches("later registration failed", tostring(err))
    assert.is_false((first:is_destroyed()))
    assert.is_nil((first:applet()))
    assert.is_false((first_surface:is_destroyed()))
    assert.is_nil((first_surface:agent()))
    assert.is_nil((first_surface:owner()))
    assert.is_false((failing:is_destroyed()))
    assert.is_nil((failing:applet()))
    assert.is_false((unvisited:is_destroyed()))
    assert.are.equal(unvisited_surface, unvisited:applet())
    assert.are.equal(unvisited, unvisited_surface:agent())
    assert.is_nil((unvisited_surface:owner()))
  end)

  it("restores a headless Agent after duplicate adoption is rejected", function()
    local headless = agent(fake_model.new({}))

    local ok, err = pcall(NeoagentApplet._from_agents, {
      agents = { headless, headless },
    })

    assert.is_false(ok)
    assert.matches("already registered", tostring(err))
    assert.is_false((headless:is_destroyed()))
    assert.is_nil((headless:applet()))
    assert_semantic_sources_usable(headless)
  end)

  it("rejects adoption while an Agent Applet has another owner", function()
    local headless = agent(fake_model.new({}))
    local first = NeoagentApplet.new({ agents = { headless } })
    applets[#applets + 1] = first

    local ok, value = pcall(NeoagentApplet.new, { agents = { headless } })
    if ok then applets[#applets + 1] = value end

    assert.is_false(ok)
    assert.matches("already has an owner", tostring(value))
    assert.are.equal(headless, first:default_agent())
    assert.are.equal(first, assert(headless:applet()):owner())
    assert.are.equal(headless, assert(headless:applet()):agent())
    assert.is_false((headless:is_destroyed()))
  end)

  it("releases retained Agent Applets for a later owner", function()
    local headless = agent(fake_model.new({}))
    local first = NeoagentApplet.new({ agents = { headless } })
    applets[#applets + 1] = first
    local surface = assert(headless:applet())

    first:destroy()

    assert.is_false((headless:is_destroyed()))
    assert.is_false((surface:is_destroyed()))
    assert.is_nil((surface:owner()))
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

    assert.is_true((headless:is_destroyed()))
    assert.is_nil((headless:applet()))
    assert.are.same({}, owner:agents())
  end)

  it("lazily stages every draft-facing facade", function()
    local renderer = require("neoagent.ui.renderers").pi
    ---@type (fun(owner: Neoagent.NeoagentApplet))[]
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
      assert.is_nil((owner:selected_applet()))
      stage(owner)
      assert(owner:selected_applet())
      assert.is_nil((owner:target_agent()))
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
    ---@type {message: string, level?: integer}?
    local notification
    function view:notify(message, level)
      notification = { message = message, level = level }
    end
    local retained = assert(owner.drafts_by_applet[draft])
    retained.set_model = function()
      return nil, util.error("model", "draft selection failed")
    end
    assert(draft:presenter():resolve(request.id, assert(assert(request.items)[1]).id))
    assert(vim.wait(1000, function()
      return draft:presenter():snapshot().active == nil
    end, 5))
    assert(vim.wait(1000, function() return notification ~= nil end, 5),
      "draft model selection failure was not reported")
    assert.matches("draft selection failed", assert(notification).message)
    assert.are.equal(vim.log.levels.ERROR, assert(notification).level)
    assert.is_true(((owner:select_model())))
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
    assert.matches("not owned", assert(select_err).message)
    assert.is_nil(rawget(neoagent, "new_session"))

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local ok, err = pcall(function()
      local positioned, position_err = neoagent.set_position("diagonal" --[[@as Neoagent.UiPosition]])
      assert.is_nil(positioned)
      assert.matches("invalid window position", assert(position_err).message)
      local styled, style_err = neoagent.set_transcript_style("missing" --[[@as "codex"]])
      assert.is_nil(styled)
      assert.matches("invalid transcript style", assert(style_err).message)
      local rendered, renderer_err = neoagent.set_renderer({})
      assert.is_nil(rendered)
      assert.matches("Renderer", assert(renderer_err).message)
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
    assert.is_false((lazy:is_destroyed()))

    local headless = agent(fake_model.new({}))
    assert.is_nil(neoagent._set_default(headless))
    local replacement = neoagent.applet()
    applets[#applets + 1] = replacement
    assert.are.equal(headless, neoagent.select_agent(headless))
  end)

  it("bounds draft defaults, provider shell ownership, and destruction", function()
    local owner = setup(fake_model.new({}))
    assert.is_string(owner:get_thinking_level())
    assert.is_true((#assert(owner:available_thinking_levels())) > 0)
    local invalid, invalid_err = owner:set_thinking_level("missing" --[[@as Neoagent.ThinkingLevel]])
    assert.is_nil(invalid)
    assert.matches("thinking level", assert(invalid_err).message)
    local profile = assert(owner:profile("neo"))
    local draft = assert(owner:retained_draft("neo"))
    local updated, update_err = owner:update_draft_options({ test = true }, unbound_applet())
    assert.is_nil(updated)
    assert.matches("not owned", assert(update_err).message)
    local selected_profile, selected_draft, selection_err =
      owner:_draft_selection_context(unbound_applet())
    assert.is_nil(selected_profile)
    assert.is_nil(selected_draft)
    assert.matches("not owned", assert(selection_err).message)
    local unowned = agent(fake_model.new({}))
    assert.is_false((owner:_accept_draft_agent(profile, draft, unowned)))
    assert.is_false((owner:_reject_draft_agent(profile, draft, unowned)))

    local shell = provider_shell()
    local active = false
    function shell:is_active() return active end
    local shell_owner = NeoagentApplet.new({
      profiles = {},
      provider_shell = shell,
    })
    applets[#applets + 1] = shell_owner
    assert.are.equal(shell, shell_owner:provider_shell())
    assert.is_false((shell_owner:provider_shell_open()))
    assert.is_true((shell_owner:toggle_provider_shell()))
    assert.is_true((shell_owner:provider_shell_open()))
    assert.is_false((shell_owner:toggle_provider_shell()))
    assert.is_true((shell_owner:set_provider_shell(true)))
    assert.is_true((shell_owner:set_provider_shell(false)))
    active = true
    assert.is_true((shell_owner:any_running()))
    active = false

    local empty = NeoagentApplet.new({ profiles = {} })
    applets[#applets + 1] = empty
    local toggled, toggle_err = empty:toggle_provider_shell()
    assert.is_nil(toggled)
    assert.matches("no Provider Shell", assert(toggle_err).message)
    toggled, toggle_err = empty:set_provider_shell(true)
    assert.is_nil(toggled)
    assert.matches("no Provider Shell", assert(toggle_err).message)
    empty:destroy()
    toggled, toggle_err = empty:set_provider_shell(true)
    assert.is_nil(toggled)
    assert.matches("destroyed", assert(toggle_err).message)

    owner:destroy()
    local constructed, construct_err = owner:_construct_agent(
      profile, draft, nil --[[@as Neoagent.Session]], {})
    assert.is_nil(constructed)
    assert.matches("destroyed", assert(construct_err).message)
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
    assert.matches("thinking cycle failed", assert(level_err).message)

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
      draft, "Select Profile:", nil, function() error("unused selection") end)
    assert.is_nil(profiled)
    assert.matches("No Profiles", assert(profile_err).message)
    local forked, fork_err = empty:fork()
    assert.is_nil(forked)
    assert.matches("bound Agent", (assert(assert(fork_err).message)))

    local headless = agent(fake_model.new({}))
    headless.get_model_selection = function() return nil end
    local shell = provider_shell()
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
      local info = assert(shell):info()
      for _, block in ipairs(info and info.state and info.state.blocks or {}) do
        if block.type == "status" and block.text:match("catalog unavailable") then return true end
      end
      return false
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
    assert(rawget(draft, "_neoagent_agent_applet"))
    ---@cast draft Neoagent.AgentApplet
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
    assert(rawget(draft, "_neoagent_agent_applet"))
    ---@cast draft Neoagent.AgentApplet

      local run, err = draft:send("Protected resources")

      assert.is_nil(run)
      assert.are.equal("workspace_trust", assert(err).kind)
      local selected = assert(owner:target_agent())
      assert(assert(assert(owner:record(selected)).metadata.sandbox).trust)
    end
  end)

  it("validates every Profile Applet recipe result transactionally", function()
    local owner = setup(fake_model.new({}))
    local profile = assert(owner:profile("neo"))
    local create_applet = profile.create_applet

    profile.create_applet = function(_)
      return nil --[[@as Neoagent.AgentApplet]],
        "Profile Applet construction failed" --[[@as Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>]]
    end
    local draft, err = owner:draft("neo")
    assert.is_nil(draft)
    assert.matches("Profile Applet construction failed", assert(err).message)

    ---@type Neoagent.AgentApplet?
    local rejected
    profile.create_applet = function(context)
      local candidate = create_applet(context)
      rejected = candidate
      return candidate, { "invalid options" } --[[@as Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>]]
    end
    draft, err = owner:draft("neo")
    assert.is_nil(draft)
    assert.matches("draft options must be an object", assert(err).message)
    assert.is_true((assert(rejected):is_destroyed()))

    profile.create_applet = function(context)
      local candidate, options = create_applet(context)
      rejected = candidate
      function candidate:claim()
        return nil, util.error("profile", "Applet claim failed")
      end
      return candidate, options
    end
    draft, err = owner:draft("neo")
    assert.is_nil(draft)
    assert.matches("Applet claim failed", assert(err).message)
    assert.is_true((assert(rejected):is_destroyed()))
    assert.is_nil((next(owner.drafts_by_key)))
    assert.is_nil((next(owner.drafts_by_applet)))
    profile.create_applet = create_applet
  end)

  it("destroys shared resources when initial Agent adoption fails", function()
    local headless = agent(fake_model.new({}))
    headless.subscribe_activity = function()
      error("resource adoption failed")
    end
    local _, _, resources = require("neoagent.profiles").bundled(headless:config())

    local ok, err = pcall(NeoagentApplet.new, {
      profiles = {},
      agents = { { agent = headless } },
      resources = resources,
    })

    assert.is_false(ok)
    assert.matches("resource adoption failed", tostring(err))
    assert.is_true(resources.destroyed)
    assert.is_nil((headless:applet()))
  end)

  it("rolls back draft binding when visibility or Session construction fails", function()
    local owner = setup(fake_model.new({}))
    local profile = assert(owner:profile("neo"))
    local draft = assert(owner:draft("neo"))
    local profile_sessions = require("neoagent.profile_sessions")
    local new_session = profile_sessions.new
    profile_sessions.new = function()
      return nil, util.error("storage", "Session construction failed")
    end
    local bound, err = owner:_bind_draft(profile, draft)
    profile_sessions.new = new_session
    assert.is_nil(bound)
    assert.matches("Session construction failed", assert(err).message)
    assert.are.equal(draft, owner:retained_draft("neo"))

    local is_open = draft.is_open
    draft.is_open = function() error("visibility inspection failed") end
    bound, err = owner:_bind_draft(profile, draft)
    draft.is_open = is_open
    assert.is_nil(bound)
    assert.matches("visibility inspection failed", assert(err).message)
    assert.are.same({}, owner:agents())
    assert.are.equal(draft, owner:retained_draft("neo"))
  end)

  it("contains every live draft model publication failure", function()
    local owner = setup(fake_model.new({}))
    local profile = assert(owner:profile("neo"))
    local draft = assert(owner:draft("neo"))
    local presented = draft:presenter()
    local select = presented.select
    ---@type Neoagent.PresentationRun?
    local selection
    local update_count = 0
    presented.select = function()
      selection = async.run(function()
        return async.await(function() end)
      end)
      return selection, function()
        update_count = update_count + 1
        if update_count == 1 then error("model update crashed") end
        return nil, util.error("presentation", "model update rejected")
      end
    end
    local models = require("neoagent.models")
    local subscribe_available = models.subscribe_available
    ---@type (fun(choices?: string[], err?: Neoagent.Error))?
    local publication
    models.subscribe_available = function(_, _, _, callback)
      publication = callback
      return function() return true end
    end

    assert.is_true(((owner:_select_unbound_model(profile, draft))))
    assert(publication)(nil, util.error("model", "catalog publication failed"))
    assert(publication)({ "fake/test" })
    assert(publication)({ "fake/test" })

    assert(selection):cancel()
    assert(vim.wait(1000, function() return assert(selection):is_done() end, 5))
    presented.select = select
    models.subscribe_available = subscribe_available
    assert.are.equal(2, update_count)
  end)

  it("rejects resumed Sessions without an assigned Profile", function()
    local owner = setup(fake_model.new({}))
    local orphan = { session = require("neoagent.session").new() }
    local resumed, err = owner:_resume_opened(orphan --[[@as Neoagent.OpenedProfileSession]])
    assert.is_nil(resumed)
    assert.matches("no assigned Profile", assert(err).message)
  end)

  it("destroys a provisional draft and its ownership maps explicitly", function()
    local configured = configuration(fake_model.new({}))
    configured.workspace_trust = { path = vim.fn.tempname() }
    configured.agent_instructions = {
      global_files = {},
      project_filenames = { "AGENTS.md" },
    }
    local owner = require("neoagent").setup(configured)
    applets[#applets + 1] = owner
    local draft = assert(owner:new("neo"))
    assert(rawget(draft, "_neoagent_agent_applet"))
    ---@cast draft Neoagent.AgentApplet

    local run, err = draft:send("Protected provisional work")
    assert.is_nil(run)
    assert.are.equal("workspace_trust", assert(err).kind)
    local selected = assert(owner:target_agent())
    local record = assert(owner:record(selected))
    local trust = assert(assert(record.metadata.sandbox).trust)
    local pending_message = draft.pending_message
    draft.pending_message = function() return nil end
    local prepare = selected.prepare
    selected.prepare = function()
      return nil, util.error("agent", "preparation after trust failed")
    end
    local notifications = {}
    local notify = vim.notify
    vim.notify = function(message) notifications[#notifications + 1] = message end
    trust.notify(util.error("workspace_trust", "trust storage failed"))
    assert(trust.on_result)({ ok = false, error = util.error("cancelled", "declined") })
    assert(trust.on_result)({ ok = true, target = vim.fn.getcwd(), persistent = false })
    vim.notify = notify
    selected.prepare = prepare
    draft.pending_message = pending_message
    assert.matches("trust storage failed", table.concat(notifications, "\n"))
    assert.matches("preparation after trust failed", table.concat(notifications, "\n"))

    assert.is_true((owner:destroy_agent(selected)))
    assert.is_true((draft:is_destroyed()))
    assert.is_nil((next(owner.drafts_by_key)))
    assert.is_nil((next(owner.drafts_by_applet)))
  end)

  it("contains bundled Profile construction failures", function()
    local Presenter = require("neoagent.presenter")
    local original_presenter_new = Presenter.new
    local original_applet_new = AgentApplet.new
    ---@type Neoagent.Presenter?
    local created_presenter
    Presenter.new = function(...)
      created_presenter = original_presenter_new(...)
      return created_presenter
    end
    AgentApplet.new = function() error("Profile Applet failed") end
    local owner = setup(fake_model.new({}))
    local draft, err = owner:draft("neo")
    Presenter.new = original_presenter_new
    AgentApplet.new = original_applet_new
    assert.is_nil(draft)
    assert.matches("Profile Applet failed", assert(err).message)
    assert.is_true(assert(created_presenter).destroyed)

    local provider_shell = require("neoagent.provider_shell")
    local provider_runtimes = require("neoagent.provider_runtimes")
    local shell_new = provider_shell.new
    local destroy_runtimes = provider_runtimes.destroy
    local destroyed = 0
    provider_shell.new = function() error("Provider Shell failed") end
    provider_runtimes.destroy = function(runtimes)
      destroyed = destroyed + 1
      return destroy_runtimes(runtimes)
    end
    local ok, setup_err = pcall(require("neoagent").setup,
      configuration(fake_model.new({})))
    provider_shell.new = shell_new
    provider_runtimes.destroy = destroy_runtimes
    assert.is_false(ok)
    assert.matches("Provider Shell failed", tostring(setup_err))
    assert.are.equal(1, destroyed)
  end)

  it("reports fallback model discovery failures on a retained draft", function()
    local configured = configuration(fake_model.new({}))
    configured.default_model = nil
    local models = require("neoagent.models")
    local first_available = models.first_available
    models.first_available = function()
      return nil, util.error("model", "fallback discovery failed", "offline")
    end
    local notifications = {}
    local notify = vim.notify
    vim.notify = function(message) notifications[#notifications + 1] = message end
    local owner = require("neoagent").setup(configured)
    applets[#applets + 1] = owner
    local draft = assert(owner:draft("neo"))
    models.first_available = first_available
    vim.notify = notify
    assert.is_table(draft)
    local reported = false
    for _, message in ipairs(notifications) do
      if message:match("fallback discovery failed") and message:match("offline") then reported = true end
    end
    assert(reported)
  end)
end)
