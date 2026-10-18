local assert = require("luassert")
local profiles = require("neoagent.profiles")
local selection = require("neoagent.profiles.selection")
local util = require("neoagent.util")

---@param overrides? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@return Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>
local function config(overrides)
  local input = {
    default_registry = false,
    providers = {},
    persistence = { enabled = false },
    recording = { enabled = false },
    workspace_trust = false,
    tools = {},
    agent_instructions = false,
    skills = false,
  }
  for name, value in pairs(overrides or {}) do input[name] = value end
  return require("neoagent.config").snapshot(input)
end

describe("bundled Profile resources", function()
  it("releases provider resources when the configured Profile is invalid", function()
    local destroyed = 0
    local valid = pcall(require("neoagent").setup, {
      default_registry = false, default_profile = "missing",
      providers = { example = {
        api = "openai-responses", base_url = "https://example.test", api_key = "synthetic",
        models = { test = {} },
        service = function()
          return { id = "example", name = "Example", operations = {}, state = function() return {} end,
            destroy = function() destroyed = destroyed + 1 end }
        end,
      } },
    })
    assert.is_false(valid)
    assert.are.equal(1, destroyed)
  end)

  it("resolves local and native compaction from the bundled Profiles", function()
    local snapshot = config()
    local selected, default_profile, resources = profiles.bundled(snapshot, { startup = false })
    assert.are.equal("pi", require("neoagent.profiles.selection").choose(default_profile))
    assert.are.same({ "pi", "chat", "codex" }, vim.tbl_map(function(profile)
      return profile.id
    end, selected))
    assert.is_false(assert(selected[2]).create_tools)
    for _, profile in ipairs(selected) do
      local configured = selection.configuration(snapshot, profile)
      assert.are.equal(profile.id ~= "chat", configured.sandbox.enabled)
      local host = selection.configuration(snapshot, profile, { sandbox = { enabled = false } })
      assert.is_false(host.sandbox.enabled)
    end
    assert.are.equal(require("neoagent.compaction.prefix").component, selection.resolve({ profiles = profiles.index(selected), snapshot = snapshot, policy = assert(selected[1]).id, runtimes = resources.runtimes, auth = resources.auth }).compaction)
    assert.are.equal(require("neoagent.compaction.prefix").component, selection.resolve({ profiles = profiles.index(selected), snapshot = snapshot, policy = assert(selected[2]).id, runtimes = resources.runtimes, auth = resources.auth }).compaction)
    assert.are.equal(require("neoagent.compaction.codex").profile_component, assert(selected[3]).compaction)
    assert.are.same({ "openai-responses", "openai-codex-responses" }, assert(selected[3]).supported_apis)
    resources:destroy()
  end)

  it("selects summary compaction for Pi and Chat while Codex keeps native compaction", function()
    local snapshot = config({ compaction = { strategy = "summary" } })
    local selected, _, resources = profiles.bundled(snapshot, { startup = false })
    assert.are.equal(require("neoagent.compaction").local_component, selection.resolve({ profiles = profiles.index(selected), snapshot = snapshot, policy = assert(selected[1]).id, runtimes = resources.runtimes, auth = resources.auth }).compaction)
    assert.are.equal(require("neoagent.compaction").local_component, selection.resolve({ profiles = profiles.index(selected), snapshot = snapshot, policy = assert(selected[2]).id, runtimes = resources.runtimes, auth = resources.auth }).compaction)
    assert.are.equal(require("neoagent.compaction.codex").profile_component, assert(selected[3]).compaction)
    resources:destroy()
  end)

  it("keeps a Codex draft default visible while its catalog is loading", function()
    local configured = config({
      default_model = { provider = "dynamic", model = "discovered" },
      providers = { dynamic = { api = "openai-codex-responses",
        base_url = "https://example.test/codex", models = {} } },
    })
    local selected, _, resources = profiles.bundled(configured, { startup = false })
    local codex = assert(selected[3])
    local owner =
      require("neoagent.applet").new({ profiles = selected, default_profile = "codex", resources = resources, snapshot = configured })
    local applet = assert(owner:draft("codex"))
    assert.are.equal("dynamic/discovered", applet:_context().model)
    owner:destroy()
  end)

  it("clears incompatible configured and persisted defaults from a Codex draft", function()
    local directory = vim.fn.tempname()
    local settings = require("neoagent.workspace_settings").new({ directory = directory, root = vim.fn.getcwd() })
    assert(settings:update({ agents = { codex = { default_model = { provider = "local", model = "test" } } } }))
    local configured = config({ default_model = { provider = "local", model = "test" },
      persistence = { enabled = true, workspace_settings = true, directory = directory },
      providers = { ["local"] = { api = "openai-completions", base_url = "https://example.test",
        models = { test = {} } } } })
    local selected, _, resources = profiles.bundled(configured, { startup = false })
    local codex = assert(selected[3])
    assert.is_nil(rawget(codex, "config"))
    local owner =
      require("neoagent.applet").new({ profiles = selected, default_profile = "codex", resources = resources, snapshot = configured })
    local applet = assert(owner:draft("codex"))
    assert.are.equal("no model", applet:_context().model)
    owner:destroy()
    vim.fn.delete(directory, "rf")
  end)

  it("buffers construction reports and destroys recording resources once", function()
    local recording = require("neoagent.http_recording")
    local runtimes = require("neoagent.provider_runtimes")
    local provider_shell = require("neoagent.provider_shell")
    local recording_new = recording.new
    local compose = runtimes.compose
    local destroy_runtimes = runtimes.destroy
    local shell_new = provider_shell.new
    local recorder_destroys, runtime_destroys = 0, 0
    local reports = {}
    local patched, patch_err = pcall(function()
      recording.new = function()
        return {
          transport = function(_, transport) return transport or {} end,
          destroy = function() recorder_destroys = recorder_destroys + 1 end,
        } --[[@as Neoagent.Recorder]]
      end
      runtimes.compose = function(_, opts)
        for index = 1, 65 do assert(assert(opts).report)("early report " .. index, index) end
        return {}
      end
      runtimes.destroy = function()
        runtime_destroys = runtime_destroys + 1
        return true
      end
      provider_shell.new = function()
        return {
          report = function(_, message, level)
            reports[#reports + 1] = { message, level }
            return true
          end,
          destroy = function() end,
        } --[[@as Neoagent.ProviderShell]]
      end

      local _, _, resources = profiles.bundled(config({
        recording = {
          enabled = true,
          format = "json",
          directory = vim.fn.tempname(),
        },
      }))
      assert.are.equal(64, #reports)
      assert.are.same({ "early report 1", 1 }, reports[1])
      assert.are.same({ "early report 64", 64 }, reports[64])
      resources:destroy()
      resources:destroy()
      assert.are.equal(1, recorder_destroys)
      assert.are.equal(1, runtime_destroys)
    end)
    recording.new = recording_new
    runtimes.compose = compose
    runtimes.destroy = destroy_runtimes
    provider_shell.new = shell_new
    assert(patched, patch_err)
  end)

  it("contains recorder, runtime, and Provider Shell construction failures", function()
    local recording = require("neoagent.http_recording")
    local runtimes = require("neoagent.provider_runtimes")
    local provider_shell = require("neoagent.provider_shell")
    local recording_new = recording.new
    local compose = runtimes.compose
    local destroy_runtimes = runtimes.destroy
    local shell_new = provider_shell.new
    local recorder_destroys, runtime_destroys = 0, 0
    local configured = config({
      recording = {
        enabled = true,
        format = "json",
        directory = vim.fn.tempname(),
      },
    })
    local patched, patch_err = pcall(function()
      recording.new = function()
        return nil, util.error("recording", "recorder construction failed")
      end
      local ok, err = pcall(profiles.bundled, configured)
      assert.is_false(ok)
      assert.matches("recorder construction failed", util.normalize_error(err, "recording").message)

      recording.new = function()
        return {
          transport = function() error("recording transport failed") end,
          destroy = function() recorder_destroys = recorder_destroys + 1 end,
        } --[[@as Neoagent.Recorder]]
      end
      ok, err = pcall(profiles.bundled, configured)
      assert.is_false(ok)
      assert.matches("recording transport failed", util.normalize_error(err, "recording").message)
      assert.are.equal(1, recorder_destroys)

      recording.new = function()
        return {
          transport = function(_, transport) return transport or {} end,
          destroy = function() recorder_destroys = recorder_destroys + 1 end,
        } --[[@as Neoagent.Recorder]]
      end
      runtimes.compose = function()
        return nil, util.error("provider", "runtime construction failed")
      end
      ok, err = pcall(profiles.bundled, configured)
      assert.is_false(ok)
      assert.matches("runtime construction failed", util.normalize_error(err, "provider").message)
      assert.are.equal(2, recorder_destroys)

      runtimes.compose = function() return {} end
      runtimes.destroy = function()
        runtime_destroys = runtime_destroys + 1
        return true
      end
      provider_shell.new = function() error("shell construction failed") end
      ok, err = pcall(profiles.bundled, configured)
      assert.is_false(ok)
      assert.matches("shell construction failed", tostring(err))
      assert.are.equal(3, recorder_destroys)
      assert.are.equal(1, runtime_destroys)
    end)
    recording.new = recording_new
    runtimes.compose = compose
    runtimes.destroy = destroy_runtimes
    provider_shell.new = shell_new
    assert(patched, patch_err)
  end)

  it("reports unreadable workspace settings without provider details", function()
    local workspace_settings = require("neoagent.workspace_settings")
    local settings_new = workspace_settings.new
    local notify = vim.notify
    local messages = {}
    local root = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(root, "p"))
    local configured = config({ persistence = { enabled = true, workspace_settings = true, directory = root } })
    local profile_list, _, resources = profiles.bundled(configured, { startup = false })
    local applet
    local patched, patch_err = pcall(function()
      workspace_settings.new = function()
        return {
          load = function()
            return nil, util.error("settings", "workspace settings unavailable")
          end,
          metadata = function()
            return { settings_path = root .. "/settings.json" }
          end,
        } --[[@as Neoagent.WorkspaceSettings]]
      end
      vim.notify = function(message)
        messages[#messages + 1] = message
      end
      applet = require("neoagent.applet").new({ profiles = profile_list, default_profile = "pi", resources = resources, snapshot = configured })
      assert(applet:draft("pi", root))
    end)
    workspace_settings.new = settings_new
    vim.notify = notify
    if applet then applet:destroy() end
    resources:destroy()
    vim.fn.delete(root, "rf")
    assert(patched, patch_err)
    assert.is_truthy(vim.tbl_contains(messages,
      "neoagent: workspace settings unavailable; the file may be outdated, update or delete "
        .. root .. "/settings.json"))
  end)
end)
