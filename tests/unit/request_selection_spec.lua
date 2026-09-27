local assert = require("luassert")
local ProfileDraft = require("neoagent.profile_draft")
local RequestSelection = require("neoagent.request_selection")
local runtime_api = require("neoagent.provider_runtimes")
local fake_model = require("tests.helpers.fake_model")

describe("neoagent upper-layer request selection", function()
  ---@type Neoagent.ProviderRuntimes[]
  local owned_runtimes = {}

  after_each(function()
    for _, value in ipairs(owned_runtimes) do runtime_api.destroy(value) end
    owned_runtimes = {}
  end)

  ---@return Neoagent.Config<Neoagent.AgentToolEnvironment>
  local function configuration()
    return require("neoagent.config").resolve({
      default_registry = false,
      default_model = { provider = "fake", model = "one" },
      default_thinking_level = "medium",
      ui = { position = "center" },
      providers = { fake = { api = "fake", models = {
        one = { thinking = { off = {}, high = {} } },
        two = { thinking = { low = {}, max = {} } },
      } } },
      _apis = { fake = function(resolved)
        local model = fake_model.new()
        model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
        model.input = vim.deepcopy(resolved.model.input or { "text" })
        model.thinking = require("neoagent.util").copy(resolved.model.thinking)
        return model
      end },
    })
  end

  ---@param configured Neoagent.Config<Neoagent.AgentToolEnvironment>
  ---@return Neoagent.ProviderRuntimes
  local function runtimes(configured)
    local result = assert(runtime_api.compose(configured, { startup = false }))
    owned_runtimes[#owned_runtimes + 1] = result
    return result
  end

  it("reports unsupported Profile-scoped workspace preferences", function()
    local accepted, issues = require("neoagent.workspace_preferences").scope({
      agents = { Neo = { unsupported = true } },
    }, {
      default_thinking_level = "off",
      ui_position = "center",
    }, "Neo")
    assert.is_nil(rawget(accepted, "unsupported"))
    assert.are.same({
      "unsupported workspace setting for Neo: unsupported",
    }, issues)
  end)

  it("rejects incompatible staged defaults and unavailable checkpoint identities", function()
    local configured = configuration()
    local providers = runtimes(configured)
    local selection = RequestSelection.new({ config = configured, runtimes = providers })
    local selected = { provider = "fake", model = "one" }
    assert(selection:stage(selected))
    selection.required_api = "openai-codex-responses"
    local accepted, err = selection:stage(selected)
    assert.is_nil(accepted)
    assert.matches("Profile requires", assert(err).message)
    assert.are.equal("no model", selection:label())

    local failure = { kind = "session", message = "Checkpoint path unavailable" }
    selection = RequestSelection.new({ config = configured, runtimes = providers,
      checkpoint_identity = function() return nil, failure end })
    local model = fake_model.new()
    local ok, bind_err = pcall(selection.bind, selection, selected, model)
    assert.is_false(ok)
    assert.are.same(failure, bind_err)
    assert.is_nil(selection:model())
  end)

  it("owns live, resolved, and Workspace-default request state", function()
    local configured = configuration()
    local selection = RequestSelection.new({
      config = configured,
      runtimes = runtimes(configured),
      initial_selection = {
        model = { provider = "fake", model = "two" },
        thinking_level = "max",
      },
      workspace = { default_thinking_level = "low" },
    })
    assert.are.same({ provider = "fake", model = "two" },
      selection:candidate())
    assert.are.equal("no model", selection:label())

    assert.are.same({ provider = "fake", model = "two" },
      selection:stage((assert(selection:candidate()))))
    assert.are.equal("max", selection:thinking_level())
    assert(selection:resolve())
    assert.are.equal("fake/two", selection:label())
    assert.are.equal("max", selection:thinking_level())
    assert.are.same({ "low", "max" }, selection:levels())
    assert.are.equal("low", selection:cycle_thinking_level())
    local unsupported, unsupported_err = selection:set_thinking_level("off")
    assert.is_nil(unsupported)
    assert.matches("not supported", assert(unsupported_err).message)

    assert(selection:select("fake", "one"))
    assert.are.equal("high", selection:thinking_level())
    local snapshot = selection:snapshot()
    assert(snapshot.model).model = "mutated"
    assert.are.equal("one", assert(selection:model_selection()).model)

    local workspace = selection:set_workspace_preferences({
      default_model = { provider = "fake", model = "two" },
      ui_position = "left",
    })
    assert(workspace.default_model).model = "mutated"
    assert.are.equal("two",
      assert(selection:workspace_preferences().default_model).model)
    assert.are.equal("left", selection:preferences().ui_position)
    selection:clear(true)
    assert.are.same({ provider = "fake", model = "two" },
      selection:candidate())

    local missing_config = configuration()
    missing_config.default_model = nil
    local missing = RequestSelection.new({
      config = missing_config,
      runtimes = runtimes(missing_config),
    })
    local resolved, resolve_err = missing:resolve()
    assert.is_nil(resolved)
    assert.matches("No default_model", assert(resolve_err).message)
    local levels
    levels, resolve_err = missing:levels()
    assert.is_nil(levels)
    assert.matches("No default_model", assert(resolve_err).message)
    local level
    level, resolve_err = missing:set_thinking_level("high")
    assert.is_nil(level)
    assert.matches("No default_model", assert(resolve_err).message)
    level, resolve_err = missing:cycle_thinking_level()
    assert.is_nil(level)
    assert.matches("No default_model", assert(resolve_err).message)

    local unsupported_config = configuration()
    unsupported_config.default_model = { provider = "fake", model = "plain" }
    assert(assert(unsupported_config.providers.fake).models).plain = {}
    local unsupported = RequestSelection.new({
      config = unsupported_config,
      runtimes = runtimes(unsupported_config),
    })
    assert(unsupported:resolve())
    assert.is_nil(unsupported:snapshot().thinking_level)
    assert.are.equal(vim.NIL,
      unsupported:snapshot({ persisted = true }).thinking_level)
    level = nil
    level, resolve_err = unsupported:set_thinking_level("high")
    assert.is_nil(level)
    assert.matches("not supported", assert(resolve_err).message)
    level, resolve_err = unsupported:cycle_thinking_level()
    assert.is_nil(level)
    assert.matches("does not support thinking", assert(resolve_err).message)
  end)

  it("contains resolution and binding failures without changing state", function()
    local configured = configuration()
    local provider_runtimes = runtimes(configured)
    local selection = RequestSelection.new({
      config = configured,
      runtimes = provider_runtimes,
    })
    local original = assert(selection:resolve())
    local original_thinking = selection:thinking_level()
    assert(provider_runtimes.fake).service.wrap_model = function(_, model)
      model.input = { "image" }
      return model
    end

    ---@type Neoagent.Model?
    local resolved
    ---@type Neoagent.Error?
    local err
    local ok = pcall(function()
      resolved, err = selection:select("fake", "two")
    end)

    assert.is_true(ok)
    assert.is_nil(resolved)
    assert.matches("include text", assert(err).message)
    assert.are.same({ provider = "fake", model = "one" },
      selection:model_selection())
    assert.are.equal(original, selection:model())
    assert.are.equal(original_thinking, selection:thinking_level())
  end)

  it("rejects incompatible lazy defaults after catalog discovery without binding a draft", function()
    local configured = configuration()
    configured.default_model = { provider = "fake", model = "discovered" }
    local providers = runtimes(configured)
    local profile = {
      id = "codex", label = "Codex", config = configured,
      compaction = require("neoagent.compaction.codex").component,
      create_applet = function() error("unused") end,
      create_agent = function() error("unused") end,
    }
    local applet = require("neoagent.agent_applet").new({ config = configured.ui })
    local draft = ProfileDraft.new({
      key = "codex\0/workspace", profile = profile, workspace = "/workspace", applet = applet,
      runtimes = providers,
    })
    assert(assert(providers.fake).catalog:publish_discoveries({ {
      id = "discovered", api = "fake", thinking = { off = {}, high = {} },
    } }))
    for _, operation in ipairs({
      function() return draft:thinking_levels() end,
      function() return draft:set_thinking_level("high") end,
      function() return draft:cycle_thinking_level() end,
      function() return draft:set_model("fake", "one") end,
      function() return draft:update({ default_model = { provider = "fake", model = "one" } }) end,
    }) do
      local result, err = operation()
      assert.is_nil(result)
      assert.matches("Profile requires a Model using openai%-codex%-responses", assert(err).message)
      assert.is_nil(draft.selection:model())
      assert.is_nil(draft:model_selection())
    end
    draft:destroy()
    applet:destroy()
  end)

  it("validates the resolved Model before replacing a compatible selection", function()
    local configured = configuration()
    local providers = runtimes(configured)
    local selection = RequestSelection.new({ config = configured, runtimes = providers, required_api = "fake" })
    local original = assert(selection:resolve())
    assert(providers.fake).service.wrap_model = function(_, model)
      model.api = "incompatible"
      return model
    end
    local selected, err = selection:select("fake", "two")
    assert.is_nil(selected)
    assert.matches("Profile requires", assert(err).message)
    assert.are.equal(original, selection:model())
    assert.are.same({ provider = "fake", model = "one" }, selection:model_selection())
  end)

  it("keeps an undiscovered compatible default staged until its catalog arrives", function()
    local configured = configuration()
    configured.default_model = { provider = "fake", model = "discovered" }
    local providers = runtimes(configured)
    local selection = RequestSelection.new({ config = configured, runtimes = providers, required_api = "fake" })
    assert.are.same(configured.default_model, selection:stage(assert(selection:candidate())))
    assert.are.same(configured.default_model, selection:model_selection())
    assert(assert(providers.fake).catalog:publish_discoveries({ { id = "discovered", api = "fake" } }))
    assert(selection:resolve())
    assert.are.equal("fake/discovered", selection:label())
  end)

  it("rejects a Model change that cannot replay the active native checkpoint", function()
    local configured = configuration()
    local providers = runtimes(configured)
    local checkpoint = { api = "fake", provider = "fake", model = "one" }
    local selection = RequestSelection.new({
      config = configured, runtimes = providers, required_api = "fake",
      checkpoint_identity = function() return checkpoint end,
    })
    local original = assert(selection:resolve())
    local changed, err = selection:select("fake", "two")
    assert.is_nil(changed)
    assert.matches("original API, provider, and Model", assert(err).message)
    assert.are.equal(original, selection:model())
    assert.are.same({ provider = "fake", model = "one" }, selection:model_selection())
  end)

  it("binds Workspace, Agent, and Session identity to resolved HTTP", function()
    local configured = configuration()
    local seen
    local seen_identity
    configured._apis.fake = function(resolved)
      seen = rawget(assert(resolved.transport), "context")
      seen_identity = resolved.request_context
      local model = fake_model.new()
      model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
      model.input = { "text" }
      model.thinking = require("neoagent.util").copy(resolved.model.thinking)
      return model
    end
    local provider_runtimes = runtimes(configured)
    ---@param context Neoagent.RequestIdentity
    ---@return Neoagent.ByteBackend
    local function contextual(context)
      local value = require("tests.helpers.fake_transport").new()
      local identity = vim.deepcopy(context)
      rawset(value, "context", identity)
      value.with_context = function(extra)
        return contextual(vim.tbl_extend(
          "force", vim.deepcopy(identity), vim.deepcopy(extra or {})))
      end
      return value
    end
    assert(provider_runtimes.fake).transport = contextual({ origin = "model" })
    local selection = RequestSelection.new({
      config = configured,
      runtimes = provider_runtimes,
      request_context = {
        workspace = "/workspace",
        agent_id = "agent-2",
        session_id = "session-9",
      },
    })

    assert(selection:resolve())
    assert.are.same({
      workspace = "/workspace",
      agent_id = "agent-2",
      session_id = "session-9",
    }, seen_identity)
    assert.are.same({
      origin = "model",
      provider = "fake",
      model = "one",
      workspace = "/workspace",
      agent_id = "agent-2",
      session_id = "session-9",
    }, seen)
  end)

  it("moves one ProfileDraft transactionally through its typestates", function()
    local profile = {
      id = "neo",
      label = "Neo",
      config = configuration(),
      compaction = require("neoagent.compaction").local_component,
      create_applet = function() error("unexpected Applet construction") end,
      create_agent = function() error("unexpected Agent construction") end,
    }
    local applet = require("neoagent.agent_applet").new({ config = profile.config.ui })
    local draft = ProfileDraft.new({
      key = "neo\0/workspace",
      profile = profile,
      workspace = "/workspace",
      applet = applet,
      runtimes = runtimes(profile.config),
      options = {
        default_model = { provider = "fake", model = "two" },
        default_thinking_level = "low",
        sandbox = { enabled = false },
      },
    })
    assert.are.equal("draft", draft:state())
    assert.is_true(draft:is_active())
    assert.are.equal("low", draft:thinking_level())
    assert.are.same({ "low", "max" }, draft:thinking_levels())
    assert.are.same({
      options = { sandbox = { enabled = false } },
      initial_selection = {
        model = { provider = "fake", model = "two" },
        thinking_level = "low",
      },
    }, draft:snapshot())

    local rejected, rejected_err = draft:update({
      default_thinking_level = "off",
    })
    assert.is_nil(rejected)
    assert.matches("not supported", assert(rejected_err).message)
    assert.are.equal("low", draft:options().default_thinking_level)

    assert.are.same({ provider = "fake", model = "one" },
      draft:set_model("fake", "one"))
    assert.are.equal("high", draft:thinking_level())
    assert.are.equal("off", draft:set_thinking_level("off"))
    assert.are.equal("high", draft:cycle_thinking_level())
    assert.are.same({ provider = "fake", model = "two" },
      assert(draft:update({
        default_model = { provider = "fake", model = "two" },
        default_thinking_level = "max",
      })).default_model)
    assert.are.equal("max", draft:thinking_level())
    assert.is_table((draft:update({ sandbox = { enabled = true } })))
    assert.is_true(assert(draft:options().sandbox).enabled)
    assert.are.same({
      options = { sandbox = { enabled = true } },
      initial_selection = {
        model = { provider = "fake", model = "two" },
        thinking_level = "max",
      },
    }, draft:snapshot())

    assert.are.equal(draft, draft:stage())
    assert.are.equal("provisional", draft:state())
    assert.are.equal(draft, draft:restore())
    assert.are.equal(draft, draft:bind())
    assert.are.equal("bound", draft:state())
    draft:destroy()
    applet:destroy()
    assert.are.equal("destroyed", draft:state())
  end)

  it("preserves ProfileDraft options when model selection cannot resolve", function()
    local configured = configuration()
    configured.default_model = nil
    local profile = {
      id = "neo", label = "Neo", config = configured,
      compaction = require("neoagent.compaction").local_component,
      create_applet = function() error("unused") end,
      create_agent = function() error("unused") end,
    }
    local applet = require("neoagent.agent_applet").new({ config = configured.ui })
    local draft = ProfileDraft.new({
      key = "neo\0/workspace", profile = profile, workspace = "/workspace",
      applet = applet, runtimes = runtimes(configured), options = { sandbox = { enabled = false } },
    })
    local before = draft:options()
    local updated, update_err = draft:update({
      default_model = { provider = "fake", model = "missing" },
    })
    assert.is_nil(updated)
    assert.matches("Unknown model", assert(update_err).message)
    assert.are.same(before, draft:options())

    local selected, select_err = draft:set_model("fake", "missing")
    assert.is_nil(selected)
    assert.matches("Unknown model", assert(select_err).message)
    local cycled, cycle_err = draft:cycle_thinking_level()
    assert.is_nil(cycled)
    assert.matches("No default_model", assert(cycle_err).message)
    draft:destroy()
    applet:destroy()
  end)
end)
