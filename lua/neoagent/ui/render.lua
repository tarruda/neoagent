local Applet = require("applet")
local markdown = require("neoagent.markdown")
local util = require("neoagent.util")

local M = {}
local display = Applet.Pane.text
local MAX_ANSI_SPANS = 512
local MAX_ANSI_HIGHLIGHTS = 256

local function style_key(style)
  return table.concat({
    tostring(style.fg or ""), tostring(style.bg or ""),
    style.bold and "1" or "", style.italic and "1" or "",
    style.underline and "1" or "", style.strikethrough and "1" or "",
    style.reverse and "1" or "",
  }, ":")
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

local function highlight_definitions(palette)
  local result = {}
  for name, link in pairs(highlight_links) do
    result[name] = { link = link, default = true }
  end
  for name, value in pairs({
    NeoagentDialogAction = {
      fg = palette:is_light() and "#005f87" or "#00ffff",
      ctermfg = palette:is_light() and 24 or 6,
      bold = true,
    },
    NeoagentCodexToolError = {
      fg = palette:terminal(1),
      ctermfg = 1,
      bold = true,
    },
    NeoagentCodexToolSuccess = {
      fg = palette:terminal(2),
      ctermfg = 2,
      bold = true,
    },
    NeoagentCyan = {
      fg = palette:terminal(6),
      ctermfg = 6,
    },
    NeoagentGreen = {
      fg = palette:terminal(2),
      ctermfg = 2,
    },
    NeoagentRed = {
      fg = palette:terminal(1),
      ctermfg = 1,
    },
    NeoagentDialogTitle = { bold = true },
    NeoagentMarkdownBold = { bold = true },
    NeoagentMarkdownItalic = { italic = true },
    NeoagentMarkdownUnderline = { underline = true },
    NeoagentMarkdownStrike = { strikethrough = true },
  }) do
    value.default = true
    result[name] = value
  end
  local light = palette:is_light()
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
    result[name] = { bg = background, default = true }
  end
  local normal = palette:group("Normal")
  local rgb = type(normal.bg) == "number" and palette:rgb(normal.bg) or nil
  local luminance = rgb and 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue or nil
  local codex_background
  if luminance then
    local top, alpha = luminance > 128 and 0 or 0xffffff,
      luminance > 128 and 0.04 or 0.12
    codex_background = palette:blend(normal.bg, top, alpha)
  end
  result.NeoagentCodexUserBackground = {
    bg = codex_background,
    default = true,
  }
  return result
end

local function ansi_highlight(theme, style, base)
  local palette = theme:colors()
  local definition = { base = base }
  if type(style.fg) == "number" then
    definition.fg, definition.ctermfg = palette:terminal(style.fg), style.fg
  elseif type(style.fg) == "string" then
    definition.fg = style.fg
  end
  if type(style.bg) == "number" then
    definition.bg, definition.ctermbg = palette:terminal(style.bg), style.bg
  elseif type(style.bg) == "string" then
    definition.bg = style.bg
  end
  for _, attribute in ipairs({
    "bold", "italic", "underline", "strikethrough", "reverse",
  }) do
    if style[attribute] then definition[attribute] = true end
  end
  return theme:derive("ansi:" .. tostring(base) .. ":" .. style_key(style),
    definition)
end

local function define_highlights()
  Applet.Theme.new({
    name = "NeoagentAnsi",
    highlights = highlight_definitions,
    max_derived_highlights = MAX_ANSI_HIGHLIGHTS,
  }):define()
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
  if source.source then
    target.source = {
      path = source.source.path,
      first = source.source.first + row_offset,
      last = source.source.last + row_offset,
    }
  end
end

local function append_tool_body(target, body)
  append_rendered(target, body, true)
end

