local config = require("neoagent.config")
local Controller = require("neoagent.controller")
local Window = require("neoagent.window")
local util = require("neoagent.util")

local M = {}
local positions = { "auto", "left", "right", "top", "bottom", "center" }
local default_window
local owned_controllers
local default_sandbox

local function configured_toolset(configured)
  return {
    tools = configured._tools_supplied and util.copy(configured.tools)
      or require("neoagent.tools").coding({
        shell_timeout = configured.shell_timeout,
      }),
    execute_tool = configured.execute_tool,
  }
end

local function trust_protected(configured, toolset)
  return #toolset.tools > 0
    or configured.agents ~= false
      and #configured.agents.project_filenames > 0
    or configured.skills ~= false
      and #configured.skills.project_dirs > 0
end

local function default_controllers(configured)
  local neo = util.copy(configured)
  neo.name = neo.name or "Neo"
  local host_toolset = configured_toolset(neo)
  local dialogs = require("neoagent.dialog").new()
  local sandbox_runtime
  local sandbox_toolset
  local sandbox_warning
  local composition = require("neoagent.sandbox.composition")
  local status
  sandbox_toolset, status, _, sandbox_runtime = composition.switchable(
    host_toolset, neo.sandbox, { dialogs = dialogs })
  if neo.sandbox.enabled and not status.active then
    sandbox_warning = composition.warning(neo.name, status)
  end
  local trust_policy
  local view = neo.view
  if configured.workspace_trust
      and trust_protected(neo, host_toolset) then
    view, trust_policy = require("neoagent.workspace_trust").compose(neo, {
      path = configured.workspace_trust.path,
      dialogs = dialogs,
      sandbox_status = status,
    })
  elseif sandbox_warning then
    view = require("neoagent.sandbox.view").warn_once(
      view, sandbox_warning, neo.name)
  end
  local neo_controller = Controller.from_config(neo, {
    workspace_trust = trust_policy,
  })
  assert(neo_controller:set_toolset(sandbox_toolset))
  local sandbox_state = {
    controller = neo_controller,
    enabled = configured.sandbox.enabled,
    runtime = sandbox_runtime,
    status = util.copy(status),
    trust = trust_policy,
  }

  local chat = util.copy(configured)
  chat.name = "Chat"
  chat.sandbox.enabled = false
  chat.tools = {}
  chat._tools_supplied = true
  chat.system_prompt = ""
  chat.agents = false
  chat.skills = false

  return {
    neo_controller,
    Controller.from_config(chat),
  }, dialogs, sandbox_state, trust_policy, view
end

local function attach_trust(policy, window, controller)
  if policy then policy:attach_window(window, controller) end
end

local function any_owned_running()
  for _, controller in ipairs(owned_controllers or {}) do
    if controller:is_running() then return true end
  end
  return false
end

local function destroy_owned()
  for _, controller in ipairs(owned_controllers or {}) do controller:destroy() end
end

local function window_for(controllers, opts)
  opts = opts or {}
  local first = controllers[1]:config()
  return Window.new({
    controllers = controllers,
    active = opts.active,
    config = util.deep_merge(first.ui, opts.ui or {}),
    view = opts.view or first.view,
    persistence = first.persistence,
    dialogs = opts.dialogs,
  })
end

function M.new(opts, runtime)
  return Controller.new(opts or {}, runtime)
end

function M.new_window(opts)
  opts = opts or {}
  assert(type(opts.controllers) == "table" and #opts.controllers > 0,
    "new_window requires controllers")
  return window_for(opts.controllers, opts)
end

function M.default_window()
  if not default_window then
    local dialogs, trust_policy, view
    owned_controllers, dialogs, default_sandbox, trust_policy, view =
      default_controllers(config.get())
    default_window = window_for(owned_controllers, {
      dialogs = dialogs,
      view = view,
    })
    attach_trust(trust_policy, default_window, owned_controllers[1])
  end
  return default_window
end

function M.default()
  return M.default_window():active()
end

function M.setup(opts)
  if any_owned_running() then
    error("Cannot reconfigure neoagent while a run is active")
  end
  local configured = config.setup(opts or {})
  local replacements, dialogs, sandbox_state, trust_policy, view =
    default_controllers(configured)
  local replacement_window = window_for(replacements, {
    dialogs = dialogs,
    view = view,
  })
  attach_trust(trust_policy, replacement_window, replacements[1])
  if default_window then default_window:destroy() end
  destroy_owned()
  default_window = replacement_window
  owned_controllers = replacements
  default_sandbox = sandbox_state
  return replacements[1]
