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

  before_each(function()
    owners, resources = {}, {}
    root, directory = vim.fn.tempname(), vim.fn.tempname()
    assert(require("neoagent.fs").mkdirp(root))
  end)

  after_each(function()
    for index = #owners, 1, -1 do
      owners[index]:destroy()
    end
    for _, resource in ipairs(resources) do
      resource:destroy()
    end
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
end)
