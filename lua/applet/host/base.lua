local chrome = require("applet.chrome")
local Mode = require("applet.mode")
local util = require("applet.util")

local M = {}

local sequence = 0

local named_borders = {
  single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
  double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
  rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
  solid = { " ", " ", " ", " ", " ", " ", " ", " " },
  shadow = {
    "", "", { " ", "FloatShadowThrough" }, { " ", "FloatShadow" },
    { " ", "FloatShadow" }, { " ", "FloatShadow" },
    { " ", "FloatShadowThrough" }, "",
  },
}

local float_config_fields = {
  "relative", "win", "anchor", "row", "col", "width", "height",
  "zindex", "border", "focusable", "hide",
}

local function copy_value(value)
  return type(value) == "table" and util.copy(value) or value
end

local function sorted_keys(value)
  local result = {}
  for key in pairs(value or {}) do result[#result + 1] = key end
  table.sort(result)
  return result
end

function M.valid_buffer(buffer)
  return buffer ~= nil and vim.api.nvim_buf_is_valid(buffer) == true
end

function M.loaded_buffer(buffer)
  return M.valid_buffer(buffer) and vim.api.nvim_buf_is_loaded(buffer) == true
end

function M.valid_window(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window) == true
end

function M.valid_tab(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab) == true
end

function M.window_displays(window, buffer)
  return M.valid_window(window) and M.valid_buffer(buffer)
    and vim.api.nvim_win_get_buf(window) == buffer
end

local function resolved_border(border)
  if border == nil or border == "" or border == "none" then return nil end
  return type(border) == "string" and named_borders[border] or border
end

function M.same_float_config(window, desired)
  local current = vim.api.nvim_win_get_config(window)
  for _, key in ipairs(float_config_fields) do
    local left, right = current[key], desired[key]
    if key == "border" then
      left, right = resolved_border(left), resolved_border(right)
    end
    if type(left) == "table" or type(right) == "table" then
      if not util.equal(left or {}, right or {}) then return false end
    elseif right ~= nil and left ~= right then
      return false
    end
  end
  return true
end

function M.buffer_windows(buffer)
  local result = {}
  if not M.valid_buffer(buffer) then return result end
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if M.valid_window(window) and vim.api.nvim_win_get_buf(window) == buffer then
      result[#result + 1] = window
    end
  end
  return result
end

local function qualified_name(applet, descriptor)
  if descriptor.buffer.uri then return descriptor.buffer.uri end
  local name = descriptor.buffer.name:gsub("[^%w%._%-]", "-")
  return ("applet://%s/%d/%s"):format(applet.name, applet.id, name)
end

local function get_option(option, scope)
  local ok, value = pcall(vim.api.nvim_get_option_value, option, scope)
  if ok then return value end
end

local function set_option(option, value, scope)
  local ok, err = pcall(vim.api.nvim_set_option_value, option, value, scope)
  if not ok then error(err, 0) end
end

local function restore_options(states, scope)
  for option, state in pairs(states or {}) do
    local current = get_option(option, scope)
    if current ~= nil and util.equal(current, state.written) then
      pcall(vim.api.nvim_set_option_value, option, state.original, scope)
    end
  end
end

local function desired_buffer_options(descriptor)
  local result = {
    buftype = "nofile",
    bufhidden = "hide",
    swapfile = false,
    undofile = false,
  }
  for option, value in pairs(descriptor.buffer.options or {}) do
    result[option] = value
  end
  if descriptor.buffer.filetype ~= nil then result.filetype = descriptor.buffer.filetype end
  return result
end

function M.configure_buffer(record, descriptor)
  if not M.loaded_buffer(record.buffer) then return false end
  local desired = desired_buffer_options(descriptor)
  local changed = record.reproject_buffer_options == true
    or not util.equal(record.requested_buffer_options, desired)
  record.buffer_option_states = record.buffer_option_states or {}
  if not changed then return true end

  local scope = { buf = record.buffer }
  for option, state in pairs(util.copy(record.buffer_option_states)) do
    if desired[option] == nil then
      local current = get_option(option, scope)
      if current ~= nil and util.equal(current, state.written) then
        pcall(vim.api.nvim_set_option_value, option, state.original, scope)
      end
      record.buffer_option_states[option] = nil
    end
  end
  for option, value in pairs(desired) do
    local state = record.buffer_option_states[option]
    if not state then
      state = { original = get_option(option, scope) }
      record.buffer_option_states[option] = state
    end
    if not util.equal(get_option(option, scope), value) then
      set_option(option, value, scope)
    end
    state.written = copy_value(value)
  end
  record.requested_buffer_options = util.copy(desired)
  record.reproject_buffer_options = nil
  return true
end

function M.restore_buffer_options(record)
  if M.loaded_buffer(record.buffer) then
    restore_options(record.buffer_option_states, { buf = record.buffer })
  end
  record.buffer_option_states = {}
  record.requested_buffer_options = nil
end

function M.ensure_buffer(applet, record, descriptor)
  if record.owns_buffer and M.loaded_buffer(record.buffer) then
    M.configure_buffer(record, descriptor)
    return record.buffer, false
  end
  local buffer = vim.api.nvim_create_buf(false, true)
  local name = qualified_name(applet, descriptor)
  local named, name_error = pcall(vim.api.nvim_buf_set_name, buffer, name)
  if not named then
    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    error("failed to name Pane buffer: " .. tostring(name_error), 0)
  end
  record.buffer = buffer
  record.buffer_name = name
  record.owns_buffer = true
  record.buffer_option_states = {}
  record.requested_buffer_options = nil
  M.configure_buffer(record, descriptor)
  return buffer, true
end

local function overwrite_sensitive(buffer)
  if not M.loaded_buffer(buffer) then return end
  local modifiable = get_option("modifiable", { buf = buffer })
  if not modifiable then
    pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buffer })
  end
  pcall(vim.api.nvim_buf_set_lines, buffer, 0, -1, false, { "" })
