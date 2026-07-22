local render = require("neoagent.ui.render")
local util = require("neoagent.util")

local M = {}

function M:_scroll_transcript_to_bottom()
  if not self.transcript_win or not vim.api.nvim_win_is_valid(self.transcript_win)
      or not self.transcript_buf or not vim.api.nvim_buf_is_valid(self.transcript_buf) then
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

function M:_restore_view(state)
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

function M:_content_width()
  if self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win) then
    return math.max(1, vim.api.nvim_win_get_width(self.transcript_win) - 2)
  end
  return math.max(1, vim.o.columns - 2)
end

function M:_mark_block(block, start, finish, content)
  block.mark = vim.api.nvim_buf_set_extmark(self.transcript_buf, self.namespace, start, 0, {
    end_row = finish,
    right_gravity = false,
    end_right_gravity = true,
  })
  for row, group in pairs(content.line_groups) do
    vim.api.nvim_buf_set_extmark(self.transcript_buf, self.namespace, start + row, 0, {
      line_hl_group = group,
      priority = 50,
    })
  end
  for _, span in ipairs(content.highlights) do
    vim.api.nvim_buf_set_extmark(self.transcript_buf, self.namespace, start + span.row, span.col, {
      end_row = start + span.row,
      end_col = span.end_col,
      hl_group = span.group,
      priority = 100,
    })
  end
  block.dirty = false
end

function M:_remove_status()
  if not self.status_mark then return end
  local position = vim.api.nvim_buf_get_extmark_by_id(self.transcript_buf, self.namespace, self.status_mark, { details = true })
  if #position > 0 then
    for _, mark in ipairs(self.status_decorations or {}) do pcall(vim.api.nvim_buf_del_extmark, self.transcript_buf, self.namespace, mark) end
    vim.api.nvim_buf_del_extmark(self.transcript_buf, self.namespace, self.status_mark)
    vim.api.nvim_buf_set_lines(self.transcript_buf, position[1], position[3].end_row, false, {})
  end
  self.status_mark, self.status_decorations = nil, nil
end

function M:_render_status()
  local active = self.context.state == "running" or self.context.state == "stopping"
    or self.context.state == "compacting"
  local steering = type(self.context.steering) == "table" and self.context.steering or {}
  if not active and #steering == 0 then return end
  local count = vim.api.nvim_buf_line_count(self.transcript_buf)
  local start = self.has_rendered and count or 0
  local finish = self.has_rendered and count or count
  local lines = {}
  for _, message in ipairs(steering) do
    local text = util.trim(tostring(message):gsub("%s+", " "))
    lines[#lines + 1] = " Steering: " .. text
  end
  if #steering > 0 then
    local key = (self.config.mappings or {}).dequeue_steering
    local hint = type(key) == "string" and key or "Alt-Up"
    lines[#lines + 1] = " ↳ " .. hint .. " to edit queued messages"
  end
  local spinner_row
  if active then
    local frame = self.spinner_frames[self.spinner_frame]
    local label = self.context.state == "stopping" and "Stopping..."
      or self.context.state == "compacting" and "Compacting..." or "Working..."
    spinner_row = #lines
    lines[#lines + 1] = " " .. frame .. " " .. label
  end
  vim.api.nvim_buf_set_lines(self.transcript_buf, start, finish, false, lines)
  self.status_mark = vim.api.nvim_buf_set_extmark(self.transcript_buf, self.namespace, start, 0, {
    end_row = start + #lines,
    right_gravity = false,
    end_right_gravity = true,
  })
  self.status_decorations = {}
  for index, line in ipairs(lines) do
    self.status_decorations[#self.status_decorations + 1] = vim.api.nvim_buf_set_extmark(
      self.transcript_buf, self.namespace, start + index - 1, 0, {
        end_col = #line,
        hl_group = "NeoagentMuted",
        priority = 100,
      })
  end
  if spinner_row then
    local frame = self.spinner_frames[self.spinner_frame]
    self.status_decorations[#self.status_decorations + 1] = vim.api.nvim_buf_set_extmark(
      self.transcript_buf, self.namespace, start + spinner_row, 1, {
      end_col = 1 + #frame,
      hl_group = "NeoagentAccent",
      priority = 110,
    })
  end
end

function M:_flush()
  self.flush_pending = false
  if not self.transcript_buf or not vim.api.nvim_buf_is_valid(self.transcript_buf) then return end
  local saved = self:_save_view()
  vim.bo[self.transcript_buf].modifiable = true
  self:_remove_status()
  if self.full_dirty then
    vim.api.nvim_buf_clear_namespace(self.transcript_buf, self.namespace, 0, -1)
    local lines = {}
    local ranges = {}
    for _, block in ipairs(self.blocks) do
      local content = render.block(self, block)
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
    for _, block in ipairs(self.blocks) do
      if block.dirty then
        local start, finish
        local position = block.mark and vim.api.nvim_buf_get_extmark_by_id(
          self.transcript_buf, self.namespace, block.mark, { details = true }
        ) or {}
        if #position > 0 then
          start = position[1]
          finish = position[3].end_row
          vim.api.nvim_buf_clear_namespace(self.transcript_buf, self.namespace, start, finish)
        else
          local count = vim.api.nvim_buf_line_count(self.transcript_buf)
          start = self.has_rendered and count or 0
          finish = self.has_rendered and count or count
        end
        local content = render.block(self, block)
        vim.api.nvim_buf_set_lines(self.transcript_buf, start, finish, false, content.lines)
        self:_mark_block(block, start, start + #content.lines, content)
        self.has_rendered = true
      end
    end
  end
  self:_render_status()
  vim.bo[self.transcript_buf].modifiable = false
  self:_restore_view(saved)
end

function M:_schedule_flush()
  if self.flush_pending then return end
  self.flush_pending = true
  vim.schedule(function()
    if not self.destroyed then self:_flush() end
  end)
end

function M:_add_block(block)
  block.dirty = true
  self.blocks[#self.blocks + 1] = block
  self:_schedule_flush()
  return block
end

function M:_message(message)
  if message.role == "user" then
    return self:_add_block({ kind = "user", text = util.text_content(message.content), extra = render.image_notes(message.content) })
  elseif message.role == "assistant" then
    for _, content in ipairs(message.content or {}) do
      if content.type == "thinking" then
        self:_add_block({ kind = "thinking", text = content.thinking or "" })
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
  self.messages = util.copy(messages or {})
  self.blocks, self.calls, self.pending_calls = {}, {}, {}
  self.response = self.response + 1
  self.live_text, self.live_texts, self.live_thinking = nil, {}, nil
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
    if not self.live_thinking then
      self.live_thinking = self:_add_block({ kind = "thinking", text = "" })
    end
    self.live_thinking.text = self.live_thinking.text .. (event.text or "")
    self.live_thinking.dirty = true
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
        elseif content.type == "thinking" then
          if not self.live_thinking then self.live_thinking = self:_add_block({ kind = "thinking", text = content.thinking or "" }) end
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
      self.live_text, self.live_texts, self.live_thinking = nil, {}, nil
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
