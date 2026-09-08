local util = require("applet.util")
local Mode = require("applet.mode")

---@class Applet.InputTarget
---@field key string
---@field role? string
---@field group? string
---@field disabled? boolean
---@field rectangles Applet.Rectangle[]
---@field point? {row: integer, col: integer}
---@field action? Applet.Action

---@class Applet.InputBinding: Applet.Binding
---@field mode string

---@class Applet.InputScope
---@field parent? string
---@field root? boolean
---@field modal? boolean
---@field rectangles Applet.Rectangle[]
---@field bindings Applet.InputBinding[]

---@class Applet.MappingPair
---@field mode string
---@field lhs string
---@field silent? boolean
---@field nowait? boolean

---@class Applet.InputLayout
---@field targets table<string, Applet.InputTarget>
---@field target_order string[]
---@field hit_order? string[]
---@field scopes table<string, Applet.InputScope>
---@field binding_pairs Applet.MappingPair[]

---@class Applet.TargetMove
---@field direction? 'previous'|'next'
---@field group? string
---@field wrap? boolean
---@field entry? 'first'

---@class Applet.ActionEvent<P>
---@field pane P
---@field action string
---@field payload? Applet.Data
---@field target? {key: string, role?: string, group?: string}
---@field count integer
---@field mode string
---@field cursor {row: integer, col: integer}
---@field binding? {mode: string, lhs: string}
---@field source 'binding'|'applet'
---@field generation integer
---@field pass_requested? boolean
---@field pass fun(self: Applet.ActionEvent<P>): Applet.ActionEvent<P>

---@class Applet.InputInteraction<P>
---@field has_action fun(action: string): boolean
---@field dispatch fun(event: Applet.ActionEvent<P>): unknown
---@field pass? fun(event: Applet.ActionEvent<P>): unknown

---@class Applet.InputSurface<P>
---@field buffer integer
---@field window? fun(): integer?
---@field interaction? Applet.InputInteraction<P>

---@class Applet.SavedMapping: table<string, unknown>
---@field desc? string

---@class Applet.InputPane<P>
---@field id integer
---@field layout? Applet.InputLayout
---@field surface? Applet.InputSurface<P>
---@field handlers table<string, fun(event: Applet.ActionEvent<P>): unknown>
---@field committed_generation integer
---@field mapping_description? string
---@field saved_mappings? table<string, Applet.SavedMapping>
---@field installed_mappings? table<string, Applet.MappingPair>
---@field key fun(self: P): string
---@field _draw_focus fun(self: P)
---@field _report fun(self: P, phase: string, error: unknown, generation: integer)

local M = {}

---@generic P: Applet.InputPane<P>
---@param pane P
---@return_overload integer, integer, integer
---@return_overload nil, nil, nil
local function cursor_position(pane)
  local surface = pane.surface
  if not surface then return nil end
  local window = surface and surface.window and surface.window()
  if not window or not vim.api.nvim_win_is_valid(window)
      or vim.api.nvim_win_get_buf(window) ~= surface.buffer then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(window) --[[@as [integer, integer] ]]
  local line = vim.api.nvim_buf_get_lines(surface.buffer, cursor[1] - 1, cursor[1], false)[1] or ""
  local prefix = line:sub(1, cursor[2])
  return cursor[1] - 1, vim.fn.strdisplaywidth(prefix), window
end

---@param rectangles? Applet.Rectangle[]
---@param row integer
---@param col integer
---@return boolean
local function contains(rectangles, row, col)
  for _, rect in ipairs(rectangles or {}) do
    if row >= rect.row and row < rect.row + rect.height
        and col >= rect.col and col < rect.col + rect.width then
      return true
    end
  end
  return false
end

---@param layout Applet.InputLayout
---@param row integer
---@param col integer
---@return Applet.InputTarget?
function M.target_at(layout, row, col)
  for _, key in ipairs(layout.hit_order or layout.target_order or {}) do
    local target = layout.targets[key]
    if target and not target.disabled and contains(target.rectangles, row, col) then
      return target
    end
  end
  ---@type Applet.InputTarget?, integer?
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

