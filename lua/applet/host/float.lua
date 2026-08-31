local base = require("applet.host.base")
local util = require("applet.util")

local Driver = {}
Driver.__index = Driver

local function desired_config(record)
  local requested = record.descriptor.projection.config
  if not util.equal(record.requested_float_config, requested) then
    record.requested_float_config = util.copy(requested)
    record.adopted_float_config = nil
  end
  return util.copy(record.adopted_float_config or requested)
end

local function staged_config(record)
  local config = desired_config(record)
  config.hide = true
  return config
end

function Driver.new(applet, origin)
  local self = setmetatable({
    kind = "floating",
    applet = applet,
    tab = origin and origin.tab or vim.api.nvim_get_current_tabpage(),
    published = false,
    released = false,
  }, Driver)
  return self
end

function Driver:begin(records)
  assert(not self.transaction, "floating Host transaction is already active")
  local windows = {}
  for key, record in pairs(records) do
    if self:owns_window(record.window, record)
        and base.window_displays(record.window, record.buffer) then
      windows[key] = {
        record = record,
        window = record.window,
        config = vim.api.nvim_win_get_config(record.window),
      }
    end
  end
  self.transaction = { windows = windows }
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
  return base.valid_window(window)
    and self.applet._windows[window] == (record and record.key)
    and vim.api.nvim_win_get_tabpage(window) == self.tab
end

function Driver:foreign_windows()
  return 0
end

function Driver:_open(record)
  local config = self.published and not self.transaction
      and desired_config(record) or staged_config(record)
  local window = base.with_tab(self.tab, function()
    return vim.api.nvim_open_win(record.buffer, false, config)
  end)
  record.window = window
  self.applet._windows[window] = record.key
  self.applet.counters.window_opens = self.applet.counters.window_opens + 1
  return window
end

function Driver:publish(_, records)
  assert(self:is_open(), "floating Host is closed")
  self.published = true
  for _, record in pairs(records) do
    if record.active and not record.suppressed
        and base.window_displays(record.window, record.buffer) then
      local config = desired_config(record)
      config.hide = false
      if not base.same_float_config(record.window, config) then
        vim.api.nvim_win_set_config(record.window, config)
        self.applet.counters.window_config_changes =
          self.applet.counters.window_config_changes + 1
      end
    end
  end
  local transaction = self.transaction
  if transaction then
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
  return true
end

function Driver:rollback(records)
  local transaction = self.transaction
  if not transaction then return true end
  local retained = {}
  for key, saved in pairs(transaction.windows) do retained[saved.window] = key end
  for window, key in pairs(util.copy(self.applet._windows)) do
    if base.valid_window(window)
        and vim.api.nvim_win_get_tabpage(window) == self.tab
        and not retained[window] then
      self.applet._windows[window] = nil
      if base.valid_window(window) then pcall(vim.api.nvim_win_close, window, true) end
      local record = records[key]
      if record and record.window == window then record.window = nil end
    end
  end
  for key, saved in pairs(transaction.windows) do
    local record = records[key]
    if record and record ~= saved.record then record.window = nil end
    if base.valid_window(saved.window) then
      pcall(vim.api.nvim_win_set_config, saved.window, saved.config)
      self.applet._windows[saved.window] = key
      saved.record.window = saved.window
    end
  end
  self.transaction = nil
  return true
end

function Driver:_close(record)
  local window = record.window
  record.window = nil
  if window then self.applet._windows[window] = nil end
  if base.valid_window(window) then
    pcall(vim.api.nvim_win_close, window, true)
    self.applet.counters.window_closes = self.applet.counters.window_closes + 1
  end
end

function Driver:reconcile(_, frame, records)
  assert(self:is_open(), "floating Host is closed")
  local desired = {}
  for _, key in ipairs(frame.pane_order) do
    local record = records[key]
    if record and not record.suppressed then desired[key] = true end
  end
  for key, record in pairs(records) do
    if record.window and not desired[key] then
      base.save_view(record)
      local saved = self.transaction and self.transaction.windows[key]
      if saved and saved.window == record.window then
        local config = vim.api.nvim_win_get_config(record.window)
        config.hide = true
        vim.api.nvim_win_set_config(record.window, config)
      else
        self:_close(record)
      end
    end
  end
  for _, key in ipairs(frame.pane_order) do
    local record = records[key]
    if record and desired[key] then
      local window = record.window
      if base.valid_window(window)
          and vim.api.nvim_win_get_buf(window) ~= record.buffer then
        self.applet._windows[window] = nil
        record.window = nil
        window = nil
      end
      if not base.valid_window(window) then
        self:_open(record)
      else
        local config = self.transaction and staged_config(record)
          or desired_config(record)
        if not base.same_float_config(window, config) then
          vim.api.nvim_win_set_config(window, config)
          self.applet.counters.window_config_changes =
            self.applet.counters.window_config_changes + 1
        end
      end
    end
  end
  return true
end

function Driver:focus(record)
  if not record or not self:pane_visible(record) then
    if base.valid_tab(self.tab) and vim.api.nvim_get_current_tabpage() ~= self.tab then
      vim.api.nvim_set_current_tabpage(self.tab)
    end
  end
  if not record or not base.valid_window(record.window) then return false end
  return base.focus_mode(record)
end

function Driver:detach(record)
  self:_close(record)
end

function Driver:release(records)
  if self.released then return end
  if self.transaction then self:rollback(records) end
  self.released = true
  self.published = false
  for _, record in pairs(records) do
    if record.window then self:_close(record) end
  end
end

function Driver:destroy(records)
  self:release(records)
end

return setmetatable({ new = Driver.new }, {
  __call = function(_, applet, origin) return Driver.new(applet, origin) end,
})
