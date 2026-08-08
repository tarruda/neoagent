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
  return render.details(view, block, { width = width })
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

local function card_target(view, direction, count)
  if direction ~= -1 and direction ~= 1 then return false end
  if not view.transcript_win or not vim.api.nvim_win_is_valid(view.transcript_win)
      or vim.api.nvim_win_get_buf(view.transcript_win) ~= view.transcript_buf then
    return nil
  end
  count = math.max(1, math.floor(tonumber(count) or 1))
  local row = vim.api.nvim_win_get_cursor(view.transcript_win)[1] - 1
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

function M:_has_card(direction)
  return card_target(self, direction, 1) ~= nil
end

function M:_move_card(direction, count)
  local target = card_target(self, direction, count)
  if not target then return false end
  vim.api.nvim_win_set_cursor(self.transcript_win, { target + 1, 0 })
  self:_update_card_outline()
  self:_refresh_input_footer()
  return true
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

local function suffix_to_width(text, width)
  local characters = vim.fn.strchars(text)
  local low, high = 0, characters
  while low < high do
    local count = math.floor((low + high + 1) / 2)
    local candidate = vim.fn.strcharpart(
      text, characters - count, count)
    if vim.fn.strdisplaywidth(candidate) <= width then
      low = count
    else
      high = count - 1
    end
  end
  return vim.fn.strcharpart(text, characters - low, low)
end

local function fit_badge(header, width)
  local available = math.max(1, width - 1)
  if vim.fn.strdisplaywidth(header) <= available then return header end
  if available <= 3 then return suffix_to_width(header, available) end
  return "..." .. suffix_to_width(header, available - 3)
end

local function overflow_badge(view, row, header, width)
  header = fit_badge(header, width)
  local start = math.max(0, width - 1 - vim.fn.strdisplaywidth(header))
  local chunks = {}
  if start >= 3 then chunks[#chunks + 1] = { "...", "NeoagentMuted" } end
  chunks[#chunks + 1] = { header, "NeoagentMuted" }
  vim.api.nvim_buf_set_extmark(view.transcript_buf, view.card_namespace, row, 0, {
    virt_text = chunks,
    virt_text_pos = "overlay",
    virt_text_win_col = start - (start >= 3 and 3 or 0),
    priority = 200,
  })
end

local function overflow_badges(view, width, skip)
  if not view.transcript_buf or not vim.api.nvim_buf_is_valid(view.transcript_buf) then return end
  for _, candidate in ipairs(view.blocks) do
    if candidate ~= skip and candidate.kind == "thinking"
        and candidate.overflow and candidate.resting_header then
      local row = card_range(view, candidate)
      if row then overflow_badge(view, row, candidate.resting_header, width) end
    end
  end
end

function M:_update_overflow_badges()
  self:_clear_card_outline()
  overflow_badges(self, card_width(self), nil)
end

function M:_update_card_outline()
  self:_clear_card_outline()
  local width = card_width(self)
  local block, first, last = self:_card_at_cursor()
  overflow_badges(self, width, block)
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
  if not block then return false end
  local function horizontal(row, left, right)
    local line = vim.api.nvim_buf_get_lines(
      self.transcript_buf, row, row + 1, false)[1] or ""
    local gap = math.min(vim.fn.strdisplaywidth(line), width - 1)
    if gap <= 0 then
      outline(row, left .. string.rep("─", width - 2) .. right)
    else
      outline(row, left)
      outline(row, string.rep("─", width - gap - 1) .. right, gap)
    end
  end
  local function bottom(row)
    local line = vim.api.nvim_buf_get_lines(
      self.transcript_buf, row, row + 1, false)[1] or ""
    if vim.fn.strdisplaywidth(line) > width then
      horizontal(row + 1, "╰", "╯")
    else
      horizontal(row, "╰", "╯")
    end
  end
  local function badge(row, header)
    header = fit_badge(header, width)
    local start = math.max(0, width - 1 - vim.fn.strdisplaywidth(header))
    local line = vim.api.nvim_buf_get_lines(
      self.transcript_buf, row, row + 1, false)[1] or ""
    local line_width = vim.fn.strdisplaywidth(line)
    outline(row, "╭")
    if line_width <= start then
      local fill = start - line_width
      if fill > 0 then outline(row, string.rep("─", fill), line_width) end
    elseif start >= 3 then
      outline(row, "...", start - 3)
    end
    vim.api.nvim_buf_set_extmark(self.transcript_buf, self.card_namespace, row, 0, {
      virt_text = { { header, "NeoagentMuted" } },
      virt_text_pos = "overlay",
      virt_text_win_col = start,
      priority = 200,
    })
  end
  local function response_badge(kind)
    local hint = render.expand_hint(self)
    return string.format("[%s: 0 words%s]", kind,
      hint and ", " .. hint .. " to expand" or "")
  end
  if block.kind == "thinking" then
    badge(first, block.header or response_badge("thinking"))
    if last > first then bottom(last) end
  elseif block.kind == "assistant" then
    badge(first, block.header or response_badge("text"))
    if last > first then bottom(last) end
  else
    outline(first, "╭" .. string.rep("─", width - 2) .. "╮")
    local bottom = "╰" .. string.rep("─", width - 2) .. "╯"
    if block.kind == "tool" then
      local key = render.expand_hint(self)
      if key then
        local hint = " " .. key .. " to expand "
        local remaining = width - 2 - vim.fn.strdisplaywidth(hint)
        if remaining >= 2 then
          local left = math.floor(remaining / 2)
          bottom = "╰" .. string.rep("─", left) .. hint
            .. string.rep("─", remaining - left) .. "╯"
        end
      end
    end
    outline(last, bottom)
  end
  return true
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
  apply_rendered(self, self.details_buf, content, background)
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
  if supports_raw_details(block) then
    self:_map(buffer, "n", (self.config.mappings or {}).card_raw,
      function() self:_toggle_card_details_raw() end)
  end
  return true
end

return M
