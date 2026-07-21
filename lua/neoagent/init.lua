local config = require("neoagent.config")
local Controller = require("neoagent.controller")

local M = {}
local default_controller

function M.new(opts)
  return Controller.new(opts or {})
end

function M.default()
  if not default_controller then
    default_controller = Controller.from_config(config.get())
  end
  return default_controller
end

function M.setup(opts)
  if default_controller and default_controller:is_running() then
    error("Cannot reconfigure neoagent while a run is active")
  end
  local configured = config.setup(opts or {})
  local replacement = Controller.from_config(configured)
  if default_controller then default_controller:destroy() end
  default_controller = replacement
  return replacement
end

function M.set_default(controller)
  assert(type(controller) == "table" and controller._neoagent_controller,
    "default must be a Neoagent Controller")
  local previous = default_controller
  default_controller = controller
  config._set(controller:config())
  return previous
end

local forwarded = {
  "open",
  "close",
  "toggle",
  "send",
  "stop",
  "new_session",
  "resume",
  "select_model",
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
}

for _, method in ipairs(forwarded) do
  M[method] = function(...)
    local controller = M.default()
    return controller[method](controller, ...)
  end
end

return M