local function append_rendered_row(target, source, row)
  local spans = {}
  for _, span in ipairs(source.highlights or {}) do
    if span.row == row then
      spans[#spans + 1] = {
        col = span.col,
        end_col = span.end_col,
        group = span.group,
        priority = span.priority,
      }
    end
  end
  add_line(target, source.lines[row + 1], spans,
    source.line_groups and source.line_groups[row])
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
  if display.width(" " .. text .. " ") <= available then return text end
  local ellipsis = string.rep(".", math.min(3, width))
  local prefix = display.truncate(text,
    math.max(0, available - display.width(ellipsis) - 2), { marker = "" })
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
  result.card = {
    first = 0,
    last = #result.lines - 2,
    after = #result.lines - 1,
  }
  if content.source then
    local row_offset = background and 1 or 0
    result.source = {
      path = content.source.path,
      first = content.source.first + row_offset,
      last = content.source.last + row_offset,
    }
  end
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
  codex_tool_error = "NeoagentCodexToolError",
  codex_tool_success = "NeoagentCodexToolSuccess",
  cyan = "NeoagentCyan",
  error = "NeoagentError",
  green = "NeoagentGreen",
  italic = "NeoagentMarkdownItalic",
  muted = "NeoagentMuted",
  red = "NeoagentRed",
  strike = "NeoagentMarkdownStrike",
}

local function presentation_line(segments_value)
  if type(segments_value) ~= "table"
      or not util.is_list(segments_value) then return nil end
  local line, spans = "", {}
  for _, segment in ipairs(segments_value) do
    if type(segment) ~= "table" or type(segment.text) ~= "string"
        or segment.text:find("\n", 1, true)
        or segment.text:find("\r", 1, true) then
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
  return line, spans
end

local function presentation_content(lines)
  if type(lines) ~= "table" or not util.is_list(lines) then return nil end
  local content = rendered()
  for _, segments_value in ipairs(lines) do
    local line, spans = presentation_line(segments_value)
    if not line then return nil end
    add_line(content, line, spans)
  end
  return content
end

local function custom_tool_presentation(self, block, args, options)
  if type(self.resolve_tool) ~= "function" then return nil end
  local name = block.name or (block.call and block.call.name)
    or (block.message and block.message.toolName)
  local resolved, tool = pcall(self.resolve_tool, name)
  if not resolved or type(tool) ~= "table"
      or type(tool.render) ~= "function" then return nil end
  local ok, semantic = pcall(tool.render, {
    arguments = util.copy(args),
    result = util.copy(block.message or block.update),
    state = block.state,
  })
  if not ok or type(semantic) ~= "table" then return nil end
  local presented, presentation = pcall(self.policy.present_tool,
    util.copy(semantic), {
      state = block.state,
      width = options.width or self:_content_width(),
      presentation_surface = options.presentation_surface,
      spinner = self.spinner_frames[self.spinner_frame],
    })
  if not presented or type(presentation) ~= "table" then return nil end
  if presentation.default ~= nil and type(presentation.default) ~= "boolean"
      or presentation.command ~= nil
        and type(presentation.command) ~= "string"
      or presentation.status ~= nil
        and type(presentation.status) ~= "boolean"
      or presentation.animated ~= nil
        and type(presentation.animated) ~= "boolean" then
    return nil
  end
  if presentation.default == true and presentation.lines ~= nil then return nil end
  if presentation.title ~= nil and presentation.title ~= true
      and not presentation_line(presentation.title) then return nil end
  if presentation.lines ~= nil
      and not presentation_content(presentation.lines) then return nil end
  if presentation.command ~= nil and (presentation.default == true
      or presentation.lines ~= nil or presentation.title == nil
      or presentation.title == true) then return nil end
  if presentation.default ~= true and presentation.title == nil
      and presentation.lines == nil and presentation.command == nil then return nil end
  return presentation
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

local function summary_value(value, surface)
  if value == vim.NIL then return "null" end
  if type(value) == "string" then
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
    return surface == "transcript" and #value > 80
      and value:sub(1, 77) .. "..." or value
  end
  if type(value) ~= "table" then return tostring(value) end
  if util.is_list(value) then return "[" .. #value .. " items]" end
  return "{…}"
end

local function argument_text(value, fallback, surface)
  if value == nil then return fallback end
  return summary_value(value, surface)
end