end

function M.delete_buffer(record)
  local buffer = record.buffer
  if not record.owns_buffer or not M.valid_buffer(buffer) then
    record.buffer, record.owns_buffer = nil, false
    record.buffer_option_states = {}
    record.requested_buffer_options = nil
    return false
  end
  local sensitive = record.descriptor and record.descriptor.buffer.sensitive == true
  local displayed = M.buffer_windows(buffer)
  if #displayed > 0 and not sensitive then
    M.restore_buffer_options(record)
    record.buffer, record.owns_buffer = nil, false
    record.relinquished_buffer = buffer
    return false
  end
  if sensitive then
    if #displayed > 0 then
      local replacement = vim.api.nvim_create_buf(false, false)
      for _, window in ipairs(displayed) do
        pcall(vim.api.nvim_win_set_buf, window, replacement)
      end
    end
    overwrite_sensitive(buffer)
  end
  record.buffer, record.owns_buffer = nil, false
  record.buffer_option_states = {}
  record.requested_buffer_options = nil
  if M.valid_buffer(buffer) then
    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
  end
  return true
end

function M.capture_origin(window)
  window = M.valid_window(window) and window or vim.api.nvim_get_current_win()
  local tab = M.valid_window(window)
      and vim.api.nvim_win_get_tabpage(window)
    or vim.api.nvim_get_current_tabpage()
  local result = { window = window, tab = tab, mode = vim.api.nvim_get_mode().mode }
  if M.valid_window(window) then
    result.cursor = vim.api.nvim_win_get_cursor(window)
    result.view = vim.api.nvim_win_call(window, function() return vim.fn.winsaveview() end)
  end
  return result
end

local function first_external_window(applet)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if not applet or not applet._windows[window] then return tab, window end
    end
  end
end

function M.restore_origin(origin, applet)
  if not origin then return false end
  local tab = M.valid_tab(origin.tab) and origin.tab or nil
  local window = M.valid_window(origin.window) and origin.window or nil
  if applet and window and applet._windows[window] then window = nil end
  if not window then tab, window = first_external_window(applet) end
  if tab and M.valid_tab(tab) then pcall(vim.api.nvim_set_current_tabpage, tab) end
  if not M.valid_window(window) then return false end
  pcall(vim.api.nvim_set_current_win, window)
  if window == origin.window then
    if origin.view then
      pcall(vim.api.nvim_win_call, window, function() vim.fn.winrestview(origin.view) end)
    end
    if origin.cursor then pcall(vim.api.nvim_win_set_cursor, window, origin.cursor) end
    Mode.apply(origin.mode and Mode.semantic(origin.mode) or "normal")
  end
  return true
