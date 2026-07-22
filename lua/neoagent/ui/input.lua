local M = {}

local function split_text(text)
  return vim.split(text or "", "\n", { plain = true })
end

function M:_complete_input()
  local key
  if vim.fn.pumvisible() == 1 then
    key = "<C-n>"
  else
    local completion = self.config.completion
    for _, source in ipairs(completion and completion.sources or {}) do
      if source == "files" then key = "<C-x><C-f>" break end
    end
  end
  if not key then return false end
  key = vim.api.nvim_replace_termcodes(key, true, false, true)
  vim.api.nvim_feedkeys(key, "in", false)
  return true
end

function M:_map(buffer, modes, key, callback)
  if key == false or key == nil then return end
  if type(key) == "table" then
    for _, lhs in ipairs(key) do self:_map(buffer, modes, lhs, callback) end
    return
  end
  vim.keymap.set(modes, key, callback, { buffer = buffer, silent = true, nowait = true })
end

function M:_map_buffers()
  local mappings = self.config.mappings or {}
  local completion = self.config.completion
  if completion and #(completion.sources or {}) > 0 then
    self:_map(self.input_buf, "i", mappings.complete, function() self:_complete_input() end)
  end
  self:_map(self.input_buf, { "n", "i" }, mappings.submit, function()
    if vim.fn.pumvisible() == 1 then
      local key = vim.api.nvim_replace_termcodes("<C-y>", true, false, true)
      vim.api.nvim_feedkeys(key, "in", false)
      return
    end
    local submitted, err = self.on_submit(self:get_input())
    if submitted and self.config.scroll_on_submit then self:_scroll_transcript_to_bottom() end
    return submitted, err
  end)
  self:_map(self.input_buf, { "n", "i" }, mappings.interrupt, function() self:_interrupt(true) end)
  self:_map(self.transcript_buf, "n", mappings.interrupt, function() self:_interrupt(false) end)
  self:_map(self.input_buf, { "n", "i", "x", "s" }, mappings.toggle_focus,
    function() self:focus_transcript() end)
  self:_map(self.transcript_buf, { "n", "x", "s" }, mappings.toggle_focus,
    function() self:focus_input() end)
  self:_map(self.input_buf, "n", mappings.close_input, function() self:close() end)
  self:_map(self.input_buf, { "n", "i" }, mappings.close_empty, function()
    if self:get_input() == "" then
      self:close()
      return
    end
    local keys = vim.api.nvim_replace_termcodes(mappings.close_empty, true, false, true)
    vim.api.nvim_feedkeys(keys, "n", false)
  end)
  self:_map(self.input_buf, { "n", "i" }, mappings.expand_tools, function() self:toggle_tools() end)
  self:_map(self.transcript_buf, "n", mappings.expand_tools, function() self:toggle_tools() end)
  self:_map(self.input_buf, { "n", "i" }, mappings.cycle_thinking, self.on_cycle_thinking)
  self:_map(self.transcript_buf, "n", mappings.cycle_thinking, self.on_cycle_thinking)
  self:_map(self.input_buf, { "n", "i" }, mappings.cycle_agent, self.on_cycle_agent)
  self:_map(self.transcript_buf, "n", mappings.cycle_agent, self.on_cycle_agent)
  self:_map(self.input_buf, { "n", "i" }, mappings.select_model, self.on_select_model)
  self:_map(self.transcript_buf, "n", mappings.select_model, self.on_select_model)
  self:_map(self.input_buf, { "n", "i" }, mappings.resume_session, self.on_resume_session)
  self:_map(self.transcript_buf, "n", mappings.resume_session, self.on_resume_session)
  self:_map(self.input_buf, "i", mappings.history_previous,
    function() self:_move_input_history(-1) end)
  self:_map(self.input_buf, "i", mappings.history_next,
    function() self:_move_input_history(1) end)
  self:_map(self.input_buf, { "n", "i" }, mappings.select_history, self.on_select_history)
  self:_map(self.transcript_buf, "n", mappings.select_history, self.on_select_history)
  self:_map(self.input_buf, { "n", "i" }, mappings.dequeue_steering,
    function() self:_restore_steering() end)
  self:_map(self.transcript_buf, "n", mappings.dequeue_steering,
    function() self:_restore_steering() end)
  local docks = {
    dock_left = "left", dock_bottom = "bottom", dock_top = "top",
    dock_right = "right", dock_center = "center",
  }
  for action, position in pairs(docks) do
    local function dock()
      if self:set_position(position) then self.on_position_change(position) end
    end
    self:_map(self.input_buf, "n", mappings[action], dock)
    self:_map(self.transcript_buf, "n", mappings[action], dock)
  end
  self:_map(self.transcript_buf, "n", mappings.close, function() self:close() end)
end

function M:get_input()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false), "\n")
end

function M:_reset_input_history()
  self.history_index = 0
  self.history_draft = nil
  self.history_changedtick = nil
end

function M:_set_history_input(text, placement, cursor)
  vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, split_text(text))
  self.history_changedtick = vim.api.nvim_buf_get_changedtick(self.input_buf)
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then return end
  local lines = vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  local target = cursor
  if not target then
    target = placement == "start" and { 1, 0 } or { #lines, #lines[#lines] }
  end
  pcall(vim.api.nvim_win_set_cursor, self.input_win, target)
end

function M:_browse_input_history(direction)
  local history = self.on_input_history()
  if type(history) ~= "table" or #history == 0 then return false end
  local next_index = self.history_index - direction
  if next_index < 0 or next_index > #history then return false end
  if self.history_index == 0 and next_index > 0 then
    self.history_draft = {
      text = self:get_input(),
      cursor = vim.api.nvim_win_get_cursor(self.input_win),
    }
  end
  self.history_index = next_index
  if next_index == 0 then
    local draft = self.history_draft or { text = "" }
    self:_set_history_input(draft.text, "end", draft.cursor)
    self.history_draft = nil
  else
    self:_set_history_input(history[next_index], direction < 0 and "start" or "end")
  end
  return true
end

function M:_move_input_history(direction)
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then return false end
  if vim.fn.pumvisible() == 1 then
    local key = direction < 0 and "<C-p>" or "<C-n>"
    key = vim.api.nvim_replace_termcodes(key, true, false, true)
    vim.api.nvim_feedkeys(key, "in", false)
    return true
  end
  local cursor = vim.api.nvim_win_get_cursor(self.input_win)
  local line_count = vim.api.nvim_buf_line_count(self.input_buf)
  if direction < 0 then
    if self.history_index > 0 or self:get_input() == "" or cursor[1] == 1 and cursor[2] == 0 then
      return self:_browse_input_history(direction)
    elseif cursor[1] == 1 then
      vim.api.nvim_win_set_cursor(self.input_win, { 1, 0 })
      return false
    end
  elseif self.history_index > 0 then
    return self:_browse_input_history(direction)
  elseif cursor[1] == line_count then
    local line = vim.api.nvim_buf_get_lines(self.input_buf, line_count - 1, line_count, false)[1]
    vim.api.nvim_win_set_cursor(self.input_win, { line_count, #line })
    return false
  end
  local key = direction < 0 and "<Up>" or "<Down>"
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
  return false
end

function M:set_input(text)
  self:_ensure_buffers()
  self:_reset_input_history()
  vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, split_text(text))
end

return M
