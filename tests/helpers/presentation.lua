local M = {}

function M.active(window)
  assert(vim.wait(1000, function()
    local view = window:view()
    local request = view and view.presentation and view.presentation.active
    local key = request and request.kind == "select"
      and "presentation-results" or "presentation"
    local pane = view and view.pane and view:pane(key)
    return request
      and pane and pane:is_mounted()
  end, 5))
  local view = window:view()
  local request = view.presentation.active
  local key = request.kind == "select" and "presentation-results" or "presentation"
  return view, request, view:pane(key)
end

function M.choose(window, id)
  local view, request, pane = M.active(window)
  local key = "presentation:" .. request.id .. ":item:" .. id
  assert(pane:reveal_target(key))
  local applet = view.presentation_component.results
  local target = assert(applet.layout.targets[key])
  assert(require("applet.pane.input").dispatch_action(
    applet, target.action, target, 1, "n", target.point.row,
    target.point.col))
  return request
end

function M.input(window, value)
  local view, request = M.active(window)
  assert.are.equal("input", request.kind)
  assert(view.presentation_component:set_text(value))
  local lhs = request.multiline and "<C-s>" or "<CR>"
  assert(require("applet.pane.input").dispatch(
    view.presentation_component.pane, "i", lhs))
  return request
end

function M.cancel(window)
  local view, request = M.active(window)
  local applet = request.kind == "select" and view.presentation_component.filter
    or view.presentation_component.pane
  local mode = request.kind == "notice" and "n" or "i"
  assert(require("applet.pane.input").dispatch(
    applet, mode, "<C-c>"))
  return request
end

return M
