local input = require("neoagent.ui.input")
local layout = require("neoagent.ui.layout")
local dialog = require("neoagent.ui.dialog")
local cards = require("neoagent.ui.cards")
local provider_console = require("neoagent.ui.provider_console")
local renderer_protocol = require("neoagent.ui.renderer")
local renderers = require("neoagent.ui.renderers")
local transcript = require("neoagent.ui.transcript")
local util = require("neoagent.util")

local M = { layout = layout.layout }
local View = {}
View.__index = View

local function active_state(context)
  return context.state == "running" or context.state == "stopping"
    or context.state == "compacting"
end

local function token_count(value)
  if value < 1000 then return tostring(math.floor(value + 0.5)) end
  local divisor, suffix = value >= 1000000 and 1000000 or 1000, value >= 1000000 and "m" or "k"
  local formatted = string.format("%.1f", value / divisor):gsub("%.0$", "")
  return formatted .. suffix
end

local function context_status(context)
  local usage = context.context_usage
  if type(usage) ~= "table" then return nil end
  local percent = usage.percent > 0 and usage.percent < 0.1
      and "<0.1" or string.format("%.1f", usage.percent)
  return string.format("ctx %s/%s (%s%%)",
    token_count(usage.used), token_count(usage.total), percent)
end

local function bottom_border_character(border)
  if type(border) == "table" then
    local value = border[6] or border[2]
    if type(value) == "table" then value = value[1] end
    if type(value) == "string" and value ~= "" then return value end
  elseif border == "double" then
    return "═"
  elseif border == "solid" then
    return " "
  end
  return "─"
end

function View:_ensure_buffers()
  if not self.transcript_buf or not vim.api.nvim_buf_is_valid(self.transcript_buf) then
    self.transcript_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self.transcript_buf].buftype = "nofile"
    vim.bo[self.transcript_buf].bufhidden = "hide"
    vim.bo[self.transcript_buf].swapfile = false
    vim.bo[self.transcript_buf].undofile = false
    vim.bo[self.transcript_buf].filetype = "neoagent"
    vim.bo[self.transcript_buf].modifiable = false
    vim.api.nvim_create_autocmd("WinLeave", {
      group = self.augroup,
      buffer = self.transcript_buf,
      callback = function()
        self:_update_overflow_badges()
        if self.config.scroll_on_transcript_leave then self:_scroll_transcript_to_bottom() end
      end,
    })
    vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter" }, {
      group = self.augroup,
      buffer = self.transcript_buf,
      callback = function()
        self:_update_card_outline()
        self:_refresh_input_footer()
      end,
    })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = self.augroup,
      buffer = self.transcript_buf,
      callback = function() vim.cmd("stopinsert") end,
    })
  end
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    self.input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self.input_buf].buftype = "nofile"
    vim.bo[self.input_buf].bufhidden = "hide"
    vim.bo[self.input_buf].swapfile = false
    vim.bo[self.input_buf].undofile = false
    vim.bo[self.input_buf].filetype = "neoagent-input"
    vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })
    self:_map_buffers()
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = self.augroup,
      buffer = self.input_buf,
      callback = function()
        local tick = vim.api.nvim_buf_get_changedtick(self.input_buf)
        if self.history_changedtick ~= tick then self:_reset_input_history() end
      end,
    })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = self.augroup,
      buffer = self.input_buf,
      callback = function()
        self.input_footer_context = "input"
        self:_refresh_input_footer()
      end,
    })
  end
end

function View:_host_container()
  if self.position ~= "auto" then return nil end
  local best, best_area
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= self.origin_win and vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      local buf = vim.api.nvim_win_get_buf(win)
      if cfg.relative == "" and vim.bo[buf].buftype == "" then
        local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
        local area = width * height
        if not best_area or area > best_area then best, best_area = win, area end
      end
    end
  end
  if not best then return nil end
  local pos = vim.api.nvim_win_get_position(best)
  return { row = pos[1], col = pos[2], width = vim.api.nvim_win_get_width(best), height = vim.api.nvim_win_get_height(best) }
