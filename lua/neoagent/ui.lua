local util = require("neoagent.util")

local M = {}
local View = {}
View.__index = View

local highlights = {
  NeoagentUser = "Identifier",
  NeoagentAssistant = "Normal",
  NeoagentThinking = "Comment",
  NeoagentToolPending = "DiagnosticInfo",
  NeoagentToolRunning = "DiagnosticWarn",
  NeoagentToolSuccess = "DiagnosticOk",
  NeoagentError = "DiagnosticError",
  NeoagentMuted = "Comment",
  NeoagentTitle = "Title",
  NeoagentBorder = "FloatBorder",
}

local function define_highlights()
  for name, link in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

local function border_size(border)
  if border == nil or border == "none" or border == "" then return 0 end
  return 2
end

local function dimension(value, available, fallback)
  if value == nil then return math.floor(available * fallback + 0.5) end
  if value <= 1 then return math.floor(available * value + 0.5) end
  return value
end

function M.layout(opts)
  local columns = assert(opts.columns)
  local lines = assert(opts.lines)
  local margin = opts.margin or 1
  local position = opts.position or "right"
  local container = opts.container or { row = 0, col = 0, width = columns, height = lines }
  local horizontal = position == "left" or position == "right"
  local vertical = position == "top" or position == "bottom"
  local default_width = horizontal and 0.45 or position == "center" and 0.72 or 1
  local default_height = vertical and 0.45 or position == "center" and 0.72 or 1
  local available_width = math.max(0, container.width - margin * 2)
  local available_height = math.max(0, container.height - margin * 2)
  local outer_width = math.min(available_width, dimension(opts.width, container.width, default_width))
  local outer_height = math.min(available_height, dimension(opts.height, container.height, default_height))
  local borders = border_size(opts.border)
  local content_width = outer_width - borders
  local input_height = math.min(opts.input_height or 5, outer_height - borders * 2 - 1)
  local transcript_height = outer_height - input_height - borders * 2
  if content_width < 1 or input_height < 1 or transcript_height < 1 then
    return nil, "Neoagent UI does not fit in the available editor area"
  end

  local row, col
  if position == "left" then
    row, col = container.row + margin, container.col + margin
  elseif position == "right" then
    row, col = container.row + margin, container.col + container.width - margin - outer_width
  elseif position == "top" then
    row, col = container.row + margin, container.col + margin
  elseif position == "bottom" then
    row, col = container.row + container.height - margin - outer_height, container.col + margin
  else
    row = container.row + math.floor((container.height - outer_height) / 2)
    col = container.col + math.floor((container.width - outer_width) / 2)
  end
  row = math.max(container.row, row)
  col = math.max(container.col, col)
  local common = {
    relative = "editor",
    style = "minimal",
    focusable = true,
    width = content_width,
    col = col,
    border = opts.border,
    zindex = opts.zindex or 50,
  }
  return {
    transcript = vim.tbl_extend("force", common, { row = row, height = transcript_height }),
    input = vim.tbl_extend("force", common, { row = row + transcript_height + borders, height = input_height }),
  }
end

local function split_text(text)
  return vim.split(text or "", "\n", { plain = true })
end

local function preview(value, limit)
  limit = limit or 4096
  if #value <= limit then return value end
  local half = math.floor((limit - 32) / 2)
  return value:sub(1, half) .. "\n... [omitted] ...\n" .. value:sub(-half)
end

