local source_syntax = require("neoagent.ui.source_syntax")
local presentation = require("neoagent.ui.presentation")
local util = require("neoagent.util")

local M = {}

local selection_modes = {
  v = true,
  V = true,
  ["\22"] = true,
  s = true,
  S = true,
  ["\19"] = true,
}

function M.interaction_pending(view)
  if not view.transcript_win
      or not vim.api.nvim_win_is_valid(view.transcript_win) then
    return false
  end
  local current = vim.api.nvim_get_current_win()
  if current ~= view.transcript_win and current ~= view.input_win then
    return false
  end
  if view.register_pending then return true end
  if vim.fn.state("o") == "" then return false end
  if current == view.transcript_win then return true end
  local mode = vim.api.nvim_get_mode().mode
  return selection_modes[mode] == true
    or mode:sub(1, 2) == "no"
end

function M.track_interactions(view)
  if view.interaction_namespace then return end
  local namespace = vim.api.nvim_create_namespace(
    "neoagent-interaction-" .. tostring(vim.uv.hrtime()))
  view.interaction_namespace = namespace
  vim.on_key(function(key)
    if view.destroyed or key ~= '"' then return end
    local current = vim.api.nvim_get_current_win()
    if current ~= view.transcript_win and current ~= view.input_win then
      return
    end
    if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then return end
    view.register_pending = true
    view:_stop_spinner()
    if view.register_safe_autocmd then return end
    local id
    id = vim.api.nvim_create_autocmd("SafeState", {
      group = view.augroup,
      once = true,
      callback = function()
        if view.register_safe_autocmd == id then
          view.register_safe_autocmd = nil
        end
        view.register_pending = false
        if not view.destroyed then view:_sync_spinner() end
      end,
    })
    view.register_safe_autocmd = id
  end, namespace)
end

function M.stop_tracking_interactions(view)
  if not view.interaction_namespace then return end
  vim.on_key(nil, view.interaction_namespace)
  view.interaction_namespace = nil
  if view.register_safe_autocmd then
    pcall(vim.api.nvim_del_autocmd, view.register_safe_autocmd)
    view.register_safe_autocmd = nil
  end
  view.register_pending = false
end

local function flush_when_safe(view)
  if view.safe_flush_autocmd then return end
  local id
  id = vim.api.nvim_create_autocmd("SafeState", {
    group = view.augroup,
    once = true,
    callback = function()
      if view.safe_flush_autocmd == id then view.safe_flush_autocmd = nil end
      if view.destroyed then return end
      view.flush_pending = false
      view:_schedule_flush()
    end,
  })
  view.safe_flush_autocmd = id
end

local function clear_safe_flush(view)
  if not view.safe_flush_autocmd then return end
  pcall(vim.api.nvim_del_autocmd, view.safe_flush_autocmd)
  view.safe_flush_autocmd = nil
end

function M:_scroll_transcript_to_bottom()
  if not self.transcript_win or not vim.api.nvim_win_is_valid(self.transcript_win)
      or not self.transcript_buf or not vim.api.nvim_buf_is_valid(self.transcript_buf)
      or vim.api.nvim_win_get_buf(self.transcript_win) ~= self.transcript_buf then
    return false
  end
  vim.api.nvim_win_call(self.transcript_win, function()
    local count = vim.api.nvim_buf_line_count(self.transcript_buf)
    vim.api.nvim_win_set_cursor(0, { count, 0 })
    vim.cmd("normal! zb")
  end)
  return true
end

function M:_save_view()
  if not self.transcript_win or not vim.api.nvim_win_is_valid(self.transcript_win)
      or vim.api.nvim_win_get_buf(self.transcript_win) ~= self.transcript_buf then
    return nil
  end
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

function M:_restore_view(state)
  if not state or not vim.api.nvim_win_is_valid(self.transcript_win)
      or vim.api.nvim_win_get_buf(self.transcript_win) ~= self.transcript_buf then
    return
  end
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

function M:_content_width()
  if self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win) then
    return math.max(1, vim.api.nvim_win_get_width(self.transcript_win) - 2)
  end
  return math.max(1, vim.o.columns - 2)
end

local function clear_block_marks(view, block)
  for _, mark in ipairs(block.marks or {}) do
    pcall(vim.api.nvim_buf_del_extmark,
      view.transcript_buf, view.namespace, mark)
  end
  block.mark = nil
  block.marks = nil
end

