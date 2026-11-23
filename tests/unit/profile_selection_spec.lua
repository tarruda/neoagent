local assert = require("luassert")
local config = require("neoagent.config")
local fake = require("tests.helpers.fake_model")
local profiles = require("neoagent.profiles")
local selection = require("neoagent.profiles.selection")

describe("Profile Model selection", function()
  ---@type (Neoagent.Agent|Neoagent.NeoagentApplet|Neoagent.Presenter)[]
  local owners
  ---@type Neoagent.ProfileResources[]
  local resources
  ---@type string
  local root
  ---@type string
  local directory
  ---@type string?
  local original_state_home

  before_each(function()
    owners, resources = {}, {}
    root, directory = vim.fn.tempname(), vim.fn.tempname()
    assert(require("neoagent.fs").mkdirp(root))
    original_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = directory .. "/state"
  end)

  after_each(function()
    for index = #owners, 1, -1 do
      owners[index]:destroy()
    end
    for _, resource in ipairs(resources) do
      resource:destroy()
    end
    vim.env.XDG_STATE_HOME = original_state_home
    vim.fn.delete(root, "rf")
    vim.fn.delete(directory, "rf")
  end)

  ---@return Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>, table<string, integer>
  local function options()
    local calls = {}
    ---@param resolved Neoagent.ResolvedApi
    ---@return Neoagent.Model
    local function factory(resolved)
      calls[resolved.provider_id] = (calls[resolved.provider_id] or 0) + 1
      local model = fake.new({})
      model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
      return model
    end
    return {
      default_registry = false,
      workspace_trust = false,
      agent_instructions = false,
      skills = false,
      sandbox = { enabled = false },
      recording = { enabled = false },
      persistence = { enabled = true, workspace_settings = true, directory = directory },
      compaction = false,
      tools = {},
      providers = {
        anthropic = {
          api = "anthropic-messages",
          base_url = "https://example.invalid",
          api_key = "synthetic",
          models = { test = {} },
        },
        openai = {
          api = "openai-responses",
          base_url = "https://example.invalid",
          api_key = "synthetic",
          models = { test = {} },
        },
      },
      _apis = { ["anthropic-messages"] = factory, ["openai-responses"] = factory },
    },
      calls
  end

  ---@param model Neoagent.ModelSelection
  local function remember(model)
    assert(require("neoagent.workspace_settings").new({ root = root, directory = directory }):write({
      default_model = model,
    }))
  end

  ---@param opts Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  ---@return Neoagent.ProfileComposition, Neoagent.ProfileResources
  local function resolve(opts)
    local snapshot = config.snapshot(opts)
    local definitions, policy, resource = profiles.bundled(snapshot, { startup = false })
    resources[#resources + 1] = resource
    return selection.resolve({
      snapshot = snapshot,
      profiles = profiles.index(definitions),
      policy = policy,
      workspace = root,
      auth = resource.auth,
      runtimes = resource.runtimes,
    }),
      resource
  end

  for _, alternative in ipairs({ false, true }) do
    it("rejects an incompatible direct Model with alternative=" .. tostring(alternative), function()
      local opts = options()
      opts.profile = "codex"
      opts.default_model = { provider = "anthropic", model = "test" }
      if not alternative then
        assert(opts.providers).openai = nil
      end
      local ok, value = pcall(require("neoagent").new, opts, { workspace = root })
      if ok then
        owners[#owners + 1] = value
      end
      assert.is_false(ok)
      assert.matches("incompatible with Profile codex", tostring(value))
    end)
  end

  it("honors a direct Model before a saved Workspace choice", function()
    remember({ provider = "anthropic", model = "test" })
    local opts, calls = options()
    opts.default_model = { provider = "openai", model = "test" }
    local agent = require("neoagent").new(opts, { workspace = root })
    owners[#owners + 1] = agent
    assert.are.equal("codex", agent:profile_id())
    assert(agent:prepare())
    assert.are.same(opts.default_model, agent:get_model_selection())
    assert.are.same({ openai = 1 }, calls)
  end)

  it("keeps setup defaults as hints for an explicitly chosen draft", function()
    local opts = options()
    opts.default_model = { provider = "anthropic", model = "test" }
    local applet = require("neoagent")._setup(opts, { startup = false })
    owners[#owners + 1] = applet
    local draft = applet:draft("codex", root)
    assert(draft)
    assert.are.equal("openai/test", draft.draft_context.model)
  end)

  for _, unavailable in ipairs({ "provider", "model", "api" }) do
    it("explains fallback from a saved choice with an unavailable " .. unavailable, function()
      local opts = options()
      opts.default_model = { provider = "openai", model = "test" }
      local saved = { provider = "anthropic", model = "test" }
      if unavailable == "provider" then
        saved.provider = "removed"
      elseif unavailable == "model" then
        saved.model = "removed"
      else
        opts.profile = "codex"
      end
      remember(saved)
      local choice = resolve(opts)
      assert.are.same(opts.default_model, choice.config.default_model)
      assert.are.equal(1, #choice.warnings)
      local warning = choice.warnings[1]
      assert(warning)
      assert.matches(saved.provider .. "/" .. saved.model, warning, 1, true)
      assert.matches(unavailable == "api" and "incompatible" or "Unknown " .. unavailable, warning, 1, true)
    end)
  end

  it("constructs a saved Model only when the Agent prepares it", function()
    remember({ provider = "anthropic", model = "test" })
    local opts, calls = options()
    local choice, resource = resolve(opts)
    assert.are.same({}, calls)
    local agent = profiles.create_agent({ composition = choice, resources = resource, runtime = { workspace = root } })
    owners[#owners + 1] = agent
    assert(agent:prepare())
    assert.are.same({ anthropic = 1 }, calls)
    assert.are.same({ provider = "anthropic", model = "test" }, agent:get_model_selection())
  end)

  it("delivers saved Model fallback diagnostics through the Agent Presenter", function()
    remember({ provider = "anthropic", model = "removed" })
    local presenter = require("neoagent.presenter").new()
    owners[#owners + 1] = presenter
    local notifications = {}
    presenter:attach({
      present = function()
        return true
      end,
      notify = function(message)
        notifications[#notifications + 1] = message
      end,
    })
    local agent = require("neoagent").new(options(), { workspace = root, presenter = presenter })
    owners[#owners + 1] = agent
    assert(agent:prepare())
    assert.are.equal(1, #notifications)
    assert.matches("anthropic/removed", notifications[1], 1, true)
    assert.matches("Unknown model", notifications[1], 1, true)
    assert.are.same({ provider = "anthropic", model = "test" }, agent:get_model_selection())
  end)

  it("reports a saved Model factory failure without switching providers", function()
    remember({ provider = "anthropic", model = "test" })
    local opts, calls = options()
    opts.default_model = { provider = "openai", model = "test" }
    assert(opts._apis)["anthropic-messages"] = function()
      error("synthetic API factory failure", 0)
    end
    local choice, resource = resolve(opts)
    local agent = profiles.create_agent({ composition = choice, resources = resource, runtime = { workspace = root } })
    owners[#owners + 1] = agent
    local prepared, err = agent:prepare()
    assert.is_nil(prepared)
    assert.matches("synthetic API factory failure", assert(err).message)
    assert.are.equal("pi", agent:profile_id())
    assert.are.same({ provider = "anthropic", model = "test" }, agent:config().default_model)
    assert.are.same({}, calls)
  end)

  it("releases a Provider subscription returned after reentrant Agent destruction", function()
    local opts = options()
    opts.default_model = { provider = "openai", model = "test" }
    local provider = assert(assert(opts.providers).openai)
    assert(type(provider) == "table")
    ---@type Neoagent.Agent?
    local active
    local subscribers = 0
    provider.service = function()
      return {
        id = "openai",
        name = "Synthetic OpenAI",
        operations = {},
        state = function()
          return false
        end,
        subscribe = function()
          subscribers = subscribers + 1
          assert(active):destroy()
          return function()
            subscribers = subscribers - 1
          end
        end,
      }
    end
    local agent = require("neoagent").new(opts, { workspace = root })
    active = agent
    owners[#owners + 1] = agent
    local prepared, err = agent:prepare()
    assert.is_nil(prepared)
    assert.matches("Agent is destroyed", assert(err).message, 1, true)
    assert.are.equal(0, subscribers)
  end)

  it("does not bind a draft destroyed by the Profile policy during selection", function()
    local opts = options()
    local providers = assert(opts.providers)
    providers.anthropic = nil
    local provider = assert(providers.openai)
    assert(type(provider) == "table")
    local available = false
    provider.api_key = function()
      return available and "synthetic" or nil
    end
    ---@type fun()?
    local on_selection
    opts.default_profile = function(model)
      if model and on_selection then
        on_selection()
      end
      return "pi"
    end
    local owner = require("neoagent")._setup(opts, { startup = false })
    owners[#owners + 1] = owner
    local applet, draft_err = owner:draft(nil, root)
    assert(applet, draft_err and draft_err.message)
    local draft = owner:_owned_draft(applet)
    assert.is_nil(draft:model_selection())

    available = true
    on_selection = function()
      owner:destroy()
    end
    local bound, err = owner:_bind_draft(draft.profile, applet)
    assert.is_nil(bound)
    assert.matches("Profile draft changed while preparing submission", assert(err).message, 1, true)
  end)

  it("publishes the committed branch even if restoring the Model fails", function()
    local opts = options()
    local provider = assert(assert(opts.providers).openai)
    assert(type(provider) == "table")
    local credential_available = true
    provider.api_key = function()
      if not credential_available then
        error("synthetic credential lookup failure", 0)
      end
      return "synthetic"
    end
    opts.default_model = { provider = "openai", model = "test" }
    local session = assert(require("neoagent.session").new({ workspace = root }))
    assert(session:append({ role = "user", content = "Earlier message." }, { model = opts.default_model }))
    local earlier = assert(session:leaf_id())
    assert(session:append({ role = "user", content = "Later message." }))
    local agent = require("neoagent").new(opts, { workspace = root, session = session })
    owners[#owners + 1] = agent
    assert(agent:prepare())
    ---@type Neoagent.TranscriptMessage[]?
    local published
    agent:subscribe(function(update)
      if update.type == "messages" then
        published = update.messages
      end
    end)

    credential_available = false
    assert(agent:branch(earlier))
    assert.are.equal(earlier, session:leaf_id())
    assert.is_nil(agent:get_model())
    assert.are.equal("Earlier message.", assert(assert(published)[1]).content)
  end)

  it("tries a failed saved Model once and releases its Provider subscription", function()
    local opts = options()
    local selected = { provider = "openai", model = "test" }
    opts.default_model = selected
    remember(selected)
    local factories = assert(opts._apis)
    local factory = assert(factories["openai-responses"])
    local attempts, subscribers, unavailable = 0, 0, false
    factories["openai-responses"] = function(resolved)
      attempts = attempts + 1
      if unavailable then
        error("Saved Model is unavailable", 0)
      end
      return factory(resolved)
    end
    local provider = assert(assert(opts.providers).openai)
    assert(type(provider) == "table")
    provider.service = function()
      return {
        id = "openai",
        name = "Synthetic OpenAI",
        operations = {},
        state = function()
          return false
        end,
        subscribe = function()
          subscribers = subscribers + 1
          return function()
            subscribers = subscribers - 1
          end
        end,
      }
    end
    local session = assert(require("neoagent.session").new({ workspace = root }))
    assert(session:append({ role = "user", content = "Earlier message." }, { model = selected }))
    local earlier = assert(session:leaf_id())
    assert(session:append({ role = "user", content = "Later message." }))
    local agent = require("neoagent").new(opts, { workspace = root, session = session })
    owners[#owners + 1] = agent
    assert(agent:prepare())
    assert.are.equal(1, subscribers)
    assert.are.equal(1, attempts)

    unavailable = true
    assert(agent:branch(earlier))
    assert.are.equal(earlier, session:leaf_id())
    assert.are.equal(2, attempts)
    assert.is_nil(agent:get_model_selection())
    assert.is_nil(agent:get_model())
    assert.are.equal(0, subscribers)
  end)

  it("handles reports after discovery invalidates a staged Model", function()
    local async = require("neoagent.async")
    local opts, calls = options()
    opts.profile = "codex"
    local selected = { provider = "openai", model = "discovered" }
    opts.default_model = selected
    local provider = assert(assert(opts.providers).openai)
    assert(type(provider) == "table")
    local api = "anthropic-messages"
    provider.catalog = {
      source_id = "profile-discovery-compatibility",
      source_revision = 1,
      discover = function()
        return async.run(function()
          return { ok = true, models = { { id = selected.model, api = api } } }
        end)
      end,
    }
    local choice, resource = resolve(opts)
    local agent = profiles.create_agent({ composition = choice, resources = resource, runtime = { workspace = root } })
    owners[#owners + 1] = agent
    assert(agent:prepare())
    assert.are.same(selected, agent:get_model_selection())
    assert.is_nil(agent:get_model())

    local catalog = assert(resource.runtimes.openai).catalog
    local first = catalog:refresh()
    assert(vim.wait(2000, function()
      return first:is_done() and agent:get_model_selection() == nil
    end, 5))
    assert.is_true(assert(first:result()).ok)
    assert.are.same({}, calls)

    local refreshed = false
    agent:subscribe(function(update)
      local discovered = catalog:snapshot().models[selected.model]
      if update.type == "context" and discovered and discovered.api == "openai-responses" then
        refreshed = true
      end
    end)
    api = "openai-responses"
    local second = catalog:refresh()
    assert(vim.wait(2000, function()
      return second:is_done() and refreshed
    end, 5))
    assert.is_true(assert(second:result()).ok)
    assert.is_nil(agent:get_model_selection())
    assert.are.same({}, calls)
    assert(agent:prepare())
    assert.are.same(selected, agent:get_model_selection())
    assert.are.same({ openai = 1 }, calls)
  end)

  it("keeps the Session Model selected until its provider is available again", function()
    local opts, calls = options()
    opts.profile = "chat"
    local saved = { provider = "anthropic", model = "test" }
    local provider = assert(assert(opts.providers).anthropic)
    assert(type(provider) == "table")
    local logged_in = false
    provider.api_key = function()
      return logged_in and "synthetic" or nil
    end
    opts.default_model = { provider = "openai", model = "test" }
    local session = assert(require("neoagent.session").new({ workspace = root }))
    assert(session:append({ role = "user", content = "Saved conversation." }, { model = saved }))
    local agent = require("neoagent").new(opts, { workspace = root, session = session, restore_session_selection = true })
    owners[#owners + 1] = agent

    assert.are.same(saved, agent:get_model_selection())
    assert.is_nil(agent:get_model())
    assert(agent:prepare())
    local run, err = agent:send("Continue.")
    assert.is_nil(run)
    assert.matches("Not logged in for inference", assert(err).message, 1, true)
    assert.are.same({}, calls)

    logged_in = true
    assert(agent:prepare())
    assert.are.same(saved, agent:get_model_selection())
    assert.are.same({ anthropic = 1 }, calls)
  end)

  for _, found in ipairs({ true, false }) do
    it("keeps a saved Model through login until discovery " .. (found and "finds it" or "confirms it is missing"), function()
      local async = require("neoagent.async")
      local opts, calls = options()
      local saved = { provider = "openai", model = "discovered" }
      remember({ provider = "anthropic", model = "test" })
      opts.auth = { path = directory .. "/credentials.json" }
      local provider = assert(assert(opts.providers).openai)
      assert(type(provider) == "table")
      provider.api_key, provider.auth, provider.models = nil, "openai", {}
      provider.catalog = {
        source_id = "profile-selection-test",
        source_revision = 1,
        account_scoped = true,
        discover = function(context)
          return async.run(function()
            local resolved = context.resolve_auth():await()
            assert(resolved.ok and resolved.configured)
            return { ok = true, models = { { id = found and saved.model or "replacement" } } }
          end)
        end,
      }
      local _, _, owned = profiles.bundled(config.snapshot(opts), {
        startup = false,
        store = require("neoagent.state_store").new({ directory = directory .. "/catalog" }),
      })
      resources[#resources + 1] = owned
      local session = assert(require("neoagent.session").new({ workspace = root }))
      assert(session:append({ role = "user", content = "Saved conversation." }, { model = saved }))
      local leaf = assert(session:leaf_id())
      local agent = require("neoagent").new(opts, {
        auth = owned.auth,
        runtimes = owned.runtimes,
        workspace = root,
        session = session,
        restore_session_selection = true,
      })
      owners[#owners + 1] = agent

      assert.are.same(saved, agent:get_model_selection())
      assert.are.equal("codex", agent:profile_id())
      assert(agent:prepare())
      local run, err = agent:send("Before login.")
      assert.is_nil(run)
      assert.matches("Not logged in for inference", assert(err).message, 1, true)

      local login = owned.auth:login(saved.provider, { prompt = function(_, done) done.resolve("synthetic-key") end })
      assert(vim.wait(2000, function() return login:is_done() end, 5))
      assert.is_true(assert(login:result()).ok)
      assert(agent:prepare())
      run, err = agent:send("Before discovery.")
      assert.is_nil(run)
      assert.matches("catalog", assert(err).message, 1, true)
      assert.are.same({}, calls)
      assert.are.equal(leaf, session:leaf_id())

      local catalog = assert(owned.runtimes[saved.provider]).catalog
      local discovery = catalog:refresh()
      assert(vim.wait(2000, function() return discovery:is_done() end, 5))
      assert.is_true(assert(discovery:result()).ok)
      if found then
        assert(vim.wait(2000, function() return agent:get_model() ~= nil end, 5))
        assert.are.equal(saved.model, assert(agent:get_model()).id)
      else
        assert(agent:prepare())
        assert.are.same(saved, agent:get_model_selection())
        run, err = agent:send("After discovery.")
        assert.is_nil(run)
        assert.matches("Unknown model", assert(err).message, 1, true)
        assert.are.equal(leaf, session:leaf_id())
        assert.are.equal("replacement", assert(agent:set_model(saved.provider, "replacement")).id)
      end
      assert.are.same({ openai = 1 }, calls)
    end)
  end

  it("rejects thinking changes against the previous branch during Model restoration", function()
    local opts = options()
    opts.profile = "chat"
    local earlier = { provider = "anthropic", model = "test" }
    local later = { provider = "openai", model = "test" }
    opts.default_model = later
    local factories = assert(opts._apis)
    local original = assert(factories["openai-responses"])
    factories["openai-responses"] = function(resolved)
      local model = original(resolved)
      model.thinking = { off = {}, high = {} }
      return model
    end
    local session = assert(require("neoagent.session").new({ workspace = root }))
    assert(session:append({ role = "user", content = "Earlier message." }, { model = earlier }))
    local earlier_id = assert(session:leaf_id())
    assert(session:append({ role = "user", content = "Later message." }, { model = later }))
    local provider = assert(assert(opts.providers).anthropic)
    assert(type(provider) == "table")
    ---@type Neoagent.Agent?
    local agent
    ---@type Neoagent.ThinkingLevel?
    local level
    ---@type Neoagent.Error?
    local change_err
    provider.api_key = function()
      level, change_err = assert(agent):set_thinking_level("off")
      return "synthetic"
    end
    local active = require("neoagent").new(opts, { workspace = root, session = session })
    agent = active
    owners[#owners + 1] = active
    assert(active:prepare())

    assert(active:branch(earlier_id))
    assert.are.equal(earlier_id, session:leaf_id())
    assert.are.same(earlier, active:get_model_selection())
    assert.is_nil(level)
    assert.matches("still being restored", assert(change_err).message, 1, true)
  end)

  it("does not overwrite the Model of a newer branch", function()
    local opts = options()
    opts.profile = "chat"
    local earlier = { provider = "anthropic", model = "test" }
    local later = { provider = "openai", model = "test" }
    opts.default_model = later
    local session = assert(require("neoagent.session").new({ workspace = root }))
    assert(session:append({ role = "user", content = "Earlier message." }, { model = earlier }))
    local earlier_id = assert(session:leaf_id())
    assert(session:append({ role = "user", content = "Later message." }, { model = later }))
    local later_id = assert(session:leaf_id())
    local provider = assert(assert(opts.providers).anthropic)
    assert(type(provider) == "table")
    ---@type Neoagent.Agent?
    local agent
    local switched
    provider.api_key = function()
      if agent and not switched then
        local turn, err = agent:send("Wait until the branch is ready.")
        assert.is_nil(turn)
        assert.matches("still being restored", assert(err).message, 1, true)
        switched = assert(agent:branch(later_id))
      end
      return "synthetic"
    end
    local active = require("neoagent").new(opts, { workspace = root, session = session })
    agent = active
    owners[#owners + 1] = active
    assert(active:prepare())

    assert(active:branch(earlier_id))
    assert.is_true(switched)
    assert.are.equal(later_id, session:leaf_id())
    assert.are.same(later, active:get_model_selection())
  end)

  it("keeps a newer explicit Model choice when a factory returns late", function()
    local opts = options()
    opts.profile = "chat"
    local initial = { provider = "openai", model = "test" }
    local newer = { provider = "anthropic", model = "test" }
    opts.default_model = initial
    ---@type Neoagent.Agent?
    local agent
    local factories = assert(opts._apis)
    local original = assert(factories["openai-responses"])
    factories["openai-responses"] = function(resolved)
      assert(assert(agent):set_model(newer.provider, newer.model))
      return original(resolved)
    end
    local active = require("neoagent").new(opts, { workspace = root })
    agent = active
    owners[#owners + 1] = active
    local prepared, err = active:prepare()
    assert.is_nil(prepared)
    assert.are.equal("cancelled", assert(err).kind)
    assert.are.same(newer, active:get_model_selection())
  end)
end)