end

function M.save_view(record)
  local window = record.window
  if not M.window_displays(window, record.buffer) then return false end
  record.cursor = vim.api.nvim_win_get_cursor(window)
  record.view = vim.api.nvim_win_call(window, function() return vim.fn.winsaveview() end)
  if record.descriptor.focus.mode == "preserve"
      and vim.api.nvim_get_current_win() == window then
    local mode = vim.api.nvim_get_mode().mode
    record.mode = Mode.semantic(mode)
  end
  return true
end

function M.restore_view(record)
  local window = record.window
  if not M.window_displays(window, record.buffer) then return false end
  if record.view then
    pcall(vim.api.nvim_win_call, window, function() vim.fn.winrestview(record.view) end)
  end
  if record.cursor then pcall(vim.api.nvim_win_set_cursor, window, record.cursor) end
  return true
end

function M.window_geometry(window)
  if not M.valid_window(window) then return nil end
  local position = vim.api.nvim_win_get_position(window)
  return {
    row = position[1],
    col = position[2],
    width = vim.api.nvim_win_get_width(window),
    height = vim.api.nvim_win_get_height(window),
  }
end

function M.window_view(window)
  if not M.valid_window(window) then return nil end
  local ok, value = pcall(vim.api.nvim_win_call, window, function()
    local view = vim.fn.winsaveview()
    return {
      cursor = vim.api.nvim_win_get_cursor(0),
      topline = view.topline,
      leftcol = view.leftcol,
      skipcol = view.skipcol,
    }
  end)
  return ok and value or nil
end

function M.with_tab(tab, callback)
  if M.valid_tab(tab) and type(vim.api.nvim_tabpage_call) == "function" then
    return vim.api.nvim_tabpage_call(tab, callback)
  end
  local current = vim.api.nvim_get_current_tabpage()
  if M.valid_tab(tab) and current ~= tab then vim.api.nvim_set_current_tabpage(tab) end
  local results = { pcall(callback) }
  if M.valid_tab(current) and vim.api.nvim_get_current_tabpage() ~= current then
    vim.api.nvim_set_current_tabpage(current)
  end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2)
end

function M.close_tab(tab, force)
  if not M.valid_tab(tab) then return true end
  if type(vim.api.nvim_tabpage_close) == "function" then
    local ok = pcall(vim.api.nvim_tabpage_close, tab, force == true)
    return ok and not M.valid_tab(tab)
  end
  if #vim.api.nvim_list_tabpages() == 1 then return false end
  local number = vim.api.nvim_tabpage_get_number(tab)
  local command = force and "tabclose! " or "tabclose "
  local ok = pcall(vim.cmd, command .. number)
  return ok and not M.valid_tab(tab)
end

function M.editor_geometry()
  return {
    row = 0,
    col = 0,
    width = math.max(1, vim.o.columns),
    height = math.max(1, vim.o.lines - vim.o.cmdheight),
  }
end

function M.largest_window(excluded)
  local selected, area
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.valid_window(window) and not (excluded and excluded[window]) then
      local config = vim.api.nvim_win_get_config(window)
      local buffer = vim.api.nvim_win_get_buf(window)
      if config.relative == ""
          and get_option("buftype", { buf = buffer }) == "" then
        local geometry = M.window_geometry(window)
        local current = geometry.width * geometry.height
        if not area or current > area then selected, area = window, current end
      end
    end
  end
  if not selected then return { available = false } end
  local result = M.window_geometry(selected)
  result.available = true
  return result
end

