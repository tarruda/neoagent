local render = require("neoagent.ui.render")

local M = {}

local function detail_height(lines)
  local available = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  return math.min(available, math.max(1, #lines))
end

local function detail_row(height)
  return math.max(0, math.floor(
    (vim.o.lines - vim.o.cmdheight - height) / 2) - 1)
end

local function card_range(view, block)
  if not block.card or not block.mark then return nil end
  local position = vim.api.nvim_buf_get_extmark_by_id(
    view.transcript_buf, view.namespace, block.mark, { details = true })
  if #position == 0 then return nil end
  return position[1] + block.card.first, position[1] + block.card.last
end

local function apply_rendered(view, buffer, content, background)
  local lines = #content.lines > 0 and content.lines or { "" }
  local readonly = vim.bo[buffer].readonly
  if readonly then vim.bo[buffer].readonly = false end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buffer, view.namespace, 0, -1)
  if background then
    for row = 0, #lines - 1 do
      vim.api.nvim_buf_set_extmark(buffer, view.namespace, row, 0, {
        line_hl_group = background,
        priority = 25,
      })
    end
  end
  for row, group in pairs(content.line_groups or {}) do
    vim.api.nvim_buf_set_extmark(buffer, view.namespace, row, 0, {
      line_hl_group = group,
      priority = 50,
    })
  end
  for _, span in ipairs(content.highlights or {}) do
    vim.api.nvim_buf_set_extmark(buffer, view.namespace, span.row, span.col, {
      end_row = span.row,
      end_col = span.end_col,
      hl_group = span.group,
      priority = span.priority or 100,
    })
  end
  vim.bo[buffer].modifiable = false
  if readonly then vim.bo[buffer].readonly = true end
  return lines
end

function M:_card_at_cursor()
  if not self.transcript_win or not vim.api.nvim_win_is_valid(self.transcript_win)
      or vim.api.nvim_get_current_win() ~= self.transcript_win
      or vim.api.nvim_win_get_buf(self.transcript_win) ~= self.transcript_buf then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(self.transcript_win)[1] - 1
  for _, block in ipairs(self.blocks) do
    local first, last = card_range(self, block)
    if first and row >= first and row <= last then return block, first, last end
  end
end

function M:_move_card(direction, count)
  if direction ~= -1 and direction ~= 1 then return false end
  if not self.transcript_win or not vim.api.nvim_win_is_valid(self.transcript_win)
      or vim.api.nvim_win_get_buf(self.transcript_win) ~= self.transcript_buf then
    return false
  end
  count = math.max(1, math.floor(tonumber(count) or 1))
  local row = vim.api.nvim_win_get_cursor(self.transcript_win)[1] - 1
  local target
  local moved = 0
  local first_index = direction > 0 and 1 or #self.blocks
  local last_index = direction > 0 and #self.blocks or 1
  for index = first_index, last_index, direction do
    local first, last = card_range(self, self.blocks[index])
    local follows = direction > 0 and first and first > row
      or direction < 0 and last and last < row
    if follows then
      target = math.min(first + 1, last)
      moved = moved + 1
      if moved == count then break end
    end
  end
  if not target then return false end
  vim.api.nvim_win_set_cursor(self.transcript_win, { target + 1, 0 })
  self:_update_card_outline()
  return true
end

function M:_clear_card_outline()
  if self.transcript_buf and vim.api.nvim_buf_is_valid(self.transcript_buf) then
    vim.api.nvim_buf_clear_namespace(
      self.transcript_buf, self.card_namespace, 0, -1)
  end
end

function M:_update_card_outline()
  self:_clear_card_outline()
  local block, first, last = self:_card_at_cursor()
  if not block then return false end
  local width = math.max(2, vim.api.nvim_win_get_width(self.transcript_win))
  local function outline(row, text, position)
    local options = {
      virt_text = { { text, "NeoagentCardFocus" } },
      virt_text_pos = position or "overlay",
      priority = 200,
    }
    if type(position) == "number" then
      options.virt_text_pos = nil
      options.virt_text_win_col = position
    end
    vim.api.nvim_buf_set_extmark(
      self.transcript_buf, self.card_namespace, row, 0, options)
  end
  outline(first, "╭" .. string.rep("─", width - 2) .. "╮")
  for row = first + 1, last - 1 do
    outline(row, "│")
    outline(row, "│", width - 1)
  end
  outline(last, "╰" .. string.rep("─", width - 2) .. "╯")
  return true
end

function M:_refresh_card_details()
  if not self.details_buf or not self.details_win then return false end
  if not vim.api.nvim_buf_is_valid(self.details_buf)
      or not vim.api.nvim_win_is_valid(self.details_win) then return false end
  local saved = vim.api.nvim_win_call(
    self.details_win, function() return vim.fn.winsaveview() end)
  local content, background = render.details(self, self.details_block, {
    width = vim.api.nvim_win_get_width(self.details_win),
  })
  local lines = apply_rendered(
    self, self.details_buf, content, background)
  local height = detail_height(lines)
  local config = vim.api.nvim_win_get_config(self.details_win)
  config.height = height
  config.row = detail_row(height)
  vim.api.nvim_win_set_config(self.details_win, config)
  vim.api.nvim_win_call(self.details_win, function()
    pcall(vim.fn.winrestview, saved)
  end)
  return true
end

function M:_close_card_details(focus_transcript)
  local window = self.details_win
  self.details_win, self.details_buf, self.details_block = nil, nil, nil
  if window and vim.api.nvim_win_is_valid(window) then
    vim.api.nvim_win_close(window, true)
  end
  if focus_transcript and self.transcript_win
      and vim.api.nvim_win_is_valid(self.transcript_win) then
    self:focus_transcript()
  end
end

function M:_card_details_closed(window)
  if window ~= self.details_win then return false end
  self.details_win, self.details_buf, self.details_block = nil, nil, nil
  return true
end

function M:show_card_details()
  local block = self:_card_at_cursor()
  if not block then return false end
  self:_close_card_details(false)
  local available_width = math.max(1, vim.o.columns - 4)
  local width = math.min(available_width,
    math.max(20, math.floor(vim.o.columns * 0.8)))
  local content, background = render.details(self, block, { width = width })
  if not content then return false end
  local buffer = vim.api.nvim_create_buf(false, true)
  self.details_counter = (self.details_counter or 0) + 1
  pcall(vim.api.nvim_buf_set_name, buffer,
    "neoagent-card://" .. tostring(self.namespace)
      .. "/" .. self.details_counter)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undofile = false
  vim.bo[buffer].filetype = "neoagent"
  local lines = apply_rendered(self, buffer, content, background)
  vim.bo[buffer].readonly = true

  local height = detail_height(lines)
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = detail_row(height),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = self.config.border,
    title = " Card details ",
    title_pos = "center",
    zindex = 70,
  })
  self.details_buf, self.details_win, self.details_block = buffer, window, block
  vim.wo[window].wrap = false
  vim.wo[window].cursorline = true
  vim.wo[window].scrolloff = 2
  vim.wo[window].sidescrolloff = 4
  vim.wo[window].winhl =
    "NormalFloat:Normal,FloatBorder:NeoagentBorder,FloatTitle:NeoagentWindowTitle"
  vim.keymap.set("n", "<C-c>", function()
    self:_close_card_details(true)
  end, { buffer = buffer, silent = true, nowait = true })
  return true
end

return M
