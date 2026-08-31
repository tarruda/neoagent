local util = require("applet.util")
local Mode = require("applet.mode")

local M = {}

local function cursor_position(pane)
  local surface = pane.surface
  local window = surface and surface.window and surface.window()
  if not window or not vim.api.nvim_win_is_valid(window)
      or vim.api.nvim_win_get_buf(window) ~= surface.buffer then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(window)
  local line = vim.api.nvim_buf_get_lines(surface.buffer, cursor[1] - 1, cursor[1], false)[1] or ""
  local prefix = line:sub(1, cursor[2])
  return cursor[1] - 1, vim.fn.strdisplaywidth(prefix), window
end

local function contains(rectangles, row, col)
  for _, rect in ipairs(rectangles or {}) do
    if row >= rect.row and row < rect.row + rect.height
        and col >= rect.col and col < rect.col + rect.width then
      return true
    end
  end
  return false
end

function M.target_at(layout, row, col)
  for _, key in ipairs(layout.hit_order or layout.target_order or {}) do
    local target = layout.targets[key]
    if target and not target.disabled and contains(target.rectangles, row, col) then
      return target
    end
  end
  local nearest, nearest_distance
  for _, key in ipairs(layout.hit_order or layout.target_order or {}) do
    local target = layout.targets[key]
    if target and not target.disabled and target.role == "menuitem" then
      for _, rect in ipairs(target.rectangles or {}) do
        if row >= rect.row and row < rect.row + rect.height then
          local distance = col < rect.col and rect.col - col
            or col - (rect.col + rect.width - 1)
          if not nearest_distance or distance < nearest_distance then
            nearest, nearest_distance = target, distance
          end
        end
      end
    end
  end
  return nearest
end

local function scope_depth(layout, scope)
  local depth, current = 0, scope
  while current and current.parent do
    depth = depth + 1
    current = layout.scopes[current.parent]
  end
  return depth
end