local function stable_json(value, indent)
  indent = indent or 0
  if value == vim.NIL then return "null" end
  if type(value) ~= "table" then return vim.json.encode(value) end
  if next(value) ~= nil and util.is_list(value) then
    if #value == 0 then return "[]" end
    local parts = {}
    for _, child in ipairs(value) do parts[#parts + 1] = string.rep(" ", indent + 2) .. stable_json(child, indent + 2) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep(" ", indent) .. "]"
  end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  if #keys == 0 then return "{}" end
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = string.rep(" ", indent + 2) .. vim.json.encode(tostring(key)) .. ": " .. stable_json(value[key], indent + 2)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep(" ", indent) .. "}"
end

local function content_text(content)
  local parts = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then parts[#parts + 1] = block.text or "" end
  end
  return table.concat(parts, "\n")
end

local function image_notes(content)
  local result = {}
  if type(content) ~= "table" then return result end
  for _, block in ipairs(content or {}) do
    if block.type == "image" then
      local bytes = math.floor(#(block.data or "") * 3 / 4)
      result[#result + 1] = string.format("[image attachment: %s, approximately %d bytes]", block.mimeType or "unknown", bytes)
    end
  end
  return result
end

local function block_lines(block)
  local lines = { block.title }
  for _, line in ipairs(split_text(block.text)) do lines[#lines + 1] = line end
  for _, line in ipairs(block.extra or {}) do lines[#lines + 1] = line end
  lines[#lines + 1] = ""
  return lines
end

function View:_save_view()
  if not self.transcript_win or not vim.api.nvim_win_is_valid(self.transcript_win) then return nil end
  local current = vim.api.nvim_get_current_win()
  local mode = vim.api.nvim_get_mode().mode
  local state = { current = current == self.transcript_win, mode = mode }
  vim.api.nvim_win_call(self.transcript_win, function()
    state.view = vim.fn.winsaveview()
    state.cursor = vim.api.nvim_win_get_cursor(0)
    state.at_bottom = state.cursor[1] >= vim.api.nvim_buf_line_count(self.transcript_buf)
  end)
  return state
end

function View:_restore_view(state)
  if not state or not vim.api.nvim_win_is_valid(self.transcript_win) then return end
  local visual = state.current and (state.mode == "v" or state.mode == "V" or state.mode == "\22")
  vim.api.nvim_win_call(self.transcript_win, function()
    if state.at_bottom and not visual then
      local count = vim.api.nvim_buf_line_count(self.transcript_buf)
      vim.api.nvim_win_set_cursor(0, { count, 0 })
      vim.cmd("normal! zb")
    else
      pcall(vim.fn.winrestview, state.view)
      pcall(vim.api.nvim_win_set_cursor, 0, state.cursor)
    end
  end)
end

function View:_mark_block(block, start, finish)
  block.mark = vim.api.nvim_buf_set_extmark(self.transcript_buf, self.namespace, start, 0, {
    end_row = finish,
    right_gravity = false,
    end_right_gravity = true,
  })
  block.highlight_mark = vim.api.nvim_buf_set_extmark(self.transcript_buf, self.namespace, start, 0, {
    end_row = start,
    end_col = #block.title,
    hl_group = block.highlight,
    priority = 100,
  })
  block.dirty = false
end

function View:_flush()
  self.flush_pending = false
  if not self.transcript_buf or not vim.api.nvim_buf_is_valid(self.transcript_buf) then return end
  local saved = self:_save_view()
  vim.bo[self.transcript_buf].modifiable = true
  if self.full_dirty then
    vim.api.nvim_buf_clear_namespace(self.transcript_buf, self.namespace, 0, -1)
    local lines = {}
    local ranges = {}
    for _, block in ipairs(self.blocks) do
      local start = #lines
      vim.list_extend(lines, block_lines(block))
      ranges[#ranges + 1] = { block = block, start = start, finish = #lines }
    end
    if #lines == 0 then lines = { "" } end
    vim.api.nvim_buf_set_lines(self.transcript_buf, 0, -1, false, lines)
    for _, range in ipairs(ranges) do
      self:_mark_block(range.block, range.start, range.finish)
    end
    self.has_rendered = #ranges > 0
    self.full_dirty = false
  else
    for _, block in ipairs(self.blocks) do
      if block.dirty then
        local start, finish
        local position = block.mark and vim.api.nvim_buf_get_extmark_by_id(
          self.transcript_buf, self.namespace, block.mark, { details = true }
        ) or {}
        if #position > 0 then
          start = position[1]
          finish = position[3].end_row
          vim.api.nvim_buf_del_extmark(self.transcript_buf, self.namespace, block.mark)
          if block.highlight_mark then
            vim.api.nvim_buf_del_extmark(self.transcript_buf, self.namespace, block.highlight_mark)
          end
        else
          local count = vim.api.nvim_buf_line_count(self.transcript_buf)
          start = self.has_rendered and count or 0
          finish = self.has_rendered and count or count
        end
        local rendered = block_lines(block)
        vim.api.nvim_buf_set_lines(self.transcript_buf, start, finish, false, rendered)
        self:_mark_block(block, start, start + #rendered)
        self.has_rendered = true
      end
    end
  end
  vim.bo[self.transcript_buf].modifiable = false
  self:_restore_view(saved)
end

function View:_schedule_flush()
  if self.flush_pending then return end
  self.flush_pending = true
  vim.schedule(function()
    if not self.destroyed then self:_flush() end
  end)
end

function View:_add_block(block)
  block.dirty = true
  self.blocks[#self.blocks + 1] = block
  self:_schedule_flush()
  return block
end

function View:_message(message)
  if message.role == "user" then
    local block = self:_add_block({ title = "You", text = util.text_content(message.content), extra = image_notes(message.content), highlight = "NeoagentUser" })
    return block
  elseif message.role == "assistant" then
    for _, content in ipairs(message.content or {}) do
      if content.type == "thinking" then
        self:_add_block({ title = "Thinking", text = content.thinking or "", highlight = "NeoagentThinking" })
      elseif content.type == "text" then
        self:_add_block({ title = "Assistant", text = content.text or "", highlight = "NeoagentAssistant" })
      elseif content.type == "toolCall" then
        local block = self:_add_block({
          title = "… " .. (content.name or "<tool>") .. "  queued",
          text = preview(stable_json(content.arguments or vim.empty_dict())),
          arguments_text = preview(stable_json(content.arguments or vim.empty_dict())),
          highlight = "NeoagentToolPending",
          call = util.copy(content),
        })
        if content.id then self.calls[content.id] = block end
      end
    end
  elseif message.role == "toolResult" then
    local block = self.calls[message.toolCallId]
    if block and block.finished then return block end
    local title = (message.isError and "✗ " or "✓ ") .. (message.toolName or "<tool>")
    return self:_add_block({ title = title, text = content_text(message.content), extra = image_notes(message.content), highlight = message.isError and "NeoagentError" or "NeoagentToolSuccess", finished = true })
  end
end

function View:set_messages(messages)
  self.messages = util.copy(messages or {})
  self.blocks, self.calls, self.pending_calls = {}, {}, {}
  self.response = self.response + 1
  self.live_text, self.live_thinking = nil, nil
  for _, message in ipairs(self.messages) do self:_message(message) end
  self.full_dirty = true
  self:_schedule_flush()
end

function View:apply(event)
  if event.type == "text_delta" then
    if not self.live_text then
      self.live_text = self:_add_block({ title = "Assistant", text = "", highlight = "NeoagentAssistant" })
    end
    self.live_text.text = self.live_text.text .. (event.text or "")
    self.live_text.dirty = true
  elseif event.type == "thinking_delta" then
    if not self.live_thinking then
      self.live_thinking = self:_add_block({ title = "Thinking", text = "", highlight = "NeoagentThinking" })
    end
    self.live_thinking.text = self.live_thinking.text .. (event.text or "")
    self.live_thinking.dirty = true
  elseif event.type == "tool_call_delta" then
    local key = self.response .. ":" .. tostring(event.index)
    local block = self.pending_calls[key]
    if not block then
      block = self:_add_block({ title = "◌ <tool>  receiving", text = "", highlight = "NeoagentToolPending", raw = "" })
      self.pending_calls[key] = block
    end
    block.name = event.name or block.name
    block.id = event.id or block.id
    block.raw = block.raw .. (event.arguments_delta or "")
    block.title = "◌ " .. (block.name or "<tool>") .. "  receiving"
    block.text = preview(block.raw)
    block.dirty = true
  elseif event.type == "message_end" then
    local message = event.message
    self.messages[#self.messages + 1] = util.copy(message)
    if message.role == "assistant" then
      local call_index = 0
      for _, content in ipairs(message.content or {}) do
        if content.type == "text" then
          if not self.live_text then self.live_text = self:_add_block({ title = "Assistant", text = content.text or "", highlight = "NeoagentAssistant" }) end
        elseif content.type == "thinking" then
          if not self.live_thinking then self.live_thinking = self:_add_block({ title = "Thinking", text = content.thinking or "", highlight = "NeoagentThinking" }) end
        elseif content.type == "toolCall" then
          local block = self.pending_calls[self.response .. ":" .. call_index]
          if not block then
            block = self:_add_block({ highlight = "NeoagentToolPending" })
          end
          block.call = util.copy(content)
          block.id, block.name = content.id, content.name
          block.title = "… " .. (content.name or "<tool>") .. "  queued"
          block.arguments_text = preview(stable_json(content.arguments or vim.empty_dict()))
          block.text = block.arguments_text
          if content.id then self.calls[content.id] = block end
          block.dirty = true
          call_index = call_index + 1
        end
      end
      self.response = self.response + 1
      self.live_text, self.live_thinking = nil, nil
    end
  elseif event.type == "tool_start" then
    local block = self.calls[event.call.id]
    if not block then
      block = self:_add_block({ text = preview(stable_json(event.call.arguments or vim.empty_dict())) })
      self.calls[event.call.id] = block
    end
    block.title = "● " .. event.call.name .. "  running"
    block.highlight = "NeoagentToolRunning"
    block.dirty = true
  elseif event.type == "tool_update" then
    local block = self.calls[event.call.id]
    if block then
      local text = content_text(event.result.content)
      local tail = require("neoagent.tools.truncate").tail(text, { max_lines = 12, max_bytes = 8 * 1024 })
      block.text = (block.arguments_text and (block.arguments_text .. "\n\n") or "") .. tail.content
      block.dirty = true
    end
  elseif event.type == "tool_end" then
    local message = event.message
    local block = self.calls[event.call.id]
    if not block then
      block = self:_add_block({})
      self.calls[event.call.id] = block
    end
    block.title = (message.isError and "✗ " or "✓ ") .. event.call.name
    block.highlight = message.isError and "NeoagentError" or "NeoagentToolSuccess"
    local text = content_text(message.content)
    local head = require("neoagent.tools.truncate").head(text, { max_lines = 12, max_bytes = 8 * 1024 })
    block.text = (block.arguments_text and (block.arguments_text .. "\n\n") or "") .. head.content
    block.extra, block.finished = image_notes(message.content), true
    block.dirty = true
  end
  self:_schedule_flush()
end

function View:finish(result)
  if not result.ok then
    local cancelled = result.error and result.error.kind == "cancelled"
    self:_add_block({
      title = cancelled and "Stopped" or "Failed",
      text = result.error and result.error.message or "Unknown error",
      highlight = cancelled and "NeoagentMuted" or "NeoagentError",
    })
  end
  self.context.state = "idle"
  self:set_context(self.context)
  self:_schedule_flush()
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
  end
end

function View:_map(buffer, modes, key, callback)
  if key == false or key == nil then return end
  vim.keymap.set(modes, key, callback, { buffer = buffer, silent = true, nowait = true })
end

function View:_map_buffers()
  local mappings = self.config.mappings or {}
  self:_map(self.input_buf, { "n", "i" }, mappings.submit, function() self.on_submit(self:get_input()) end)
  self:_map(self.input_buf, { "n", "i" }, mappings.cancel_input, function()
    if self:get_input() ~= "" then self:set_input("") end
    vim.api.nvim_set_current_win(self.input_win)
    vim.cmd("startinsert")
  end)
  self:_map(self.input_buf, "n", mappings.toggle_focus, function() self:focus_transcript() end)
  self:_map(self.transcript_buf, "n", mappings.toggle_focus, function() self:focus_input() end)
  local docks = {
    dock_left = "left", dock_bottom = "bottom", dock_top = "top",
    dock_right = "right", dock_center = "center",
  }
  for action, position in pairs(docks) do
    self:_map(self.input_buf, "n", mappings[action], function() self:set_position(position) end)
    self:_map(self.transcript_buf, "n", mappings[action], function() self:set_position(position) end)
  end
  self:_map(self.transcript_buf, "n", mappings.close, function() self:close() end)
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
  vim.wo[win].winhl = "Normal:NormalFloat,FloatBorder:NeoagentBorder"
  if transcript then vim.wo[win].spell = false end
end

function View:_title()
  local model = self.context.model or "no model"
  return "Neoagent · " .. model .. " · " .. (self.context.state or "idle")
end

function View:open(origin)
  if self:is_open() then self:focus_input() return true end
  self:_ensure_buffers()
  self.origin_win = origin or vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(self.origin_win) then
    self.origin_buf = vim.api.nvim_win_get_buf(self.origin_win)
    self.origin_cursor = vim.api.nvim_win_get_cursor(self.origin_win)
  end
  local configs, err = self:_configs()
  if not configs then vim.notify(err, vim.log.levels.ERROR) return nil, err end
  configs.transcript.title = self:_title()
  configs.transcript.title_pos = "center"
  configs.input.title = "Input · " .. ((self.config.mappings or {}).submit or "send") .. " send"
  configs.input.title_pos = "center"
  self.transcript_win = vim.api.nvim_open_win(self.transcript_buf, false, configs.transcript)
  self.input_win = vim.api.nvim_open_win(self.input_buf, true, configs.input)
  self:_window_options(self.transcript_win, true)
  self:_window_options(self.input_win, false)
  self:_flush()
  vim.cmd("startinsert")
  return true
end

function View:close()
  local transcript_win, input_win = self.transcript_win, self.input_win
  self.transcript_win, self.input_win = nil, nil
  if transcript_win and vim.api.nvim_win_is_valid(transcript_win) then vim.api.nvim_win_close(transcript_win, true) end
  if input_win and vim.api.nvim_win_is_valid(input_win) then vim.api.nvim_win_close(input_win, true) end
  if self.origin_win and vim.api.nvim_win_is_valid(self.origin_win) then
    vim.api.nvim_set_current_win(self.origin_win)
    if self.origin_cursor then pcall(vim.api.nvim_win_set_cursor, self.origin_win, self.origin_cursor) end
  end
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
  if self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win) then
    local cfg = vim.api.nvim_win_get_config(self.transcript_win)
    cfg.title = self:_title()
    cfg.title_pos = "center"
    vim.api.nvim_win_set_config(self.transcript_win, cfg)
  end
end

function View:get_input()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false), "\n")
end

function View:set_input(text)
  self:_ensure_buffers()
  vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, split_text(text))
end

function View:set_position(position)
  assert(({ left = true, right = true, top = true, bottom = true, center = true, auto = true })[position], "invalid position")
  self.position = position
  if not self:is_open() then return end
  local focused = vim.api.nvim_get_current_win()
  local mode = vim.api.nvim_get_mode().mode
  local configs, err = self:_configs()
  if not configs then vim.notify(err, vim.log.levels.ERROR) return nil, err end
  configs.transcript.title = self:_title()
  configs.transcript.title_pos = "center"
  configs.input.title = "Input · " .. ((self.config.mappings or {}).submit or "send") .. " send"
  configs.input.title_pos = "center"
  vim.api.nvim_win_set_config(self.transcript_win, configs.transcript)
  vim.api.nvim_win_set_config(self.input_win, configs.input)
  if vim.api.nvim_win_is_valid(focused) then vim.api.nvim_set_current_win(focused) end
  if mode:sub(1, 1) == "i" and focused == self.input_win then vim.cmd("startinsert") end
  return true
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
    vim.cmd("startinsert")
  end
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "UI config is required")
  define_highlights()
  local view = setmetatable({
    config = util.copy(opts.config),
    on_submit = opts.on_submit or function() end,
    on_stop = opts.on_stop or function() end,
    namespace = vim.api.nvim_create_namespace("neoagent-view-" .. tostring(vim.uv.hrtime())),
    blocks = {}, messages = {}, calls = {}, pending_calls = {}, response = 1,
    context = { state = "idle" },
    position = opts.config.position or "auto",
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
  return view
end

M.View = View
M._stable_json = stable_json
M._preview = preview

return M
