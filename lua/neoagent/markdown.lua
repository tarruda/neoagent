local M = {}

local function width(text)
  return vim.fn.strdisplaywidth(text)
end

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function find_plain(text, needle, from)
  return text:find(needle, from, true)
end

local function append(target, text, spans)
  local offset = target.length
  target.parts[#target.parts + 1] = text
  target.length = offset + #text
  for _, span in ipairs(spans or {}) do
    target.spans[#target.spans + 1] = {
      col = span.col + offset,
      end_col = span.end_col + offset,
      group = span.group,
    }
  end
  return offset
end

local function inline(text)
  local result = { parts = {}, spans = {}, length = 0 }
  local plain = {}

  local function flush()
    if #plain == 0 then return end
    append(result, table.concat(plain))
    plain = {}
  end

  local function styled(inner, group)
    flush()
    local rendered = inline(inner)
    local start = append(result, rendered.text, rendered.spans)
    if #rendered.text > 0 then
      result.spans[#result.spans + 1] = { col = start, end_col = start + #rendered.text, group = group }
    end
  end

  local index = 1
  while index <= #text do
    local two = text:sub(index, index + 1)
    local char = text:sub(index, index)
    if char == "\\" and index < #text and text:sub(index + 1, index + 1):match("[%p]") then
      plain[#plain + 1] = text:sub(index + 1, index + 1)
      index = index + 2
    elseif two == "**" or two == "__" then
      local close = find_plain(text, two, index + 2)
      if close and close > index + 2 then
        styled(text:sub(index + 2, close - 1), "NeoagentMarkdownBold")
        index = close + 2
      else
        plain[#plain + 1] = char
        index = index + 1
      end
    elseif two == "~~" then
      local close = find_plain(text, two, index + 2)
      local inner = close and text:sub(index + 2, close - 1) or ""
      if close and inner ~= "" and not inner:match("^%s") and not inner:match("%s$") then
        styled(inner, "NeoagentMarkdownStrike")
        index = close + 2
      else
        plain[#plain + 1] = char
        index = index + 1
      end
    elseif char == "`" then
      local finish = index
      while text:sub(finish + 1, finish + 1) == "`" do finish = finish + 1 end
      local marker = text:sub(index, finish)
      local close = find_plain(text, marker, finish + 1)
      if close then
        flush()
        local code = text:sub(finish + 1, close - 1):gsub("^ ", ""):gsub(" $", "")
        local start = append(result, code)
        if #code > 0 then
          result.spans[#result.spans + 1] = { col = start, end_col = start + #code, group = "NeoagentMarkdownCode" }
        end
        index = close + #marker
      else
        plain[#plain + 1] = marker
        index = finish + 1
      end
    elseif char == "[" or (char == "!" and text:sub(index + 1, index + 1) == "[") then
      local image = char == "!"
      local label_start = index + (image and 2 or 1)
      local label_end = find_plain(text, "]", label_start)
      local url_start = label_end and text:sub(label_end + 1, label_end + 1) == "(" and label_end + 2 or nil
      local url_end = url_start and find_plain(text, ")", url_start) or nil
      if label_end and url_start and url_end then
        flush()
        local label = text:sub(label_start, label_end - 1)
        local url = text:sub(url_start, url_end - 1)
        local rendered = inline(label)
        if image then
          append(result, "[image: ")
        end
        local start = append(result, rendered.text, rendered.spans)
        if #rendered.text > 0 then
          result.spans[#result.spans + 1] = { col = start, end_col = start + #rendered.text, group = "NeoagentMarkdownLink" }
        end
        if image then append(result, "]") end
        if url ~= label then
          local url_text = " (" .. url .. ")"
          local url_col = append(result, url_text)
          result.spans[#result.spans + 1] = { col = url_col, end_col = url_col + #url_text, group = "NeoagentMarkdownLinkUrl" }
        end
        index = url_end + 1
      else
        plain[#plain + 1] = char
        index = index + 1
      end
    elseif char == "*" or char == "_" then
      local close = find_plain(text, char, index + 1)
      local inner = close and text:sub(index + 1, close - 1) or ""
      local word_underscore = char == "_" and index > 1 and text:sub(index - 1, index - 1):match("[%w]")
      if close and inner ~= "" and not inner:match("^%s") and not inner:match("%s$") and not word_underscore then
        styled(inner, "NeoagentMarkdownItalic")
        index = close + 1
      else
        plain[#plain + 1] = char
        index = index + 1
      end
    else
      plain[#plain + 1] = char
      index = index + 1
    end
  end
  flush()
  result.text = table.concat(result.parts)
  return result
end

local function cells(line)
  line = trim(line)
  if line:sub(1, 1) == "|" then line = line:sub(2) end
  if line:sub(-1) == "|" then line = line:sub(1, -2) end
  local result = {}
  for cell in (line .. "|"):gmatch("(.-)|") do result[#result + 1] = trim(cell) end
  return result
end

local function table_separator(line)
  local parsed = cells(line)
  if #parsed == 0 then return false end
  for _, cell in ipairs(parsed) do
    if not cell:match("^:?-+:?$") then return false end
  end
  return true
end

local function pad(text, target)
  return text .. string.rep(" ", math.max(0, target - width(text)))
end

local function shift_spans(spans, offset, group)
  local result = {}
  for _, span in ipairs(spans) do
    result[#result + 1] = { col = span.col + offset, end_col = span.end_col + offset, group = span.group }
  end
  if group and offset > 0 then
    result[#result + 1] = { col = 0, end_col = offset, group = group }
  end
  return result
end

local function render_table(source, first, available)
  local rows = { cells(source[first]) }
  local index = first + 2
  while index <= #source and source[index]:find("|", 1, true) and source[index] ~= "" do
    rows[#rows + 1] = cells(source[index])
    index = index + 1
  end
  local columns = #rows[1]
  local rendered, widths = {}, {}
  for row_index, row in ipairs(rows) do
    rendered[row_index] = {}
    for column = 1, columns do
      local value = inline(row[column] or "")
      rendered[row_index][column] = value
      widths[column] = math.max(widths[column] or 1, width(value.text))
    end
  end
  local total = 3 * columns + 1
  for _, value in ipairs(widths) do total = total + value end
  if total > available then return nil, first end

  local result = {}
  local function border(left, middle, right)
    local parts = {}
    for _, value in ipairs(widths) do parts[#parts + 1] = string.rep("─", value) end
    local text = left .. "─" .. table.concat(parts, "─" .. middle .. "─") .. "─" .. right
    result[#result + 1] = { text = text, spans = { { col = 0, end_col = #text, group = "NeoagentMarkdownTableBorder" } } }
  end
  border("┌", "┬", "┐")
  for row_index, row in ipairs(rendered) do
    local prefix = "│ "
    local line = { parts = { prefix }, spans = {}, length = #prefix }
    for column, value in ipairs(row) do
      local start = append(line, pad(value.text, widths[column]), value.spans)
      if row_index == 1 then
        line.spans[#line.spans + 1] = { col = start, end_col = start + #value.text, group = "NeoagentMarkdownBold" }
      end
      append(line, column == columns and " │" or " │ ")
    end
    local text = table.concat(line.parts)
    line.spans[#line.spans + 1] = { col = 0, end_col = #prefix, group = "NeoagentMarkdownTableBorder" }
    line.spans[#line.spans + 1] = { col = #text - #" │", end_col = #text, group = "NeoagentMarkdownTableBorder" }
    result[#result + 1] = { text = text, spans = line.spans }
    if row_index == 1 or row_index < #rendered then border("├", "┼", "┤") end
  end
  border("└", "┴", "┘")
  return result, index - 1
end

local function fence(line)
  local ticks, language = line:match("^%s*(`+)%s*([^`]*)$")
  if ticks and #ticks >= 3 then return ticks, trim(language) end
  local tildes
  tildes, language = line:match("^%s*(~+)%s*([^~]*)$")
  if tildes and #tildes >= 3 then return tildes, trim(language) end
end

local function add(output, text, spans)
  local row = #output.lines
  output.lines[#output.lines + 1] = text
  for _, span in ipairs(spans or {}) do
    if span.end_col > span.col then
      output.highlights[#output.highlights + 1] = {
        row = row,
        col = span.col,
        end_col = span.end_col,
        group = span.group,
      }
    end
  end
end

function M.render(text, opts)
  opts = opts or {}
  text = (text or ""):gsub("\t", "   ")
  if trim(text) == "" then return { lines = {}, highlights = {} } end
  local source = vim.split(text, "\n", { plain = true })
  local output = { lines = {}, highlights = {} }
  local available = math.max(1, opts.width or 80)
  local index = 1
  while index <= #source do
    local line = source[index]
    local marker, language = fence(line)
    if marker then
      add(output, "```" .. language, { { col = 0, end_col = 3 + #language, group = "NeoagentMarkdownCodeBorder" } })
      local close = index + 1
      while close <= #source do
        local candidate = source[close]:match("^%s*([`~]+)%s*$")
        if candidate and candidate:sub(1, 1) == marker:sub(1, 1) and #candidate >= #marker then break end
        close = close + 1
      end
      local last = close <= #source and close - 1 or #source
      if close > #source and last >= index + 1 then
        local partial = source[last]:match("^%s*([`~]+)%s*$")
        if partial and partial:sub(1, 1) == marker:sub(1, 1) and #partial < #marker then last = last - 1 end
      end
      for code_line = index + 1, last do
        local value = "  " .. source[code_line]
        add(output, value, { { col = 2, end_col = #value, group = "NeoagentMarkdownCodeBlock" } })
      end
      add(output, "```", { { col = 0, end_col = 3, group = "NeoagentMarkdownCodeBorder" } })
      index = close <= #source and close + 1 or #source + 1
    elseif index < #source and line:find("|", 1, true) and table_separator(source[index + 1]) then
      local rendered, last = render_table(source, index, available)
      if rendered then
        for _, row in ipairs(rendered) do add(output, row.text, row.spans) end
        index = last + 1
      else
        local value = inline(line)
        add(output, value.text, value.spans)
        index = index + 1
      end
    else
      local hashes, heading = line:match("^%s*(#+)%s+(.+)$")
      if hashes and #hashes > 6 then hashes = nil end
      local quote = line:match("^%s*>%s?(.*)$")
      local indent, bullet, item = line:match("^(%s*)([-+*])%s+(.+)$")
      local ordered
      if not bullet then indent, ordered, item = line:match("^(%s*)(%d+[.)])%s+(.+)$") end
      if hashes then
        local value = inline(heading:gsub("%s+#+%s*$", ""))
        local prefix = #hashes >= 3 and hashes .. " " or ""
        local spans = shift_spans(value.spans, #prefix, "NeoagentMarkdownHeading")
        spans[#spans + 1] = { col = 0, end_col = #prefix + #value.text, group = "NeoagentMarkdownHeading" }
        spans[#spans + 1] = { col = 0, end_col = #prefix + #value.text, group = "NeoagentMarkdownBold" }
        if #hashes == 1 then spans[#spans + 1] = { col = 0, end_col = #prefix + #value.text, group = "NeoagentMarkdownUnderline" } end
        add(output, prefix .. value.text, spans)
      elseif quote ~= nil then
        local value = inline(quote)
        local prefix = "│ "
        local spans = shift_spans(value.spans, #prefix, "NeoagentMarkdownQuoteBorder")
        spans[#spans + 1] = { col = #prefix, end_col = #prefix + #value.text, group = "NeoagentMarkdownQuote" }
        spans[#spans + 1] = { col = #prefix, end_col = #prefix + #value.text, group = "NeoagentMarkdownItalic" }
        add(output, prefix .. value.text, spans)
      elseif bullet or ordered then
        local marker_text = bullet and (opts.preserve_markers and bullet or "-") or ordered
        local task, rest = item:match("^%[([ xX])%]%s*(.*)$")
        if task then item = "[" .. (task:lower() == "x" and "x" or " ") .. "] " .. rest end
        local prefix = indent .. marker_text .. " "
        local value = inline(item)
        local spans = shift_spans(value.spans, #prefix)
        spans[#spans + 1] = { col = #indent, end_col = #prefix, group = "NeoagentMarkdownListBullet" }
        add(output, prefix .. value.text, spans)
      elseif line:match("^%s*([-*_])%s*%1%s*%1[%s%1]*$") then
        local value = string.rep("─", math.min(available, 80))
        add(output, value, { { col = 0, end_col = #value, group = "NeoagentMarkdownHr" } })
      elseif line == "" then
        add(output, "")
      else
        local value = inline(line)
        add(output, value.text, value.spans)
      end
      index = index + 1
    end
  end
  return output
end

return M
