local util = require("neoagent.util")

local M = {}

local function wrapped_lines(text, width)
  width = math.max(20, width)
  local result = {}
  for _, source in ipairs(vim.split(tostring(text or ""), "\n",
    { plain = true })) do
    if source == "" then
      result[#result + 1] = ""
    else
      local remaining = source
      while vim.fn.strdisplaywidth(remaining) > width do
        local count = 1
        while count < vim.fn.strchars(remaining)
            and vim.fn.strdisplaywidth(
              vim.fn.strcharpart(remaining, 0, count + 1)) <= width do
          count = count + 1
        end
        result[#result + 1] = vim.fn.strcharpart(remaining, 0, count)
        remaining = vim.fn.strcharpart(remaining, count)
      end
      result[#result + 1] = remaining
    end
  end
  return result
end

local function dialog_lines(snapshot, width)
  local dialog = snapshot.active
  local lines = {
    string.rep("─", math.max(1, width)),
    dialog.title,
    "",
  }
  vim.list_extend(lines, wrapped_lines(dialog.body, width))
  lines[#lines + 1] = ""
  local action_row = #lines
  for _, action in ipairs(dialog.actions) do
    lines[#lines + 1] =
      string.format("[%s] %s", action.key, action.label)
  end
  if snapshot.queue_count and snapshot.queue_count > 0 then
    lines[#lines + 1] = string.format(
      "%d more dialog%s pending",
      snapshot.queue_count, snapshot.queue_count == 1 and "" or "s")
  end
  return lines, action_row
end

local extmark_fields = {
  "end_row", "end_col", "hl_group", "hl_eol", "virt_text",
  "virt_text_pos", "virt_text_win_col", "virt_text_hide", "virt_lines",
  "virt_lines_above", "virt_lines_leftcol", "priority", "right_gravity",
  "end_right_gravity", "line_hl_group", "number_hl_group", "sign_text",
  "sign_hl_group", "conceal", "spell", "ui_watched",
}

function M:_copy_transcript_marks(target)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    self.transcript_buf, self.namespace, 0, -1, { details = true }
  )) do
    if mark[1] ~= self.status_mark then
      local options = {}
      for _, key in ipairs(extmark_fields) do
        if mark[4][key] ~= nil then options[key] = mark[4][key] end
      end
      pcall(vim.api.nvim_buf_set_extmark,
        target, self.namespace, mark[2], mark[3], options)
    end
  end
end

function M:_hide_dialog_surface()
  local buffer = self.dialog_buf
  if not buffer then return end
  if self.dialog_win and vim.api.nvim_win_is_valid(self.dialog_win) then
    self.hiding_dialog = true
    vim.api.nvim_win_close(self.dialog_win, true)
    self.hiding_dialog = false
  end
  if self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win) then
    if vim.api.nvim_win_get_buf(self.transcript_win) == buffer then
      vim.api.nvim_win_set_buf(self.transcript_win, self.transcript_buf)
    end
    if self.dialog_scroll
        and vim.api.nvim_win_get_buf(self.transcript_win)
          == self.transcript_buf then
      vim.api.nvim_win_call(self.transcript_win, function()
        pcall(vim.fn.winrestview, self.dialog_scroll)
      end)
    end
  end
  self.dialog_buf = nil
  self.dialog_win = nil
  self.dialog_scroll = nil
  self.dialog_status_mark = nil
  self.dialog_status_row = nil
  if vim.api.nvim_buf_is_valid(buffer) then
    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
  end
end

function M:_dialog_input()
  if not self.dialog or not self.dialog.active.input
      or not self.dialog_buf
      or not vim.api.nvim_buf_is_valid(self.dialog_buf) then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(
    self.dialog_buf, 0, -1, false), "\n")
end

local function input_has_text(view)
  if not view.input_buf or not vim.api.nvim_buf_is_valid(view.input_buf) then
    return false
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)) do
    if line:find("%S") then return true end
  end
  return false
end

function M:_respond_to_dialog(action_id)
  return self.on_dialog_action(
    self.dialog.active.id, action_id, self:_dialog_input())
end

function M:_map_dialog_actions(buffer, modes)
  for _, source in ipairs(self.dialog.active.actions) do
    local action = source
    self:_map(buffer, modes, action.key, function()
      self:_respond_to_dialog(action.id)
    end)
  end
end