local function active_scopes(layout, row, col)
  local modal, scopes = {}, {}
  for _, scope in pairs(layout.scopes) do
    if scope.modal then
      modal[#modal + 1] = scope
    elseif scope.root or contains(scope.rectangles, row, col) then
      scopes[#scopes + 1] = scope
    end
  end
  table.sort(modal, function(left, right)
    return scope_depth(layout, left) > scope_depth(layout, right)
  end)
  table.sort(scopes, function(left, right)
    return scope_depth(layout, left) > scope_depth(layout, right)
  end)
  for index = #modal, 1, -1 do table.insert(scopes, 1, modal[index]) end
  return scopes
end

local function binding_for(layout, row, col, mode, lhs)
  for _, scope in ipairs(active_scopes(layout, row, col)) do
    for _, binding in ipairs(scope.bindings) do
      if binding.mode == mode and binding.lhs == lhs then return binding end
    end
  end
end

local function target_point(target)
  local point = target and target.point
  if point then return point.row + 1, point.col end
  local rect = target and target.rectangles and target.rectangles[1]
  if rect then return rect.row + 1, rect.col end
end

local function target_end_point(target)
  local line, col
  for _, rect in ipairs(target and target.rectangles or {}) do
    local candidate = rect.row + rect.height
    if not line or candidate > line then
      line, col = candidate, rect.col
    end
  end
  if line then return line, col end
  return target_point(target)
end

local function place_cursor(pane, window, line, display_col)
  if not line then return false end
  local text = vim.api.nvim_buf_get_lines(
    pane.surface.buffer, line - 1, line, false)[1] or ""
  local byte_col = util.byte_col(text, display_col)
  vim.api.nvim_win_set_cursor(window, { line, math.min(byte_col, #text) })
  return true
end

local function target_before_cursor(target, row, col)
  local line, target_col = target_point(target)
  if not line then return false end
  local target_row = line - 1
  return target_row < row or target_row == row and target_col < col
end

function M.move(pane, payload, count)
  local layout = pane.layout
  local row, col, window = cursor_position(pane)
  if not layout or not row then return false end
  local candidates = {}
  for _, key in ipairs(layout.target_order) do
    local target = layout.targets[key]
    if target and not target.disabled and (not payload.group or target.group == payload.group) then
      candidates[#candidates + 1] = target
    end
  end
  if #candidates == 0 then return false end
  local current, index = M.target_at(layout, row, col)
  for candidate_index, candidate in ipairs(candidates) do
    if current and candidate.key == current.key then index = candidate_index break end
  end
  if not index then
    for candidate_index, candidate in ipairs(candidates) do
      if contains(candidate.rectangles, row, col) then
        index = candidate_index
        break
      end
    end
  end
  local direction = payload.direction == "previous" and -1 or 1
  count = math.max(1, math.floor(tonumber(count) or 1))
  local next_index
  if index then
    next_index = index + direction * count
  elseif payload.entry == "first" then
    next_index = 1
  else
    local previous, following = 0, #candidates + 1
    for candidate_index, candidate in ipairs(candidates) do
      if target_before_cursor(candidate, row, col) then
        previous = candidate_index
      elseif following == #candidates + 1 then
        following = candidate_index
      end
    end
    next_index = direction > 0
      and following + count - 1
      or previous - count + 1
  end
  if payload.wrap then next_index = ((next_index - 1) % #candidates) + 1 end
  if next_index < 1 or next_index > #candidates then return false end
  local line, display_col = target_point(candidates[next_index])
  local ok = pcall(function()
    place_cursor(pane, window, line, display_col)
    vim.api.nvim_win_call(window, function() vim.cmd("normal! zv") end)
    pane:_draw_focus()
    vim.cmd("redraw")
  end)
  return ok
end

local function handler_event(pane, action, target, count, mode, row, col, binding)
  local event = {
    pane = pane,
    action = action.action,
    payload = action.payload,
    target = target and {
      key = target.key,
      role = target.role,
      group = target.group,
    } or nil,
    count = count,
    mode = mode,
    cursor = { row = row, col = col },
    binding = binding and { mode = binding.mode, lhs = binding.lhs } or nil,
    source = binding and "binding" or "applet",
    generation = pane.committed_generation,
  }
  function event:pass()
    self.pass_requested = true
    return self
  end
  return event
end

function M.dispatch_action(pane, action, target, count, mode, row, col, binding)
  if action.action == "applet.target.move" then
    return M.move(pane, action.payload or {}, count)
  end
  if action.action == "applet.target.reveal" then
    return M.reveal(pane, action.payload and action.payload.target)
  end
  if action.action == "applet.target.activate" then
    local key = action.payload and action.payload.target
    local selected = key and pane.layout.targets[key] or target
    if not selected or selected.disabled or not selected.action then return false end
    return M.dispatch_action(pane, selected.action, selected, count, mode, row, col,
      binding)
  end
  local event = handler_event(pane, action, target, count, mode, row, col, binding)
  local handler = pane.handlers[action.action]
  local interaction = pane.surface and pane.surface.interaction
  local ok, result
  if handler then
    ok, result = pcall(handler, event)
  elseif interaction and interaction.has_action(action.action) then
    ok, result = pcall(interaction.dispatch, event)
  else
    return false
  end
  if not ok then
    pane:_report("handler", result, pane.committed_generation)
    return false
  end
  if event.pass_requested then
    if interaction and type(interaction.pass) == "function" then
      local passed, pass_result = pcall(interaction.pass, event)
      if not passed then
        pane:_report("handler", pass_result, pane.committed_generation)
        return false
      end
      return pass_result ~= false
    end
    return false
  end
  if result == false then return false end
  return true
end

function M.dispatch(pane, mode, lhs)
  local layout = pane.layout
  local row, col = cursor_position(pane)
  if not layout or not row then return false end
  local binding = binding_for(layout, row, col, mode, lhs)
  if not binding then return false end
  local target = M.target_at(layout, row, col)
  local count = binding.count and vim.v.count1 or 1
  return M.dispatch_action(pane, binding.action, target, count, mode, row, col,
    binding)
end

function M.reveal(pane, key)
  local target = pane.layout and pane.layout.targets[key]
  local line, col = target_point(target)
  local surface = pane.surface
  local window = surface and surface.window and surface.window()
  if not line or not window or not vim.api.nvim_win_is_valid(window) then return false end
  local ok = pcall(function()
    place_cursor(pane, window, line, col)
    vim.api.nvim_win_call(window, function() vim.cmd("normal! zv") end)
    pane:_draw_focus()
  end)
  return ok
end

function M.apply_target_intent(pane, intent)
  local layout = pane.layout
  local selected = layout and layout.targets[intent.select]
  if not selected then return false end
  local select_line, select_col = target_point(selected)
  local revealed = intent.reveal and layout.targets[intent.reveal] or nil
  local reveal_line, reveal_col = target_end_point(revealed)
  local surface = pane.surface
  local window = surface and surface.window and surface.window()
  if not select_line or not window or not vim.api.nvim_win_is_valid(window)
      or vim.api.nvim_win_get_buf(window) ~= surface.buffer then
    return false
  end
  local ok = pcall(vim.api.nvim_win_call, window, function()
    if reveal_line then
      place_cursor(pane, window, reveal_line, reveal_col)
      vim.cmd("normal! zv")
    end
    place_cursor(pane, window, select_line, select_col)
    vim.cmd("normal! zv")
  end)
  if ok then pane:_draw_focus() end
  return ok
end

local function mapping_id(mode, lhs)
  return mode .. "\0" .. lhs
end

local function current_mapping(buffer, mode, lhs)
  return vim.api.nvim_buf_call(buffer, function()
    local value = vim.fn.maparg(lhs, mode, false, true)
    return type(value) == "table" and next(value) and value or nil
  end)
end

local function remove_mapping(pane, pair)
  local current = current_mapping(pane.surface.buffer, pair.mode, pair.lhs)
  local owned = current and current.desc == pane.mapping_description
  if owned then
    pcall(vim.keymap.del, pair.mode, pair.lhs, { buffer = pane.surface.buffer })
  end
  local id = mapping_id(pair.mode, pair.lhs)
  local saved = pane.saved_mappings and pane.saved_mappings[id]
  if saved and (owned or not current) then
    vim.api.nvim_buf_call(pane.surface.buffer, function()
      vim.fn.mapset(pair.mode, false, saved)
    end)
  end
  if pane.saved_mappings then pane.saved_mappings[id] = nil end
  if pane.installed_mappings then pane.installed_mappings[id] = nil end
end

function M.update_mappings(pane, previous, layout)
  local old, new = {}, {}
  local changes = 0
  pane.saved_mappings = pane.saved_mappings or {}
  pane.installed_mappings = pane.installed_mappings or {}
  if not pane.mapping_description then
    pane.mapping_description = ("Pane[%s:%d] action"):format(pane:key(), pane.id)
  end
  for _, pair in ipairs(previous and previous.binding_pairs or {}) do
    old[mapping_id(pair.mode, pair.lhs)] = pair
  end
  for _, pair in ipairs(layout.binding_pairs or {}) do
    new[mapping_id(pair.mode, pair.lhs)] = pair
  end
  for id, pair in pairs(old) do
    if not new[id] then
      remove_mapping(pane, pair)
      changes = changes + 1
    end
  end
  for id, pair in pairs(new) do
    if not old[id] then
      pane.saved_mappings[id] = current_mapping(
        pane.surface.buffer, pair.mode, pair.lhs)
      vim.keymap.set(pair.mode, pair.lhs, function()
        return Mode.with_mapping(pair.mode, function()
          return M.dispatch(pane, pair.mode, pair.lhs)
        end)
      end, {
        buffer = pane.surface.buffer,
        silent = pair.silent ~= false,
        remap = false,
        nowait = pair.nowait ~= false,
        desc = pane.mapping_description,
      })
      pane.installed_mappings[id] = pair
      changes = changes + 1
    end
  end
  return changes
end

function M.clear_mappings(pane)
  local installed = {}
  for _, pair in pairs(pane.installed_mappings or {}) do installed[#installed + 1] = pair end
  for _, pair in ipairs(installed) do remove_mapping(pane, pair) end
  pane.saved_mappings = {}
  pane.installed_mappings = {}
end

function M.focus_target(pane)
  local layout = pane.layout
  local row, col = cursor_position(pane)
  if not layout or not row then return nil end
  return M.target_at(layout, row, col)
end

function M.contains(rectangles, row, col)
  return contains(rectangles, row, col)
end

return M
