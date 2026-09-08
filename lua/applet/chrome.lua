local util = require("applet.util")

local M = {}

---@class Applet.ChromeRun
---@field [1]? string
---@field [2]? string
---@field text? string
---@field group? string

---@class Applet.ChromeValue
---@field title? Applet.ChromeRun[]
---@field footer? Applet.ChromeRun[]
---@field title_pos? Applet.Alignment
---@field footer_pos? Applet.Alignment
---@field options? Applet.Options

---@class Applet.ChromeRecord
---@field window? integer
---@field descriptor {chrome: Applet.Insets}
---@field adopted_window_options? Applet.Options

---@class Applet.WrittenOption
---@field original? Applet.OptionValue
---@field written? Applet.OptionValue

---@class Applet.ChromeState
---@field window? integer
---@field options table<string, Applet.WrittenOption>
---@field config? vim.api.keyset.win_config
---@field written_config? vim.api.keyset.win_config
---@field metrics Applet.Insets

---@class Applet.WindowChrome
---@field kind "floating"|"split"
---@field apply fun(value: Applet.ChromeValue, window_options?: Applet.Options)
---@field measure fun(): Applet.Insets
---@field restore fun()


local copy_value = util.copy_value

---@param window? integer
---@return TypeGuard<integer>
local function valid_window(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

---@param runs? Applet.ChromeRun[]
---@return string
local function statusline(runs)
  local result = {}
  for _, run in ipairs(runs or {}) do
    local text, group = run[1] or run.text or "", run[2] or run.group
    if group and group ~= "" then result[#result + 1] = "%#" .. group .. "#" end
    result[#result + 1] = tostring(text):gsub("%%", "%%%%")
    if group and group ~= "" then result[#result + 1] = "%*" end
  end
  return table.concat(result)
end

---@param runs? Applet.ChromeRun[]
---@return string|[string, string?][]
local function float_runs(runs)
  if not runs or #runs == 0 then return "" end
  local result = {}
  for _, run in ipairs(runs) do
    result[#result + 1] = { run[1] or run.text or "", run[2] or run.group }
  end
  return result
end

---@param window integer
---@param option string
---@return Applet.OptionValue?
local function current_option(window, option)
  local ok, value = pcall(vim.api.nvim_get_option_value, option, { win = window })
  if ok then return value end
end

---@param window integer
---@param option string
---@param state Applet.WrittenOption
local function restore_option(window, option, state)
  local current = current_option(window, option)
  if current ~= nil and util.equal(current, state.written) then
    pcall(vim.api.nvim_set_option_value, option, state.original, { win = window })
  end
end

local config_fields = { "title", "title_pos", "footer", "footer_pos" }

---@param window integer
---@param original? vim.api.keyset.win_config
---@param written? vim.api.keyset.win_config
local function restore_config(window, original, written)
  if not original or not written then return end
  local ok, current = pcall(vim.api.nvim_win_get_config, window)
  if not ok then return end
  local changed = false
  for _, field in ipairs(config_fields) do
    if written[field] ~= nil and util.equal(current[field], written[field]) then
      local value = original[field]
      if value == nil and (field == "title" or field == "footer") then
        value = ""
      end
      current[field] = copy_value(value)
      changed = true
    end
  end
  if changed then pcall(vim.api.nvim_win_set_config, window, current) end
end

---@param record Applet.ChromeRecord
---@param kind "floating"|"split"
---@return Applet.WindowChrome
function M.new(record, kind)
  ---@type Applet.ChromeState
  local state = {
    window = nil,
    options = {},
    config = nil,
    written_config = nil,
    metrics = { top = 0, right = 0, bottom = 0, left = 0 },
  }

  local function restore()
    local window = state.window
    if valid_window(window) then
      for option, value in pairs(state.options) do
        restore_option(window, option, value)
      end
      if kind == "floating" then
        restore_config(window, state.config, state.written_config)
      end
    end
    state.window, state.options = nil, {}
    state.config, state.written_config = nil, nil
    state.metrics = { top = 0, right = 0, bottom = 0, left = 0 }
  end

  ---@param window integer
  local function capture(window)
    if state.window == window then return end
    restore()
    state.window = window
    if kind == "floating" then
      local config = vim.api.nvim_win_get_config(window)
      state.config = {}
      for _, field in ipairs(config_fields) do
        state.config[field] = copy_value(config[field])
      end
    end
  end

  ---@param value Applet.ChromeValue
  ---@param window_options? Applet.Options
  local function apply(value, window_options)
    local window = record.window
    if not valid_window(window) then return end
    capture(window)
    local desired = util.copy(window_options or {})
    for option, option_value in pairs(value.options or {}) do
      desired[option] = option_value
    end
    if kind == "split" then
      desired.winbar = statusline(value.title)
      desired.statusline = statusline(value.footer)
    end
    for option, option_state in pairs(util.copy(state.options)) do
      local adopted = record.adopted_window_options
        and record.adopted_window_options[option] ~= nil
        and (value.options or {})[option] == nil
      if adopted then
        state.options[option] = nil
      elseif desired[option] == nil then
        restore_option(window, option, option_state)
        state.options[option] = nil
      end
    end
    for option, option_value in pairs(desired) do
      local adopted = record.adopted_window_options
        and record.adopted_window_options[option] ~= nil
        and (value.options or {})[option] == nil
      if not adopted then
        local option_state = state.options[option]
        if not option_state then
          option_state = { original = current_option(window, option) }
          state.options[option] = option_state
        end
        if not util.equal(current_option(window, option), option_value) then
          pcall(vim.api.nvim_set_option_value, option, option_value, { win = window })
        end
        option_state.written = copy_value(option_value)
      end
    end
    if kind == "floating" then
      local config = vim.api.nvim_win_get_config(window)
      -- Capture populated the original configuration for this floating window.
      local original_config = state.config
      ---@cast original_config vim.api.keyset.win_config
      local previous = state.written_config or {}
      local written, changed = {}, false
      local title = value.title and #value.title > 0 and float_runs(value.title) or nil
      local footer = value.footer and #value.footer > 0 and float_runs(value.footer) or nil
      local requested = {
        title = title,
        title_pos = title and value.title_pos or nil,
        footer = footer,
        footer_pos = footer and value.footer_pos or nil,
      }
      for _, field in ipairs(config_fields) do
        local desired = requested[field]
        if desired ~= nil then
          config[field] = desired
          written[field] = copy_value(desired)
          changed = true
        elseif previous[field] ~= nil and util.equal(config[field], previous[field]) then
          local original = original_config[field]
          if original == nil and (field == "title" or field == "footer") then
            original = ""
          end
          config[field] = copy_value(original)
          changed = true
        end
      end
      if changed then vim.api.nvim_win_set_config(window, config) end
      state.written_config = written
      state.metrics = util.copy(record.descriptor.chrome)
    else
      state.metrics = {
        top = value.title and #value.title > 0 and 1 or 0,
        right = 0,
        bottom = value.footer and #value.footer > 0 and 1 or 0,
        left = 0,
      }
    end
  end

  return {
    kind = kind,
    apply = apply,
    measure = function() return util.copy(state.metrics) end,
    restore = restore,
  }
end

return M
