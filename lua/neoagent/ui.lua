local markdown = require("neoagent.markdown")
local util = require("neoagent.util")

local M = {}
local View = {}
View.__index = View

local highlight_links = {
  NeoagentAccent = "Identifier",
  NeoagentThinking = "Comment",
  NeoagentToolOutput = "Comment",
  NeoagentError = "DiagnosticError",
  NeoagentMuted = "Comment",
  NeoagentBorder = "FloatBorder",
  NeoagentMarkdownHeading = "Title",
  NeoagentMarkdownLink = "Underlined",
  NeoagentMarkdownLinkUrl = "Comment",
  NeoagentMarkdownCode = "String",
  NeoagentMarkdownCodeBlock = "String",
  NeoagentMarkdownCodeBorder = "Comment",
  NeoagentMarkdownQuote = "Comment",
  NeoagentMarkdownQuoteBorder = "Comment",
  NeoagentMarkdownHr = "Comment",
  NeoagentMarkdownListBullet = "Special",
  NeoagentMarkdownTableBorder = "Comment",
  NeoagentDiffAdded = "DiagnosticOk",
  NeoagentDiffRemoved = "DiagnosticError",
  NeoagentDiffContext = "Comment",
}

local function define_highlights()
  for name, link in pairs(highlight_links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  for name, value in pairs({
    NeoagentMarkdownBold = { bold = true },
    NeoagentMarkdownItalic = { italic = true },
    NeoagentMarkdownUnderline = { underline = true },
    NeoagentMarkdownStrike = { strikethrough = true },
  }) do
    value.default = true
    vim.api.nvim_set_hl(0, name, value)
  end
  local light = vim.o.background == "light"
  for name, background in pairs(light and {
    NeoagentUserBackground = "#e8e8e8",
    NeoagentToolPendingBackground = "#e8e8f0",
    NeoagentToolSuccessBackground = "#e8f0e8",
    NeoagentToolErrorBackground = "#f0e8e8",
  } or {
    NeoagentUserBackground = "#343541",
    NeoagentToolPendingBackground = "#282832",
    NeoagentToolSuccessBackground = "#283228",
    NeoagentToolErrorBackground = "#3c2828",
  }) do
    vim.api.nvim_set_hl(0, name, { bg = background, default = true })
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
  local default_width = horizontal and 0.45 or position == "center" and 0.95 or 1
  local default_height = vertical and 0.45 or position == "center" and 0.95 or 1
  local available_width = math.max(0, container.width - margin * 2)
  local available_height = math.max(0, container.height - margin * 2)
  local outer_width = math.min(available_width, dimension(opts.width, container.width, default_width))
  local outer_height = math.min(available_height, dimension(opts.height, container.height, default_height))
  local borders = border_size(opts.border)
  local content_width = outer_width - borders
  local input_height = math.min(opts.input_height or 7, outer_height - borders * 2 - 1)
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

local function rendered()
  return { lines = {}, highlights = {}, line_groups = {} }
end

local function add_line(result, text, spans, line_group)
  local row = #result.lines
  result.lines[#result.lines + 1] = text
  if line_group then result.line_groups[row] = line_group end
  for _, span in ipairs(spans or {}) do
    if span.end_col > span.col then
      result.highlights[#result.highlights + 1] = {
        row = row,
        col = span.col,
        end_col = span.end_col,
        group = span.group,
      }
    end
  end
end

local function append_rendered(target, source, gap)
  if #source.lines == 0 then return end
  if gap and #target.lines > 0 then add_line(target, "") end
  local row_offset = #target.lines
  vim.list_extend(target.lines, source.lines)
  for row, group in pairs(source.line_groups or {}) do target.line_groups[row + row_offset] = group end
  for _, span in ipairs(source.highlights or {}) do
    target.highlights[#target.highlights + 1] = {
      row = span.row + row_offset,
      col = span.col,
      end_col = span.end_col,
      group = span.group,
    }
  end
end

local function plain(text, group)
  local result = rendered()
  if text == nil or text == "" then return result end
  for _, line in ipairs(split_text(text)) do
    local spans = #line > 0 and { { col = 0, end_col = #line, group = group or "NeoagentToolOutput" } } or nil
    add_line(result, line, spans)
  end
  return result
end

local function segments(parts)
  local text, spans = "", {}
  for _, part in ipairs(parts) do
    local start = #text
    text = text .. (part.text or "")
    if part.group and #text > start then
      spans[#spans + 1] = { col = start, end_col = #text, group = part.group }
    end
  end
  return text, spans
end

local function card(content, background)
  local result = rendered()
  add_line(result, "", nil, background)
  for row, line in ipairs(content.lines) do
    local spans = {}
    for _, span in ipairs(content.highlights) do
      if span.row == row - 1 then
        spans[#spans + 1] = {
          col = span.col + 1,
          end_col = span.end_col + 1,
          group = span.group,
        }
      end
    end
    add_line(result, " " .. line .. " ", spans, background)
  end
  add_line(result, "", nil, background)
  add_line(result, "")
  return result
end

local function prose(content, default_group, italic)
  local result = rendered()
  for row, line in ipairs(content.lines) do
    local spans = {}
    for _, span in ipairs(content.highlights) do
      if span.row == row - 1 then
        spans[#spans + 1] = {
          col = span.col + 1,
          end_col = span.end_col + 1,
          group = span.group,
        }
      end
    end
    if #line > 0 and default_group then
      spans[#spans + 1] = { col = 1, end_col = #line + 1, group = default_group }
    end
    if #line > 0 and italic then
      spans[#spans + 1] = { col = 1, end_col = #line + 1, group = "NeoagentMarkdownItalic" }
    end
    add_line(result, " " .. line, spans)
  end
  add_line(result, "")
  return result
end

local function partial_string(raw, key)
  if not raw or raw == "" then return nil end
  local key_start = raw:find('"' .. key .. '"', 1, true)
  if not key_start then return nil end
  local colon = raw:find(":", key_start + #key + 2, true)
  local quote = colon and raw:find('"', colon + 1, true) or nil
  if not quote then return nil end
  local escaped = false
  for index = quote + 1, #raw do
    local char = raw:sub(index, index)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == '"' then
      local encoded = raw:sub(quote + 1, index - 1)
      local ok, value = pcall(vim.json.decode, '"' .. encoded .. '"')
      return ok and value or encoded
    end
  end
  local encoded = raw:sub(quote + 1)
  for trim = 0, math.min(6, #encoded) do
    local candidate = encoded:sub(1, #encoded - trim)
    local ok, value = pcall(vim.json.decode, '"' .. candidate .. '"')
    if ok then return value end
  end
  return encoded
end

local function partial_number(raw, key)
  if not raw then return nil end
  local key_start = raw:find('"' .. key .. '"', 1, true)
  local colon = key_start and raw:find(":", key_start + #key + 2, true) or nil
  return colon and tonumber(raw:sub(colon + 1):match("^%s*(-?[%d.]+)")) or nil
end

local partial_keys = { "path", "file_path", "command", "pattern", "glob", "offset", "limit", "content" }

local function partial_arguments(raw)
  if not raw or raw == "" then return {} end
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "table" then return decoded end
  local result = {}
  for _, key in ipairs(partial_keys) do
    result[key] = partial_string(raw, key) or partial_number(raw, key)
  end
  return result
end

local tool_labels = {
  read = "read",
  read_file = "read",
  write = "write",
  write_file = "write",
  edit = "edit",
  edit_file = "edit",
  read_agent_documentation = "neoagent docs",
}

local function summary_value(value)
  if value == vim.NIL then return "null" end
  if type(value) == "string" then
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
    return #value > 80 and value:sub(1, 77) .. "..." or value
  end
  if type(value) ~= "table" then return tostring(value) end
  if util.is_list(value) then return "[" .. #value .. " items]" end
  return "{…}"
end

local function argument_text(value, fallback)
  if value == nil then return fallback end
  return summary_value(value)
end

local function numeric_argument(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then return tonumber(value) end
end

local function read_range(args)
  local offset = numeric_argument(args.offset)
  local limit = numeric_argument(args.limit)
  if (args.offset == nil or offset) and (args.limit == nil or limit) then
    local first = offset or 1
    local last = limit and first + limit - 1
    return ":" .. first .. (last and "-" .. last or "")
  end
  local fields = {}
  if args.offset ~= nil then fields[#fields + 1] = "offset=" .. argument_text(args.offset, "?") end
  if args.limit ~= nil then fields[#fields + 1] = "limit=" .. argument_text(args.limit, "?") end
  return " (" .. table.concat(fields, " ") .. ")"
end

local function tool_title(name, args)
  name = type(name) == "string" and name or "<tool>"
  local label = tool_labels[name] or name
  if name == "shell" then
    return segments({ { text = "$ " .. argument_text(args.command, "…"), group = "NeoagentMarkdownBold" } })
  end
  local parts = { { text = label, group = "NeoagentMarkdownBold" } }
  if name == "read" or name == "read_file" or name == "write" or name == "write_file"
      or name == "edit" or name == "edit_file" then
    parts[#parts + 1] = { text = " " .. argument_text(args.path or args.file_path, "…"), group = "NeoagentAccent" }
    if (name == "read" or name == "read_file") and (args.offset or args.limit) then
      parts[#parts + 1] = { text = read_range(args), group = "DiagnosticWarn" }
    end
  elseif name == "grep" then
    parts[#parts + 1] = { text = " " .. argument_text(args.pattern, "…"), group = "NeoagentAccent" }
    parts[#parts + 1] = { text = " in " .. argument_text(args.path, "."), group = "NeoagentToolOutput" }
    if args.glob then parts[#parts + 1] = { text = " (" .. argument_text(args.glob, "?") .. ")", group = "NeoagentToolOutput" } end
  elseif name == "find" then
    parts[#parts + 1] = { text = " " .. argument_text(args.pattern, "…"), group = "NeoagentAccent" }
    parts[#parts + 1] = { text = " in " .. argument_text(args.path, "."), group = "NeoagentToolOutput" }
  else
    local values = {}
    for key, value in pairs(args) do
      if key ~= "content" and value ~= nil then values[#values + 1] = tostring(key) .. "=" .. summary_value(value) end
    end
    table.sort(values)
    if #values > 0 then parts[#parts + 1] = { text = " " .. table.concat(values, " "), group = "NeoagentToolOutput" } end
  end
  return segments(parts)
end

local function limited(text, maximum, tail)
  local lines = split_text(text)
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  if maximum == nil or #lines <= maximum then return lines, 0 end
  local omitted = #lines - maximum
  if tail then return vim.list_slice(lines, omitted + 1, #lines), omitted end
  return vim.list_slice(lines, 1, maximum), omitted
end

local function output_lines(text, maximum, tail, group, hint)
  local result = rendered()
  if text == nil or text == "" then return result end
  local lines, omitted = limited(text, maximum, tail)
  for _, line in ipairs(lines) do
    local line_group = group
    if group == "diff" then
      line_group = line:sub(1, 1) == "+" and "NeoagentDiffAdded"
        or line:sub(1, 1) == "-" and "NeoagentDiffRemoved" or "NeoagentDiffContext"
    end
    add_line(result, line, #line > 0 and { { col = 0, end_col = #line, group = line_group } } or nil)
  end
  if omitted > 0 then
    local message = string.format("... (%d more lines%s)", omitted, hint and ", " .. hint .. " to expand" or "")
    add_line(result, message, { { col = 0, end_col = #message, group = "NeoagentMuted" } })
  end
  return result
end

function View:_scroll_transcript_to_bottom()
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

function View:_content_width()
  if self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win) then
    return math.max(1, vim.api.nvim_win_get_width(self.transcript_win) - 2)
  end
  return math.max(1, vim.o.columns - 2)
end

function View:_tool_output(block, args)
  local name = block.name or (block.call and block.call.name) or (block.message and block.message.toolName)
  local message = block.message
  local update = block.update
  local value = message and content_text(message.content) or update and content_text(update.content) or nil
  local hint = (self.config.mappings or {}).expand_tools
  hint = type(hint) == "string" and hint or nil
  local maximum
  if not self.tools_expanded then maximum = name == "grep" and 15 or name == "find" and 20 or 10 end

  if name == "write" or name == "write_file" then
    return output_lines(args.content, maximum, false, "NeoagentToolOutput", hint)
  elseif name == "edit" or name == "edit_file" then
    local diff = message and message.details and message.details.diff
    if diff and diff ~= "" then return output_lines(diff, maximum, false, "diff", hint) end
    if message and message.isError then return output_lines(value, maximum, false, "NeoagentError", hint) end
    return rendered()
  elseif name == "read" or name == "read_file" then
    return output_lines(value, maximum, false, message and message.isError and "NeoagentError" or "NeoagentToolOutput", hint)
  elseif name == "shell" then
    return output_lines(value, maximum, true, message and message.isError and "NeoagentError" or "NeoagentToolOutput", hint)
  elseif name == "grep" or name == "find" then
    return output_lines(value, maximum, false, message and message.isError and "NeoagentError" or "NeoagentToolOutput", hint)
  elseif message and message.isError then
    return output_lines(value, maximum, false, "NeoagentError", hint)
  end
  return output_lines(value, maximum, false, "NeoagentToolOutput", hint)
end

function View:_render_block(block)
  if block.kind == "user" then
    local content = markdown.render(block.text, { width = self:_content_width(), preserve_markers = true })
    for _, note in ipairs(block.extra or {}) do
      add_line(content, note, { { col = 0, end_col = #note, group = "NeoagentMuted" } })
    end
    return card(content, "NeoagentUserBackground")
  elseif block.kind == "assistant" then
    return prose(markdown.render(block.text, { width = self:_content_width() }))
  elseif block.kind == "thinking" then
    return prose(markdown.render(block.text, { width = self:_content_width() }), "NeoagentThinking", true)
  elseif block.kind == "notice" then
    return prose(plain(block.text, block.error and "NeoagentError" or "NeoagentMuted"))
  end

  local args = block.call and block.call.arguments or partial_arguments(block.raw)
  if type(args) ~= "table" then args = {} end
  local content = rendered()
  local title, spans = tool_title(block.name or (block.call and block.call.name), args)
  add_line(content, title, spans)
  append_rendered(content, self:_tool_output(block, args), true)
  for _, note in ipairs(block.message and image_notes(block.message.content) or {}) do
    add_line(content, note, { { col = 0, end_col = #note, group = "NeoagentMuted" } })
  end
  local background = block.state == "error" and "NeoagentToolErrorBackground"
    or block.state == "success" and "NeoagentToolSuccessBackground" or "NeoagentToolPendingBackground"
  return card(content, background)
end

function View:_mark_block(block, start, finish, content)
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

function View:_remove_status()
  if not self.status_mark then return end
  local position = vim.api.nvim_buf_get_extmark_by_id(self.transcript_buf, self.namespace, self.status_mark, { details = true })
  if #position > 0 then
    for _, mark in ipairs(self.status_decorations or {}) do pcall(vim.api.nvim_buf_del_extmark, self.transcript_buf, self.namespace, mark) end
    vim.api.nvim_buf_del_extmark(self.transcript_buf, self.namespace, self.status_mark)
    vim.api.nvim_buf_set_lines(self.transcript_buf, position[1], position[3].end_row, false, {})
  end
  self.status_mark, self.status_decorations = nil, nil
end

function View:_render_status()
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

function View:_flush()
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
      local content = self:_render_block(block)
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
        local content = self:_render_block(block)
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
    return self:_add_block({ kind = "user", text = util.text_content(message.content), extra = image_notes(message.content) })
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
    local tokens = type(message.tokensBefore) == "number" and string.format(" · %.1fk tokens", message.tokensBefore / 1000) or ""
    return self:_add_block({ kind = "notice", text = "Context compacted" .. tokens })
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
      self.live_text = self:_add_block({ kind = "assistant", text = "" })
    end
    self.live_text.text = self.live_text.text .. (event.text or "")
    self.live_text.dirty = true
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
      for _, content in ipairs(message.content or {}) do
        if content.type == "text" then
          if not self.live_text then self.live_text = self:_add_block({ kind = "assistant", text = content.text or "" }) end
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
      self.live_text, self.live_thinking = nil, nil
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

function View:finish(result)
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

function View:_map(buffer, modes, key, callback)
  if key == false or key == nil then return end
  if type(key) == "table" then
    for _, lhs in ipairs(key) do self:_map(buffer, modes, lhs, callback) end
    return
  end
  vim.keymap.set(modes, key, callback, { buffer = buffer, silent = true, nowait = true })
end

function View:_map_buffers()
  local mappings = self.config.mappings or {}
  self:_map(self.input_buf, { "n", "i" }, mappings.submit, function()
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
  vim.wo[win].winhl = "NormalFloat:Normal,FloatBorder:NeoagentBorder"
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
  local usage = self.context.context_usage
  if type(usage) == "table" then
    local function tokens(value)
      if value < 1000 then return tostring(math.floor(value + 0.5)) end
      local divisor, suffix = value >= 1000000 and 1000000 or 1000, value >= 1000000 and "m" or "k"
      local formatted = string.format("%.1f", value / divisor):gsub("%.0$", "")
      return formatted .. suffix
    end
    local percent = usage.percent > 0 and usage.percent < 0.1
        and "<0.1" or string.format("%.1f", usage.percent)
    parts[#parts + 1] = string.format("ctx %s/%s (%s%%)",
      tokens(usage.used), tokens(usage.total), percent)
  end
  parts[#parts + 1] = self.context.state or "idle"
  return table.concat(parts, " · ")
end

function View:_footer()
  local status = self.context.provider_status
  if type(status) ~= "string" or util.trim(status) == "" then return "" end
  return " " .. util.trim(status) .. " "
end

function View:_decorate(configs)
  configs.transcript.title = self:_title()
  configs.transcript.title_pos = "center"
  configs.input.title = "Input · " .. ((self.config.mappings or {}).submit or "send") .. " send"
  configs.input.title_pos = "center"
  configs.input.footer = self:_footer()
  configs.input.footer_pos = "right"
end

function View:open(origin)
  if self:is_open() then
    self:focus_input()
    return true
  end
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
  local active = self.context.state == "running" or self.context.state == "stopping"
    or self.context.state == "compacting"
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
  if self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win) then
    local cfg = vim.api.nvim_win_get_config(self.transcript_win)
    cfg.title = self:_title()
    cfg.title_pos = "center"
    vim.api.nvim_win_set_config(self.transcript_win, cfg)
  end
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    local cfg = vim.api.nvim_win_get_config(self.input_win)
    cfg.footer = self:_footer()
    cfg.footer_pos = "right"
    vim.api.nvim_win_set_config(self.input_win, cfg)
  end
  self:_sync_spinner()
end

function View:_stop_spinner()
  if not self.spinner_timer then return end
  self.spinner_timer:stop()
  self.spinner_timer:close()
  self.spinner_timer = nil
end

function View:_sync_spinner()
  local active = self.context.state == "running" or self.context.state == "stopping"
    or self.context.state == "compacting"
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
    self:_schedule_flush()
  end))
  self:_schedule_flush()
end

function View:get_input()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false), "\n")
end

function View:_reset_input_history()
  self.history_index = 0
  self.history_draft = nil
  self.history_changedtick = nil
end

function View:_set_history_input(text, placement, cursor)
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

function View:_browse_input_history(direction)
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

function View:_move_input_history(direction)
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then return false end
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

function View:set_input(text)
  self:_ensure_buffers()
  self:_reset_input_history()
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

function M.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "UI config is required")
  define_highlights()
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
    callback = define_highlights,
  })
  return view
end

M.View = View

return M