end

function View:_configs()
  local position = self.position
  local container = self:_host_container()
  if position == "auto" and not container then position = "right" end
  local provider_console = self.config.provider_console or {}
  return M.layout({
    columns = vim.o.columns,
    lines = vim.o.lines - vim.o.cmdheight,
    position = position == "auto" and "host" or position,
    container = container,
    width = self.config.width,
    height = self.config.height,
    margin = self.config.margin,
    input_height = self.config.input_height,
    border = self.config.border,
    provider = self.provider_open == true and self.provider_snapshot ~= nil,
    provider_position = provider_console.position or "right",
    provider_width = provider_console.width or 0.4,
    provider_height = provider_console.height or 0.35,
  })
end

function View:_window_options(win, transcript)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].winhl = "NormalFloat:Normal,FloatBorder:NeoagentBorder,FloatTitle:NeoagentWindowTitle"
  if transcript then vim.wo[win].spell = false end
end

function View:_title()
  local parts = {}
  local title = self.context.name or self.config.title
  if type(title) == "string" and title ~= "" then
    parts[#parts + 1] = title
  end
  parts[#parts + 1] = self.context.model or "no model"
  if type(self.context.thinking) == "string" then
    parts[#parts + 1] = "think: " .. self.context.thinking
  end
  return " " .. table.concat(parts, " · ") .. " "
end

local function slice_to_display_width(text, max_width, from_end)
  local characters = vim.fn.strchars(text)
  local low, high = 0, characters
  while low < high do
    local count = math.floor((low + high + 1) / 2)
    local start = from_end and characters - count or 0
    local candidate = vim.fn.strcharpart(text, start, count)
    if vim.fn.strdisplaywidth(candidate) <= max_width then
      low = count
    else
      high = count - 1
    end
  end
  local start = from_end and characters - low or 0
  return vim.fn.strcharpart(text, start, low)
end

local function truncate_right(text, max_width)
  if vim.fn.strdisplaywidth(text) <= max_width then return text end
  if max_width == 1 then return "…" end
  return slice_to_display_width(text, max_width - 1, false) .. "…"
end

local function mapping_hint(mapping)
  if type(mapping) == "string" then return mapping end
  if type(mapping) == "table" then return mapping[1] end
end

function View:_footer_context()
  local current = vim.api.nvim_get_current_win()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win)
      and current == self.input_win
      and self.input_footer_context ~= "input" then
    self.input_footer_context = "input"
  elseif self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win)
      and current == self.transcript_win then
    self.input_footer_context = "transcript"
  end
  return self.input_footer_context or "input"
end

function View:_input_footer(width)
  width = math.max(1, width or 1)
  local mappings = self.config.mappings or {}
  local context = self:_footer_context()
  local items
  if context == "input" then
    items = {
      { action = "select_history", label = "history" },
      { action = "resume_session", label = "resume" },
      { action = "select_model", label = "select model" },
      { action = "interrupt", label = "clear/cancel" },
    }
  else
    items = {
      { action = "card_details", label = "details" },
      { action = "resume_session", label = "resume" },
      { action = "select_model", label = "select model" },
      { action = "focus_provider", label = "provider" },
      { action = "interrupt", label = "clear/cancel" },
    }
  end
  local text = ""
  local count = 0
  for _, item in ipairs(items) do
    local key = mapping_hint(mappings[item.action])
    if key then
      local separator = count == 0 and " " or " · "
      local candidate = text .. separator .. key .. " " .. item.label
      if vim.fn.strdisplaywidth(candidate .. " ") <= width then
        text = candidate
        count = count + 1
      end
    end
  end
  return truncate_right(text .. " ", width)
end

function View:_refresh_input_footer()
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return false
  end
  local config = vim.api.nvim_win_get_config(self.input_win)
  config.footer = self:_input_footer(vim.api.nvim_win_get_width(self.input_win))
  config.footer_pos = "center"
  vim.api.nvim_win_set_config(self.input_win, config)
  return true
end

local function fit_left_chunks(chunks, width, max_width)
  if width <= max_width then return chunks, width end
  if max_width <= 0 then return {}, 0 end
  local remaining = max_width - 1
  local fitted = {}
  for index = #chunks, 1, -1 do
    if remaining <= 0 then break end
    local chunk = chunks[index]
    local chunk_width = vim.fn.strdisplaywidth(chunk[1])
    if chunk_width <= remaining then
      table.insert(fitted, 1, chunk)
      remaining = remaining - chunk_width
    else
      local suffix = slice_to_display_width(chunk[1], remaining, true)
      if suffix ~= "" then
        table.insert(fitted, 1, { suffix, chunk[2] })
        remaining = remaining - vim.fn.strdisplaywidth(suffix)
      end
    end
  end
  table.insert(fitted, 1, { "…", "NeoagentMuted" })
  local fitted_width = 0
  for _, chunk in ipairs(fitted) do
    fitted_width = fitted_width + vim.fn.strdisplaywidth(chunk[1])
  end
  return fitted, fitted_width
end

function View:_transcript_footer(width)
  width = math.max(1, width or 1)
  local left = {}
  local left_width = 0
  local function add_left(text, group)
    left[#left + 1] = { text, group }
    left_width = left_width + vim.fn.strdisplaywidth(text)
  end
  local waiting = self.dialog ~= nil
  local active = active_state(self.context)
  local spinning = active and not waiting
  local label = waiting and "Waiting for response"
    or active and (self.context.state == "stopping" and "Stopping..."
      or self.context.state == "compacting" and "Compacting..." or "Working...")
    or "Idle"
  local label_padding = waiting and 1
    or vim.fn.strdisplaywidth("Compacting...")
      - vim.fn.strdisplaywidth(label) + 1
  add_left(" ", "NeoagentMuted")
  add_left(spinning and self.spinner_frames[self.spinner_frame] or " ",
    spinning and "NeoagentAccent" or "NeoagentMuted")
  add_left(" " .. label .. string.rep(" ", label_padding),
    waiting and "NeoagentDialogAction" or "NeoagentMuted")

  local right_parts = {}
  local context = context_status(self.context)
  if context then right_parts[#right_parts + 1] = context end
  local right = #right_parts > 0 and " " .. table.concat(right_parts, " ") .. " " or nil
  if not active and not waiting and not right then
    local idle = truncate_right(" Idle ", width)
    local idle_width = vim.fn.strdisplaywidth(idle)
    local before = math.floor((width - idle_width) / 2)
    local after = width - idle_width - before
    local border = bottom_border_character(self.config.border)
    local centered = {}
    if before > 0 then centered[#centered + 1] = { string.rep(border, before), "NeoagentBorder" } end
    centered[#centered + 1] = { idle, "NeoagentMuted" }
    if after > 0 then centered[#centered + 1] = { string.rep(border, after), "NeoagentBorder" } end
    return centered
  end

  local midpoint = math.floor(width / 2)
  left, left_width = fit_left_chunks(left, left_width, midpoint)
  if right then right = truncate_right(right, width - midpoint) end

  local chunks = {}
  local used = 0
  local function add(text, group)
    if text == "" then return end
    chunks[#chunks + 1] = { text, group }
    used = used + vim.fn.strdisplaywidth(text)
  end
  add(string.rep(bottom_border_character(self.config.border), midpoint - left_width), "NeoagentBorder")
  for _, chunk in ipairs(left) do add(chunk[1], chunk[2]) end
  if right then add(right, "NeoagentMuted") end
  add(string.rep(bottom_border_character(self.config.border), width - used), "NeoagentBorder")
  return chunks
end

function View:_decorate(configs)
  configs.transcript.title = self:_title()
  configs.transcript.title_pos = "center"
  configs.transcript.footer = self:_transcript_footer(configs.transcript.width)
  configs.transcript.footer_pos = "left"
  configs.input.footer = self:_input_footer(configs.input.width)
  configs.input.footer_pos = "center"
end

function View:_refresh_transcript_border()
  if not self.transcript_win or not vim.api.nvim_win_is_valid(self.transcript_win) then return false end
  if transcript.interaction_pending(self) then
    self.border_dirty = true
    return false
  end
  local cfg = vim.api.nvim_win_get_config(self.transcript_win)
  cfg.title = self:_title()
  cfg.title_pos = "center"
  cfg.footer = self:_transcript_footer(vim.api.nvim_win_get_width(self.transcript_win))
  cfg.footer_pos = "left"
  vim.api.nvim_win_set_config(self.transcript_win, cfg)
  self.border_dirty = false
  return true
end

function View:open(origin)
  if self:is_open() then
    self:focus_input()
    return true
  end
  local reopening = self.has_opened
  self:_ensure_buffers()
  self.input_footer_context = "input"
  self.origin_win = origin or vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(self.origin_win) then
    self.origin_buf = vim.api.nvim_win_get_buf(self.origin_win)
    self.origin_cursor = vim.api.nvim_win_get_cursor(self.origin_win)
  end
  local configs, err = self:_configs()
  if not configs then vim.notify(err, vim.log.levels.ERROR) return nil, err end
  self:_decorate(configs)
  self.transcript_win = vim.api.nvim_open_win(self.transcript_buf, false, configs.transcript)
  self.input_win = vim.api.nvim_open_win(self.input_buf, true, configs.input)
  self:_window_options(self.transcript_win, true)
  self:_window_options(self.input_win, false)
  self:_flush()
  self.has_opened = true
  if self.provider_open and self.provider_snapshot then
    self:_open_provider(false)
  end
  if reopening and self.config.scroll_on_reopen then self:_scroll_transcript_to_bottom() end
  self:_sync_spinner()
  if self.dialog then
    self:_show_dialog()
  else
    self:focus_input()
  end
  return true
end

function View:close()
  self:_close_card_details(false)
  self:_close_provider(false)
  self.provider_open = false
  self:_hide_dialog_surface()
  self:_stop_spinner()
  local transcript_win, input_win = self.transcript_win, self.input_win
  if input_win and vim.api.nvim_win_is_valid(input_win)
      and vim.api.nvim_get_current_win() == input_win
      and vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end
  self.transcript_win, self.input_win = nil, nil
  if transcript_win and vim.api.nvim_win_is_valid(transcript_win) then vim.api.nvim_win_close(transcript_win, true) end
  if input_win and vim.api.nvim_win_is_valid(input_win) then vim.api.nvim_win_close(input_win, true) end
  if self.origin_win and vim.api.nvim_win_is_valid(self.origin_win) then
    vim.api.nvim_set_current_win(self.origin_win)
    if self.origin_cursor then pcall(vim.api.nvim_win_set_cursor, self.origin_win, self.origin_cursor) end
  end
end

function View:_restore_steering()
  local messages = util.copy(self.on_dequeue_steering())
  if type(messages) ~= "table" or #messages == 0 then return 0 end
  local current = self:get_input()
  if util.trim(current) ~= "" then messages[#messages + 1] = current end
  self:set_input(table.concat(messages, "\n\n"))
  self:focus_input()
  return #messages
end

function View:_interrupt()
  if self:get_input() ~= "" then
    self:set_input("")
    self:focus_input()
    return false
  end
  if active_state(self.context) then
    self:_restore_steering()
    return self.on_stop()
  end
  return false
end

function View:destroy()
  self:close()
  self.dialog = nil
  self.destroyed = true
  if self.augroup then pcall(vim.api.nvim_del_augroup_by_id, self.augroup) end
  for _, buffer in ipairs({ self.transcript_buf, self.input_buf, self.provider_buf }) do
    if buffer and vim.api.nvim_buf_is_valid(buffer) then pcall(vim.api.nvim_buf_delete, buffer, { force = true }) end
  end
end

function View:is_open()
  return self.transcript_win ~= nil and self.input_win ~= nil
    and vim.api.nvim_win_is_valid(self.transcript_win) and vim.api.nvim_win_is_valid(self.input_win)
end

function View:set_context(context)
  self.context = vim.tbl_extend("force", self.context or {}, context or {})
  if context and context.position and context.position ~= self.position then
    self:set_position(context.position)
  end
  self:_refresh_transcript_border()
  self:_sync_spinner()
  self:_schedule_flush()
end

function View:_presentation_options(block)
  local tool
  if block and block.kind == "tool" and type(self.resolve_tool) == "function" then
    local name = block.name or block.call and block.call.name
      or block.message and block.message.toolName
    local ok, resolved = pcall(self.resolve_tool, name)
    if ok and type(resolved) == "table" then
      tool = { name = resolved.name, render = resolved.render }
    end
  end
  return {
    width = self:_content_width(),
    spinner = self.spinner_frames[self.spinner_frame],
    details_key = mapping_hint((self.config.mappings or {}).card_details),
    wrap_cards = self.config.wrap_cards == true,
    tool = tool,
  }
end

function View:_render_block(block, neighbors)
  local opts = self:_presentation_options(block)
  opts.previous = neighbors and neighbors.previous or nil
  opts.following = neighbors and neighbors.next or nil
  local content, err = renderer_protocol.render_block(
    self.renderer, block, opts)
  if not content then error(err.message, 0) end
  return content
end

function View:_render_details(block, opts)
  local options = self:_presentation_options(block)
  options.width = opts and opts.width or options.width
  local content, err = renderer_protocol.render_details(
    self.renderer, block, options)
  if err then error(err.message, 0) end
  return content
end

function View:_render_dialog(snapshot, opts)
  local content, err = renderer_protocol.render_dialog(
    self.renderer, snapshot, opts)
  if not content then error(err.message, 0) end
  return content
end

function View:_present_status(status, opts)
  local content, err = renderer_protocol.render_status(
    self.renderer, status, opts)
  if err then error(err.message, 0) end
  return content
end

function View:_present_focus(block, opts)
  local decorations, err = renderer_protocol.render_focus(
    self.renderer, block, opts)
  if not decorations then error(err.message, 0) end
  return decorations
end

function View:_stop_spinner()
  if not self.spinner_timer then return end
  self.spinner_timer:stop()
  self.spinner_timer:close()
  self.spinner_timer = nil
end

function View:_sync_spinner()
  local active = active_state(self.context) and not self.dialog
  if not active or not self:is_open() then
    self:_stop_spinner()
    self:_schedule_flush()
    return
  end
  if self.spinner_timer then return end
  local timer = vim.uv.new_timer()
  self.spinner_timer = timer
  timer:start(80, 80, vim.schedule_wrap(function()
    if self.destroyed or self.spinner_timer ~= timer then return end
    self.spinner_frame = self.spinner_frame % #self.spinner_frames + 1
    self:_refresh_transcript_border()
    local animated = false
    for _, block in ipairs(self.blocks) do
      if block.animated then
        block.dirty = true
        animated = true
      end
    end
    if animated then self:_schedule_flush() end
  end))
  self:_schedule_flush()
end

function View:set_position(position)
  assert(({ left = true, right = true, top = true, bottom = true, center = true, auto = true })[position], "invalid position")
  self.position = position
  if not self:is_open() then return end
  local focused = vim.api.nvim_get_current_win()
  local mode = vim.api.nvim_get_mode().mode
  local configs, err = self:_configs()
  if not configs then vim.notify(err, vim.log.levels.ERROR) return nil, err end
  self:_decorate(configs)
  vim.api.nvim_win_set_config(self.transcript_win, configs.transcript)
  vim.api.nvim_win_set_config(self.input_win, configs.input)
  self:_layout_provider()
  self.full_dirty = true
  self:_schedule_flush()
  if vim.api.nvim_win_is_valid(focused) then vim.api.nvim_set_current_win(focused) end
  if mode:sub(1, 1) == "i" and focused == self.input_win then vim.cmd("startinsert") end
  return true
end

function View:set_renderer(renderer)
  local selected, err = renderer_protocol.validate(renderer)
  if not selected then return nil, err end
  if self.renderer == selected then return selected end
  local defined, define_err = renderer_protocol.define_highlights(selected)
  if not defined then return nil, define_err end
  local dialog_visible = self.dialog ~= nil and self:is_open()
  if dialog_visible then self:_hide_dialog_surface() end
  self.renderer = selected
  self.config.renderer = selected
  self.full_dirty = true
  self:_schedule_flush()
  if dialog_visible then self:_show_dialog() end
  return selected
end

function View:set_style(style)
  local renderer = renderers.get(style)
  if not renderer then
    return nil, util.error("ui", "transcript style must be pi or codex")
  end
  if self.config.style == style and self.renderer == renderer then return style end
  local selected, err = self:set_renderer(renderer)
  if not selected then return nil, err end
  self.config.style = style
  return style
end

function View:focus_transcript()
  if self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win) then
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(self.transcript_win)
    self:_update_card_outline()
    self:_refresh_input_footer()
  end
end

function View:focus_input()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    vim.api.nvim_set_current_win(self.input_win)
    self.input_footer_context = "input"
    self:_refresh_input_footer()
    vim.cmd("startinsert!")
    vim.schedule(function()
      if not self.destroyed and self:is_open()
          and vim.api.nvim_get_current_win() == self.input_win
          and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
        vim.cmd("startinsert!")
      end
    end)
  end
end

View._scroll_transcript_to_bottom = transcript._scroll_transcript_to_bottom
View._save_view = transcript._save_view
View._restore_view = transcript._restore_view
View._content_width = transcript._content_width
View._mark_block = transcript._mark_block
View._remove_status = transcript._remove_status
View._render_dialog_status = transcript._render_dialog_status
View._render_status = transcript._render_status
View._flush = transcript._flush
View._schedule_flush = transcript._schedule_flush
View._add_block = transcript._add_block
View._message = transcript._message
View.set_messages = transcript.set_messages
View.apply = transcript.apply
View.finish = transcript.finish

View._copy_transcript_marks = dialog._copy_transcript_marks
View._hide_dialog_surface = dialog._hide_dialog_surface
View._dialog_input = dialog._dialog_input
View._respond_to_dialog = dialog._respond_to_dialog
View._map_dialog_actions = dialog._map_dialog_actions
View._map_dialog_navigation = dialog._map_dialog_navigation
View._show_transcript_dialog = dialog._show_transcript_dialog
View._show_float_dialog = dialog._show_float_dialog
View._show_dialog = dialog._show_dialog
View.set_dialog = dialog.set_dialog

View._complete_input = input._complete_input
View._map = input._map
local map_buffers = input._map_buffers
View._map_buffers = function(self, ...)
  local result = { map_buffers(self, ...) }
  self:_map_provider_toggle()
  return unpack(result)
end
View.get_input = input.get_input
View._reset_input_history = input._reset_input_history
View._set_history_input = input._set_history_input
View._browse_input_history = input._browse_input_history
View._move_input_history = input._move_input_history
View.set_input = input.set_input

View._card_at_cursor = cards._card_at_cursor
View._move_card = cards._move_card
View._move_card_details = cards._move_card_details
View._clear_card_outline = cards._clear_card_outline
View._update_overflow_badges = cards._update_overflow_badges
View._update_card_outline = cards._update_card_outline
View._refresh_card_details = cards._refresh_card_details
View._close_card_details = cards._close_card_details
View._card_details_closed = cards._card_details_closed
View._toggle_card_details_raw = cards._toggle_card_details_raw
View.show_card_details = cards.show_card_details

View._provider_width = provider_console._provider_width
View._provider_content = provider_console._provider_content
View._ensure_provider_buffer = provider_console._ensure_provider_buffer
View._provider_rows = provider_console._provider_rows
View._provider_row = provider_console._provider_row
View._move_provider = provider_console._move_provider
View._select_provider = provider_console._select_provider
View._refresh_provider = provider_console._refresh_provider
View._schedule_provider_refresh = provider_console._schedule_provider_refresh
View._map_provider_buffer = provider_console._map_provider_buffer
View._open_provider = provider_console._open_provider
View._close_provider = provider_console._close_provider
View._provider_closed = provider_console._provider_closed
View._layout_provider = provider_console._layout_provider
View._toggle_provider = provider_console._toggle_provider
View._map_provider_toggle = provider_console._map_provider_toggle
View.set_provider = provider_console.set_provider
View.set_provider_open = provider_console.set_provider_open
View.focus_provider = provider_console.focus_provider

function M.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "UI config is required")
  local renderer = opts.config.renderer or renderers.get(opts.config.style)
  renderer_protocol.assert(renderer, "UI Renderer")
  local defined, define_err = renderer_protocol.define_highlights(renderer)
  assert(defined, define_err and define_err.message
    or "UI Renderer highlight definition failed")
  local view = setmetatable({
    config = util.copy(opts.config),
    renderer = renderer,
    on_submit = opts.on_submit or function() end,
    on_stop = opts.on_stop or function() end,
    on_dequeue_steering = opts.on_dequeue_steering or function() return {} end,
    on_input_history = opts.on_input_history or function() return {} end,
    on_select_history = opts.on_select_history or function() end,
    on_cycle_thinking = opts.on_cycle_thinking or function() end,
    on_cycle_agent = opts.on_cycle_agent or function() end,
    on_select_model = opts.on_select_model or function() end,
    on_resume_session = opts.on_resume_session or function() end,
    on_dialog_action = opts.on_dialog_action or function() end,
    on_dialog_dismiss = opts.on_dialog_dismiss or function() end,
    on_provider_action = opts.on_provider_action or function() end,
    on_provider_close = opts.on_provider_close or function() end,
    on_provider_toggle = opts.on_provider_toggle,
    resolve_tool = opts.resolve_tool or function() end,
    namespace = vim.api.nvim_create_namespace("neoagent-view-" .. tostring(vim.uv.hrtime())),
    card_namespace = vim.api.nvim_create_namespace(
      "neoagent-card-outline-" .. tostring(vim.uv.hrtime())),
    blocks = {}, messages = {}, calls = {}, pending_calls = {}, response = 1,
    context = { state = "idle" },
    position = opts.config.position or "auto",
    spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    spinner_frame = 1,
    history_index = 0,
    has_opened = false,
    provider_buf = nil,
    provider_win = nil,
    provider_open = false,
    provider_snapshot = nil,
    provider_targets = nil,
    provider_refresh_pending = false,
    provider_counter = 0,
  }, View)
  if not view.on_provider_toggle then
    view.on_provider_toggle = function() view:_toggle_provider() end
  end
  view.augroup = vim.api.nvim_create_augroup("NeoagentView" .. tostring(view.namespace), { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "WinNew", "WinClosed" }, {
    group = view.augroup,
    callback = function(event)
      if event.event == "WinClosed" then
        local closed = tonumber(event.match)
        if view:_card_details_closed(closed) then return end
        if view:_provider_closed(closed) then
          view.on_provider_close()
          return
        end
        if closed == view.dialog_win and not view.hiding_dialog then
          local id = view.dialog and view.dialog.active.id
          view.dialog_win = nil
          vim.schedule(function()
            if id and view.dialog and view.dialog.active.id == id then
              view.on_dialog_dismiss(id)
            end
          end)
        end
        if closed == view.transcript_win or closed == view.input_win then
          vim.schedule(function()
            if closed == view.transcript_win or closed == view.input_win then view:close() end
          end)
        end
        return
      end
      if view:is_open() and not view.layout_pending then
        view.layout_pending = true
        vim.schedule(function()
          view.layout_pending = false
          if view:is_open() then view:set_position(view.position) end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = view.augroup,
    callback = function()
      local ok, err = renderer_protocol.define_highlights(view.renderer)
      if not ok then vim.notify("neoagent: " .. err.message, vim.log.levels.ERROR) end
    end,
  })
  return view
end

M.View = View

return M
