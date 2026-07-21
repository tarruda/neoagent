local config = require("neoagent.config")
local Controller = require("neoagent.controller")
local Window = require("neoagent.window")
local util = require("neoagent.util")

local M = {}
local default_window
local owned_controllers

local function default_controllers(configured)
  local neo = util.copy(configured)
  neo.name = neo.name or "Neo"

  local chat = util.copy(configured)
  chat.name = "Chat"
  chat.tools = {}
  chat._tools_supplied = true
  chat.system_prompt = ""
  chat.agents = false
  chat.skills = false

  return {
    Controller.from_config(neo),
    Controller.from_config(chat),
  }
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
  })
end

function M.new(opts)
  return Controller.new(opts or {})
end

function M.new_window(opts)
  opts = opts or {}
  assert(type(opts.controllers) == "table" and #opts.controllers > 0,
    "new_window requires controllers")
  return window_for(opts.controllers, opts)
end

function M.default_window()
  if not default_window then
    owned_controllers = default_controllers(config.get())
    default_window = window_for(owned_controllers)
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
  local replacements = default_controllers(configured)
  local replacement_window = window_for(replacements)
  if default_window then default_window:destroy() end
  destroy_owned()
  default_window = replacement_window
  owned_controllers = replacements
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
  config._set(controller:config())
  return previous
end

function M.set_default_window(window)
  assert(type(window) == "table" and window._neoagent_window,
    "default window must be a Neoagent Window")
  local previous = default_window
  default_window = window
  owned_controllers = nil
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
  "stop",
  "new_session",
  "set_model",
  "available_thinking_levels",
  "get_thinking_level",
  "set_thinking_level",
  "cycle_thinking_level",
  "login",
  "cancel_login",
  "get_session",
  "get_model",
  "_state",
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

function M.select_model()
  local controller = M.default()
  return controller:select_model(function()
    if M.default() == controller then M.open() end
  end)
end

return M