function M.environment(host, origin, applet, reopening)
  local editor = M.editor_geometry()
  local container = host.kind == "floating" and host.container ~= "editor"
      and M.largest_window(applet and applet._windows)
    or editor
  local origin_geometry = origin and M.valid_window(origin.window)
      and M.window_geometry(origin.window) or nil
  return {
    editor = editor,
    container = container,
    origin = origin_geometry and {
      available = true,
      row = origin_geometry.row,
      col = origin_geometry.col,
      width = origin_geometry.width,
      height = origin_geometry.height,
    } or { available = false },
    reopening = reopening == true,
  }
end

local function merged_window_options(record, descriptor, kind)
  local result = util.copy(descriptor.window.options)
  for option, value in pairs(descriptor.window.host_options[kind] or {}) do
    result[option] = value
  end
  for option, value in pairs(record.adopted_window_options or {}) do
    result[option] = value
  end
  return result
end

function M.surface(applet, driver, record)
  local kind = record.descriptor.projection.kind == "split" and "split" or "floating"
  record.chrome = chrome.new(record, kind)
  record.chrome_kind = kind
  local surface = {
    buffer = record.buffer,
    owns_buffer = false,
    domain = applet.domain,
    buffer_options = {},
    window_options = merged_window_options(record, record.descriptor,
      driver.kind == "tab" and "tab" or "floating"),
    window = function()
      return M.window_displays(record.window, record.buffer) and record.window or nil
    end,
    visible = function() return driver:pane_visible(record) end,
    on_commit = function(info) applet:_content_committed(record, info) end,
    chrome = record.chrome,
  }
  surface.interaction = applet:_surface_interaction(record)
  record.surface = surface
  return surface
end

function M.update_surface(applet, driver, record)
  local surface = record.surface
  if not surface then return M.surface(applet, driver, record) end
  local kind = record.descriptor.projection.kind == "split" and "split" or "floating"
  if record.chrome_kind ~= kind then
    if record.chrome then record.chrome.restore() end
    record.chrome = chrome.new(record, kind)
    record.chrome_kind = kind
    surface.chrome = record.chrome
  end
  surface.window_options = merged_window_options(record, record.descriptor,
    driver.kind == "tab" and "tab" or "floating")
  local interaction = applet:_surface_interaction(record)
  surface.interaction = interaction
  surface.on_commit = function(info) applet:_content_committed(record, info) end
  record.descriptor.pane:_connect(surface)
  record.descriptor.pane:set_surface_interaction(interaction)
  return surface
end

local function resolved_mode(record)
  local mode = record.descriptor.focus.mode
  if mode == "preserve" then mode = record.mode or "normal" end
  return mode
end

function M.apply_mode(record, confirm)
  local window = record.window
  if not M.window_displays(window, record.buffer)
      or vim.api.nvim_get_current_win() ~= window then return false end
  local mode = resolved_mode(record)
  Mode.apply(mode)
  record.mode = mode
  if confirm ~= false then
    vim.defer_fn(function()
      if M.window_displays(record.window, record.buffer)
          and vim.api.nvim_get_current_win() == record.window then
        M.apply_mode(record, false)
      end
    end, 1)
  end
  return true
end

