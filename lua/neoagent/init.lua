local async = require("neoagent.async")
local config = require("neoagent.config")
local util = require("neoagent.util")

local M = {}
---@type Neoagent.UiPosition[]
local positions = { "auto", "left", "right", "top", "bottom", "center" }
---@type Neoagent.NeoagentApplet?
local default_applet

local function applet_type()
  return require("neoagent.applet")
end

---@param snapshot Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>
---@param runtime Neoagent.ProfileRuntimeOptions?
---@return Neoagent.NeoagentApplet
local function build_applet(snapshot, runtime)
  local profiles, default_profile, resources = require("neoagent.profiles").bundled(snapshot, runtime)
  local ok, result = pcall(applet_type().new, {
    profiles = profiles,
    default_profile = default_profile,
    resources = resources,
    snapshot = snapshot,
  })
  if not ok then
    resources:destroy()
    error(result, 0)
  end
  return result
end

---@param opts Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>?
---@param runtime Neoagent.AgentRuntimeOptions?
---@return Neoagent.Agent
function M.new(opts, runtime)
  return require("neoagent.profiles").new(opts, runtime)
end

---@param opts Neoagent.AppletFromAgentsOptions
---@return Neoagent.NeoagentApplet
function M._new_applet(opts)
  return applet_type()._from_agents(opts)
end

---@return Neoagent.NeoagentApplet
function M.applet()
  if not default_applet or default_applet:is_destroyed() then
    default_applet = build_applet(config.get_snapshot())
  end
  return default_applet
end

---@return Neoagent.Agent?
function M.default()
  return M.applet():default_agent()
end

---@param opts Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>?
---@param runtime Neoagent.ProfileRuntimeOptions?
---@return Neoagent.NeoagentApplet
local function setup(opts, runtime)
  if default_applet and default_applet:any_running() then
    error("Cannot reconfigure neoagent while a run is active")
  end
  local snapshot = config.snapshot(opts)
  local replacement = build_applet(snapshot, runtime)
  local previous = default_applet
  default_applet = replacement
  config._set(snapshot)
  if previous then
    previous:destroy()
  end
  return replacement
end

---@param opts Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>?
---@return Neoagent.NeoagentApplet
function M.setup(opts)
  return setup(opts)
end

---@param opts Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>?
---@param runtime Neoagent.ProfileRuntimeOptions?
---@return Neoagent.NeoagentApplet
function M._setup(opts, runtime)
  assert(runtime == nil or type(runtime) == "table", "setup runtime must be an object")
  return setup(opts, runtime)
end

---@param agent Neoagent.Agent
---@return Neoagent.Agent?
function M._set_default(agent)
  assert(type(agent) == "table" and agent._neoagent_agent, "default must be a Neoagent Agent")
  local previous
  if default_applet and not default_applet:is_destroyed() then
    previous = default_applet:default_agent()
  end
  local replacement = applet_type()._from_agents({
    agents = { agent },
  })
  if default_applet then
    default_applet:destroy()
  end
  default_applet = replacement
  local configured = agent:config()
  config._set({ config = configured, overrides = config.agent_options(configured) })
  return previous
end

---@param applet Neoagent.NeoagentApplet
---@return Neoagent.NeoagentApplet?
function M._set_default_applet(applet)
  assert(type(applet) == "table" and applet._neoagent_applet, "default applet must be a Neoagent Applet")
  local previous = default_applet
  default_applet = applet
  local agent = applet:default_agent()
  if agent then
    local configured = agent:config()
    config._set({ config = configured, overrides = config.agent_options(configured) })
  end
  return previous
end

---@param value Neoagent.Agent|string|integer
---@return Neoagent.Agent?, Neoagent.Error|Applet.Error?
function M.select_agent(value)
  return M.applet():select(value)
end

---@param message string
---@param level integer?
---@return unknown
local function report(message, level)
  local presenter = M.applet():presenter()
  return assert(presenter):notify({
    message = message,
    level = level or vim.log.levels.INFO,
  })
end

---@param message string
---@param level integer?
---@return unknown
function M.notify(message, level)
  assert(type(message) == "string", "notification message must be a string")
  return report("neoagent: " .. message, level)
end

---@return true?, Neoagent.Error|Applet.Error?
function M.open()
  return M.applet():open()
end

---@return boolean
function M.close()
  return M.applet():close()
end

