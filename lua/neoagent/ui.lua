local applet_view = require("neoagent.ui.applet_view")

local M = {
  View = applet_view.View,
}

---@param opts Neoagent.ViewOptions
---@return Neoagent.View
function M.new(opts)
  return applet_view.new(opts)
end

return M
