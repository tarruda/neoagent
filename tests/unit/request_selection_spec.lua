local ProfileDraft = require("neoagent.profile_draft")
local RequestSelection = require("neoagent.request_selection")
local ModelCatalog = require("neoagent.model_catalog")

describe("neoagent upper-layer request selection", function()
  local catalogs = {}

  after_each(function()
    for _, catalog in ipairs(catalogs) do catalog:destroy() end
    catalogs = {}
  end)

  local function configuration()
    return {
      default_model = { provider = "fake", model = "one" },
      default_thinking_level = "medium",
      ui = { position = "center" },
      providers = { fake = { api = "fake", models = {
        one = { thinking = { off = {}, high = {} } },
        two = { thinking = { low = {}, max = {} } },
      } } },
      _apis = { fake = function(resolved)
        return {
          api = resolved.api,
          provider = resolved.provider_id,
          id = resolved.model_id,
          input = vim.deepcopy(resolved.model.input or { "text" }),
          stream = function() end,
          thinking = vim.deepcopy(resolved.model.thinking),
        }
      end },
    }
  end

  local function runtimes(configured)
    local result = {}
    for provider_id, provider in pairs(configured.providers) do
      local catalog = ModelCatalog.new({
        provider_id = provider_id,
        provider = provider,
        definition = provider.catalog or {},
        models = provider.models,
      })
      catalogs[#catalogs + 1] = catalog
      result[provider_id] = {
        id = provider_id,
        definition = provider,
        catalog = catalog,
        service = {
          id = provider_id,
          name = provider_id,
          state = function() return false end,
          operations = {},
        },
      }
    end
    return result
  end

  it("reports unsupported Profile-scoped workspace preferences", function()
    local accepted, issues = require("neoagent.workspace_preferences").scope({
      agents = { Neo = { unsupported = true } },
    }, {
      default_thinking_level = "off",
      ui_position = "center",
    }, "Neo")
    assert.is_nil(accepted.unsupported)
    assert.are.same({
      "unsupported workspace setting for Neo: unsupported",
    }, issues)
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
      selection:stage(selection:candidate()))
    assert.are.equal("max", selection:thinking_level())
    assert(selection:resolve())
    assert.are.equal("fake/two", selection:label())
    assert.are.equal("max", selection:thinking_level())
    assert.are.same({ "low", "max" }, selection:levels())
    assert.are.equal("low", selection:cycle_thinking_level())
    local unsupported, unsupported_err = selection:set_thinking_level("off")
    assert.is_nil(unsupported)
    assert.matches("not supported", unsupported_err.message)

    assert(selection:select("fake", "one"))
    assert.are.equal("high", selection:thinking_level())
    local snapshot = selection:snapshot()
    snapshot.model.model = "mutated"
    assert.are.equal("one", selection:model_selection().model)

    local workspace = selection:set_workspace_preferences({
      default_model = { provider = "fake", model = "two" },
      ui_position = "left",
    })
    workspace.default_model.model = "mutated"
    assert.are.equal("two",
      selection:workspace_preferences().default_model.model)
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
    assert.matches("No default_model", resolve_err.message)

    local unsupported_config = configuration()
    unsupported_config.default_model = { provider = "fake", model = "plain" }
    unsupported_config.providers.fake.models.plain = {}
    local unsupported = RequestSelection.new({
      config = unsupported_config,
      runtimes = runtimes(unsupported_config),
    })
    assert(unsupported:resolve())
    assert.is_nil(unsupported:snapshot().thinking_level)
    assert.are.equal(vim.NIL,
      unsupported:snapshot({ persisted = true }).thinking_level)
    resolved, resolve_err = unsupported:set_thinking_level("high")
    assert.is_nil(resolved)
    assert.matches("not supported", resolve_err.message)
    resolved, resolve_err = unsupported:cycle_thinking_level()
    assert.is_nil(resolved)
    assert.matches("does not support thinking", resolve_err.message)
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
    provider_runtimes.fake.service.wrap_model = function(_, model)
      model.input = { "image" }
      return model
    end

    local resolved, err
    local ok = pcall(function()
      resolved, err = selection:select("fake", "two")
    end)

    assert.is_true(ok)
    assert.is_nil(resolved)
    assert.matches("include text", err.message)
    assert.are.same({ provider = "fake", model = "one" },
      selection:model_selection())
    assert.are.equal(original, selection:model())
    assert.are.equal(original_thinking, selection:thinking_level())
  end)

  it("binds Workspace, Agent, and Session identity to resolved HTTP", function()
    local configured = configuration()
    local seen
    configured._apis.fake = function(resolved)
      seen = resolved.transport.context
      return {
        api = resolved.api,
        provider = resolved.provider_id,
        id = resolved.model_id,
        input = { "text" },
        stream = function() end,
        thinking = vim.deepcopy(resolved.model.thinking),
      }
    end
    local provider_runtimes = runtimes(configured)
    local function contextual(context)
      local value = { context = vim.deepcopy(context or {}) }
      value.with_context = function(extra)
        return contextual(vim.tbl_extend(
          "force", vim.deepcopy(value.context), vim.deepcopy(extra)))
      end
      return value
    end
    provider_runtimes.fake.transport = contextual({ origin = "model" })
    local selection = RequestSelection.new({
      config = configured,
      runtimes = provider_runtimes,
      http_context = {
        workspace = "/workspace",
        agent_id = "agent-2",
        session_id = "session-9",
      },
    })

    assert(selection:resolve())
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
      config = configuration(),
    }
    local applet = {}
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
    assert.matches("not supported", rejected_err.message)
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
    assert.is_table(draft:update({ sandbox = { enabled = true } }))
    assert.is_true(draft:options().sandbox.enabled)
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
    assert.are.equal("destroyed", draft:state())
  end)
end)