end

function M.set_default(controller)
  assert(type(controller) == "table" and controller._neoagent_controller,
    "default must be a Neoagent Controller")
  local previous = default_window and default_window:active()
    or (owned_controllers and owned_controllers[1])
  local replacement = window_for({ controller })
  if default_window then default_window:destroy() end
  default_window = replacement
  owned_controllers = nil
  default_sandbox = nil
  config._set(controller:config())
  return previous
end

function M.set_default_window(window)
  assert(type(window) == "table" and window._neoagent_window,
    "default window must be a Neoagent Window")
  local previous = default_window
  default_window = window
  owned_controllers = nil
  default_sandbox = nil
  config._set(window:active():config())
  return previous
end

function M.select_agent(value)
  return M.default_window():select(value)
end

function M.cycle_agent()
  return M.default_window():cycle()
end

for _, method in ipairs({ "open", "close", "toggle" }) do
  M[method] = function(...)
    local window = M.default_window()
    return window[method](window, ...)
  end
end

for _, method in ipairs({
  "send",
  "steer",
  "dequeue_steering",
  "compact",
  "stop",
  "new_session",
  "branch",
  "fork",
  "set_model",
  "available_thinking_levels",
  "get_thinking_level",
  "set_thinking_level",
  "cycle_thinking_level",
  "login",
  "cancel_login",
  "logout",
  "get_session",
  "get_model",
}) do
  M[method] = function(...)
    local controller = M.default()
    return controller[method](controller, ...)
  end
end

function M.resume(path)
  local controller = M.default()
  return controller:resume(path, path and nil or function()
    if M.default() == controller then M.open() end
  end)
end

function M.select_position()
  vim.ui.select(positions, { prompt = "Select Neoagent window position:" }, function(choice)
    if choice then M.set_position(choice) end
  end)
  return true
end

function M.set_position(position)
  local selected, err = M.default_window():set_position(position)
  if not selected then
    vim.notify("neoagent: " .. err.message, vim.log.levels.ERROR)
    return nil, err
  end
  M.open()
  return selected, err
end

function M.select_model()
  local controller = M.default()
  return controller:select_model(function()
    if M.default() == controller then M.open() end
  end)
end

function M.select_branch()
  local controller = M.default()
  return controller:select_branch(function()
    if M.default() == controller then M.open() end
  end)
end

function M.select_fork()
  local controller = M.default()
  return controller:select_fork(function(_, selected_text)
    if M.default() == controller then
      M.default_window():set_input(selected_text or "")
      M.open()
    end
  end)
end

function M.set_sandbox_enabled(enabled)
  assert(type(enabled) == "boolean", "sandbox state must be boolean")
  M.default_window()
  local state = default_sandbox
  if not state then
    local err = util.error("sandbox",
      "Sandbox toggling is available only for the built-in Neo composition")
    vim.notify("neoagent: " .. err.message, vim.log.levels.ERROR)
    return nil, err
  end
  local status, err = state.runtime:set_enabled(enabled)
  if not status then
    vim.notify("neoagent: " .. err.message, vim.log.levels.ERROR)
    return nil, err
  end
  state.enabled = status.enabled
  state.status = util.copy(status)
  if state.trust then state.trust:set_sandbox_status(state.status) end
  if enabled and not status.active then
    vim.notify(require("neoagent.sandbox.composition").warning(
      state.controller:config().name, status), vim.log.levels.WARN)
    return util.copy(state.status)
  end
  vim.notify(enabled and "neoagent: sandbox enabled"
      or "neoagent: sandbox disabled; tools execute on the host",
    vim.log.levels.INFO)
  return util.copy(state.status)
end

function M.toggle_sandbox()
  M.default_window()
  if not default_sandbox then return M.set_sandbox_enabled(true) end
  return M.set_sandbox_enabled(not default_sandbox.enabled)
end

function M.sandbox_info()
  M.default_window()
  if default_sandbox then return util.copy(default_sandbox.status) end
  return require("neoagent.sandbox").info(M.default())
end

function M.show_sandbox_info()
  local sandbox = require("neoagent.sandbox")
  local status = M.sandbox_info()
  vim.notify(sandbox.format_info(status),
    status.enabled and not status.active
      and vim.log.levels.WARN or vim.log.levels.INFO)
  return status
end

return M
