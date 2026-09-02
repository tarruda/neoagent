local async = require("neoagent.async")
local config = require("neoagent.config")
local Agent = require("neoagent.agent")
local util = require("neoagent.util")

local M = {}
local positions = { "auto", "left", "right", "top", "bottom", "center" }
local default_applet

local function applet_type()
  return require("neoagent.applet")
end

local function build_applet(configured, runtime)
  local profiles, default_profile, resources =
    require("neoagent.profiles").bundled(configured, runtime)
  return applet_type().new({
    profiles = profiles,
    default_profile = default_profile,
    resources = resources,
  })
end

function M.new(opts, runtime)
  return Agent.new(opts, runtime)
end

function M._new_applet(opts)
  return applet_type()._from_agents(opts)
end

function M.applet()
  if not default_applet or default_applet:is_destroyed() then
    default_applet = build_applet(config.get())
  end
  return default_applet
end

function M.default()
  return M.applet():default_agent()
end

local function setup(opts, runtime)
  if default_applet and default_applet:any_running() then
    error("Cannot reconfigure neoagent while a run is active")
  end
  local configured = config.resolve(opts or {})
  local replacement = build_applet(configured, runtime)
  local previous = default_applet
  default_applet = replacement
  config._set(configured)
  if previous then previous:destroy() end
  return replacement
end

function M.setup(opts)
  return setup(opts)
end

function M._setup(opts, runtime)
  assert(runtime == nil or type(runtime) == "table",
    "setup runtime must be an object")
  return setup(opts, runtime)
end

function M._set_default(agent)
  assert(type(agent) == "table" and agent._neoagent_agent,
    "default must be a Neoagent Agent")
  local previous
  if default_applet and not default_applet:is_destroyed() then
    previous = default_applet:default_agent()
  end
  local replacement = applet_type()._from_agents({
    agents = { agent },
  })
  if default_applet then default_applet:destroy() end
  default_applet = replacement
  config._set(agent:config())
  return previous
end

function M._set_default_applet(applet)
  assert(type(applet) == "table" and applet._neoagent_applet,
    "default applet must be a Neoagent Applet")
  local previous = default_applet
  default_applet = applet
  local agent = applet:default_agent()
  if agent then config._set(agent:config()) end
  return previous
end

function M.select_agent(value)
  return M.applet():select(value)
end

local function report(message, level)
  local presenter = M.applet():presenter()
  return presenter:notify({
    message = message,
    level = level or vim.log.levels.INFO,
  })
end

function M.notify(message, level)
  assert(type(message) == "string", "notification message must be a string")
  return report("neoagent: " .. message, level)
end

for _, method in ipairs({ "open", "close", "toggle" }) do
  M[method] = function(...)
    local applet = M.applet()
    return applet[method](applet, ...)
  end
end

function M.show_agents()
  return M.applet():show_agents()
end

function M.send(text)
  return M.applet():send(text)
end

local function agent_method(method, fallback, ...)
  local agent = M.applet():target_agent()
  if not agent then return fallback end
  return agent[method](agent, ...)
end

function M.steer(...) return agent_method("steer", nil, ...) end
function M.dequeue_steering(...)
  return agent_method("dequeue_steering", {}, ...)
end
function M.compact(...) return agent_method("compact", nil, ...) end
function M.stop(...) return agent_method("stop", false, ...) end
function M.branch(...) return agent_method("branch", nil, ...) end
function M.fork(...) return M.applet():fork(...) end
function M.get_session(...) return agent_method("get_session", nil, ...) end
function M.get_model(...) return agent_method("get_model", nil, ...) end
function M.toggle_provider_shell()
  return M.applet():toggle_provider_shell()
end

function M.resume(path)
  return M.applet():resume(path)
end

function M.select_position()
  local selection = M.applet():presenter():select({
    prompt = "Select window position:",
    items = positions,
  })
  local run = async.run(function()
    local result = selection:await()
    if result.ok then M.set_position(result.value) end
    return result
  end, { error_kind = "presentation" })
  M.open()
  return run
end

