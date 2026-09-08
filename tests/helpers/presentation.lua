local M = {}

---@param window Neoagent.AgentApplet|Neoagent.NeoagentApplet|Neoagent.ProviderShell
---@return Neoagent.View|Neoagent.ProviderShellView, Neoagent.PublicPresentation, Applet.Pane
---@overload fun(window: Neoagent.AgentApplet|Neoagent.NeoagentApplet): Neoagent.View, Neoagent.PublicPresentation, Applet.Pane
---@overload fun(window: Neoagent.ProviderShell): Neoagent.ProviderShellView, Neoagent.PublicPresentation, Applet.Pane
function M.active(window)
  assert(vim.wait(1000, function()
    local view = window:view()
    local request = view and view.presentation and view.presentation.active
    local key = request and request.kind == "select"
      and "presentation-results" or "presentation"
    local pane = view and view.pane and view:pane(key)
    return request ~= nil and pane ~= nil and pane:is_mounted()
  end, 5))
  ---@type Neoagent.View|Neoagent.ProviderShellView|nil
  local view = window:view()
  assert(view)
  local snapshot = assert(view.presentation)
  local request = assert(snapshot.active)
  local key = request.kind == "select" and "presentation-results" or "presentation"
  return view, request, assert(view:pane(key))
end

---@param window Neoagent.AgentApplet|Neoagent.NeoagentApplet|Neoagent.ProviderShell
---@param id string
---@return Neoagent.PublicSelect
function M.choose(window, id)
  local view, request, pane = M.active(window)
  assert(request.kind == "select")
  ---@cast request Neoagent.PublicSelect
  local key = "presentation:" .. request.id .. ":item:" .. id
  assert(pane:reveal_target(key))
  local applet = assert(assert(view.presentation_component).results)
  local target = assert(assert(applet.layout).targets[key])
  assert(require("applet.pane.input").dispatch_action(
    applet, assert(target.action), target, 1, "n", assert(target.point).row,
    assert(target.point).col))
  return request
end

---@param window Neoagent.AgentApplet|Neoagent.NeoagentApplet|Neoagent.ProviderShell
---@param value string
---@return Neoagent.PublicInput
function M.input(window, value)
  local view, request = M.active(window)
  assert(request.kind == "input")
  ---@cast request Neoagent.PublicInput
  assert(assert(view.presentation_component):set_text(value))
  local lhs = request.multiline and "<C-s>" or "<CR>"
  assert(require("applet.pane.input").dispatch(
    assert(view.presentation_component).pane, "i", lhs))
  return request
end

---@param window Neoagent.AgentApplet|Neoagent.NeoagentApplet|Neoagent.ProviderShell
---@return Neoagent.PublicPresentation
function M.cancel(window)
  local view, request = M.active(window)
  local applet = request.kind == "select" and assert(view.presentation_component).filter
    or assert(view.presentation_component).pane
  local mode = request.kind == "notice" and "n" or "i"
  assert(require("applet.pane.input").dispatch(
    assert(applet), mode, "<C-c>"))
  return request
end

return M