---@return boolean?, Neoagent.Error|Applet.Error?
function M.toggle()
  return M.applet():toggle()
end

---@return true?, Neoagent.Error|Applet.Error?
function M.show_agents()
  return M.applet():show_agents()
end

---@param text string
---@return Neoagent.AppletSubmissionResult, Neoagent.Error?
function M.send(text)
  return M.applet():send(text)
end

---@param text string
---@return true?, Neoagent.Error?, integer?, 'steering'?
function M.steer(text)
  local agent = M.applet():target_agent()
  if not agent then
    return nil
  end
  return agent:steer(text)
end

---@return string[], integer[]?
function M.dequeue_steering()
  local agent = M.applet():target_agent()
  if not agent then
    return {}
  end
  return agent:dequeue_steering()
end

---@param instructions string?
---@return Neoagent.AgentRun?, Neoagent.Error?
function M.compact(instructions)
  local agent = M.applet():target_agent()
  if not agent then
    return nil
  end
  return agent:compact(instructions)
end

---@return boolean
function M.stop()
  local agent = M.applet():target_agent()
  if not agent then
    return false
  end
  return agent:stop()
end

---@param entry_id string
---@return true?, Neoagent.Error?
function M.branch(entry_id)
  local agent = M.applet():target_agent()
  if not agent then
    return nil
  end
  return agent:branch(entry_id)
end

---@param entry_id string?
---@param position 'before'|'at'?
---@return Neoagent.Run<Neoagent.SessionDerivation, unknown>?, Neoagent.Error?
function M.fork(entry_id, position)
  return M.applet():fork(entry_id, position)
end

---@return Neoagent.Session?
function M.get_session()
  local agent = M.applet():target_agent()
  if not agent then
    return nil
  end
  return agent:get_session()
end

---@return Neoagent.Model?
function M.get_model()
  local agent = M.applet():target_agent()
  if not agent then
    return nil
  end
  return agent:get_model()
end

---@return boolean?, Neoagent.Error|Applet.Error?
function M.toggle_provider_shell()
  return M.applet():toggle_provider_shell()
end

---@param path string?
---@return Neoagent.Agent|true|nil, Neoagent.Error|Applet.Error?
function M.resume(path)
  return M.applet():resume(path)
end

---@return Neoagent.PresentationRun
function M.select_position()
  local selection = assert(M.applet():presenter()):select({
    prompt = "Select window position:",
    items = positions,
  })
  local run = async.run(function()
    local result = selection:await()
    if result.ok then
      M.set_position(result.value --[[@as Neoagent.UiPosition]])
    end
    return result
  end, { error_kind = "presentation" })
  M.open()
  return run
end

---@param position Neoagent.UiPosition
---@return Neoagent.UiPosition?, Neoagent.Error?
function M.set_position(position)
  local selected, err = M.applet():set_position(position)
  if not selected then
    assert(err)
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  M.open()
  return selected, err
end

---@param style 'codex'|'pi'
---@return ('codex'|'pi')?, Neoagent.Error|Applet.Error?
function M.set_transcript_style(style)
  local selected, err = M.applet():set_transcript_style(style)
  if not selected then
    assert(err)
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  M.open()
  return selected
end

---@param renderer unknown
---@return Neoagent.Renderer<unknown>?, Neoagent.Error|Applet.Error?
function M.set_renderer(renderer)
  local selected, err = M.applet():set_renderer(renderer)
  if not selected then
    assert(err)
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  M.open()
  return selected
end

---@return true?
function M.select_model()
  local selected = M.applet():select_model()
  if selected then
    M.open()
  end
  return selected
end

---@param provider string
---@param model string
---@return (Neoagent.Model|Neoagent.ModelSelection)?, Neoagent.Error?
function M.set_model(provider, model)
  local selected, err = M.applet():set_model(provider, model)
  if selected then
    M.open()
  end
  return selected, err
end

---@return Neoagent.ThinkingLevel[]?, Neoagent.Error?
function M.available_thinking_levels()
  return M.applet():available_thinking_levels()
end

---@return Neoagent.ThinkingLevel?
function M.get_thinking_level()
  return M.applet():get_thinking_level()
end

---@param level Neoagent.ThinkingLevel
---@return Neoagent.ThinkingLevel?, Neoagent.Error?
function M.set_thinking_level(level)
  return M.applet():set_thinking_level(level)
end