function M.focus_mode(record)
  local descriptor = record.descriptor
  local window = record.window
  if not M.window_displays(window, record.buffer) then return false end
  vim.api.nvim_set_current_win(window)
  if descriptor.focus.cursor == "start" then
    pcall(vim.api.nvim_win_set_cursor, window, { 1, 0 })
  elseif descriptor.focus.cursor == "end" then
    local count = vim.api.nvim_buf_line_count(record.buffer)
    local line = vim.api.nvim_buf_get_lines(record.buffer, count - 1, count, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, window, { count, #line })
  end
  return M.apply_mode(record)
end

function M.buffer_text(record)
  if not M.loaded_buffer(record.buffer) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(record.buffer, 0, -1, false), "\n")
end

function M.replace_text(record, text, cursor)
  assert(M.loaded_buffer(record.buffer), "Pane buffer is unavailable")
  local modifiable = get_option("modifiable", { buf = record.buffer })
  if not modifiable then set_option("modifiable", true, { buf = record.buffer }) end
  vim.api.nvim_buf_set_lines(record.buffer, 0, -1, false,
    vim.split(text or "", "\n", { plain = true }))
  if not modifiable then set_option("modifiable", false, { buf = record.buffer }) end
  if cursor then M.set_cursor(record, cursor) end
  return true
end

function M.cursor(record)
  if M.window_displays(record.window, record.buffer) then
    local value = vim.api.nvim_win_get_cursor(record.window)
    return { line = value[1], column = value[2] }
  end
  if record.cursor then return { line = record.cursor[1], column = record.cursor[2] } end
  return { line = 1, column = 0 }
end

function M.set_cursor(record, cursor)
  assert(type(cursor) == "table" and type(cursor.line) == "number"
      and type(cursor.column) == "number", "cursor must contain line and column")
  record.cursor = { cursor.line, cursor.column }
  if M.window_displays(record.window, record.buffer) then
    pcall(vim.api.nvim_win_set_cursor, record.window, record.cursor)
  end
  return true
end

function M.move_cursor(record, direction, count)
  local cursor = M.cursor(record)
  count = math.max(1, math.floor(tonumber(count) or 1))
  if direction == "up" or direction == "previous" then
    cursor.line = math.max(1, cursor.line - count)
  elseif direction == "down" or direction == "next" then
    local lines = M.loaded_buffer(record.buffer)
      and vim.api.nvim_buf_line_count(record.buffer) or cursor.line
    cursor.line = math.min(lines, cursor.line + count)
  elseif direction == "start" then
    cursor.line, cursor.column = 1, 0
  elseif direction == "end" then
    cursor.line = M.loaded_buffer(record.buffer)
      and vim.api.nvim_buf_line_count(record.buffer) or cursor.line
    local line = M.loaded_buffer(record.buffer)
      and vim.api.nvim_buf_get_lines(record.buffer, cursor.line - 1, cursor.line, false)[1]
      or ""
    cursor.column = #line
  else
    error("cursor direction must be up, down, previous, next, start, or end", 2)
  end
  return M.set_cursor(record, cursor)
end

function M.scroll(record, opts)
  if not M.window_displays(record.window, record.buffer) then return false end
  opts = opts or {}
  local scrolled = vim.api.nvim_win_call(record.window, function()
    if opts.target == "end" then
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(record.buffer), 0 })
    elseif opts.target == "start" then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
    end
    if opts.align == "bottom" then vim.cmd("normal! zb")
    elseif opts.align == "center" then vim.cmd("normal! zz")
    elseif opts.align == "top" then vim.cmd("normal! zt") end
    return true
  end)
  if scrolled then M.save_view(record) end
  return scrolled
end

function M.completion_visible()
  return vim.fn.pumvisible() == 1
end

local function feed(record, keys)
  if not M.window_displays(record.window, record.buffer) then return false end
  vim.api.nvim_set_current_win(record.window)
  vim.api.nvim_feedkeys(vim.keycode(keys), "in", false)
  return true
end

function M.complete(record)
  return feed(record, "<C-x><C-f>")
end

function M.completion_move(record, direction)
  return feed(record, direction == "previous" and "<C-p>" or "<C-n>")
end

function M.completion_accept(record)
  return feed(record, "<C-y>")
end

function M.pass(record, event)
  local binding = event.binding
  if not binding or not M.window_displays(record.window, record.buffer) then return false end
  vim.api.nvim_set_current_win(record.window)
  local flags = binding.mode:sub(1, 1) == "i" and "in" or "n"
  vim.api.nvim_feedkeys(vim.keycode(binding.lhs), flags, false)
  return true
end

function M.measure(record)
  if not M.window_displays(record.window, record.buffer) then return nil end
  local count = vim.api.nvim_buf_line_count(record.buffer)
  local screen_lines = count
  if type(vim.api.nvim_win_text_height) == "function" then
    local ok, measured = pcall(vim.api.nvim_win_text_height, record.window, {})
    if ok and measured then screen_lines = measured.all or measured.fill or count end
  end
  return {
    content_lines = count,
    screen_lines = math.max(1, screen_lines),
    chrome = record.chrome and record.chrome.measure() or {
      top = 0, right = 0, bottom = 0, left = 0,
    },
  }
