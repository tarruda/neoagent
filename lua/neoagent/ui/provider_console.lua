local presentation = require("neoagent.ui.presentation")
local renderer_protocol = require("neoagent.ui.renderer")
local util = require("neoagent.util")

local M = {}

function M:_provider_width()
  if self.provider_win and vim.api.nvim_win_is_valid(self.provider_win) then
    return math.max(1, vim.api.nvim_win_get_width(self.provider_win) - 2)
  end
  return math.max(1, vim.o.columns - 4)
end

function M:_provider_content()
  if not self.provider_snapshot then return nil end
  local content, err = renderer_protocol.render_provider(
    self.renderer, self.provider_snapshot, {
      width = self:_provider_width(),
      surface = "panel",
    })
  if not content then
    return nil, err or util.error("ui",
      "Renderer does not support the provider console")
  end
  return content
end

function M:_ensure_provider_buffer()
  if self.provider_buf and vim.api.nvim_buf_is_valid(self.provider_buf) then
    return self.provider_buf
  end
  local buffer = vim.api.nvim_create_buf(false, true)
  self.provider_counter = (self.provider_counter or 0) + 1
  pcall(vim.api.nvim_buf_set_name, buffer,
    "neoagent-provider://" .. tostring(self.namespace)
      .. "/" .. self.provider_counter)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undofile = false
  vim.bo[buffer].filetype = "neoagent-provider"
  vim.bo[buffer].modifiable = false
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = self.augroup,
    buffer = buffer,
    callback = function() vim.cmd("stopinsert") end,
  })
  self.provider_buf = buffer
  return buffer
end

