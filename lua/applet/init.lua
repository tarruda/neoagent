local modules = {
  Pane = "applet.pane",
  layout = "applet.layout",
  host = "applet.host",
  Theme = "applet.theme",
  InteractionDomain = "applet.interaction_domain",
  ImageSystem = "applet.image",
  Presenter = "applet.presenter",
  presentation = "applet.presentation",
  host_effects = "applet.host_effects",
}

local M = {}

local function load(key)
  local module = modules[key]
  local value
  if module then value = require(module)
  else value = require("applet.applet")[key] end
  if value ~= nil then rawset(M, key, value) end
  return value
end

return setmetatable(M, {
  __index = function(_, key) return load(key) end,
  __call = function(_, opts) return M.new(opts) end,
})