end

function M.default_notify(message, level)
  return vim.notify(message, level)
end

function M.default_open_uri(uri)
  if vim.ui and type(vim.ui.open) == "function" then return vim.ui.open(uri) end
  error("URI opening is unavailable", 2)
end

function M.new_augroup(name)
  sequence = sequence + 1
  return vim.api.nvim_create_augroup(
    "Applet" .. name:gsub("[^%w]", "") .. sequence,
    { clear = true })
end

local buffer_events = {
  BufWinLeave = true,
  BufWinEnter = true,
  BufUnload = true,
  BufDelete = true,
  BufWipeout = true,
}

local function tracked_buffer(applet, buffer)
  if not buffer or buffer == 0 then return false end
  for _, record in pairs(applet.records) do
    applet.counters.observer_record_scans =
      applet.counters.observer_record_scans + 1
    if record.buffer == buffer then return true end
  end
  return false
end

local function observer_relevant(applet, event, native)
  if applet.lifecycle == "destroyed" or applet.mutating then return false end
  local open = applet.lifecycle ~= "closed"
  if buffer_events[event.event] then
    return tracked_buffer(applet, event.buf)
      or open and native.window and applet._windows[native.window] ~= nil
  end
  if not open then return false end
  -- OptionSet does not identify the target window when an API call changes a
  -- non-current window-local option. Inspect the bounded Applet snapshot
  -- and let fact equality discard unrelated option events.
  if event.event == "OptionSet" then return true end
  if event.event == "ModeChanged" or event.event == "WinScrolled" then
    return tracked_buffer(applet, event.buf)
      or native.window and applet._windows[native.window] ~= nil
  end
  local driver = applet.driver
  local function host_window(window)
    return driver and M.valid_window(window) and M.valid_tab(driver.tab)
      and vim.api.nvim_win_get_tabpage(window) == driver.tab
  end
  local function relevant_window(window)
    return window ~= nil and (applet._windows[window] ~= nil
      or host_window(window))
  end
  if event.event == "VimResized" then return true end
  if event.event == "TabClosed" then
    return driver ~= nil and not driver:is_open()
  end
  if event.event == "TabEnter" or event.event == "TabLeave" then
    return driver ~= nil
      and applet.observed_snapshot.host.visible ~= driver:is_visible()
  end
  if event.event == "WinResized" then
    return driver ~= nil and M.valid_tab(driver.tab)
      and vim.api.nvim_get_current_tabpage() == driver.tab
  end
  local matched_window = tonumber(event.match)
  if relevant_window(matched_window) or relevant_window(native.window) then
    return true
  end
  return false
end

local function layout_leaf(applet, window)
  local key = applet._windows[window]
  local record = key and applet.records[key]
  if record and record.window == window and M.window_displays(window, record.buffer) then
    return { kind = "pane", key = key }
  end
  return { kind = "foreign" }
end