---@param layout Applet.InputLayout
---@param scope? Applet.InputScope
---@return integer
local function scope_depth(layout, scope)
  local depth = 0
  local current = scope
  while current and current.parent do
    depth = depth + 1
    current = layout.scopes[current.parent]
  end
  return depth
end

---@param layout Applet.InputLayout
---@param row integer
---@param col integer
---@return Applet.InputScope[]
local function active_scopes(layout, row, col)
  ---@type Applet.InputScope[], Applet.InputScope[]
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

---@param layout Applet.InputLayout
---@param row integer
---@param col integer
---@param mode string
---@param lhs string
---@return Applet.InputBinding?
local function binding_for(layout, row, col, mode, lhs)
  for _, scope in ipairs(active_scopes(layout, row, col)) do
    for _, binding in ipairs(scope.bindings) do
      if binding.mode == mode and binding.lhs == lhs then return binding end
    end
  end
end

---@param target? Applet.InputTarget
---@return_overload integer, integer
---@return_overload nil, nil
local function target_point(target)
  local point = target and target.point
  if point then return point.row + 1, point.col end
  local rect = target and target.rectangles and target.rectangles[1]
  if rect then return rect.row + 1, rect.col end
end

---@param target? Applet.InputTarget
---@return_overload integer, integer
---@return_overload nil, nil
local function target_end_point(target)
  ---@type integer?, integer?
  local line, col
  ---@type Applet.Rectangle[]
  local rectangles = target and target.rectangles or {}
  for _, rect in ipairs(rectangles) do
    local candidate = rect.row + rect.height
    if not line or candidate > line then
      line, col = candidate, rect.col
    end
  end
  if line then return line, assert(col) end
  return target_point(target)
end