function M:_mark_block(block, start, finish, content)
  local marks = {}
  local function mark(row, col, options)
    local id = vim.api.nvim_buf_set_extmark(
      self.transcript_buf, self.namespace, row, col, options)
    marks[#marks + 1] = id
    return id
  end
  block.mark = mark(start, 0, {
    end_row = finish,
    right_gravity = true,
    end_right_gravity = false,
  })
  block.marks = marks
  block.card = content.card
  block.separators = content.separators
  block.source = content.source
  block.animated = content.animated == true
  block.focus = util.copy(content.focus)
  for row, group in pairs(content.line_groups) do
    mark(start + row, 0, {
      line_hl_group = group,
      priority = 50,
    })
  end
  for _, span in ipairs(content.highlights) do
    mark(start + span.row, span.col, {
      end_row = start + span.row,
      end_col = span.end_col,
      hl_group = span.group,
      priority = span.priority or 100,
    })
  end
  block.dirty = false
end

local function apply_transcript_source_syntax(view)
  local sources = {}
  for _, block in ipairs(view.blocks) do
    if block.source and block.mark then
      local position = vim.api.nvim_buf_get_extmark_by_id(
        view.transcript_buf, view.namespace, block.mark, {})
      if #position > 0 then
        sources[#sources + 1] = {
          path = block.source.path,
          first = position[1] + block.source.first,
          last = position[1] + block.source.last,
        }
      end
    end
  end
  local lines = vim.api.nvim_buf_get_lines(
    view.transcript_buf, 0, -1, false)
  source_syntax.apply(view.transcript_buf, sources, lines)
end

function M:_remove_status()
  if self.status_mark then
    pcall(vim.api.nvim_buf_del_extmark,
      self.transcript_buf, self.namespace, self.status_mark)
  end
  if self.dialog_status_mark and self.dialog_buf
      and vim.api.nvim_buf_is_valid(self.dialog_buf) then
    pcall(vim.api.nvim_buf_del_extmark,
      self.dialog_buf, self.namespace, self.dialog_status_mark)
  end
  self.status_mark = nil
  self.dialog_status_mark = nil
end

local function status_lines(view)
  local key = (view.config.mappings or {}).dequeue_steering
  local hint = type(key) == "table" and key[1] or key
  local content = view:_present_status({
    steering = util.copy(view.context.steering or {}),
  }, { dequeue_key = hint or "Alt-Up" })
  return content and presentation.virtual_lines(content)
end

function M:_render_dialog_status(lines)
  if not self.dialog_buf
      or self.dialog_win
      or not vim.api.nvim_buf_is_valid(self.dialog_buf) then
    return
  end
  lines = lines or status_lines(self)
  if not lines then return end
  local row = math.min(self.dialog_status_row or 0,
    vim.api.nvim_buf_line_count(self.dialog_buf) - 1)
  self.dialog_status_mark = vim.api.nvim_buf_set_extmark(
    self.dialog_buf, self.namespace, row, 0, {
      virt_lines = lines,
      virt_lines_above = true,
    })
end

function M:_render_status()
  local lines = status_lines(self)
  if not lines then return end
  local row = math.max(0, vim.api.nvim_buf_line_count(self.transcript_buf) - 1)
  self.status_mark = vim.api.nvim_buf_set_extmark(self.transcript_buf, self.namespace, row, 0, {
    virt_lines = lines,
    virt_lines_above = true,
  })
  self:_render_dialog_status(lines)
end

function M:_flush()
  if M.interaction_pending(self) then
    flush_when_safe(self)
    return
  end
  clear_safe_flush(self)
  self.flush_pending = false
  if self.border_dirty then self:_refresh_transcript_border() end
  if not self.transcript_buf or not vim.api.nvim_buf_is_valid(self.transcript_buf) then return end
  local saved = self:_save_view()
  vim.bo[self.transcript_buf].modifiable = true
  self:_remove_status()
  if self.full_dirty then
    vim.api.nvim_buf_clear_namespace(self.transcript_buf, self.namespace, 0, -1)
    local lines = {}
    local ranges = {}
    for index, block in ipairs(self.blocks) do
      local content = self:_render_block(block, {
        previous = self.blocks[index - 1],
        next = self.blocks[index + 1],
      })
      local start = #lines
      vim.list_extend(lines, content.lines)
      ranges[#ranges + 1] = { block = block, content = content, start = start, finish = #lines }
    end
    if #lines == 0 then lines = { "" } end
    vim.api.nvim_buf_set_lines(self.transcript_buf, 0, -1, false, lines)
    for _, range in ipairs(ranges) do
      self:_mark_block(range.block, range.start, range.finish, range.content)
    end
    self.has_rendered = #ranges > 0
    self.full_dirty = false
  else
    local rendered, appended = {}, {}
    for index, block in ipairs(self.blocks) do
      if block.dirty then
        local position = block.mark and vim.api.nvim_buf_get_extmark_by_id(
          self.transcript_buf, self.namespace, block.mark, { details = true }
        ) or {}
        local target = #position > 0 and rendered or appended
        target[#target + 1] = {
          block = block,
          content = self:_render_block(block, {
            previous = self.blocks[index - 1],
            next = self.blocks[index + 1],
          }),
          start = position[1],
          finish = position[3] and position[3].end_row,
        }
      end
    end
    for index = #rendered, 1, -1 do
      local range = rendered[index]
      clear_block_marks(self, range.block)
      vim.api.nvim_buf_set_lines(self.transcript_buf,
        range.start, range.finish, false, range.content.lines)
      self:_mark_block(range.block, range.start,
        range.start + #range.content.lines, range.content)
    end
    for _, range in ipairs(appended) do
      local count = vim.api.nvim_buf_line_count(self.transcript_buf)
      local start = self.has_rendered and count or 0
      local finish = self.has_rendered and count or count
      vim.api.nvim_buf_set_lines(
        self.transcript_buf, start, finish, false, range.content.lines)
      self:_mark_block(range.block, start,
        start + #range.content.lines, range.content)
      self.has_rendered = true
    end
  end
  self:_render_status()
  apply_transcript_source_syntax(self)
  vim.bo[self.transcript_buf].modifiable = false
  self:_restore_view(saved)
  self:_refresh_card_details()
  self:_update_card_outline()
  self:_refresh_input_footer()
end

function M:_schedule_flush()
  if M.interaction_pending(self) then
    self.flush_pending = true
    flush_when_safe(self)
    return
  end
  if self.flush_pending then return end
  self.flush_pending = true
  vim.schedule(function()
    if not self.destroyed then self:_flush() end
  end)
end

function M:_add_block(block)
  local previous = self.blocks[#self.blocks]
  if previous then previous.dirty = true end
  block.dirty = true
  self.blocks[#self.blocks + 1] = block
  self:_schedule_flush()
  return block
end

function M:_message(message)
  if message.role == "user" then
    return self:_add_block({
      kind = "user",
      content = util.copy(message.content),
      text = util.text_content(message.content),
    })
  elseif message.role == "assistant" then
    for _, content in ipairs(message.content or {}) do
      if content.type == "thinking" then
        if self.config.show_thinking ~= false then
          self:_add_block({ kind = "thinking", text = content.thinking or "" })
        end
      elseif content.type == "text" then
        self:_add_block({ kind = "assistant", text = content.text or "" })
      elseif content.type == "toolCall" then
        local block = self:_add_block({
          kind = "tool",
          name = content.name,
          state = "pending",
          call = util.copy(content),
        })
        if content.id then self.calls[content.id] = block end
      end
    end
  elseif message.role == "toolResult" then
    local block = self.calls[message.toolCallId]
    if block and block.finished then return block end
    if not block then
      block = self:_add_block({ kind = "tool", name = message.toolName, call = { name = message.toolName, arguments = {} } })
      if message.toolCallId then self.calls[message.toolCallId] = block end
    end
    block.message = util.copy(message)
    block.state = message.isError and "error" or "success"
    block.finished, block.dirty = true, true
    return block
  elseif message.role == "compactionSummary" then
    return self:_add_block({
      kind = "compaction",
      summary = message.summary or "",
      tokens_before = message.tokensBefore,
    })
  elseif message.role == "branchSummary" then
    return self:_add_block({ kind = "notice", text = "Branch context\n" .. (message.summary or "") })
  elseif message.role == "custom" and message.display then
    return self:_add_block({ kind = "notice", text = util.text_content(message.content) })
  elseif message.role == "bashExecution" then
    local text = "$ " .. (message.command or "")
    if message.output and message.output ~= "" then text = text .. "\n" .. message.output end
    return self:_add_block({ kind = "notice", text = text, error = message.exitCode and message.exitCode ~= 0 })
  end
end

function M:set_messages(messages)
  self:_close_card_details(false)
  self.messages = util.copy(messages or {})
  self.blocks, self.calls, self.pending_calls = {}, {}, {}
  self.response = self.response + 1
  self.live_text, self.live_texts = nil, {}
  self.live_thinking, self.live_thinkings = nil, {}
  for _, message in ipairs(self.messages) do self:_message(message) end
  self.full_dirty = true
  self:_schedule_flush()
end

function M:apply(event)
  if event.type == "text_delta" then
    self.live_texts = self.live_texts or {}
    local key = event.index ~= nil and tostring(event.index) or "default"
    local block = self.live_texts[key]
    if not block then
      block = self:_add_block({ kind = "assistant", text = "" })
      self.live_texts[key] = block
      if key == "default" then self.live_text = block end
    end
    block.text = block.text .. (event.text or "")
    block.dirty = true
  elseif event.type == "thinking_delta" then
    if self.config.show_thinking ~= false then
      self.live_thinkings = self.live_thinkings or {}
      local key = event.index ~= nil and tostring(event.index) or "default"
      local block = self.live_thinkings[key]
      if not block then
        block = self:_add_block({ kind = "thinking", text = "" })
        self.live_thinkings[key] = block
        if key == "default" then self.live_thinking = block end
      end
      block.text = block.text .. (event.text or "")
      block.dirty = true
    end
  elseif event.type == "tool_call_delta" then
    local key = self.response .. ":" .. tostring(event.index)
    local block = self.pending_calls[key]
    if not block then
      block = self:_add_block({ kind = "tool", name = event.name, state = "pending", raw = "" })
      self.pending_calls[key] = block
    end
    block.name = event.name or block.name
    block.id = event.id or block.id
    if block.id then self.calls[block.id] = block end
    block.raw = block.raw .. (event.arguments_delta or "")
    block.dirty = true
  elseif event.type == "message_end" then
    local message = event.message
    self.messages[#self.messages + 1] = util.copy(message)
    if message.role == "user" then
      self:_message(message)
    elseif message.role == "assistant" then
      local call_index = 0
      self.live_texts = self.live_texts or {}
      for _, content in ipairs(message.content or {}) do
        if content.type == "text" then
          local key = content.index ~= nil and tostring(content.index) or "default"
          local block = self.live_texts[key] or (key == "default" and self.live_text or nil)
          if block then
            block.dirty = true
          else
            block = self:_add_block({ kind = "assistant", text = content.text or "" })
            self.live_texts[key] = block
            if key == "default" then self.live_text = block end
          end
        elseif content.type == "thinking" and self.config.show_thinking ~= false then
          self.live_thinkings = self.live_thinkings or {}
          local key = content.index ~= nil and tostring(content.index) or "default"
          local block = self.live_thinkings[key]
            or (key == "default" and self.live_thinking or nil)
          if block then
            block.text = content.thinking or ""
            block.dirty = true
          else
            block = self:_add_block({ kind = "thinking", text = content.thinking or "" })
            self.live_thinkings[key] = block
            if key == "default" then self.live_thinking = block end
          end
        elseif content.type == "toolCall" then
          local block = content.id and self.calls[content.id]
            or self.pending_calls[self.response .. ":" .. call_index]
          if not block then
            block = self:_add_block({ kind = "tool", state = "pending" })
          end
          block.call = util.copy(content)
          block.id, block.name = content.id, content.name
          if content.id then self.calls[content.id] = block end
          block.dirty = true
          call_index = call_index + 1
        end
      end
      self.response = self.response + 1
      self.live_text, self.live_texts = nil, {}
      self.live_thinking, self.live_thinkings = nil, {}
    end
  elseif event.type == "tool_start" then
    local block = self.calls[event.call.id]
    if not block then
      block = self:_add_block({ kind = "tool" })
      self.calls[event.call.id] = block
    end
    block.call, block.name, block.state = util.copy(event.call), event.call.name, "running"
    block.dirty = true
  elseif event.type == "tool_update" then
    local block = self.calls[event.call.id]
    if block then
      block.update = util.copy(event.result)
      block.dirty = true
    end
  elseif event.type == "tool_end" then
    local message = event.message
    local block = self.calls[event.call.id]
    if not block then
      block = self:_add_block({ kind = "tool" })
      self.calls[event.call.id] = block
    end
    block.call, block.name, block.message = util.copy(event.call), event.call.name, util.copy(message)
    block.state = message.isError and "error" or "success"
    block.update, block.finished = nil, true
    block.dirty = true
  elseif event.type == "compaction_end" and event.result and not event.result.ok then
    self:_add_block({
      kind = "notice",
      text = event.result.error and event.result.error.message or "Compaction failed",
      error = true,
    })
  end
  self:_schedule_flush()
end

function M:finish(result)
  if not result.ok then
    local cancelled = result.error and result.error.kind == "cancelled"
    self:_add_block({
      kind = "notice",
      text = result.error and result.error.message or "Unknown error",
      error = not cancelled,
    })
  end
  self.context.state = "idle"
  self:set_context(self.context)
  self:_schedule_flush()
end

return M