function M.set_position(position)
  local selected, err = M.applet():set_position(position)
  if not selected then
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  M.open()
  return selected, err
end

function M.set_transcript_style(style)
  local selected, err = M.applet():set_transcript_style(style)
  if not selected then
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  M.open()
  return selected
end

function M.set_renderer(renderer)
  local selected, err = M.applet():set_renderer(renderer)
  if not selected then
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  M.open()
  return selected
end

function M.select_model()
  local selected = M.applet():select_model()
  if selected then M.open() end
  return selected
end

function M.set_model(provider, model)
  local selected, err = M.applet():set_model(provider, model)
  if selected then M.open() end
  return selected, err
end

function M.available_thinking_levels()
  return M.applet():available_thinking_levels()
end

function M.get_thinking_level()
  return M.applet():get_thinking_level()
end

function M.set_thinking_level(level)
  return M.applet():set_thinking_level(level)
end

function M.cycle_thinking_level()
  return M.applet():cycle_thinking_level()
end

function M.select_branch()
  local agent = M.applet():target_agent()
  if not agent then return nil end
  local selected = agent:select_branch(function()
    if M.default() == agent then M.open() end
  end)
  if selected then M.open() end
  return selected
end

function M.select_fork()
  local selected, err = M.applet():select_fork()
  if selected then M.open() end
  return selected, err
end

function M.copy_session()
  return M.applet():copy_session()
end

local function sandbox_target(create_draft)
  local applet = M.applet()
  local agent = applet:target_agent()
  if agent then
    local record = applet:record(agent)
    return {
      runtime = record and record.metadata.sandbox,
      agent = agent,
    }
  end
  local selected = applet:selected_applet()
  local profile_id = selected and selected.profile or applet.default_profile
  local profile = profile_id and applet:profile(profile_id) or nil
  if not profile or profile.id ~= "neo" then return {} end
  if not selected then selected = applet:retained_draft(profile.id) end
  if not selected and create_draft then
    selected = assert(applet:draft(profile.id))
  end
  local options = selected and applet:get_draft_options(selected) or {}
  local configured = util.copy(profile.config)
  configured.sandbox = util.deep_merge(
    configured.sandbox, options.sandbox or {})
  return {
    applet = applet,
    draft = selected,
    config = configured,
  }
end

function M.set_sandbox_enabled(enabled)
  assert(type(enabled) == "boolean", "sandbox state must be boolean")
  local target = sandbox_target(true)
  local state = target.runtime
  if not state then
    if target.draft then
      local updated, update_err = target.applet:update_draft_options({
        sandbox = { enabled = enabled },
      }, target.draft)
      if not updated then return nil, update_err end
      local status = { enabled = enabled, active = false }
      M.notify(enabled and "sandbox will be enabled for the next Neo Agent"
          or "sandbox disabled; tools execute on the host",
        vim.log.levels.INFO)
      return status
    end
    local err = util.error("sandbox",
      "Sandbox toggling is unavailable for the selected Agent")
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  local status, err = state.runtime:set_enabled(enabled)
  if not status then
    M.notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  state.status = util.copy(status)
  if state.trust then state.trust:set_sandbox_status(status) end
  if enabled and not status.active then
    report(require("neoagent.sandbox.composition").warning(
      target.agent:label(), status), vim.log.levels.WARN)
    return util.copy(status)
  end
  M.notify(enabled and "sandbox enabled"
      or "sandbox disabled; tools execute on the host",
    vim.log.levels.INFO)
  return util.copy(status)
end

function M.toggle_sandbox()
  local status = M.sandbox_info()
  return M.set_sandbox_enabled(not status.enabled)
end

function M.sandbox_info()
  local target = sandbox_target()
  if target.runtime then return util.copy(target.runtime.status) end
  return require("neoagent.sandbox").info(target.config)
end

function M.show_sandbox_info()
  local sandbox = require("neoagent.sandbox")
  local status = M.sandbox_info()
  report(sandbox.format_info(status),
    status.enabled and not status.active
      and vim.log.levels.WARN or vim.log.levels.INFO)
  return status
end

return M
