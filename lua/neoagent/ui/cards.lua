local source_syntax = require("neoagent.ui.source_syntax")

local M = {}

local function detail_height(lines)
  local available = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  return math.min(available, math.max(1, #lines))
end

local function detail_row(height)
  return math.max(0, math.floor(
    (vim.o.lines - vim.o.cmdheight - height) / 2) - 1)
end

local function detail_width()
  local available = math.max(1, vim.o.columns - 4)
  return math.min(available,
    math.max(20, math.floor(vim.o.columns * 0.8)))
end

local function mapping_hint(mapping)
  if type(mapping) == "string" then return mapping end
  if type(mapping) == "table" then return mapping[1] end
end

local function supports_raw_details(block)
  return block and (block.kind == "thinking" or block.kind == "assistant")
end

local function raw_detail_content(block)
  return {
    lines = vim.split(block.text or "", "\n", { plain = true }),
    highlights = {},
    line_groups = {},
  }
end

local function detail_content(view, block, width)
  if view.details_raw and supports_raw_details(block) then
    return raw_detail_content(block)
  end
  local content = view:_render_details(block, { width = width })
  return content, content and content.background
end

local function detail_title(view, block)
  local label = "Card details"
  if block.kind == "tool" then
    label = "Tool call"
  elseif block.kind == "thinking" then
    label = "Thinking"
  elseif block.kind == "assistant" then
    label = "Text"
  end
  if supports_raw_details(block) then
    local key = mapping_hint((view.config.mappings or {}).card_raw)
    if key then
      label = label .. " · " .. key .. " "
        .. (view.details_raw and "rendered" or "raw")
    end
  end
  return " " .. label .. " "
end

local function update_detail_title(view)
  local config = vim.api.nvim_win_get_config(view.details_win)
  config.title = detail_title(view, view.details_block)
  vim.api.nvim_win_set_config(view.details_win, config)
end

local function prepare_detail_window(window)
  local width = detail_width()
  local available = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  local config = vim.api.nvim_win_get_config(window)
  config.width = width
  config.col = math.max(0, math.floor((vim.o.columns - width) / 2))
  config.height = math.min(available, config.height)
  config.row = detail_row(config.height)
  vim.api.nvim_win_set_config(window, config)
  return width
end

local function fit_detail_height(window)
  local available = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  local text_height = vim.api.nvim_win_text_height(window, {}).all
  local height = math.min(available, math.max(1, text_height))
  local config = vim.api.nvim_win_get_config(window)
  config.height = height
  config.row = detail_row(height)
  vim.api.nvim_win_set_config(window, config)
end

local function block_start(view, block)
  if not block.mark then return nil end
  local position = vim.api.nvim_buf_get_extmark_by_id(
    view.transcript_buf, view.namespace, block.mark, { details = true })
  if #position == 0 then return nil end
  return position[1]
end

local function card_range(view, block)
  if not block.card then return nil end
  local start = block_start(view, block)
  if not start then return nil end
  return start + block.card.first, start + block.card.last
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

local function card_target(view, direction, count, row)
  if direction ~= -1 and direction ~= 1 then return false end
  if not view.transcript_win or not vim.api.nvim_win_is_valid(view.transcript_win)
      or vim.api.nvim_win_get_buf(view.transcript_win) ~= view.transcript_buf then
    return nil
  end
  count = math.max(1, math.floor(tonumber(count) or 1))
  row = row or vim.api.nvim_win_get_cursor(view.transcript_win)[1] - 1
  local target
  local moved = 0
  local first_index = direction > 0 and 1 or #view.blocks
  local last_index = direction > 0 and #view.blocks or 1
  for index = first_index, last_index, direction do
    local first, last = card_range(view, view.blocks[index])
    local follows = direction > 0 and first and first > row
      or direction < 0 and last and last < row
    if follows then
      target = math.min(first + 1, last)
      moved = moved + 1
      if moved == count then break end
    end
  end
  return target
end

local function select_card(view, target)
  if not target then return false end
  vim.api.nvim_win_set_cursor(view.transcript_win, { target + 1, 0 })
  view:_update_card_outline()
  view:_refresh_input_footer()
  return true
end

function M:_move_card(direction, count)
  return select_card(self, card_target(self, direction, count))
end

function M:_move_card_details(direction, count)
  if not self.details_win or not vim.api.nvim_win_is_valid(self.details_win)
      or vim.api.nvim_get_current_win() ~= self.details_win then
    return false
  end
  local first, last = card_range(self, self.details_block)
  if not first then return false end
  local target = card_target(
    self, direction, count, direction > 0 and last or first)
  if not target then
    if direction > 0 then
      self:_close_card_details(false)
      self:focus_input()
    end
    return false
  end
  self:_close_card_details(false)
  self:focus_transcript()
  select_card(self, target)
  return self:show_card_details()
end

function M:_clear_card_outline()
  if self.transcript_buf and vim.api.nvim_buf_is_valid(self.transcript_buf) then
    vim.api.nvim_buf_clear_namespace(
      self.transcript_buf, self.card_namespace, 0, -1)
  end
end

local function card_width(view)
  if view.transcript_win and vim.api.nvim_win_is_valid(view.transcript_win) then
    return math.max(2, vim.api.nvim_win_get_width(view.transcript_win))
  end
  return 2
end

local function apply_focus(view, block, active, width)
  if not block.card or not block.mark then return false end
  local position = vim.api.nvim_buf_get_extmark_by_id(
    view.transcript_buf, view.namespace, block.mark, { details = true })
  if #position == 0 then return false end
  local first, finish = position[1], position[3].end_row
  local lines = vim.api.nvim_buf_get_lines(
    view.transcript_buf, first, finish, false)
  local decorations = view:_present_focus(block, {
    active = active,
    lines = lines,
    width = width,
    card = block.card,
    separators = block.separators,
    focus = block.focus,
    details_key = mapping_hint((view.config.mappings or {}).card_details),
  })
  for _, decoration in ipairs(decorations) do
    local chunks = {}
    for _, chunk in ipairs(decoration.chunks) do
      chunks[#chunks + 1] = { chunk.text, chunk.group }
    end
    vim.api.nvim_buf_set_extmark(
      view.transcript_buf, view.card_namespace,
      first + decoration.row, 0, {
        virt_text = chunks,
        virt_text_pos = decoration.position,
        virt_text_win_col = decoration.win_col,
        priority = decoration.priority,
      })
  end
  return true
end

function M:_update_overflow_badges()
  self:_clear_card_outline()
  local width = card_width(self)
  for _, block in ipairs(self.blocks) do
    apply_focus(self, block, false, width)
  end
end

function M:_update_card_outline()
  self:_clear_card_outline()
  local active = self:_card_at_cursor()
  local width = card_width(self)
  for _, block in ipairs(self.blocks) do
    apply_focus(self, block, block == active, width)
  end
  return active ~= nil
end

function M:_refresh_card_details()
  if not self.details_buf or not self.details_win then return false end
  if not vim.api.nvim_buf_is_valid(self.details_buf)
      or not vim.api.nvim_win_is_valid(self.details_win) then return false end
  local saved = vim.api.nvim_win_call(
    self.details_win, function() return vim.fn.winsaveview() end)
  local width = prepare_detail_window(self.details_win)
  local content, background = detail_content(
    self, self.details_block, width)
  local lines = apply_rendered(
    self, self.details_buf, content, background)
  source_syntax.apply(self.details_buf, content.source, lines)
  fit_detail_height(self.details_win)
  vim.api.nvim_win_call(self.details_win, function()
    pcall(vim.fn.winrestview, saved)
  end)
  return true
end

function M:_close_card_details(focus_transcript)
  local window = self.details_win
  self.details_win, self.details_buf, self.details_block = nil, nil, nil
  self.details_raw = nil
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
  self.details_raw = nil
  return true
end

function M:_toggle_card_details_raw()
  if not self.details_win or not vim.api.nvim_win_is_valid(self.details_win)
      or not supports_raw_details(self.details_block) then return false end
  self.details_raw = not self.details_raw
  if not self:_refresh_card_details() then return false end
  update_detail_title(self)
  return true
end

function M:show_card_details()
  local block = self:_card_at_cursor()
  if not block then return false end
  local transcript_view = self:_save_view()
  self:_close_card_details(false)
  self.details_raw = false
  local width = detail_width()
  local content, background = detail_content(self, block, width)
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
  source_syntax.apply(buffer, content.source, lines)
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
    title = detail_title(self, block),
    title_pos = "center",
    zindex = 70,
  })
  self.details_buf, self.details_win, self.details_block = buffer, window, block
  self:_restore_view(transcript_view)
  vim.wo[window].wrap = true
  vim.wo[window].linebreak = true
  vim.wo[window].breakindent = true
  vim.wo[window].cursorline = true
  vim.wo[window].scrolloff = 2
  vim.wo[window].sidescrolloff = 4
  vim.wo[window].winhl =
    "NormalFloat:Normal,FloatBorder:NeoagentBorder,FloatTitle:NeoagentWindowTitle"
  fit_detail_height(window)
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = self.augroup,
    buffer = buffer,
    callback = function() vim.cmd("stopinsert") end,
  })
  vim.keymap.set("n", "<C-c>", function()
    self:_close_card_details(true)
  end, { buffer = buffer, silent = true, nowait = true })
  local mappings = self.config.mappings or {}
  self:_map(buffer, "n", mappings.card_previous,
    function() self:_move_card_details(-1, vim.v.count1) end)
  self:_map(buffer, "n", mappings.card_next,
    function() self:_move_card_details(1, vim.v.count1) end)
  if supports_raw_details(block) then
    self:_map(buffer, "n", mappings.card_raw,
      function() self:_toggle_card_details_raw() end)
  end
  return true
end

return M
