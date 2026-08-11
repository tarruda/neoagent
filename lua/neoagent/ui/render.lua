local markdown = require("neoagent.markdown")
local util = require("neoagent.util")

local M = {}
local MAX_ANSI_SPANS = 512
local MAX_ANSI_HIGHLIGHTS = 256

local ansi_palette = {
  0x000000, 0xcd0000, 0x00cd00, 0xcdcd00,
  0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
  0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00,
  0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
}
local ansi_highlights = {}
local ansi_highlight_names = {}

local function palette_rgb(index)
  local configured = index < 16 and vim.g["terminal_color_" .. index] or nil
  if type(configured) == "string" and configured ~= "" then
    local value = vim.api.nvim_get_color_by_name(configured)
    if value >= 0 then return value end
  end
  if index < 16 then return ansi_palette[index + 1] end
  if index < 232 then
    local value = index - 16
    local levels = { 0, 95, 135, 175, 215, 255 }
    local red = levels[math.floor(value / 36) + 1]
    local green = levels[math.floor(value / 6) % 6 + 1]
    local blue = levels[value % 6 + 1]
    return red * 0x10000 + green * 0x100 + blue
  end
  local level = 8 + (index - 232) * 10
  return level * 0x10000 + level * 0x100 + level
end

local function rgb_cterm(value)
  local red = math.floor(value / 0x10000) % 0x100
  local green = math.floor(value / 0x100) % 0x100
  local blue = value % 0x100
  return 16 + math.floor(red * 5 / 255 + 0.5) * 36
    + math.floor(green * 5 / 255 + 0.5) * 6
    + math.floor(blue * 5 / 255 + 0.5)
end

local function style_color(value)
  if value == nil then return nil, nil end
  if type(value) == "number" then return palette_rgb(value), value end
  if type(value) ~= "string" then return nil, nil end
  local red, green, blue = value:match("^#(%x%x)(%x%x)(%x%x)$")
  if not red then return nil, nil end
  local rgb = tonumber(red .. green .. blue, 16)
  return rgb, rgb_cterm(rgb)
end

local function style_key(style)
  return table.concat({
    tostring(style.fg or ""), tostring(style.bg or ""),
    style.bold and "1" or "", style.italic and "1" or "",
    style.underline and "1" or "", style.strikethrough and "1" or "",
    style.reverse and "1" or "",
  }, ":")
end

local function define_ansi_highlight(name, definition)
  local attributes = vim.api.nvim_get_hl(0, {
    name = definition.base,
    link = false,
  })
  local foreground, foreground_cterm = style_color(definition.style.fg)
  local background, background_cterm = style_color(definition.style.bg)
  if foreground then
    attributes.fg = foreground
    attributes.ctermfg = foreground_cterm
  end
  if background then
    attributes.bg = background
    attributes.ctermbg = background_cterm
  end
  for _, attribute in ipairs({
    "bold", "italic", "underline", "strikethrough", "reverse",
  }) do
    if definition.style[attribute] then attributes[attribute] = true end
  end
  vim.api.nvim_set_hl(0, name, attributes)
end

local function ansi_highlight(style, base)
  local key = base .. ":" .. style_key(style)
  local name = ansi_highlight_names[key]
  if name then return name end
  if vim.tbl_count(ansi_highlight_names) >= MAX_ANSI_HIGHLIGHTS then return base end
  name = "NeoagentAnsi" .. tostring(vim.tbl_count(ansi_highlight_names) + 1)
  local definition = { base = base, style = util.copy(style) }
  ansi_highlight_names[key] = name
  ansi_highlights[name] = definition
  define_ansi_highlight(name, definition)
  return name
end

