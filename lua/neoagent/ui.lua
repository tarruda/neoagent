local input = require("neoagent.ui.input")
local layout = require("neoagent.ui.layout")
local render = require("neoagent.ui.render")
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
        if self.config.scroll_on_transcript_leave then self:_scroll_transcript_to_bottom() end
      end,
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
  return table.concat(parts, " · ")
end

function View:_transcript_footer(width)
  local chunks = {}
  local left_width = 0
  local function add(text, group)
    chunks[#chunks + 1] = { text, group }
    left_width = left_width + vim.fn.strdisplaywidth(text)
  end
  if active_state(self.context) then
    local label = self.context.state == "stopping" and "Stopping..."
      or self.context.state == "compacting" and "Compacting..." or "Working..."
    add(" ", "NeoagentMuted")
    add(self.spinner_frames[self.spinner_frame], "NeoagentAccent")
    add(" " .. label, "NeoagentMuted")
  end
  if #chunks > 0 then add(" ", "NeoagentMuted") end

  local right_parts = {}
  local context = context_status(self.context)
  if context then right_parts[#right_parts + 1] = context end
  local status = self.context.provider_status
  if type(status) == "string" then
    status = util.trim(status)
    if status ~= "" then right_parts[#right_parts + 1] = "(" .. status .. ")" end
  end
  if #right_parts > 0 then
    local right = " " .. table.concat(right_parts, " ") .. " "
    local padding = math.max(1, (width or 1) - left_width - vim.fn.strdisplaywidth(right))
    add(string.rep(bottom_border_character(self.config.border), padding), "NeoagentBorder")
    add(right, "NeoagentMuted")
  end
  return #chunks > 0 and chunks or ""
end

function View:_decorate(configs)
  configs.transcript.title = self:_title()
  configs.transcript.title_pos = "center"
  configs.transcript.footer = self:_transcript_footer(configs.transcript.width)
  configs.transcript.footer_pos = "left"
  configs.input.title = "Input · " .. ((self.config.mappings or {}).submit or "send") .. " send"
  configs.input.title_pos = "center"
end

function View:_refresh_transcript_border()
  if not self.transcript_win or not vim.api.nvim_win_is_valid(self.transcript_win) then return false end
  if vim.api.nvim_get_current_win() == self.transcript_win and vim.fn.state("o") ~= "" then
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
  if reopening and self.config.scroll_on_reopen then self:_scroll_transcript_to_bottom() end
  self:_sync_spinner()
  self:focus_input()
  return true
end

function View:close()
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

function View:_interrupt(clear_input)
  local active = active_state(self.context)
  if active then
    self:_restore_steering()
    return self.on_stop()
  end
  if clear_input then
    if self:get_input() ~= "" then self:set_input("") end
    self:focus_input()
  end
  return false
end

function View:destroy()
  self:close()
  self.destroyed = true
  if self.augroup then pcall(vim.api.nvim_del_augroup_by_id, self.augroup) end
  for _, buffer in ipairs({ self.transcript_buf, self.input_buf }) do
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

function View:_stop_spinner()
  if not self.spinner_timer then return end
  self.spinner_timer:stop()
  self.spinner_timer:close()
  self.spinner_timer = nil
end

function View:_sync_spinner()
  local active = active_state(self.context)
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
  self.full_dirty = true
  self:_schedule_flush()
  if vim.api.nvim_win_is_valid(focused) then vim.api.nvim_set_current_win(focused) end
  if mode:sub(1, 1) == "i" and focused == self.input_win then vim.cmd("startinsert") end
  return true
end

function View:toggle_tools()
  self.tools_expanded = not self.tools_expanded
  self.full_dirty = true
  self:_schedule_flush()
end

function View:focus_transcript()
  if self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win) then
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(self.transcript_win)
  end
end

function View:focus_input()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    vim.api.nvim_set_current_win(self.input_win)
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
View._render_status = transcript._render_status
View._flush = transcript._flush
View._schedule_flush = transcript._schedule_flush
View._add_block = transcript._add_block
View._message = transcript._message
View.set_messages = transcript.set_messages
View.apply = transcript.apply
View.finish = transcript.finish

View._complete_input = input._complete_input
View._map = input._map
View._map_buffers = input._map_buffers
View.get_input = input.get_input
View._reset_input_history = input._reset_input_history
View._set_history_input = input._set_history_input
View._browse_input_history = input._browse_input_history
View._move_input_history = input._move_input_history
View.set_input = input.set_input

function M.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "UI config is required")
  render.define_highlights()
  local view = setmetatable({
    config = util.copy(opts.config),
    on_submit = opts.on_submit or function() end,
    on_stop = opts.on_stop or function() end,
    on_dequeue_steering = opts.on_dequeue_steering or function() return {} end,
    on_input_history = opts.on_input_history or function() return {} end,
    on_select_history = opts.on_select_history or function() end,
    on_cycle_thinking = opts.on_cycle_thinking or function() end,
    on_cycle_agent = opts.on_cycle_agent or function() end,
    on_select_model = opts.on_select_model or function() end,
    on_resume_session = opts.on_resume_session or function() end,
    on_position_change = opts.on_position_change or function() end,
    namespace = vim.api.nvim_create_namespace("neoagent-view-" .. tostring(vim.uv.hrtime())),
    blocks = {}, messages = {}, calls = {}, pending_calls = {}, response = 1,
    context = { state = "idle" },
    position = opts.config.position or "auto",
    tools_expanded = false,
    spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    spinner_frame = 1,
    history_index = 0,
    has_opened = false,
  }, View)
  view.augroup = vim.api.nvim_create_augroup("NeoagentView" .. tostring(view.namespace), { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "WinNew", "WinClosed" }, {
    group = view.augroup,
    callback = function(event)
      if event.event == "WinClosed" then
        local closed = tonumber(event.match)
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
    callback = render.define_highlights,
  })
  return view
end

M.View = View

return M
