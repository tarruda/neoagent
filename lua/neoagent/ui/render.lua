local markdown = require("neoagent.markdown")
local util = require("neoagent.util")

local M = {}

local highlight_links = {
  NeoagentWindowTitle = "NeoagentMuted",
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

local function tool_output(self, block, args)
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

local function format_token_count(value)
  if type(value) ~= "number" then return "unknown token count" end
  local digits = tostring(math.max(0, math.floor(value + 0.5)))
  digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return digits .. " tokens"
end

local function compaction(self, block)
  local content = rendered()
  local label, label_spans = segments({ { text = "[compaction]", group = "NeoagentMarkdownBold" } })
  add_line(content, label, label_spans)
  add_line(content, "")
  local token_count = format_token_count(block.tokens_before)
  if self.tools_expanded then
    local body = "**Compacted from " .. token_count .. "**"
    if block.summary ~= "" then body = body .. "\n\n" .. block.summary end
    append_rendered(content, markdown.render(body, { width = self:_content_width() }))
  else
    local hint = (self.config.mappings or {}).expand_tools
    local suffix = type(hint) == "string" and " (" .. hint .. " to expand)" or ""
    local message = "Compacted from " .. token_count .. suffix
    add_line(content, message, { { col = 0, end_col = #message, group = "NeoagentMuted" } })
  end
  return card(content, "NeoagentUserBackground")
end

function M.block(self, block)
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
  elseif block.kind == "compaction" then
    return compaction(self, block)
  elseif block.kind == "notice" then
    return prose(plain(block.text, block.error and "NeoagentError" or "NeoagentMuted"))
  end

  local args = block.call and block.call.arguments or partial_arguments(block.raw)
  if type(args) ~= "table" then args = {} end
  local content = rendered()
  local title, spans = tool_title(block.name or (block.call and block.call.name), args)
  add_line(content, title, spans)
  append_rendered(content, tool_output(self, block, args), true)
  for _, note in ipairs(block.message and image_notes(block.message.content) or {}) do
    add_line(content, note, { { col = 0, end_col = #note, group = "NeoagentMuted" } })
  end
  local background = block.state == "error" and "NeoagentToolErrorBackground"
    or block.state == "success" and "NeoagentToolSuccessBackground" or "NeoagentToolPendingBackground"
  return card(content, background)
end

M.define_highlights = define_highlights
M.image_notes = image_notes

return M