local function semantic_layout(applet, driver, frame)
  if driver.kind == "floating" then
    return { kind = "floating", container = util.copy(frame.plan.container) }
  end
  if not M.valid_tab(driver.tab) then return { kind = "closed" } end
  local tab_number = vim.api.nvim_tabpage_get_number(driver.tab)
  local native = vim.fn.winlayout(tab_number)
  local function convert(value)
    if value[1] == "leaf" then return layout_leaf(applet, value[2]) end
    local children = {}
    for _, child in ipairs(value[2] or {}) do children[#children + 1] = convert(child) end
    return {
      kind = "split",
      axis = value[1] == "col" and "vertical" or "horizontal",
      children = children,
    }
  end
  return convert(native)
end

local function snapshot_options(record, mounted)
  local buffer_options, window_options = {}, {}
  if M.loaded_buffer(record.buffer) then
    for option in pairs(record.requested_buffer_options or {}) do
      buffer_options[option] = get_option(option, { buf = record.buffer })
    end
  end
  if mounted then
    local desired = record.surface and record.surface.window_options or {}
    for option in pairs(desired) do
      window_options[option] = get_option(option, { win = record.window })
    end
  end
  return buffer_options, window_options
end

function M.snapshot(driver, records, frame, revision, request_generation)
  local current_tab = vim.api.nvim_get_current_tabpage()
  local current_window = vim.api.nvim_get_current_win()
  local applet = driver.applet
  local result = {
    revision = revision or 0,
    request_generation = request_generation or 0,
    host = { kind = driver.kind, open = driver:is_open(), visible = driver:is_visible() },
    layout = semantic_layout(applet, driver, frame),
    panes = {},
    focused_pane = nil,
    foreign_windows = driver.foreign_windows and driver:foreign_windows() or 0,
  }
  local ordered, included = {}, {}
  for _, key in ipairs(frame and frame.pane_order or {}) do
    ordered[#ordered + 1], included[key] = key, true
  end
  for _, key in ipairs(sorted_keys(records)) do
    if not included[key] then ordered[#ordered + 1] = key end
  end
  for _, key in ipairs(ordered) do
    local record = records[key]
    local buffer = record and record.buffer
    local mounted = record and M.window_displays(record.window, buffer)
      and driver:owns_window(record.window, record) or false
    local displayed = #M.buffer_windows(buffer) > 0
    local buffer_options, window_options = snapshot_options(record, mounted)
    local pane = {
      mounted = mounted == true,
      visible = mounted == true and driver:pane_visible(record) or false,
      buffer = {
        ownership = record and record.owns_buffer and "owned" or "none",
        loaded = M.loaded_buffer(buffer),
        displayed = displayed,
      },
      buffer_options = buffer_options,
      window_options = window_options,
    }
    if record and record.detach_reason then pane.detach_reason = record.detach_reason end
    if mounted then
      pane.geometry = M.window_geometry(record.window)
      pane.view = M.window_view(record.window)
      pane.mode = current_tab == vim.api.nvim_win_get_tabpage(record.window)
          and current_window == record.window
          and Mode.semantic()
        or record.mode or "normal"
      if current_window == record.window then result.focused_pane = key end
    else
      pane.mode = record and record.mode or nil
    end
    result.panes[key] = pane
  end
  return result
end

function M.install_observers(applet, scope)
  assert(scope == "live" or scope == "retained",
    "Applet observer scope must be live or retained")
  M.clear_observers(applet)
  local group = M.new_augroup(applet.name)
  applet.augroup = group
  local events = scope == "live" and {
    "WinResized", "VimResized", "WinScrolled", "WinNew", "WinClosed",
    "BufWinLeave", "BufWinEnter", "BufUnload", "BufDelete", "BufWipeout",
    "TabEnter", "TabLeave", "TabClosed", "WinEnter", "WinLeave",
    "ModeChanged", "OptionSet",
  } or { "BufUnload", "BufDelete", "BufWipeout" }
  local function observe(event)
    applet.counters.observer_callbacks = applet.counters.observer_callbacks + 1
    local native = { event = event.event, buffer = event.buf, match = event.match }
    if M.valid_window(vim.api.nvim_get_current_win()) then
      native.window = vim.api.nvim_get_current_win()
      native.tab = vim.api.nvim_win_get_tabpage(native.window)
    end
    if not observer_relevant(applet, event, native) then return end
    applet.counters.observer_relevant_callbacks =
      applet.counters.observer_relevant_callbacks + 1
    applet:_schedule_observe(event.event, native)
  end
  local installed, install_error = pcall(function()
    if scope == "live" then
      vim.api.nvim_create_autocmd(events, { group = group, callback = observe })
    else
      local buffers = {}
      for _, record in pairs(applet.records) do
        if M.loaded_buffer(record.buffer) and not buffers[record.buffer] then
          buffers[record.buffer] = true
          vim.api.nvim_create_autocmd(events, {
            group = group,
            buffer = record.buffer,
            callback = observe,
          })
        end
      end
    end
  end)
  if not installed then
    M.clear_observers(applet)
    error(install_error, 0)
  end
  applet.observer_scope = scope
  return group
end

function M.clear_observers(applet)
  if applet.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, applet.augroup)
  end
  applet.augroup = nil
  applet.observer_scope = nil
end

return M
