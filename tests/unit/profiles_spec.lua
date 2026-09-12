local assert = require("luassert")
local profiles = require("neoagent.profiles")
local util = require("neoagent.util")

---@param overrides? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@return Neoagent.Config<Neoagent.AgentToolEnvironment>
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
  return require("neoagent.config").resolve(input)
end

describe("bundled Profile resources", function()
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
      assert.are.equal(1, recorder_destroys)

      runtimes.compose = function() return {} end
      runtimes.destroy = function()
        runtime_destroys = runtime_destroys + 1
        return true
      end
      provider_shell.new = function() error("shell construction failed") end
      ok, err = pcall(profiles.bundled, configured)
      assert.is_false(ok)
      assert.matches("shell construction failed", tostring(err))
      assert.are.equal(2, recorder_destroys)
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
    local profile_list, _, resources = profiles.bundled(config({
      persistence = {
        enabled = true,
        workspace_settings = true,
        directory = root,
      },
    }), { startup = false })
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
      vim.notify = function(message) messages[#messages + 1] = message end
      applet = assert(profile_list[1]).create_applet({
        profile = assert(profile_list[1]),
        label = "Neo",
        workspace = root,
      })
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