---@return Neoagent.ThinkingLevel?, Neoagent.Error?
function M.cycle_thinking_level()
  return M.applet():cycle_thinking_level()
end

---@return true?
function M.select_branch()
  local agent = M.applet():target_agent()
  if not agent then
    return nil
  end
  local selected = agent:select_branch(function()
    if M.default() == agent then
      M.open()
    end
  end)
  if selected then
    M.open()
  end
  return selected
end

---@return true?, Neoagent.Error?
function M.select_fork()
  local selected, err = M.applet():select_fork()
  if selected then
    M.open()
  end
  return selected, err
end

---@return true?, Neoagent.Error?
function M.copy_session()
  return M.applet():copy_session()
end

---@class Neoagent.SandboxTarget
---@field runtime? Neoagent.ProfileSandboxState
---@field trust? Neoagent.WorkspaceTrust
---@field agent? Neoagent.Agent
---@field applet? Neoagent.NeoagentApplet
---@field draft? Neoagent.AgentApplet
---@field config? Neoagent.Config<Neoagent.AgentToolEnvironment>
---@field label? string

---@param create_draft boolean?
---@return Neoagent.SandboxTarget
local function sandbox_target(create_draft)
  local applet = M.applet()
  local agent = applet:target_agent()
  if agent then
    local runtime = agent:get_toolset().sandbox
    return {
      runtime = runtime and { runtime = runtime, status = runtime:status() },
      trust = agent:workspace_trust(),
      agent = agent,
    }
  end
  local selected = applet:selected_applet() or applet:retained_draft()
  if not selected and create_draft then
    selected = applet:draft()
  end
  local resolved = selected and applet:_owned_draft(selected):snapshot() or applet:_resolve()
  if not resolved then
    return {}
  end
  local profile = resolved.profile
  return {
    applet = applet,
    draft = profile.sandbox_controls and selected or nil,
    config = resolved.config,
    label = profile.label,
  }
end

---@param enabled boolean
---@return Neoagent.SandboxInfo?, Neoagent.Error?
function M.set_sandbox_enabled(enabled)
  assert(type(enabled) == "boolean", "sandbox state must be boolean")
  local target = sandbox_target(true)
  local state = target.runtime
  if not state then
    if target.draft then
      local updated, update_err = assert(target.applet):update_draft_options({
        sandbox = { enabled = enabled },
      }, target.draft)
      if not updated then
        return nil, update_err
      end
      local status = { enabled = enabled, active = false }
      M.notify(
        enabled and "sandbox will be enabled for the next " .. assert(target.label) .. " Agent"
          or "sandbox disabled; tools execute on the host",
        vim.log.levels.INFO
      )
      return status
    end
    local err = util.error("sandbox", "Sandbox toggling is unavailable for the selected Agent")
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  local toggle = state.runtime.set_enabled
  if not toggle then
    local err = util.error("sandbox", "Sandbox toggling is unavailable for the selected Agent")
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  local status, err = toggle(state.runtime, enabled)
  if not status then
    assert(err)
    state.status = state.runtime:status()
    if target.trust then
      target.trust:set_sandbox_status(state.status)
    end
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  state.status = util.copy(status)
  if target.trust then
    target.trust:set_sandbox_status(status)
  end
  if enabled and not status.active then
    report(require("neoagent.sandbox.composition").warning(assert(target.agent):label(), status), vim.log.levels.WARN)
    return util.copy(status)
  end
  M.notify(enabled and "sandbox enabled" or "sandbox disabled; tools execute on the host", vim.log.levels.INFO)
  return util.copy(status)
end

---@return Neoagent.SandboxInfo?, Neoagent.Error?
function M.toggle_sandbox()
  local status = M.sandbox_info()
  return M.set_sandbox_enabled(not status.enabled)
end

---@return Neoagent.SandboxInfo
function M.sandbox_info()
  local target = sandbox_target()
  if target.runtime then
    return util.copy(target.runtime.status)
  end
  if target.agent then
    return { enabled = false, active = false }
  end
  return require("neoagent.sandbox").info(target.config)
end

---@return Neoagent.SandboxInfo
function M.show_sandbox_info()
  local sandbox = require("neoagent.sandbox")
  local status = M.sandbox_info()
  report(
    sandbox.format_info(status),
    status.enabled and not status.active and vim.log.levels.WARN or vim.log.levels.INFO
  )
  return status
end

return M