function M:_provider_rows()
  if not self.provider_targets then return {} end
  local rows = {}
  for row in pairs(self.provider_targets) do rows[#rows + 1] = row end
  table.sort(rows)
  return rows
end

function M:_provider_row()
  if not self.provider_win or not vim.api.nvim_win_is_valid(self.provider_win) then
    return nil
  end
  return vim.api.nvim_win_get_cursor(self.provider_win)[1] - 1
end

function M:_move_provider(direction, count)
  if not self.provider_win or not vim.api.nvim_win_is_valid(self.provider_win) then
    return false
  end
  count = math.max(1, math.floor(tonumber(count) or 1))
  local rows = self:_provider_rows()
  if #rows == 0 then return false end
  local moved = 0
  for _ = 1, count do
    local current = self:_provider_row()
    local target
    for _, row in ipairs(rows) do
      if direction < 0 and row < current then
        target = row
      elseif direction > 0 and row > current then
        target = row
        break
      end
    end
    if target == nil then
      if direction < 0 then target = rows[#rows] end
      if direction > 0 then target = rows[1] end
    end
    if target == nil then break end
    vim.api.nvim_win_set_cursor(self.provider_win, { target + 1, 0 })
    moved = moved + 1
  end
  return moved > 0
end

function M:_select_provider()
  if not self.provider_win or not vim.api.nvim_win_is_valid(self.provider_win) then
    return false
  end
  local row = self:_provider_row()
  local target = row and self.provider_targets and self.provider_targets[row]
  if not target then return false end
  self.on_provider_action(target.id, "")
  return true
end

local function clamped_view(saved, lines)
  local line_count = math.max(1, #lines)
  local restored = vim.tbl_extend("force", {}, saved)
  restored.lnum = math.max(1, math.min(line_count, saved.lnum or 1))
  restored.topline = math.max(1,
    math.min(line_count, saved.topline or restored.lnum))
  restored.col = math.max(0,
    math.min(#(lines[restored.lnum] or ""), saved.col or 0))
  return restored
end

function M:_refresh_provider(initial)
  if not self.provider_buf or not vim.api.nvim_buf_is_valid(self.provider_buf)
      or not self.provider_win or not vim.api.nvim_win_is_valid(self.provider_win) then
    return false
  end
  local selected_id
  local saved_view
  if not initial then
    saved_view = vim.api.nvim_win_call(
      self.provider_win, function() return vim.fn.winsaveview() end)
    local selected_row = self:_provider_row()
    if selected_row and self.provider_targets
        and self.provider_targets[selected_row] then
      selected_id = self.provider_targets[selected_row].id
    end
  end
  local content, err = self:_provider_content()
  if not content then
    vim.notify("neoagent: " .. (err and err.message or "provider rendering failed"),
      vim.log.levels.ERROR)
    return false, err
  end
  vim.bo[self.provider_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(self.provider_buf, self.namespace, 0, -1)
  local lines = #content.content.lines > 0 and content.content.lines or { "" }
  vim.api.nvim_buf_set_lines(self.provider_buf, 0, -1, false, lines)
  presentation.apply_marks(self, self.provider_buf, content.content)
  vim.bo[self.provider_buf].modifiable = false
  self.provider_targets = content.selectable
  local rows = self:_provider_rows()
  local target_row
  if selected_id then
    for row, target in pairs(self.provider_targets or {}) do
      if target.id == selected_id then target_row = row break end
    end
  end
  if target_row then
    saved_view.lnum = target_row + 1
    saved_view.col = 0
    vim.api.nvim_win_call(self.provider_win, function()
      vim.fn.winrestview(clamped_view(saved_view, lines))
    end)
  elseif saved_view then
    vim.api.nvim_win_call(self.provider_win, function()
      vim.fn.winrestview(clamped_view(saved_view, lines))
    end)
  elseif #rows > 0 then
    vim.api.nvim_win_set_cursor(self.provider_win, { rows[1] + 1, 0 })
  else
    vim.api.nvim_win_set_cursor(self.provider_win, { 1, 0 })
  end
  local config = vim.api.nvim_win_get_config(self.provider_win)
  config.title = " " .. (content.title or "Provider") .. " "
  config.title_pos = "center"
  vim.api.nvim_win_set_config(self.provider_win, config)
  return true
end

function M:_schedule_provider_refresh()
  if self.provider_refresh_pending then return end
  self.provider_refresh_pending = true
  util.schedule(function()
    self.provider_refresh_pending = false
    if self.destroyed then return end
    self:_refresh_provider(false)
  end)
end

function M:_map_provider_buffer(buffer)
  local mappings = self.config.mappings or {}
  for _, key in ipairs({
    "i", "I", "a", "A", "o", "O", "s", "S", "c", "C", "R", "gi", "gI",
  }) do
    vim.keymap.set("n", key, "<Nop>", {
      buffer = buffer,
      silent = true,
      nowait = true,
    })
  end
  self:_map(buffer, "n", mappings.toggle_provider,
    function() self.on_provider_toggle() end)
  self:_map(buffer, "n", mappings.provider_previous,
    function() self:_move_provider(-1, vim.v.count1) end)
  self:_map(buffer, "n", mappings.provider_next,
    function() self:_move_provider(1, vim.v.count1) end)
  self:_map(buffer, "n", mappings.card_details,
    function() self:_select_provider() end)
  self:_map(buffer, "n", mappings.provider_close,
    function() self:set_provider_open(false) end)
  self:_map(buffer, "n", mappings.provider_back,
    function() self:focus_transcript() end)
  self:_map(buffer, "n", mappings.provider_input,
    function() self:focus_input() end)
end

function M:_open_provider(enter)
  if self.provider_win and vim.api.nvim_win_is_valid(self.provider_win) then
    if enter then
      vim.api.nvim_set_current_win(self.provider_win)
      vim.cmd("stopinsert")
    end
    return true
  end
  if not self.provider_snapshot then return nil, util.error("ui", "No provider console state") end
  local buffer = self:_ensure_provider_buffer()
  local configs, err = self:_configs()
  if not configs or not configs.provider then return nil, err or util.error("ui", "Provider console does not fit") end
  self:_decorate(configs)
  vim.api.nvim_win_set_config(self.transcript_win, configs.transcript)
  vim.api.nvim_win_set_config(self.input_win, configs.input)
  self.provider_win = vim.api.nvim_open_win(buffer, enter == true, configs.provider)
  if enter then vim.cmd("stopinsert") end
  vim.wo[self.provider_win].wrap = true
  vim.wo[self.provider_win].linebreak = true
  vim.wo[self.provider_win].breakindent = true
  vim.wo[self.provider_win].number = false
  vim.wo[self.provider_win].relativenumber = false
  vim.wo[self.provider_win].signcolumn = "no"
  vim.wo[self.provider_win].foldcolumn = "0"
  vim.wo[self.provider_win].cursorline = true
  vim.wo[self.provider_win].winhl =
    "NormalFloat:Normal,FloatBorder:NeoagentBorder,FloatTitle:NeoagentWindowTitle"
  self:_map_provider_buffer(buffer)
  local refreshed, refresh_err = self:_refresh_provider(true)
  if not refreshed then
    self:_close_provider(false)
    return nil, refresh_err
  end
  return true
end

function M:_close_provider(focus_input)
  local window = self.provider_win
  local was_open = self.provider_open or window ~= nil
  self.provider_win = nil
  self.provider_targets = nil
  self.provider_open = false
  if window and vim.api.nvim_win_is_valid(window) then
    vim.api.nvim_win_close(window, true)
  end
  if self:is_open() then
    local configs = self:_configs()
    if configs then
      self:_decorate(configs)
      vim.api.nvim_win_set_config(self.transcript_win, configs.transcript)
      vim.api.nvim_win_set_config(self.input_win, configs.input)
    end
  end
  if focus_input and self:is_open() then self:focus_input() end
  if was_open then self.on_provider_close() end
end

function M:_provider_closed(window)
  if window ~= self.provider_win then return false end
  self.provider_win = nil
  self.provider_targets = nil
  self.provider_open = false
  if self:is_open() then
    local configs = self:_configs()
    if configs then
      self:_decorate(configs)
      vim.api.nvim_win_set_config(self.transcript_win, configs.transcript)
      vim.api.nvim_win_set_config(self.input_win, configs.input)
    end
  end
  return true
end

function M:_layout_provider()
  if not self.provider_win or not vim.api.nvim_win_is_valid(self.provider_win) then
    self.provider_win = nil
    self.provider_open = false
    return
  end
  local configs, err = self:_configs()
  if not configs or not configs.provider then
    self:_close_provider(true)
    return
  end
  self:_decorate(configs)
  vim.api.nvim_win_set_config(self.transcript_win, configs.transcript)
  vim.api.nvim_win_set_config(self.input_win, configs.input)
  vim.api.nvim_win_set_config(self.provider_win, configs.provider)
  self:_refresh_provider()
end

function M:set_provider(snapshot, immediate)
  self.provider_snapshot = snapshot and util.copy(snapshot) or nil
  if not self.provider_snapshot then
    self:set_provider_open(false)
    return
  end
  if self.provider_win and vim.api.nvim_win_is_valid(self.provider_win) then
    if immediate then
      self:_refresh_provider(false)
    else
      self:_schedule_provider_refresh()
    end
  end
end

function M:focus_provider()
  if not self.provider_win or not vim.api.nvim_win_is_valid(self.provider_win) then
    local opened, err = self:set_provider_open(true)
    if not opened then return nil, err end
  end
  vim.api.nvim_set_current_win(self.provider_win)
  vim.cmd("stopinsert")
  self:_refresh_input_footer()
  return true
end

function M:set_provider_open(open)
  assert(type(open) == "boolean", "provider console visibility must be boolean")
  if not open then
    self.provider_open = false
    self:_close_provider(true)
    return true
  end
  if not self:is_open() then
    return nil, util.error("ui", "Provider console requires the Neoagent window")
  end
  if not self.provider_snapshot then
    return nil, util.error("ui", "No provider console state")
  end
  self.provider_open = true
  local opened, err = self:_open_provider(true)
  if not opened then
    self.provider_open = false
    return nil, err
  end
  return true
end

function M:_toggle_provider()
  if self.provider_win and vim.api.nvim_win_is_valid(self.provider_win) then
    self:set_provider_open(false)
  else
    local opened, err = self:set_provider_open(true)
    if not opened and err then
      vim.notify("neoagent: " .. err.message, vim.log.levels.WARN)
    end
  end
end

function M:_map_provider_toggle()
  local mappings = self.config.mappings or {}
  local function toggle() self.on_provider_toggle() end
  self:_map(self.input_buf, { "n", "i" }, mappings.toggle_provider, toggle)
  self:_map(self.transcript_buf, "n", mappings.toggle_provider, toggle)
  local function focus_provider()
    local focused, err = self:focus_provider()
    if not focused and err then
      vim.notify("neoagent: " .. err.message, vim.log.levels.WARN)
    end
  end
  self:_map(self.transcript_buf, "n", mappings.focus_provider, focus_provider)
  self:_map(self.input_buf, { "n", "i" }, mappings.focus_provider, focus_provider)
end

return M
