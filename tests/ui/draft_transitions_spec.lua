local fs = require("neoagent.fs")
local assert = require("luassert")
local neoagent = require("neoagent")
local util = require("neoagent.util")
local fake_model = require("tests.helpers.fake_model")

describe("draft selection transitions", function()
  ---@type Neoagent.NeoagentApplet?
  local owner
  ---@type string[]
  local paths = {}

  after_each(function()
    if owner then
      owner:destroy()
    end
    owner = nil
    for _, path in ipairs(paths) do
      vim.fn.delete(path, "rf")
    end
    paths = {}
  end)

  ---@return string
  local function directory()
    local path = fs.canonical(vim.fn.tempname())
    paths[#paths + 1] = path
    return path
  end

  ---@param extra? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  ---@return Neoagent.NeoagentApplet
  local function setup(extra)
    ---@type Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
    local options = {
      default_registry = false,
      workspace_trust = false,
      sandbox = { enabled = false },
      persistence = { enabled = false },
      recording = { enabled = false },
      agent_instructions = false,
      skills = false,
      tools = {},
      compaction = false,
      default_model = { provider = "fake", model = "a" },
      providers = { fake = { api = "fake-api", models = { a = {}, b = {}, c = {} } } },
      _apis = {
        ["fake-api"] = function(resolved)
          local model = fake_model.new({
            { result = fake_model.assistant({ { type = "text", text = "done" } }) },
          })
          model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
          model.thinking = resolved.model.thinking or { medium = {}, high = {} }
          return model
        end,
      },
      ui = { images = false, position = "center" },
    }
    -- These are top-level setup options, including provider and Profile policy.
    options = util.deep_merge(options, extra or {}) --[[@as Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>]]
    owner = neoagent.setup(options)
    return owner
  end

  ---@param path string
  ---@return Neoagent.WorkspaceSettings
  local function settings(path)
    return require("neoagent.workspace_settings").new({ directory = path, root = vim.fn.getcwd() })
  end

  ---@param draft Neoagent.AgentApplet
  ---@return Neoagent.Agent
  local function submit(draft)
    local run = draft:send("remember this selection")
    assert(run)
    assert(type(run) == "table")
    assert(vim.wait(2000, function()
      return run:is_done()
    end))
    assert.is_true(assert(run:result()).ok)
    local agent = draft:agent()
    assert(agent)
    return agent
  end

  it("targets the draft that ordinary open will use when enabling sandboxing", function()
    local applet = setup()
    assert(applet:new("pi"))
    local explicit = applet:foreground_applet()
    assert(explicit)
    assert(applet:new())
    local automatic = applet:foreground_applet()
    assert(automatic)
    assert.are_not.equal(explicit, automatic)
    assert(applet:close())
    assert.is_nil(applet:selected_applet())
    assert.is_true(assert(neoagent.set_sandbox_enabled(true)).enabled)
    assert(applet:open())
    assert.are.equal(automatic, applet:foreground_applet())
    assert.is_true(neoagent.sandbox_info().enabled)
    assert.is_nil(assert(applet:get_draft_options(explicit)).sandbox)
  end)

  it("retains accepted thinking and only reselects a Profile when the Model changes", function()
    local calls = 0
    local applet = setup({
      default_profile = function()
        calls = calls + 1
        return "pi"
      end,
      providers = { fake = { models = { b = { thinking = { max = {} } } } } },
    })
    local draft = applet:draft()
    assert(draft)
    assert.are.equal(1, calls)
    assert(applet:update_draft_options({
      default_model = { provider = "fake", model = "b" }, default_thinking_level = "low",
    }, draft))
    assert.are.equal(2, calls)
    assert.are.equal("max", applet:_owned_draft(draft):thinking_level())
    assert(applet:update_draft_options({ ui = { position = "left" } }, draft))
    assert.are.equal("max", applet:get_thinking_level())
    assert.are.equal(2, calls)
    assert.are.equal("low", assert(applet:get_draft_options(draft)).default_thinking_level)
  end)

  it("remembers an inherited Model in the explicit Profile scope after acceptance", function()
    local path = directory()
    local applet = setup({ persistence = { enabled = true, workspace_settings = true, directory = path } })
    local initial = applet:draft()
    assert(initial)
    submit(initial)
    local explicit = applet:draft("pi")
    assert(explicit)
    assert.are.equal("fake/a", explicit.draft_context.model)
    submit(explicit)
    local automatic = applet:draft()
    assert(automatic)
    assert(applet:update_draft_options({ default_model = { provider = "fake", model = "b" } }, automatic))
    submit(automatic)
    local remembered = applet:draft("pi")
    assert(remembered)
    assert.are.equal("fake/a", remembered.draft_context.model)
    local saved = settings(path):load()
    assert(saved)
    assert.are.same({ provider = "fake", model = "a" }, assert(saved.agents.pi).default_model)
    assert.are.same({ provider = "fake", model = "b" }, saved.default_model)
  end)

  it("commits accepted preferences to a changed persistence directory", function()
    local source, destination = directory(), directory()
    local applet = setup({ persistence = { enabled = true, workspace_settings = true, directory = source } })
    local initial = applet:draft("pi")
    assert(initial)
    submit(initial)
    local draft = applet:draft("pi")
    assert(draft)
    assert(applet:update_draft_options({ persistence = { directory = destination } }, draft))
    local agent = submit(draft)
    assert.are.equal(destination, agent:config().persistence.directory)
    local expected = settings(source):load()
    assert(expected)
    assert.are.same(expected, settings(destination):load())
  end)

  it("persists an inherited Model after pinning an automatic draft", function()
    local path = directory()
    local applet = setup({ persistence = { enabled = true, workspace_settings = true, directory = path } })
    local initial = applet:draft()
    assert(initial)
    submit(initial)
    local automatic = applet:draft()
    assert(automatic)
    local explicit = applet:draft("pi")
    assert(explicit)
    assert.are.equal(automatic, explicit)
    submit(explicit)
    local saved = settings(path):load()
    assert(saved)
    assert.are.same({ provider = "fake", model = "a" }, assert(saved.agents.pi).default_model)
  end)

  for _, explicit_position in ipairs({ false, "bottom" }) do
    it(
      "refreshes destination preferences while preserving explicit presentation: " .. tostring(explicit_position),
      function()
        local source, destination = directory(), directory()
        assert(settings(source):write({ ui_position = "left" }))
        assert(settings(destination):write({ ui_position = "right" }))
        local applet = setup({ persistence = { enabled = true, workspace_settings = true, directory = source } })
        assert(applet:new("pi"))
        local draft = applet:foreground_applet()
        assert(draft)
        assert.are.equal("left", assert(draft:view()).position)
        if explicit_position then
          assert(applet:set_position(explicit_position))
        end
        assert(applet:update_draft_options({ system_prompt = "updated" }, draft))
        assert(applet:update_draft_options({ persistence = { directory = destination } }, draft))
        assert.are.equal(explicit_position or "right", assert(draft:view()).position)
        local agent = submit(draft)
        assert.are.equal(explicit_position or "right", agent:config().ui.position)
        assert.are.equal("left", assert(settings(source):load()).ui_position)
        assert.are.equal(explicit_position or "right", assert(settings(destination):load()).ui_position)
      end
    )
  end

  it("reopens and binds an accepted draft without rerunning its default policy", function()
    local calls = 0
    local applet = setup({
      default_profile = function()
        calls = calls + 1
        assert.are.equal(1, calls, "default policy reran without a selection change")
        return "pi"
      end,
    })
    assert(applet:open())
    local draft = applet:foreground_applet()
    assert(draft)
    assert(applet:close())
    assert.is_false(neoagent.sandbox_info().enabled)
    assert(applet:open())
    assert.are.equal(draft, applet:foreground_applet())
    assert.are.equal("pi", submit(draft):profile_id())
    assert.are.equal(1, calls)
  end)

  it("retains clamped thinking through presentation changes without making it an override", function()
    local applet = setup({ providers = { fake = { api = "fake-api", models = { b = { thinking = { high = {} } } } } } })
    assert(applet:new("pi"))
    local draft = applet:foreground_applet()
    assert(draft)
    assert(applet:set_model("fake", "b"))
    assert.are.equal("high", applet:get_thinking_level())
    assert(applet:set_position("left"))
    assert.are.equal("high", applet:get_thinking_level())
    assert.is_nil(assert(applet:get_draft_options(draft)).default_thinking_level)
    assert.are.equal("high", submit(draft):get_thinking_level())
  end)

  ---@type table<string, Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>>
  local unrelated_defaults = {
    ["failing selector"] = {
      default_profile = function()
        error("unrelated selector failed", 0)
      end,
    },
    ["unknown Profile"] = {
      default_profile = function()
        return "unknown-profile"
      end,
    },
    ["incompatible automatic API"] = {
      default_model = { provider = "openai", model = "test" },
      providers = {
        openai = { api = "openai-completions", base_url = "https://example.test", models = { test = {} } },
      },
    },
  }
  for name, options in pairs(unrelated_defaults) do
    it("opens an explicit Model picker despite an unrelated " .. name, function()
      local applet = setup(options)
      assert(applet:new("pi"))
      local draft = applet:foreground_applet()
      assert(draft)
      local called, selected = pcall(applet.select_model, applet)
      assert(called, type(selected) == "table" and vim.inspect(selected) or tostring(selected))
      assert(selected)
      local request = draft:presenter():snapshot().active
      assert(request)
      assert.are.equal("select", request.kind)
      assert(draft:presenter():cancel(request.id, "test complete"))
    end)
  end

  for _, policy in ipairs({ "explicit", "constant", "callback" }) do
    it("keeps Model picker eligibility consistent for a " .. policy .. " Profile", function()
      ---@param resolved Neoagent.ResolvedApi
      ---@return Neoagent.Model
      local function factory(resolved)
        local model = fake_model.new({})
        model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
        return model
      end
      local applet = setup({
        profile = policy == "explicit" and "codex" or nil,
        default_model = { provider = policy == "constant" and "anthropic" or "fake", model = "a" },
        default_profile = policy == "constant" and "codex" or function(selected)
          return selected and selected.provider == "anthropic" and "pi" or "codex"
        end,
        providers = {
          fake = { api = "openai-responses", base_url = "https://example.test" },
          anthropic = {
            api = "anthropic-messages",
            base_url = "https://example.test",
            models = { a = {} },
          },
        },
        _apis = { ["openai-responses"] = factory, ["anthropic-messages"] = factory },
      })
      assert(applet:open())
      local draft = applet:foreground_applet()
      assert(draft)
      assert.are.equal("codex", draft.profile)
      assert.are.equal("fake/a", draft.draft_context.model)
      assert.are.equal(policy ~= "explicit", applet:_owned_draft(draft):is_automatic())
      assert(applet:select_model())
      local presenter = draft:presenter()
      ---@return string[]
      local function choices()
        local request = presenter:snapshot().active
        assert(request and request.kind == "select")
        local ids = {}
        for _, item in ipairs(request.items) do
          ids[#ids + 1] = item.id
        end
        return ids
      end
      local expected = { "fake/a", "fake/b", "fake/c" }
      if policy == "callback" then
        table.insert(expected, 1, "anthropic/a")
      end
      assert.are.same(expected, choices())
      local resources = applet.resources
      assert(resources)
      local runtimes = resources.runtimes
      assert(runtimes.anthropic.catalog:publish_discoveries({ { id = "remote" } }))
      assert(runtimes.fake.catalog:publish_discoveries({ { id = "remote" } }))
      if policy == "callback" then
        table.insert(expected, 2, "anthropic/remote")
      end
      expected[#expected + 1] = "fake/remote"
      assert(vim.wait(1000, function()
        return vim.deep_equal(expected, choices())
      end))
      local request = presenter:snapshot().active
      assert(request)
      local selected = policy == "callback" and "anthropic/remote" or "fake/remote"
      assert(presenter:resolve(request.id, selected))
      assert(vim.wait(1000, function()
        return draft.draft_context.model == selected
      end))
      assert.are.equal(policy == "callback" and "pi" or "codex", draft.profile)
      assert.are.equal(policy ~= "explicit", applet:_owned_draft(draft):is_automatic())
      if policy ~= "callback" then
        local changed, err = applet:set_model("anthropic", "remote")
        assert.is_nil(changed)
        assert.matches("Profile requires a Model using", assert(err).message)
        assert.are.equal(selected, draft.draft_context.model)
      end
    end)
  end

  ---@type table<string, fun(applet: Neoagent.NeoagentApplet)>
  local presentation_updates = {
    position = function(applet)
      assert(applet:set_position("left"))
    end,
    style = function(applet)
      assert(applet:set_transcript_style("codex"))
    end,
    ["empty patch"] = function(applet)
      assert(applet:update_draft_options({}))
    end,
    thinking = function(applet)
      assert(applet:set_thinking_level("high"))
    end,
  }
  for name, update in pairs(presentation_updates) do
    it("accepts a pending Model choice after a " .. name .. " update", function()
      local applet = setup()
      assert(applet:new("pi"))
      local draft = applet:foreground_applet()
      assert(draft)
      assert(applet:select_model())
      local presenter = draft:presenter()
      local request = presenter:snapshot().active
      assert(request)
      update(applet)
      assert.are.equal(request.id, assert(presenter:snapshot().active).id)
      assert(presenter:resolve(request.id, "fake/b"))
      assert(vim.wait(1000, function()
        return draft.draft_context.model == "fake/b"
      end))
    end)
  end

  it("cancels a Model picker when an explicit Model change supersedes it", function()
    local applet = setup()
    assert(applet:new("pi"))
    local draft = applet:foreground_applet()
    assert(draft)
    assert(applet:select_model())
    local presenter = draft:presenter()
    local request = presenter:snapshot().active
    assert(request)
    assert(applet:set_model("fake", "c"))
    assert.is_nil(presenter:snapshot().active)
    assert.is_nil((presenter:resolve(request.id, "fake/b")))
    assert.are.equal("fake/c", draft.draft_context.model)
  end)

  it("keeps a pending Model choice usable when presentation publication fails", function()
    local applet = setup()
    assert(applet:new("pi"))
    local draft = applet:foreground_applet()
    assert(draft)
    local view = draft:view()
    assert(view)
    assert(applet:select_model())
    local request = draft:presenter():snapshot().active
    assert(request)
    local original = view.set_context
    local reject = true
    function view:set_context(context)
      original(view, context)
      if reject then
        reject = false
        error("presentation rejected", 0)
      end
    end
    local changed, err = applet:set_position("right")
    view.set_context = original
    assert.is_nil(changed)
    assert.matches("presentation rejected", assert(err).message)
    assert.are.equal(request.id, assert(draft:presenter():snapshot().active).id)
    assert(draft:presenter():resolve(request.id, "fake/b"))
    assert(vim.wait(1000, function()
      return draft.draft_context.model == "fake/b"
    end))
  end)
end)