local highlight_links = {
  NeoagentWindowTitle = "NeoagentMuted",
  NeoagentAccent = "Identifier",
  NeoagentCardFocus = "NeoagentAccent",
  NeoagentDialogBackground = "NeoagentUserBackground",
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
    NeoagentDialogAction = {
      fg = vim.o.background == "light" and "#005f87" or "#00ffff",
      ctermfg = vim.o.background == "light" and 24 or 6,
      bold = true,
    },
    NeoagentCyan = {
      fg = palette_rgb(6),
      ctermfg = 6,
    },
    NeoagentDialogTitle = { bold = true },
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
  for name, definition in pairs(ansi_highlights) do
    define_ansi_highlight(name, definition)
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
        priority = span.priority,
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
      priority = span.priority,
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

local function fit_card_line(text, width)
  local available = width + 2
  if vim.fn.strdisplaywidth(" " .. text .. " ") <= available then return text end
  local ellipsis = string.rep(".", math.min(3, width))
  local characters = vim.fn.strchars(text)
  local low, high = 0, characters
  while low < high do
    local count = math.floor((low + high + 1) / 2)
    local prefix = vim.fn.strcharpart(text, 0, count)
    if vim.fn.strdisplaywidth(" " .. prefix .. ellipsis .. " ") <= available then
      low = count
    else
      high = count - 1
    end
  end
  local prefix = vim.fn.strcharpart(text, 0, low)
  return prefix .. ellipsis, #prefix
end

local function truncate_card_lines(content, width)
  width = math.max(1, width)
  local truncated = {}
  for row, line in ipairs(content.lines) do
    local fitted, prefix_length = fit_card_line(line, width)
    if prefix_length then
      content.lines[row] = fitted
      content.truncated = true
      truncated[row - 1] = {
        prefix_length = prefix_length,
        end_col = #fitted,
      }
    end
  end
  if not next(truncated) then return end

  local highlights = {}
  for _, span in ipairs(content.highlights) do
    local truncation = truncated[span.row]
    if not truncation then
      highlights[#highlights + 1] = span
    elseif span.col < truncation.prefix_length then
      highlights[#highlights + 1] = {
        row = span.row,
        col = span.col,
        end_col = math.min(span.end_col, truncation.prefix_length),
        group = span.group,
        priority = span.priority,
      }
    end
  end
  for row, truncation in pairs(truncated) do
    highlights[#highlights + 1] = {
      row = row,
      col = truncation.prefix_length,
      end_col = truncation.end_col,
      group = "NeoagentMuted",
      priority = 120,
    }
  end
  content.highlights = highlights
end

local function card(content, background, width)
  if width then truncate_card_lines(content, width) end
  local result = rendered()
  result.animated = content.animated
  if background then add_line(result, "", nil, background) end
  for row, line in ipairs(content.lines) do
    local spans = {}
    for _, span in ipairs(content.highlights) do
      if span.row == row - 1 then
        spans[#spans + 1] = {
          col = span.col + 1,
          end_col = span.end_col + 1,
          group = span.group,
          priority = span.priority,
        }
      end
    end
    add_line(result, " " .. line .. " ", spans, background)
  end
  if background then add_line(result, "", nil, background) end
  add_line(result, "")
  result.card = { first = 0, last = #result.lines - 2 }
  return result
end

local function prose(content)
  local result = rendered()
  local finish = #content.lines
  while finish > 0 and not content.lines[finish]:find("%S") do finish = finish - 1 end
  if finish == 0 then return result end
  for row = 1, finish do
    local line = content.lines[row]
    local spans = {}
    for _, span in ipairs(content.highlights) do
      if span.row == row - 1 then
        spans[#spans + 1] = {
          col = span.col + 1,
          end_col = span.end_col + 1,
          group = span.group,
          priority = span.priority,
        }
      end
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

local presentation_styles = {
  accent = "NeoagentAccent",
  bold = "NeoagentMarkdownBold",
  cyan = "NeoagentCyan",
  error = "NeoagentError",
  italic = "NeoagentMarkdownItalic",
  muted = "NeoagentMuted",
  strike = "NeoagentMarkdownStrike",
}

local function custom_tool_content(self, block, args, options)
  if type(self.resolve_tool) ~= "function" then return nil end
  local name = block.name or (block.call and block.call.name)
    or (block.message and block.message.toolName)
  local resolved, tool = pcall(self.resolve_tool, name)
  if not resolved or type(tool) ~= "table"
      or type(tool.render) ~= "function" then return nil end
  local ok, presentation = pcall(tool.render, {
    arguments = util.copy(args),
    result = util.copy(block.message or block.update),
    state = block.state,
    width = options.width or self:_content_width(),
    full = options.full == true,
    spinner = self.spinner_frames[self.spinner_frame],
  })
  if not ok or type(presentation) ~= "table"
      or not util.is_list(presentation.lines) then
    return nil
  end

  local content = rendered()
  for _, segments_value in ipairs(presentation.lines) do
    if type(segments_value) ~= "table" or not util.is_list(segments_value) then
      return nil
    end
    local line, spans = "", {}
    for _, segment in ipairs(segments_value) do
      if type(segment) ~= "table" or type(segment.text) ~= "string" then
        return nil
      end
      local start = #line
      line = line .. segment.text
      local styles
      if segment.style == nil then
        styles = {}
      elseif type(segment.style) == "string" then
        styles = { segment.style }
      elseif type(segment.style) == "table" and util.is_list(segment.style) then
        styles = segment.style
      else
        return nil
      end
      for index, style in ipairs(styles) do
        local group = presentation_styles[style]
        if not group then return nil end
        spans[#spans + 1] = {
          col = start,
          end_col = #line,
          group = group,
          priority = 100 + index,
        }
      end
    end
    add_line(content, line, spans)
  end
  if presentation.animated == true then content.animated = true end
  local background = block.state == "error" and "NeoagentToolErrorBackground"
    or block.state == "success" and "NeoagentToolSuccessBackground"
    or "NeoagentToolPendingBackground"
  if presentation.background == false then background = nil end
  return content, background, presentation.card ~= false
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

local function summary_value(value, full)
  if value == vim.NIL then return "null" end
  if type(value) == "string" then
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
    return not full and #value > 80 and value:sub(1, 77) .. "..." or value
  end
  if type(value) ~= "table" then return tostring(value) end
  if util.is_list(value) then return "[" .. #value .. " items]" end
  return "{…}"
end

local function argument_text(value, fallback, full)
  if value == nil then return fallback end
  return summary_value(value, full)
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

local function tool_title(name, args, full)
  name = type(name) == "string" and name or "<tool>"
  local label = tool_labels[name] or name
  if name == "shell" then
    return segments({ { text = "$ " .. argument_text(args.command, "…", full), group = "NeoagentMarkdownBold" } })
  end
  local parts = { { text = label, group = "NeoagentMarkdownBold" } }
  if name == "read" or name == "read_file" or name == "write" or name == "write_file"
      or name == "edit" or name == "edit_file" then
    parts[#parts + 1] = { text = " " .. argument_text(args.path or args.file_path, "…", full), group = "NeoagentAccent" }
    if (name == "read" or name == "read_file") and (args.offset or args.limit) then
      parts[#parts + 1] = { text = read_range(args), group = "DiagnosticWarn" }
    end
  elseif name == "grep" then
    parts[#parts + 1] = { text = " " .. argument_text(args.pattern, "…", full), group = "NeoagentAccent" }
    parts[#parts + 1] = { text = " in " .. argument_text(args.path, ".", full), group = "NeoagentToolOutput" }
    if args.glob then parts[#parts + 1] = { text = " (" .. argument_text(args.glob, "?", full) .. ")", group = "NeoagentToolOutput" } end
  elseif name == "find" then
    parts[#parts + 1] = { text = " " .. argument_text(args.pattern, "…", full), group = "NeoagentAccent" }
    parts[#parts + 1] = { text = " in " .. argument_text(args.path, ".", full), group = "NeoagentToolOutput" }
  else
    local values = {}
    for key, value in pairs(args) do
      if key ~= "content" and value ~= nil then values[#values + 1] = tostring(key) .. "=" .. summary_value(value, full) end
    end
    table.sort(values)
    if #values > 0 then parts[#parts + 1] = { text = " " .. table.concat(values, " "), group = "NeoagentToolOutput" } end
  end
  return segments(parts)
end

local function limited(text, maximum, tail)
  local lines = split_text(text)
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  if maximum == nil or #lines <= maximum then return lines, 0, 0 end
  local omitted = #lines - maximum
  if tail then return vim.list_slice(lines, omitted + 1, #lines), omitted, omitted end
  return vim.list_slice(lines, 1, maximum), omitted, 0
end

local function sgr_params(value)
  if value == "" then return { 0 } end
  local result = {}
  for field in (value .. ";"):gmatch("([^;]*);") do
    result[#result + 1] = field == "" and 0 or tonumber(field)
  end
  return result
end

local function reset_style(style)
  for key in pairs(style) do style[key] = nil end
end

local function apply_sgr(style, params)
  local index = 1
  while index <= #params do
    local code = params[index]
    if code == 0 then
      reset_style(style)
    elseif code == 1 then
      style.bold = true
    elseif code == 3 then
      style.italic = true
    elseif code == 4 then
      style.underline = true
    elseif code == 7 then
      style.reverse = true
    elseif code == 9 then
      style.strikethrough = true
    elseif code == 22 then
      style.bold = nil
    elseif code == 23 then
      style.italic = nil
    elseif code == 24 then
      style.underline = nil
    elseif code == 27 then
      style.reverse = nil
    elseif code == 29 then
      style.strikethrough = nil
    elseif code and code >= 30 and code <= 37 then
      style.fg = code - 30
    elseif code == 39 then
      style.fg = nil
    elseif code and code >= 40 and code <= 47 then
      style.bg = code - 40
    elseif code == 49 then
      style.bg = nil
    elseif code and code >= 90 and code <= 97 then
      style.fg = code - 90 + 8
    elseif code and code >= 100 and code <= 107 then
      style.bg = code - 100 + 8
    elseif code == 38 or code == 48 then
      local field = code == 38 and "fg" or "bg"
      if params[index + 1] == 5 and type(params[index + 2]) == "number"
          and params[index + 2] >= 0 and params[index + 2] <= 255 then
        style[field] = math.floor(params[index + 2])
        index = index + 2
      elseif params[index + 1] == 2
          and type(params[index + 2]) == "number"
          and type(params[index + 3]) == "number"
          and type(params[index + 4]) == "number" then
        local red, green, blue = params[index + 2], params[index + 3], params[index + 4]
        if red >= 0 and red <= 255 and green >= 0 and green <= 255
            and blue >= 0 and blue <= 255 then
          style[field] = string.format("#%02x%02x%02x", red, green, blue)
        end
        index = index + 4
      end
    end
    index = index + 1
  end
end

local function ansi_sequence(value, start)
  if value:sub(start + 1, start + 1) ~= "[" then return nil end
  local finish = start + 2
  while finish <= #value do
    local byte = value:byte(finish)
    if (byte >= 48 and byte <= 57) or byte == 59 then
      finish = finish + 1
    elseif byte == 109 then
      return finish, value:sub(start + 2, finish - 1)
    else
      return nil
    end
  end
end

local function parse_ansi(value)
  local output = {}
  local spans = {}
  local style = {}
  local row, col = 0, 0

  local function append(value_part)
    if value_part == "" then return end
    local safe = util.text_from_bytes(value_part)
    output[#output + 1] = safe
    local start = 1
    while start <= #safe do
      local newline = safe:find("\n", start, true)
      local finish = newline and newline - 1 or #safe
      if finish >= start and next(style) and #spans < MAX_ANSI_SPANS then
        local length = finish - start + 1
        local key = style_key(style)
        local previous = spans[#spans]
        if previous and previous.row == row and previous.end_col == col
            and previous.key == key then
          previous.end_col = previous.end_col + length
        else
          spans[#spans + 1] = {
            row = row,
            col = col,
            end_col = col + length,
            key = key,
            style = util.copy(style),
          }
        end
        col = col + length
      else
        col = col + math.max(0, finish - start + 1)
      end
      if not newline then break end
      row, col = row + 1, 0
      start = newline + 1
    end
  end

  local start = 1
  while start <= #value do
    local escape = value:find("\27", start, true)
    if not escape then
      append(value:sub(start))
      break
    end
    append(value:sub(start, escape - 1))
    local finish, params = ansi_sequence(value, escape)
    if finish then
      apply_sgr(style, sgr_params(params))
      start = finish + 1
    else
      append("\\x1B")
      start = escape + 1
    end
  end
  return table.concat(output), spans
end

local function output_lines(text, maximum, tail, group, ansi)
  local result = rendered()
  if text == nil or text == "" then return result end
  local ansi_spans = {}
  if type(ansi) == "string" then text, ansi_spans = parse_ansi(ansi) end
  local lines, omitted, first_row = limited(text, maximum, tail)
  for index, line in ipairs(lines) do
    local line_group = group
    if group == "diff" then
      line_group = line:sub(1, 1) == "+" and "NeoagentDiffAdded"
        or line:sub(1, 1) == "-" and "NeoagentDiffRemoved" or "NeoagentDiffContext"
    end
    local line_spans = #line > 0
        and { { col = 0, end_col = #line, group = line_group } } or {}
    local source_row = first_row + index - 1
    for _, span in ipairs(ansi_spans) do
      if span.row == source_row and span.col < #line then
        line_spans[#line_spans + 1] = {
          col = span.col,
          end_col = math.min(span.end_col, #line),
          group = ansi_highlight(span.style, line_group),
          priority = 110,
        }
      end
    end
    add_line(result, line, line_spans)
  end
  if omitted > 0 then
    local message = string.format("[... %d more line%s]", omitted, omitted == 1 and "" or "s")
    add_line(result, message, { { col = 0, end_col = #message, group = "NeoagentMuted" } })
  end
  return result
end

local function tool_output(self, block, args, full)
  local name = block.name or (block.call and block.call.name) or (block.message and block.message.toolName)
  local message = block.message
  local update = block.update
  local value = message and content_text(message.content) or update and content_text(update.content) or nil
  local maximum
  if not full then maximum = name == "grep" and 15 or name == "find" and 20 or 10 end

  if name == "write" or name == "write_file" then
    return output_lines(args.content, maximum, false, "NeoagentToolOutput")
  elseif name == "edit" or name == "edit_file" then
    local diff = message and message.details and message.details.diff
    if diff and diff ~= "" then return output_lines(diff, maximum, false, "diff") end
    if message and message.isError then return output_lines(value, maximum, false, "NeoagentError") end
    return rendered()
  elseif name == "read" or name == "read_file" then
    return output_lines(value, maximum, false, message and message.isError and "NeoagentError" or "NeoagentToolOutput")
  elseif name == "shell" then
    local active = message or update
    local ansi = active and active.details and active.details.ansi
    return output_lines(value, maximum, true,
      message and message.isError and "NeoagentError" or "NeoagentToolOutput", ansi)
  elseif name == "grep" or name == "find" then
    return output_lines(value, maximum, false, message and message.isError and "NeoagentError" or "NeoagentToolOutput")
  elseif message and message.isError then
    return output_lines(value, maximum, false, "NeoagentError")
  end
  return output_lines(value, maximum, false, "NeoagentToolOutput")
end

local function format_token_count(value)
  if type(value) ~= "number" then return "unknown token count" end
  local digits = tostring(math.max(0, math.floor(value + 0.5)))
  digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return digits .. " tokens"
end

local function expand_hint(self)
  local key = (self.config.mappings or {}).card_details
  if type(key) == "string" then return key end
  if type(key) == "table" then return key[1] end
end

local COMPACTION_CARD_MAX_LINES = 20
local COMPACTION_CONTENT_MAX_LINES = COMPACTION_CARD_MAX_LINES - 2

local function clip_head(content, maximum)
  if #content.lines <= maximum then return 0 end
  local kept = maximum - 1
  local omitted = #content.lines - kept
  content.lines = vim.list_slice(content.lines, 1, kept)
  local highlights = {}
  for _, span in ipairs(content.highlights) do
    if span.row < kept then highlights[#highlights + 1] = span end
  end
  content.highlights = highlights
  local line_groups = {}
  for row, group in pairs(content.line_groups) do
    if row < kept then line_groups[row] = group end
  end
  content.line_groups = line_groups
  local message = string.format(
    "[... %d more line%s]", omitted, omitted == 1 and "" or "s")
  add_line(content, message, {
    { col = 0, end_col = #message, group = "NeoagentMuted" },
  })
  return omitted
end

local function compaction_content(self, block, full, width)
  local content = rendered()
  local label, label_spans = segments({ { text = "[compaction]", group = "NeoagentMarkdownBold" } })
  local token_count = format_token_count(block.tokens_before)
  if full then
    add_line(content, label, label_spans)
    add_line(content, "")
    local body = "**Compacted from " .. token_count .. "**"
    if block.summary ~= "" then body = body .. "\n\n" .. block.summary end
    append_rendered(content, markdown.render(body, { width = width }))
  else
    local message = "Compacted from " .. token_count
    local title, spans = segments({
      { text = label, group = "NeoagentMarkdownBold" },
      { text = " " .. message, group = "NeoagentMuted" },
    })
    add_line(content, title, spans)
    if block.summary ~= "" then
      append_rendered(content, markdown.render(block.summary, { width = width }))
    end
    clip_head(content, COMPACTION_CONTENT_MAX_LINES)
  end
  return content
end

local THINKING_MAX_LINES = 10

local function trim_trailing_lines(content)
  while #content.lines > 0 and content.lines[#content.lines] == "" do
    table.remove(content.lines)
  end
end

local function clip_tail(content, maximum)
  local omitted = math.max(0, #content.lines - maximum)
  if omitted == 0 then return 0 end
  local highlights = {}
  for _, span in ipairs(content.highlights) do
    if span.row >= omitted then
      highlights[#highlights + 1] = {
        row = span.row - omitted,
        col = span.col,
        end_col = span.end_col,
        group = span.group,
        priority = span.priority,
      }
    end
  end
  content.lines = vim.list_slice(content.lines, omitted + 1, #content.lines)
  content.highlights = highlights
  return omitted
end

local function response_header(self, kind, text, omitted, expandable)
  local words = select(2, (text or ""):gsub("%S+", ""))
  local message = string.format("[%s: %d word%s",
    kind, words, words == 1 and "" or "s")
  if omitted > 0 then
    local unit = omitted == 1 and "line" or "lines"
    message = message .. string.format(", %d %s above...", omitted, unit)
  end
  local hint = expandable and expand_hint(self) or nil
  if hint then message = message .. ", " .. hint .. " to expand" end
  return message .. "]"
end

local function assistant_content(self, block, full, width)
  local content = markdown.render(block.text or "", { width = width })
  trim_trailing_lines(content)
  if not full then
    block.header = response_header(
      self, "text", block.text, 0, true)
  end
  return content
end

local function thinking_content(self, block, full, width)
  local content = markdown.render(block.text or "", { width = width })
  trim_trailing_lines(content)
  for row = 1, #content.lines do
    local length = #content.lines[row]
    if length > 0 then
      content.highlights[#content.highlights + 1] = {
        row = row - 1, col = 0, end_col = length, group = "NeoagentThinking",
      }
      content.highlights[#content.highlights + 1] = {
        row = row - 1, col = 0, end_col = length, group = "NeoagentMarkdownItalic",
      }
    end
  end
  if not full then
    local omitted = clip_tail(content, THINKING_MAX_LINES)
    block.header = response_header(
      self, "thinking", block.text, omitted, true)
    block.resting_header = response_header(
      self, "thinking", block.text, omitted, false)
  end
  return content
end

local function card_content(self, block, options)
  options = options or {}
  local width = options.width or self:_content_width()
  if block.kind == "user" then
    local content = markdown.render(block.text, { width = width, preserve_markers = true })
    for _, note in ipairs(block.extra or {}) do
      add_line(content, note, { { col = 0, end_col = #note, group = "NeoagentMuted" } })
    end
    return content, "NeoagentUserBackground"
  elseif block.kind == "compaction" then
    return compaction_content(self, block, options.full, width), "NeoagentUserBackground"
  elseif block.kind == "thinking" then
    return thinking_content(self, block, options.full, width)
  elseif block.kind == "assistant" then
    return assistant_content(self, block, options.full, width)
  elseif block.kind ~= "tool" then
    return nil
  end

  local args = block.call and block.call.arguments or partial_arguments(block.raw)
  if type(args) ~= "table" then args = {} end
  local custom, custom_background, custom_card =
    custom_tool_content(self, block, args, options)
  if custom then return custom, custom_background, custom_card end
  local content = rendered()
  local title, spans = tool_title(
    block.name or (block.call and block.call.name), args, options.full)
  add_line(content, title, spans)
  append_rendered(content, tool_output(self, block, args, options.full), true)
  for _, note in ipairs(block.message and image_notes(block.message.content) or {}) do
    add_line(content, note, { { col = 0, end_col = #note, group = "NeoagentMuted" } })
  end
  local background = block.state == "error" and "NeoagentToolErrorBackground"
    or block.state == "success" and "NeoagentToolSuccessBackground" or "NeoagentToolPendingBackground"
  return content, background
end

function M.block(self, block)
  local content, background, as_card = card_content(self, block)
  if content then
    if as_card == false then
      add_line(content, "")
      return content
    end
    local width
    if block.kind == "compaction" or (
        self.config.wrap_cards ~= true and block.kind ~= "assistant"
          and block.kind ~= "user") then
      width = self:_content_width()
    end
    local result = card(content, background, width)
    if block.kind == "thinking" then
      block.overflow = content.truncated == true
    end
    return result
  end
  return prose(plain(block.text, block.error and "NeoagentError" or "NeoagentMuted"))
end

function M.details(self, block, options)
  options = vim.tbl_extend("force", options or {}, { full = true })
  return card_content(self, block, options)
end

M.define_highlights = define_highlights
M.expand_hint = expand_hint
M.image_notes = image_notes

return M
