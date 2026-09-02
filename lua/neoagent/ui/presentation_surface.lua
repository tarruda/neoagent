local Applet = require("applet")
local util = require("neoagent.util")

local M = {}

local function options(view)
  return assert(view._presentation_surface,
    "presentation surface is not configured")
end

function M.configure(view, opts)
  assert(type(view) == "table", "presentation View is required")
  assert(type(opts) == "table"
      and type(opts.submit) == "function"
      and type(opts.flush) == "function"
      and type(opts.is_open) == "function"
      and type(opts.resolve) == "function"
      and type(opts.cancel) == "function",
    "presentation surface options are invalid")
  view._presentation_surface = opts
  return view
end

function M.new_component(view, active)
  local opts = options(view)
  return Applet.presentation.new({
    key = "presentation",
    filter_key = "presentation-filter",
    results_key = "presentation-results",
    request = active,
    theme = view.applet_theme,
    on_choose = function(value) opts.resolve(active.id, value) end,
    on_cancel = function() opts.cancel(active.id) end,
    on_error = view.on_error,
  })
end

function M.ensure(view)
  local active = view.presentation and view.presentation.active
  if not active then return false end
  local current = view.presentation_component
  local editable = current and current:editable_pane() or nil
  local results = current and current.pane or nil
  if current and not current:is_destroyed()
      and editable and not editable:is_destroyed()
      and results and not results:is_destroyed() then
    return false
  end
  if current then current:destroy() end
  view.presentation_component = M.new_component(view, active)
  return true
end

function M.seed(view)
  local component = view.presentation_component
  local editable = component and component:editable_pane() or nil
  if view.presentation_seed == nil or not editable
      or not editable:is_editable() or not editable:is_connected() then
    return false
  end
  local value = view.presentation_seed
  view.presentation_seed = nil
  component:set_text(value)
  return true
end

function M.retain_seed(view)
  local active = view.presentation and view.presentation.active
  if not active or active.kind ~= "input" then return false end
  view.presentation_seed = active.default or ""
  return true
end

function M.set(view, snapshot)
  assert(snapshot == nil or type(snapshot) == "table",
    "presentation snapshot must be a table")
  snapshot = snapshot and util.copy(snapshot)
    or { active = nil, queue_count = 0 }
  local active = snapshot.active
  if active then
    assert(type(active.id) == "string" and active.id ~= ""
        and (active.kind == "select" or active.kind == "input"
          or active.kind == "notice"),
      "presentation request is invalid")
  end

  local current = view.presentation and view.presentation.active
  if current and active and current.id == active.id
      and current.kind == active.kind then
    if active.kind == "select" and view.presentation_component then
      view.presentation_component:set_items(active.items)
    end
    view.presentation = snapshot
    return true
  end

  local opts = options(view)
  local previous_snapshot = view.presentation
  local previous_component = view.presentation_component
  local previous_seed = view.presentation_seed
  local next_component = active and M.new_component(view, active) or nil
  view.presentation = active and snapshot or nil
  view.presentation_component = next_component
  view.presentation_seed = active and active.kind == "input"
      and (active.default or "") or nil
  opts.submit()
  if opts.is_open() then
    local committed, err = opts.flush()
    if not committed then
      view.presentation = previous_snapshot
      view.presentation_component = previous_component
      view.presentation_seed = previous_seed
      opts.submit()
      opts.flush()
      if next_component then next_component:destroy() end
      return nil, err
    end
    M.seed(view)
  elseif previous_component then
    previous_component:destroy()
  end
  return true
end

function M.set_theme(view, theme)
  local component = view.presentation_component
  if not component then return false end
  if M.ensure(view) then return true end
  component:set_theme(theme)
  return true
end

function M.destroy(view)
  if view.presentation_component then
    view.presentation_component:destroy()
  end
  view.presentation = nil
  view.presentation_component = nil
  view.presentation_seed = nil
  view._presentation_surface = nil
end

return M