function M:_show_transcript_dialog()
  self:_flush()
  self.dialog_scroll =
    vim.api.nvim_win_call(self.transcript_win, vim.fn.winsaveview)
  local buffer = vim.api.nvim_create_buf(false, true)
  self.dialog_counter = (self.dialog_counter or 0) + 1
  pcall(vim.api.nvim_buf_set_name, buffer,
    "neoagent-dialog://" .. tostring(self.namespace)
      .. "/" .. self.dialog_counter)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undofile = false
  vim.bo[buffer].filetype = "neoagent-dialog"
  local lines = vim.api.nvim_buf_get_lines(
    self.transcript_buf, 0, -1, false)
  if #lines > 0 and lines[#lines] ~= "" then lines[#lines + 1] = "" end
  local dialog_start = #lines
  local rendered, action_row = dialog_lines(
    self.dialog,
    math.max(20, vim.api.nvim_win_get_width(self.transcript_win) - 2))
  vim.list_extend(lines, rendered)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  self:_copy_transcript_marks(buffer)
  self.dialog_status_row = math.max(
    0, vim.api.nvim_buf_line_count(self.transcript_buf) - 1)
  for row = dialog_start, #lines - 1 do
    vim.api.nvim_buf_set_extmark(buffer, self.namespace, row, 0, {
      line_hl_group = "NeoagentDialogBackground",
      priority = 25,
    })
  end
  vim.api.nvim_buf_set_extmark(
    buffer, self.namespace, dialog_start + 1, 0, {
      end_row = dialog_start + 1,
      end_col = #lines[dialog_start + 2],
      hl_group = "NeoagentDialogTitle",
      priority = 100,
    })
  for row = dialog_start + action_row,
      dialog_start + action_row + #self.dialog.active.actions - 1 do
    vim.api.nvim_buf_set_extmark(buffer, self.namespace, row, 0, {
      end_row = row,
      end_col = #lines[row + 1],
      hl_group = "NeoagentDialogAction",
      priority = 100,
    })
  end
  vim.bo[buffer].modifiable = false
  self:_map_dialog_actions(buffer, "n")
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = self.augroup,
    buffer = buffer,
    callback = function() vim.cmd("stopinsert") end,
  })
  self.dialog_buf = buffer
  self:_render_dialog_status()
  vim.api.nvim_win_set_buf(self.transcript_win, buffer)
  if not input_has_text(self) then
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(self.transcript_win)
  end
  vim.api.nvim_win_set_cursor(
    self.transcript_win, { #lines, math.max(0, #lines[#lines] - 1) })
end

function M:_show_float_dialog()
  local dialog = self.dialog.active
  local width = math.max(20, math.min(80, vim.o.columns - 4))
  local body = wrapped_lines(dialog.body, width - 2)
  local virtual = {}
  for _, line in ipairs(body) do
    virtual[#virtual + 1] = { { line, "NormalFloat" } }
  end
  if dialog.input then
    if #virtual > 0 then virtual[#virtual + 1] = { { "", "NormalFloat" } } end
    virtual[#virtual + 1] =
      { { dialog.input.label, "NeoagentDialogTitle" } }
  end
  local input_lines = dialog.input
      and vim.split(dialog.input.value, "\n", { plain = true })
    or { "" }
  local action_lines = {}
  for _, action in ipairs(dialog.actions) do
    action_lines[#action_lines + 1] =
      string.format("[%s] %s", action.key, action.label)
  end
  virtual[#virtual + 1] = { { "", "NormalFloat" } }
  virtual[#virtual + 1] = {
    { table.concat(action_lines, "  "), "NeoagentDialogAction" },
  }
  if self.dialog.queue_count and self.dialog.queue_count > 0 then
    virtual[#virtual + 1] = { {
      string.format("%d more dialog%s pending",
        self.dialog.queue_count,
        self.dialog.queue_count == 1 and "" or "s"),
      "NeoagentMuted",
    } }
  end
  local buffer = vim.api.nvim_create_buf(false, true)
  self.dialog_counter = (self.dialog_counter or 0) + 1
  pcall(vim.api.nvim_buf_set_name, buffer,
    "neoagent-dialog-input://" .. tostring(self.namespace)
      .. "/" .. self.dialog_counter)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undofile = false
  vim.bo[buffer].filetype = "neoagent-dialog-input"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, input_lines)
  vim.bo[buffer].modifiable = dialog.input ~= nil
  vim.api.nvim_buf_set_extmark(buffer, self.namespace, 0, 0, {
    virt_lines = virtual,
    virt_lines_above = true,
  })
  local height = math.max(3, math.min(vim.o.lines - 4,
    #virtual + #input_lines))
  local keep_focus = not dialog.input and input_has_text(self)
  local window = vim.api.nvim_open_win(buffer, not keep_focus, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = self.config.border,
    title = " " .. dialog.title .. " ",
    title_pos = "center",
  })
  vim.wo[window].wrap = false
  self:_map_dialog_actions(
    buffer, dialog.input and { "n", "i" } or "n")
  self.dialog_buf = buffer
  self.dialog_win = window
  if dialog.input then
    vim.api.nvim_win_set_cursor(window, {
      #input_lines, #input_lines[#input_lines],
    })
    vim.cmd("startinsert!")
  elseif not keep_focus then
    vim.cmd("stopinsert")
  end
end

function M:_show_dialog()
  if not self.dialog or not self:is_open() then return end
  if self.dialog_buf and vim.api.nvim_buf_is_valid(self.dialog_buf) then
    local window = self.dialog_win
    if window and vim.api.nvim_win_is_valid(window) then
      if not input_has_text(self) then
        vim.api.nvim_set_current_win(window)
      end
    else
      vim.api.nvim_win_set_buf(self.transcript_win, self.dialog_buf)
      if not input_has_text(self) then
        vim.cmd("stopinsert")
        vim.api.nvim_set_current_win(self.transcript_win)
      end
    end
    return
  end
  if self.dialog.active.placement == "float" then
    self:_show_float_dialog()
  else
    self:_show_transcript_dialog()
  end
end

function M:set_dialog(snapshot)
  local previous = self.dialog
  if snapshot and previous
      and snapshot.active.id == previous.active.id
      and snapshot.queue_count == previous.queue_count
      and self.dialog_buf
      and vim.api.nvim_buf_is_valid(self.dialog_buf) then
    return
  end
  self:_hide_dialog_surface()
  self.dialog = snapshot and util.copy(snapshot) or nil
  self:_sync_spinner()
  self:_refresh_transcript_border()
  if self.dialog then
    self:_show_dialog()
  elseif self:is_open() then
    self:focus_input()
    vim.schedule(function()
      if not self.destroyed and self:is_open() and not self.dialog then
        self:_flush()
      end
    end)
  end
end

return M