---@generic P: Applet.InputPane<P>
---@param pane P
---@param window integer
---@param line? integer
---@param display_col? integer
---@return boolean
local function place_cursor(pane, window, line, display_col)
  if not line then return false end
  local text = vim.api.nvim_buf_get_lines(
    assert(pane.surface).buffer, line - 1, line, false)[1] or ""
  local byte_col = util.byte_col(text, assert(display_col))
  vim.api.nvim_win_set_cursor(window, { line, math.min(byte_col, #text) })
  return true
end

---@param target Applet.InputTarget
---@param row integer
---@param col integer
---@return boolean
local function target_before_cursor(target, row, col)
  local line, target_col = target_point(target)
  if not line then return false end
  local target_row = line - 1
  return target_row < row or target_row == row and target_col < col
end

---@generic P: Applet.InputPane<P>
---@param pane P
---@param payload Applet.TargetMove
---@param count? number|string
---@return boolean
function M.move(pane, payload, count)
  local layout = pane.layout
  local row, col, window = cursor_position(pane)
  if not layout or not row then return false end
  ---@type Applet.InputTarget[]
  local candidates = {}
  for _, key in ipairs(layout.target_order) do
    local target = layout.targets[key]
    if target and not target.disabled and (not payload.group or target.group == payload.group) then
      candidates[#candidates + 1] = target
    end
  end
  if #candidates == 0 then return false end
  local current = M.target_at(layout, row, col)
  ---@type integer?
  local index
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
  ---@type integer
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

---@generic P: Applet.InputPane<P>
---@param pane P
---@param action Applet.Action
---@param target? Applet.InputTarget
---@param count integer
---@param mode string
---@param row integer
---@param col integer
---@param binding? Applet.InputBinding
---@return Applet.ActionEvent<P>
local function handler_event(pane, action, target, count, mode, row, col, binding)
  ---@type Applet.ActionEvent<P>
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
    pass = function(self)
      self.pass_requested = true
      return self
    end,
  }
  return event
end

---@generic P: Applet.InputPane<P>
---@param pane P
---@param action Applet.Action
---@param target? Applet.InputTarget
---@param count integer
---@param mode string
---@param row integer
---@param col integer
---@param binding? Applet.InputBinding
---@return boolean
function M.dispatch_action(pane, action, target, count, mode, row, col, binding)
  if action.action == "applet.target.move" then
    return M.move(pane, (action.payload or {}) --[[@as Applet.TargetMove]], count)
  end
  if action.action == "applet.target.reveal" then
    local payload = action.payload --[[@as {target?: string}?]]
    return M.reveal(pane, payload and payload.target)
  end
  if action.action == "applet.target.activate" then
    local payload = action.payload --[[@as {target?: string}?]]
    local key = payload and payload.target
    local selected = key and assert(pane.layout).targets[key] or target
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

---@generic P: Applet.InputPane<P>
---@param pane P
---@param mode string
---@param lhs string
---@return boolean
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

---@generic P: Applet.InputPane<P>
---@param pane P
---@param key? string
---@return boolean
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

---@generic P: Applet.InputPane<P>
---@param pane P
---@param intent Applet.TargetIntent
---@return boolean
function M.apply_target_intent(pane, intent)
  local layout = pane.layout
  if not layout then return false end
  local selected = layout.targets[intent.select]
  if not selected then return false end
  local select_line, select_col = target_point(selected)
  local revealed = intent.reveal and layout.targets[intent.reveal] or nil
  local reveal_line, reveal_col = target_end_point(revealed)
  local surface = pane.surface
  local window = surface and surface.window and surface.window()
  if not surface or not select_line or not window or not vim.api.nvim_win_is_valid(window)
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

---@param mode string
---@param lhs string
---@return string
local function mapping_id(mode, lhs)
  return mode .. "\0" .. lhs
end

---@param buffer integer
---@param mode string
---@param lhs string
---@return Applet.SavedMapping?
local function current_mapping(buffer, mode, lhs)
  return vim.api.nvim_buf_call(buffer, function()
    local value = vim.fn.maparg(lhs, mode, false, true)
    return type(value) == "table" and next(value) and value or nil
  end)
end

---@generic P: Applet.InputPane<P>
---@param pane P
---@param pair Applet.MappingPair
local function remove_mapping(pane, pair)
  local current = current_mapping(assert(pane.surface).buffer, pair.mode, pair.lhs)
  local owned = current and current.desc == pane.mapping_description
  if owned then
    pcall(vim.keymap.del, pair.mode, pair.lhs, { buffer = assert(pane.surface).buffer })
  end
  local id = mapping_id(pair.mode, pair.lhs)
  local saved = pane.saved_mappings and pane.saved_mappings[id]
  if saved and (owned or not current) then
    vim.api.nvim_buf_call(assert(pane.surface).buffer, function()
      vim.fn.mapset(pair.mode, false, saved)
    end)
  end
  if pane.saved_mappings then pane.saved_mappings[id] = nil end
  if pane.installed_mappings then pane.installed_mappings[id] = nil end
end

---@generic P: Applet.InputPane<P>
---@param pane P
---@param previous? Applet.InputLayout
---@param layout Applet.InputLayout
---@return integer
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
        assert(pane.surface).buffer, pair.mode, pair.lhs)
      vim.keymap.set(pair.mode, pair.lhs, function()
        return Mode.with_mapping(pair.mode, function()
          return M.dispatch(pane, pair.mode, pair.lhs)
        end)
      end, {
        buffer = assert(pane.surface).buffer,
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

---@generic P: Applet.InputPane<P>
---@param pane P
function M.clear_mappings(pane)
  local installed = {}
  for _, pair in pairs(pane.installed_mappings or {}) do installed[#installed + 1] = pair end
  for _, pair in ipairs(installed) do remove_mapping(pane, pair) end
  pane.saved_mappings = {}
  pane.installed_mappings = {}
end

---@generic P: Applet.InputPane<P>
---@param pane P
---@return Applet.InputTarget?
function M.focus_target(pane)
  local layout = pane.layout
  local row, col = cursor_position(pane)
  if not layout or not row then return nil end
  return M.target_at(layout, row, col)
end

---@param rectangles? Applet.Rectangle[]
---@param row integer
---@param col integer
---@return boolean
function M.contains(rectangles, row, col)
  return contains(rectangles, row, col)
end

return M