local function numeric_argument(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then return tonumber(value) end
end

local function read_range(args, surface)
  local offset = numeric_argument(args.offset)
  local limit = numeric_argument(args.limit)
  if (args.offset == nil or offset) and (args.limit == nil or limit) then
    local first = offset or 1
    local last = limit and first + limit - 1
    return ":" .. first .. (last and "-" .. last or "")
  end
  local fields = {}
  if args.offset ~= nil then
    fields[#fields + 1] = "offset="
      .. argument_text(args.offset, "?", surface)
  end
  if args.limit ~= nil then
    fields[#fields + 1] = "limit="
      .. argument_text(args.limit, "?", surface)
  end
  return " (" .. table.concat(fields, " ") .. ")"
end

local function tool_title(name, args, surface)
  name = type(name) == "string" and name or "<tool>"
  local label = tool_labels[name] or name
  if name == "shell" then
    return { {
      text = "$ " .. argument_text(args.command, "…", surface),
      group = "NeoagentMarkdownBold",
    } }
  end
  local parts = { { text = label, group = "NeoagentMarkdownBold" } }
  if name == "read" or name == "read_file" or name == "write" or name == "write_file"
      or name == "edit" or name == "edit_file" then
    parts[#parts + 1] = { text = " " .. argument_text(
      args.path or args.file_path, "…", surface), group = "NeoagentAccent" }
    if (name == "read" or name == "read_file") and (args.offset or args.limit) then
      parts[#parts + 1] = {
        text = read_range(args, surface), group = "DiagnosticWarn",
      }
    end
  elseif name == "grep" then
    parts[#parts + 1] = { text = " "
      .. argument_text(args.pattern, "…", surface), group = "NeoagentAccent" }
    parts[#parts + 1] = { text = " in "
      .. argument_text(args.path, ".", surface), group = "NeoagentToolOutput" }
    if args.glob then
      parts[#parts + 1] = { text = " ("
        .. argument_text(args.glob, "?", surface) .. ")",
        group = "NeoagentToolOutput" }
    end
  elseif name == "find" then
    parts[#parts + 1] = { text = " "
      .. argument_text(args.pattern, "…", surface), group = "NeoagentAccent" }
    parts[#parts + 1] = { text = " in "
      .. argument_text(args.path, ".", surface), group = "NeoagentToolOutput" }
  else
    local values = {}
    for key, value in pairs(args) do
      if key ~= "content" and value ~= nil then
        values[#values + 1] = tostring(key) .. "="
          .. summary_value(value, surface)
      end
    end
    table.sort(values)
    if #values > 0 then parts[#parts + 1] = { text = " " .. table.concat(values, " "), group = "NeoagentToolOutput" } end
  end
  return parts
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

local function output_lines(self, text, maximum, tail, group, ansi)
  local result = rendered()
  result.output_line_count = 0
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
    local line_spans = #line > 0 and line_group
        and { { col = 0, end_col = #line, group = line_group } } or {}
    local source_row = first_row + index - 1
    for _, span in ipairs(ansi_spans) do
      if span.row == source_row and span.col < #line then
        line_spans[#line_spans + 1] = {
          col = span.col,
          end_col = math.min(span.end_col, #line),
          group = ansi_highlight(self.theme, span.style, line_group),
          priority = 110,
        }
      end
    end
    add_line(result, line, line_spans)
  end
  result.output_line_count = #lines
  if omitted > 0 then
    local message = string.format("[... %d more line%s]", omitted, omitted == 1 and "" or "s")
    add_line(result, message, { { col = 0, end_col = #message, group = "NeoagentMuted" } })
  end
  return result
end

local function source_output(result, path, line_count)
  if line_count == nil then line_count = result.output_line_count end
  if type(path) == "string" and path ~= "" and type(line_count) == "number"
      and line_count >= 0 and line_count % 1 == 0 then
    line_count = math.min(line_count, result.output_line_count)
    if line_count > 0 then
      result.source = {
        path = path,
        first = 0,
        last = line_count - 1,
      }
    end
  end
  return result
end

local function tool_output(self, block, args, surface)
  local name = block.name or (block.call and block.call.name) or (block.message and block.message.toolName)
  local message = block.message
  local update = block.update
  local value = message and content_text(message.content) or update and content_text(update.content) or nil
  local maximum
  if surface == "transcript" then
    maximum = name == "grep" and 15 or name == "find" and 20 or 10
  end

  if name == "write" or name == "write_file" then
    if surface == "transcript" and self.policy.write_preview_lines then
      maximum = self.policy.write_preview_lines
    end
    local result = output_lines(self,
      args.content, maximum, false, self.policy.write_output_group())
    local path = args.path or args.file_path
    if self.policy.write_source_syntax then source_output(result, path) end
    return result
  elseif name == "edit" or name == "edit_file" then
    local patch = message and message.details and message.details.patch
    if patch and patch ~= "" then
      return output_lines(self, patch, maximum, false, "diff")
    end
    if message and message.isError then
      return output_lines(self, value, maximum, false, "NeoagentError")
    end
    return rendered()
  elseif name == "read" or name == "read_file" then
    local syntax = surface == "details" and self.policy.read_source_syntax
      and not (message and message.isError)
    local group
    if not syntax then
      group = self.policy.plain_output_group(message and message.isError)
    end
    local result = output_lines(self, value, maximum, false, group)
    local path = args.path or args.file_path
    local truncation = message and message.details
      and message.details.truncation
    local source_lines = type(truncation) == "table"
      and truncation.outputLines or nil
    if syntax then source_output(result, path, source_lines) end
    return result
  elseif name == "shell" then
    local active = message or update
    local ansi = active and active.details and active.details.ansi
    return output_lines(self, value, maximum, true,
      self.policy.plain_output_group(message and message.isError), ansi)
  elseif name == "grep" or name == "find" then
    return output_lines(self, value, maximum, false,
      self.policy.plain_output_group(message and message.isError))
  elseif message and message.isError then
    return output_lines(self, value, maximum, false, "NeoagentError")
  end
  return output_lines(self, value, maximum, false, "NeoagentToolOutput")
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
  local message = string.format(
    "[... %d more line%s]", omitted, omitted == 1 and "" or "s")
  add_line(content, message, {
    { col = 0, end_col = #message, group = "NeoagentMuted" },
  })
  return omitted
end

local function compaction_content(self, block, surface, width)
  local content = rendered()
  local label, label_spans = segments({ { text = "[compaction]", group = "NeoagentMarkdownBold" } })
  local token_count = format_token_count(block.tokens_before)
  if surface == "details" then
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

local function thinking_header(self, source, omitted, expandable)
  local words = source:word_count()
  local message = string.format("[thinking: %d word%s",
    words, words == 1 and "" or "s")
  if omitted > 0 then
    local unit = omitted == 1 and "line" or "lines"
    message = message .. string.format(", %d %s above...", omitted, unit)
  end
  local hint = expandable and expand_hint(self) or nil
  if hint then message = message .. ", " .. hint .. " to expand" end
  return message .. "]"
end

local function assistant_content(self, block, surface, width)
  local document = self:render_markdown(
    "assistant", block.text or "", { width = width })
  local finish = document:finish()
  if surface == "details" then
    return {
      markdown_document = document,
      markdown_first = 1,
      markdown_last = finish,
    }
  end
  return document:slice(1, finish)
end

local function thinking_content(self, block, surface, width)
  local source = self:render_markdown(
    "thinking", block.text or "", { width = width })
  if surface == "details" then
    return {
      markdown_document = source,
      markdown_first = 1,
      markdown_last = source:finish(),
      markdown_groups = {
        "NeoagentThinking",
        "NeoagentMarkdownItalic",
      },
    }
  end
  local content, omitted = source:tail(THINKING_MAX_LINES)
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
  block.header = thinking_header(self, source, omitted, true)
  block.resting_header = thinking_header(self, source, omitted, false)
  return content
end

local function ordinary_tool_title(self, block, args, surface, status)
  return segments(self.policy.tool_title(tool_title(
    block.name or (block.call and block.call.name), args, surface), status))
end

local COMMAND_CONTINUATION_MAX_LINES = 2
local COMMAND_OUTPUT_MAX_LINES = 5

local function middle_rendered(source, maximum)
  if #source.lines <= maximum then return source end
  local result = rendered()
  local retained = maximum - 1
  local head = math.floor(retained / 2)
  local tail = retained - head
  for row = 0, head - 1 do append_rendered_row(result, source, row) end
  local omitted = #source.lines - head - tail
  local message = string.format("… +%d lines", omitted)
  add_line(result, message, {
    { col = 0, end_col = #message, group = "NeoagentMuted" },
  })
  for row = #source.lines - tail, #source.lines - 1 do
    append_rendered_row(result, source, row)
  end
  return result
end

local function prefix_rendered(source, first_prefix, prefix)
  local result = rendered()
  for row, line in ipairs(source.lines) do
    local value = row == 1 and first_prefix or prefix
    local spans = #value > 0 and {
      { col = 0, end_col = #value, group = "NeoagentMuted" },
    } or {}
    for _, span in ipairs(source.highlights or {}) do
      if span.row == row - 1 then
        spans[#spans + 1] = {
          col = span.col + #value,
          end_col = span.end_col + #value,
          group = span.group,
          priority = span.priority,
        }
      end
    end
    add_line(result, value .. line, spans,
      source.line_groups and source.line_groups[row - 1])
  end
  return result
end

local function command_output_content(self, block, surface)
  local active = block.message or block.update
  if not active then return rendered() end
  local value = content_text(active.content)
  local ansi = active.details and active.details.ansi
  local content = output_lines(self, value, nil, false,
    self.policy.plain_output_group(active.isError), ansi)
  if surface == "details" then return content end
  if #content.lines == 0 then
    add_line(content, "(no output)", {
      { col = 0, end_col = 11, group = "NeoagentMuted" },
    })
  end
  return prefix_rendered(
    middle_rendered(content, COMMAND_OUTPUT_MAX_LINES), "  └ ", "    ")
end

local function command_tool_content(self, block, presentation, surface)
  local content = rendered()
  local title, title_spans = presentation_line(self.policy.tool_title(
    presentation.title,
    presentation.status and block.state or nil))
  local command = presentation.command:gsub("\r\n", "\n"):gsub("\r", "\n")
  local source = vim.split(command, "\n", { plain = true })
  local first_command = source[1] or ""
  add_line(content, title .. (first_command == "" and "" or " " .. first_command),
    title_spans)

  local last_command = surface == "transcript"
      and math.min(#source, COMMAND_CONTINUATION_MAX_LINES + 1)
    or #source
  for index = 2, last_command do
    local line, spans = segments({
      { text = "  │ ", group = "NeoagentMuted" },
      { text = source[index] },
    })
    add_line(content, line, spans)
  end
  local continuation_count = #source - 1
  if surface == "transcript"
      and continuation_count > COMMAND_CONTINUATION_MAX_LINES then
    local omitted = continuation_count - COMMAND_CONTINUATION_MAX_LINES
    local line, spans = segments({
      { text = "  │ ", group = "NeoagentMuted" },
      { text = string.format("… +%d lines", omitted),
        group = "NeoagentMuted" },
    })
    add_line(content, line, spans)
  end
  append_tool_body(content, command_output_content(self, block, surface))
  return content
end

local function ordinary_tool_content(
    self, block, args, surface, title_override, status)
  local content = rendered()
  local title, spans = ordinary_tool_title(
    self, block, args, surface, status)
  if title_override and title_override ~= true then
    title, spans = presentation_line(
      self.policy.tool_title(title_override, status))
  end
  add_line(content, title, spans)
  append_tool_body(content, tool_output(self, block, args, surface))
  return content
end

local function presented_tool_content(self, block, args, options, presentation)
  if not presentation then
    return ordinary_tool_content(
      self, block, args, options.presentation_surface)
  end
  if presentation.command then
    return command_tool_content(
      self, block, presentation, options.presentation_surface)
  end
  local content
  if presentation.default == true then
    content = ordinary_tool_content(
      self, block, args, options.presentation_surface, presentation.title,
      presentation.status and block.state or nil)
  else
    content = rendered()
    if presentation.title then
      local title, spans
      if presentation.title == true then
        title, spans = ordinary_tool_title(
          self, block, args, options.presentation_surface,
          presentation.status and block.state or nil)
      else
        title, spans = presentation_line(
          self.policy.tool_title(presentation.title,
            presentation.status and block.state or nil))
      end
      add_line(content, title, spans)
    end
    if presentation.lines then
      append_tool_body(content, presentation_content(presentation.lines))
    end
  end
  if presentation.animated == true then content.animated = true end
  return content
end

local function card_content(self, block, options)
  options = options or {}
  local surface = options.presentation_surface
  assert(surface == "transcript" or surface == "details",
    "render surface must be transcript or details")
  local width = options.width or self:_content_width()
  if block.kind == "user" then
    return markdown.render(block.text, {
      width = width,
      preserve_markers = true,
    }), self.policy.user_background()
  elseif block.kind == "compaction" then
    return compaction_content(self, block, surface, width),
      self.policy.compaction_background()
  elseif block.kind == "thinking" then
    return thinking_content(self, block, surface, width)
  elseif block.kind == "assistant" then
    return assistant_content(self, block, surface, width)
  elseif block.kind ~= "tool" then
    return nil
  end

  local args = block.call and block.call.arguments or partial_arguments(block.raw)
  if type(args) ~= "table" then args = {} end
  local presentation = custom_tool_presentation(self, block, args, options)
  local content = presented_tool_content(
    self, block, args, options, presentation)
  local background = self.policy.tool_background(block.state)
  return content, background
end

local function insert_group_separator(content, width, index, side)
  if #content.lines == 0 then return content end
  local row = index - 1
  for _, span in ipairs(content.highlights) do
    if span.row >= row then span.row = span.row + 1 end
  end
  local separators = {}
  for name, separator in pairs(content.separators or {}) do
    separators[name] = separator >= row and separator + 1 or separator
  end
  separators[side] = row
  content.separators = separators
  local line = " " .. string.rep("─", math.max(1, width))
  table.insert(content.lines, index, line)
  content.highlights[#content.highlights + 1] = {
    row = row,
    col = 1,
    end_col = #line,
    group = "NeoagentMuted",
  }
  if content.card then
    for _, name in ipairs({ "first", "last", "after" }) do
      if content.card[name] and row <= content.card[name] then
        content.card[name] = content.card[name] + 1
      end
    end
  end
  if content.source and row <= content.source.first then
    content.source.first = content.source.first + 1
    content.source.last = content.source.last + 1
  end
  return content
end

local function prepend_group_separator(content, width)
  return insert_group_separator(content, width, 1, "before")
end

local function append_group_separator(content, width)
  return insert_group_separator(content, width, #content.lines, "after")
end

local function decorate_block(self, block, content, neighbors)
  local previous = neighbors and neighbors.previous or nil
  local following = neighbors and neighbors.next or nil
  if self.policy.separator(previous, block) == "before_current" then
    prepend_group_separator(content, self:_content_width())
  end
  if self.policy.separator(block, following) == "after_previous" then
    append_group_separator(content, self:_content_width())
  end
  return content
end

function M.block(self, block, neighbors)
  local options = vim.tbl_extend(
    "force", neighbors or {}, { presentation_surface = "transcript" })
  local content, background = card_content(self, block, options)
  if content then
    local width
    if content.wrap ~= true and (block.kind == "compaction" or (
        self.config.wrap_cards ~= true and block.kind ~= "assistant"
          and block.kind ~= "user")) then
      width = self:_content_width()
    end
    local result = card(content, background, width)
    if block.kind == "thinking" then
      block.overflow = content.truncated == true
    end
    return decorate_block(self, block, result, neighbors)
  end
  return decorate_block(self, block,
    prose(plain(block.text,
      block.error and "NeoagentError" or "NeoagentMuted")), neighbors)
end

function M.details(self, block, options)
  options = vim.tbl_extend(
    "force", options or {}, { presentation_surface = "details" })
  return card_content(self, block, options)
end

M.highlight_definitions = highlight_definitions
M.define_highlights = define_highlights
return M
