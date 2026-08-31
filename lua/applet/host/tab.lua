local base = require("applet.host.base")
local util = require("applet.util")

local Driver = {}
Driver.__index = Driver

local function first_pane(topology)
  if topology.type == "pane" then return topology.key end
  for _, child in ipairs(topology.children or {}) do
    local key = first_pane(child.child)
    if key then return key end
  end
end

local function structure(topology)
  if topology.type == "pane" then return "pane:" .. topology.key end
  local result = { "split:", topology.key, ":", topology.axis }
  for _, child in ipairs(topology.children or {}) do
    result[#result + 1] = ":" .. child.key .. "[" .. structure(child.child) .. "]"
  end
  return table.concat(result)
end

local function projected_topology(topology, records)
  if topology.type == "pane" then
    local record = records[topology.key]
    if not record or record.suppressed
        or record.descriptor.projection.kind ~= "split" then return nil end
    return topology
  end
  if topology.type == "scope" then return projected_topology(topology.child, records) end
  local children = {}
  for _, child in ipairs(topology.children or {}) do
    local projected = projected_topology(child.child, records)
    if projected then
      local copy = util.copy(child)
      copy.child = projected
      children[#children + 1] = copy
    end
  end
  if #children == 0 then return nil end
  if #children == 1 then return children[1].child end
  local result = util.copy(topology)
  result.children = children
  return result
end

local function layer_config(record)
  local requested = record.descriptor.projection.config
  if not util.equal(record.requested_float_config, requested) then
    record.requested_float_config = util.copy(requested)
    record.adopted_float_config = nil
  end
  return util.copy(record.adopted_float_config or requested)
end

function Driver.new(applet, origin)
  local self = setmetatable({
    kind = "tab",
    applet = applet,
    origin = origin,
    tab = nil,
    published = false,
    released = false,
    structure = nil,
  }, Driver)
  return self
end

function Driver:begin(records)
  assert(not self.transaction, "tab Host transaction is already active")
  local windows = {}
  for key, record in pairs(records) do
    if self:owns_window(record.window, record)
        and base.window_displays(record.window, record.buffer) then
      windows[key] = {
        record = record,
        window = record.window,
        config = vim.api.nvim_win_get_config(record.window),
        width = vim.api.nvim_win_get_width(record.window),
        height = vim.api.nvim_win_get_height(record.window),
      }
    end
  end
  self.transaction = { windows = windows }
  self.staging = true
  return true
end

function Driver:is_open()
  return not self.released and base.valid_tab(self.tab)
end

function Driver:is_visible()
  return self.published and self:is_open()
    and vim.api.nvim_get_current_tabpage() == self.tab
end

function Driver:pane_visible(record)
  if not self:is_visible() or not base.valid_window(record.window) then return false end
  local config = vim.api.nvim_win_get_config(record.window)
  return not config.hide and vim.api.nvim_win_get_buf(record.window) == record.buffer
end

function Driver:owns_window(window, record)
  return base.valid_window(window) and base.valid_tab(self.tab)
    and vim.api.nvim_win_get_tabpage(window) == self.tab
    and self.applet._windows[window] == (record and record.key)
end

function Driver:foreign_windows()
  if not base.valid_tab(self.tab) then return 0 end
  local count = 0
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(self.tab)) do
    if not self.applet._windows[window] then count = count + 1 end
  end
  return count
end

function Driver:_mark(record, window)
  record.window = window
  self.applet._windows[window] = record.key
end

function Driver:_forget(record)
  local window = record.window
  record.window = nil
  if window then self.applet._windows[window] = nil end
end

function Driver:_create_tab(frame, records)
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local origin_number = vim.api.nvim_tabpage_get_number(origin_tab)
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local root = vim.api.nvim_get_current_win()
  local temporary = vim.api.nvim_win_get_buf(root)
  self.tab = tab
  local position = frame.host.position
  if position == "first" then
    vim.cmd("tabmove 0")
  elseif position == "last" then
    vim.cmd("tabmove")
  elseif position == "before" then
    vim.cmd("tabmove " .. math.max(0, origin_number - 1))
  end
  pcall(vim.api.nvim_tabpage_set_var, tab,
    "applet_label", frame.host.label)
  if base.valid_tab(origin_tab) then vim.api.nvim_set_current_tabpage(origin_tab) end
  base.with_tab(tab, function()
    local topology = assert(projected_topology(frame.topology, records),
      "tab Host requires one mounted main Pane")
    self:_build_topology(topology, root, records)
    self:_open_layers(frame, records)
    self:_apply_sizes(topology)
  end)
  if base.valid_buffer(temporary) then
    local displayed = false
    for _, window in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(window) == temporary then displayed = true break end
    end
    if not displayed then pcall(vim.api.nvim_buf_delete, temporary, { force = true }) end
  end
  self.applet.counters.tab_opens = self.applet.counters.tab_opens + 1
  self.applet.counters.topology_rebuilds =
    self.applet.counters.topology_rebuilds + 1
end

function Driver:_build_topology(topology, target, records)
  if topology.type == "pane" then
    local record = assert(records[topology.key])
    vim.api.nvim_win_set_buf(target, record.buffer)
    self:_mark(record, target)
    return target
  end
  local windows = { target }
  local split = topology.axis == "vertical" and "below" or "right"
  for index = 2, #topology.children do
    local key = assert(first_pane(topology.children[index].child))
    local record = assert(records[key])
    windows[index] = vim.api.nvim_open_win(record.buffer, false, {
      split = split,
      win = windows[index - 1],
    })
    self.applet.counters.window_opens = self.applet.counters.window_opens + 1
  end
  for index, child in ipairs(topology.children) do
    self:_build_topology(child.child, windows[index], records)
  end
  return windows[1]
end

function Driver:_apply_sizes(topology)
  if topology.type == "pane" then return end
  for _, child in ipairs(topology.children) do
    local key = first_pane(child.child)
    local record = self.applet.records[key]
    if record and base.valid_window(record.window) then
      if topology.axis == "vertical" then
        pcall(vim.api.nvim_win_set_height, record.window, child.size)
      else
        pcall(vim.api.nvim_win_set_width, record.window, child.size)
      end
      self.applet.counters.split_size_changes =
        self.applet.counters.split_size_changes + 1
    end
    self:_apply_sizes(child.child)
  end
end

function Driver:_open_layers(frame, records)
  for _, key in ipairs(frame.pane_order) do
    local record = records[key]
    if record and record.descriptor.projection.kind == "floating"
        and not record.suppressed then
      local config = layer_config(record)
      if not self.published or self.staging then config.hide = true end
      local window = vim.api.nvim_open_win(record.buffer, false, config)
      self:_mark(record, window)
      self.applet.counters.window_opens = self.applet.counters.window_opens + 1
    end
  end
end

function Driver:publish(_, records)
  assert(self:is_open(), "tab Host is closed")
  local was_published = self.published
  self.published = true
  base.with_tab(self.tab, function()
    for _, record in pairs(records) do
      if record.active and not record.suppressed
          and record.descriptor.projection.kind == "floating"
          and base.window_displays(record.window, record.buffer) then
        local config = layer_config(record)
        config.hide = false
        if not base.same_float_config(record.window, config) then
          vim.api.nvim_win_set_config(record.window, config)
        end
      end
    end
  end)
  local shadow = self.pending_shadow
  if shadow then
    for key, window in pairs(shadow.old_windows) do
      if self.applet._windows[window] == key then
        self.applet._windows[window] = nil
      end
    end
    if shadow.was_visible and base.valid_tab(self.tab) then
      vim.api.nvim_set_current_tabpage(self.tab)
    elseif base.valid_tab(shadow.previous_tab) then
      vim.api.nvim_set_current_tabpage(shadow.previous_tab)
    end
    if base.valid_tab(shadow.old_tab) then base.close_tab(shadow.old_tab, true) end
    self.applet.counters.tab_closes = self.applet.counters.tab_closes + 1
    self.pending_shadow = nil
  elseif not was_published and vim.api.nvim_get_current_tabpage() ~= self.tab then
    vim.api.nvim_set_current_tabpage(self.tab)
  end
  local transaction = self.transaction
  if transaction and not shadow then
    for key, saved in pairs(transaction.windows) do
      local record = records[key]
      if not record or not record.active or record.window ~= saved.window then
        if self.applet._windows[saved.window] == key then
          self.applet._windows[saved.window] = nil
        end
        if base.valid_window(saved.window) then
          pcall(vim.api.nvim_win_close, saved.window, true)
          self.applet.counters.window_closes =
            self.applet.counters.window_closes + 1
        end
      end
    end
  end
  self.transaction = nil
  self.staging = false
  return true
end

function Driver:_close_window(record)
  local window = record.window
  self:_forget(record)
  if base.valid_window(window) then
    pcall(vim.api.nvim_win_close, window, true)
    self.applet.counters.window_closes = self.applet.counters.window_closes + 1
  end
end

function Driver:_close_owned_windows(records, floats_only)
  for _, record in pairs(records) do
    if record.window and (not floats_only
        or record.descriptor.projection.kind == "floating") then
      self:_close_window(record)
    end
  end
end

function Driver:_rebuild(frame, records)
  assert(not self.pending_shadow, "tab Host already has a staged topology")
  if self:foreign_windows() > 0 then
    error("tab Host topology cannot replace a tab containing foreign windows", 0)
  end
  for _, record in pairs(records) do base.save_view(record) end
  local old_tab = self.tab
  local previous_tab = vim.api.nvim_get_current_tabpage()
  local old_windows = {}
  for key, record in pairs(records) do old_windows[key] = record.window end
  local old_structure = self.structure

  vim.cmd("tabnew")
  local staging_tab = vim.api.nvim_get_current_tabpage()
  local root = vim.api.nvim_get_current_win()
  local temporary = vim.api.nvim_win_get_buf(root)
  pcall(vim.api.nvim_tabpage_set_var, staging_tab,
    "applet_label", frame.host.label)
  if base.valid_tab(previous_tab) then vim.api.nvim_set_current_tabpage(previous_tab) end

  self.tab = staging_tab
  for _, record in pairs(records) do record.window = nil end
  local built, build_error = pcall(function()
    base.with_tab(staging_tab, function()
      local topology = assert(projected_topology(frame.topology, records),
        "tab Host requires one mounted main Pane")
      self:_build_topology(topology, root, records)
      self:_open_layers(frame, records)
      self:_apply_sizes(topology)
    end)
  end)
  if not built then
    for _, record in pairs(records) do
      if record.window then self.applet._windows[record.window] = nil end
    end
    if base.valid_tab(staging_tab) then
      base.close_tab(staging_tab, true)
    end
    self.tab = old_tab
    for key, window in pairs(old_windows) do
      records[key].window = window
      if base.valid_window(window) then self.applet._windows[window] = key end
    end
    if base.valid_tab(previous_tab) then
      pcall(vim.api.nvim_set_current_tabpage, previous_tab)
    end
    error(build_error, 0)
  end

  if base.valid_buffer(temporary) and #base.buffer_windows(temporary) == 0 then
    pcall(vim.api.nvim_buf_delete, temporary, { force = true })
  end
  self.pending_shadow = {
    old_tab = old_tab,
    old_windows = old_windows,
    old_structure = old_structure,
    previous_tab = previous_tab,
    was_visible = previous_tab == old_tab,
  }
  self.applet.counters.tab_opens = self.applet.counters.tab_opens + 1
  self.applet.counters.topology_rebuilds =
    self.applet.counters.topology_rebuilds + 1
end

function Driver:rollback(records)
  local shadow = self.pending_shadow
  if shadow then
    local staging_tab = self.tab
    for _, record in pairs(records) do
      if record.window and self.applet._windows[record.window] == record.key then
        self.applet._windows[record.window] = nil
      end
    end
    if base.valid_tab(staging_tab) then base.close_tab(staging_tab, true) end
    self.tab = shadow.old_tab
    self.structure = shadow.old_structure
    for key, window in pairs(shadow.old_windows) do
      local saved = self.transaction and self.transaction.windows[key]
      local record = records[key]
      if record and (not saved or record ~= saved.record) then record.window = nil end
      if saved then saved.record.window = window end
      if base.valid_window(window) then self.applet._windows[window] = key end
    end
    if base.valid_tab(shadow.previous_tab) then
      vim.api.nvim_set_current_tabpage(shadow.previous_tab)
    end
    self.pending_shadow = nil
  end
  local transaction = self.transaction
  if transaction then
    local retained = {}
    for _, saved in pairs(transaction.windows) do retained[saved.window] = true end
    for window, key in pairs(util.copy(self.applet._windows)) do
      if base.valid_window(window)
          and vim.api.nvim_win_get_tabpage(window) == self.tab
          and not retained[window] then
        self.applet._windows[window] = nil
        local config = vim.api.nvim_win_get_config(window)
        if config.relative ~= "" then pcall(vim.api.nvim_win_close, window, true) end
        local record = records[key]
        if record and record.window == window then record.window = nil end
      end
    end
    for key, saved in pairs(transaction.windows) do
      local record = records[key]
      if record and record ~= saved.record then record.window = nil end
      if base.valid_window(saved.window) then
        if saved.config.relative ~= "" then
          pcall(vim.api.nvim_win_set_config, saved.window, saved.config)
        else
          pcall(vim.api.nvim_win_set_width, saved.window, saved.width)
          pcall(vim.api.nvim_win_set_height, saved.window, saved.height)
        end
        self.applet._windows[saved.window] = key
        saved.record.window = saved.window
      end
    end
  end
  self.transaction = nil
  self.staging = false
  return true
end

function Driver:reconcile(previous, frame, records)
  local topology = assert(projected_topology(frame.topology, records),
    "tab Host requires one mounted main Pane")
  if not self.tab then
    self:_create_tab(frame, records)
    self.structure = structure(topology)
    return true
  end
  assert(self:is_open(), "tab Host is closed")
  pcall(vim.api.nvim_tabpage_set_var, self.tab,
    "applet_label", frame.host.label)
  local next_structure = structure(topology)
  local missing_main = false
  for _, key in ipairs(frame.pane_order) do
    local record = records[key]
    if record and record.descriptor.projection.kind == "split"
        and not record.suppressed
        and not base.window_displays(record.window, record.buffer) then
      missing_main = true
      break
    end
  end
  if self.structure ~= next_structure or missing_main then
    self:_rebuild(frame, records)
    self.structure = next_structure
    return true
  end
  base.with_tab(self.tab, function()
    local desired = {}
    for _, key in ipairs(frame.pane_order) do desired[key] = true end
    for key, record in pairs(records) do
      if record.window and not desired[key] then
        local saved = assert(self.transaction and self.transaction.windows[key],
          "removed tab Pane must belong to the active transaction")
        assert(saved.window == record.window
          and record.descriptor.projection.kind == "floating",
          "only floating tab Panes can leave without rebuilding topology")
        local config = vim.api.nvim_win_get_config(record.window)
        config.hide = true
        vim.api.nvim_win_set_config(record.window, config)
      end
    end
    for _, key in ipairs(frame.pane_order) do
      local record = records[key]
      if record and record.descriptor.projection.kind == "floating"
          and not record.suppressed then
        if not base.valid_window(record.window) then
          local config = layer_config(record)
          if self.staging then config.hide = true end
          local window = vim.api.nvim_open_win(record.buffer, false, config)
          self:_mark(record, window)
        else
          local config = layer_config(record)
          if self.staging then config.hide = true end
          if not base.same_float_config(record.window, config) then
            vim.api.nvim_win_set_config(record.window, config)
            self.applet.counters.window_config_changes =
              self.applet.counters.window_config_changes + 1
          end
        end
      end
    end
    local sizing_changed = not previous
    if previous then
      for _, split_key in ipairs(frame.split_order) do
        local before, after = previous.splits[split_key], frame.splits[split_key]
        if not before or before.signature ~= after.signature then sizing_changed = true break end
      end
    end
    if sizing_changed then self:_apply_sizes(topology) end
  end)
  return true
end

function Driver:adopt_detach(frame, records)
  local topology = frame and projected_topology(frame.topology, records)
  self.structure = topology and structure(topology) or nil
end

function Driver:focus(record)
  assert(self:is_open() and record and base.valid_window(record.window),
    "tab Host focus requires an open mounted Pane")
  if vim.api.nvim_get_current_tabpage() ~= self.tab then
    vim.api.nvim_set_current_tabpage(self.tab)
  end
  return base.focus_mode(record)
end

function Driver:detach(record)
  self:_close_window(record)
end

function Driver:release(records)
  if self.released then return end
  if self.pending_shadow or self.transaction then self:rollback(records) end
  self.released = true
  self.published = false
  local tab = self.tab
  self:_close_owned_windows(records, true)
  if base.valid_tab(tab) then
    local foreign = self:foreign_windows()
    if foreign == 0 then
      local tabs = vim.api.nvim_list_tabpages()
      if #tabs == 1 then
        vim.cmd("tabnew")
      elseif vim.api.nvim_get_current_tabpage() == tab
          and self.origin and base.valid_tab(self.origin.tab) then
        vim.api.nvim_set_current_tabpage(self.origin.tab)
      end
      for _, record in pairs(records) do
        if record.window then self:_forget(record) end
      end
      base.close_tab(tab, true)
      self.applet.counters.tab_closes = self.applet.counters.tab_closes + 1
    else
      self:_close_owned_windows(records, false)
      pcall(vim.api.nvim_tabpage_del_var, tab, "applet_label")
    end
  else
    for _, record in pairs(records) do self:_forget(record) end
  end
  self.tab = nil
end

function Driver:destroy(records)
  self:release(records)
end

return setmetatable({ new = Driver.new }, {
  __call = function(_, applet, origin) return Driver.new(applet, origin) end,
})
