local text = require("applet").Pane.text

local M = {}
local Document = {}
Document.__index = Document

local function width(value) return text.width(value) end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function find_plain(value, needle, from)
  return value:find(needle, from, true)
end

local function append(target, value, spans)
  local offset = target.length
  target.parts[#target.parts + 1] = value
  target.length = offset + #value
  for _, span in ipairs(spans or {}) do
    target.spans[#target.spans + 1] = {
      col = span.col + offset,
      end_col = span.end_col + offset,
      group = span.group,
    }
  end
  return offset
end

local function parse_inline(value, previous_char)
  local result = { parts = {}, spans = {}, length = 0 }
  local plain = {}
  local unstable_source, unstable_output

  local function flush()
    if #plain == 0 then return end
    append(result, table.concat(plain))
    plain = {}
  end

  local function depend(index)
    if unstable_source then return end
    flush()
    unstable_source = index
    unstable_output = result.length
  end

  local function styled(inner, group)
    flush()
    local rendered = parse_inline(inner)
    local start = append(result, rendered.text, rendered.spans)
    if #rendered.text > 0 then
      result.spans[#result.spans + 1] = {
        col = start,
        end_col = start + #rendered.text,
        group = group,
      }
    end
  end

  local index = 1
  while index <= #value do
    local two = value:sub(index, index + 1)
    local char = value:sub(index, index)
    if char == "\\" and index < #value
        and value:sub(index + 1, index + 1):match("[%p]") then
      plain[#plain + 1] = value:sub(index + 1, index + 1)
      index = index + 2
    elseif char == "\\" and index == #value then
      depend(index)
      plain[#plain + 1] = char
      index = index + 1
    elseif two == "**" or two == "__" then
      local close = find_plain(value, two, index + 2)
      if close and close > index + 2 then
        styled(value:sub(index + 2, close - 1),
          "NeoagentMarkdownBold")
        index = close + 2
      else
        if not close then depend(index) end
        plain[#plain + 1] = char
        index = index + 1
      end
    elseif two == "~~" then
      local close = find_plain(value, two, index + 2)
      local inner = close and value:sub(index + 2, close - 1) or ""
      if close and inner ~= "" and not inner:match("^%s")
          and not inner:match("%s$") then
        styled(inner, "NeoagentMarkdownStrike")
        index = close + 2
      else
        if not close then depend(index) end
        plain[#plain + 1] = char
        index = index + 1
      end
    elseif char == "`" then
      local finish = index
      while value:sub(finish + 1, finish + 1) == "`" do
        finish = finish + 1
      end
      local marker = value:sub(index, finish)
      local close = find_plain(value, marker, finish + 1)
      if close then
        flush()
        local code = value:sub(finish + 1, close - 1)
          :gsub("^ ", ""):gsub(" $", "")
        local start = append(result, code)
        if #code > 0 then
          result.spans[#result.spans + 1] = {
            col = start,
            end_col = start + #code,
            group = "NeoagentMarkdownCode",
          }
        end
        index = close + #marker
      else
        depend(index)
        plain[#plain + 1] = marker
        index = finish + 1
      end
    elseif char == "[" or (char == "!"
        and value:sub(index + 1, index + 1) == "[") then
      local image = char == "!"
      local label_start = index + (image and 2 or 1)
      local label_end = find_plain(value, "]", label_start)
      local url_start
      if label_end and value:sub(label_end + 1, label_end + 1) == "(" then
        url_start = label_end + 2
      end
      local url_end = url_start and find_plain(value, ")", url_start) or nil
      if label_end and url_start and url_end then
        flush()
        local label = value:sub(label_start, label_end - 1)
        local url = value:sub(url_start, url_end - 1)
        local rendered = parse_inline(label)
        if image then append(result, "[image: ") end
        local start = append(result, rendered.text, rendered.spans)
        if #rendered.text > 0 then
          result.spans[#result.spans + 1] = {
            col = start,
            end_col = start + #rendered.text,
            group = "NeoagentMarkdownLink",
          }
        end
        if image then append(result, "]") end
        if url ~= label then
          local url_text = " (" .. url .. ")"
          local url_col = append(result, url_text)
          result.spans[#result.spans + 1] = {
            col = url_col,
            end_col = url_col + #url_text,
            group = "NeoagentMarkdownLinkUrl",
          }
        end
        index = url_end + 1
      else
        depend(index)
        plain[#plain + 1] = char
        index = index + 1
      end
    elseif char == "*" or char == "_" then
      local close = find_plain(value, char, index + 1)
      local inner = close and value:sub(index + 1, close - 1) or ""
      local before = index > 1 and value:sub(index - 1, index - 1)
        or previous_char
      local word_underscore = char == "_" and before
        and before:match("[%w]")
      if close and inner ~= "" and not inner:match("^%s")
          and not inner:match("%s$") and not word_underscore then
        styled(inner, "NeoagentMarkdownItalic")
        index = close + 1
      else
        if not close and (not word_underscore or index == #value) then
          depend(index)
        end
        plain[#plain + 1] = char
        index = index + 1
      end
    else
      if index == #value and (char == "~" or char == "!") then
        depend(index)
      end
      plain[#plain + 1] = char
      index = index + 1
    end
  end
  flush()
  result.text = table.concat(result.parts)
  result.unstable_source = unstable_source
  result.unstable_output = unstable_output
  return result
end

local function copy_prefix_spans(spans, finish)
  local result = {}
  for _, span in ipairs(spans or {}) do
    if span.end_col <= finish then result[#result + 1] = span end
  end
  return result
end

local function update_inline(previous, value)
  local source_first, output_first = 1, 0
  local prefix, spans = "", {}
  if previous and #value >= #previous.source
      and value:find(previous.source, 1, true) == 1 then
    source_first = previous.unstable_source or (#previous.source + 1)
    output_first = previous.unstable_output or #previous.text
    prefix = previous.text:sub(1, output_first)
    spans = copy_prefix_spans(previous.spans, output_first)
  end

  local suffix = value:sub(source_first)
  local rendered = parse_inline(suffix,
    source_first > 1 and value:sub(source_first - 1, source_first - 1)
      or nil)
  local offset = #prefix
  for _, span in ipairs(rendered.spans) do
    spans[#spans + 1] = {
      col = span.col + offset,
      end_col = span.end_col + offset,
      group = span.group,
    }
  end
  local unstable_source, unstable_output
  if rendered.unstable_source then
    unstable_source = source_first - 1 + rendered.unstable_source
  end
  if rendered.unstable_output then
    unstable_output = output_first + rendered.unstable_output
  end
  return {
    source = value,
    text = prefix .. rendered.text,
    spans = spans,
    unstable_source = unstable_source,
    unstable_output = unstable_output,
  }
end

local function cells(line)
  line = trim(line)
  if line:sub(1, 1) == "|" then line = line:sub(2) end
  if line:sub(-1) == "|" then line = line:sub(1, -2) end
  local result = {}
  for cell in (line .. "|"):gmatch("(.-)|") do
    result[#result + 1] = trim(cell)
  end
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

local function pad(value, target)
  return value .. string.rep(" ", math.max(0, target - width(value)))
end

local function shift_spans(spans, offset, group)
  local result = {}
  for _, span in ipairs(spans) do
    result[#result + 1] = {
      col = span.col + offset,
      end_col = span.end_col + offset,
      group = span.group,
    }
  end
  if group and offset > 0 then
    result[#result + 1] = {
      col = 0,
      end_col = offset,
      group = group,
    }
  end
  return result
end

local function row(value, spans)
  local kept = {}
  for _, span in ipairs(spans or {}) do
    if span.end_col > span.col then kept[#kept + 1] = span end
  end
  return { text = value, spans = kept }
end

local function render_table(source, first, available)
  local values = { cells(source[first]) }
  local index = first + 2
  while index <= #source and source[index]:find("|", 1, true)
      and source[index] ~= "" do
    values[#values + 1] = cells(source[index])
    index = index + 1
  end
  local last = index - 1
  local columns = #values[1]
  local rendered, widths = {}, {}
  for row_index, cells_value in ipairs(values) do
    rendered[row_index] = {}
    for column = 1, columns do
      local value = parse_inline(cells_value[column] or "")
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
    for _, value in ipairs(widths) do
      parts[#parts + 1] = string.rep("─", value)
    end
    local value = left .. "─"
      .. table.concat(parts, "─" .. middle .. "─") .. "─" .. right
    result[#result + 1] = row(value, { {
      col = 0,
      end_col = #value,
      group = "NeoagentMarkdownTableBorder",
    } })
  end
  border("┌", "┬", "┐")
  for row_index, cells_value in ipairs(rendered) do
    local prefix = "│ "
    local line = { parts = { prefix }, spans = {}, length = #prefix }
    for column, value in ipairs(cells_value) do
      local start = append(line, pad(value.text, widths[column]), value.spans)
      if row_index == 1 then
        line.spans[#line.spans + 1] = {
          col = start,
          end_col = start + #value.text,
          group = "NeoagentMarkdownBold",
        }
      end
      append(line, column == columns and " │" or " │ ")
    end
    local value = table.concat(line.parts)
    line.spans[#line.spans + 1] = {
      col = 0,
      end_col = #prefix,
      group = "NeoagentMarkdownTableBorder",
    }
    line.spans[#line.spans + 1] = {
      col = #value - #" │",
      end_col = #value,
      group = "NeoagentMarkdownTableBorder",
    }
    result[#result + 1] = row(value, line.spans)
    if row_index == 1 or row_index < #rendered then
      border("├", "┼", "┤")
    end
  end
  border("└", "┴", "┘")
  return result, last
end

local function fence(line)
  local ticks, language = line:match("^%s*(`+)%s*([^`]*)$")
  if ticks and #ticks >= 3 then return ticks, trim(language) end
  local tildes
  tildes, language = line:match("^%s*(~+)%s*([^~]*)$")
  if tildes and #tildes >= 3 then return tildes, trim(language) end
end

local function closing_fence(line, marker)
  local candidate = line:match("^%s*([`~]+)%s*$")
  return candidate and candidate:sub(1, 1) == marker:sub(1, 1)
    and #candidate >= #marker
end

local function partial_fence(line, marker)
  local candidate = line:match("^%s*([`~]+)%s*$")
  return candidate and candidate:sub(1, 1) == marker:sub(1, 1)
    and #candidate < #marker
end

local function code_row(value)
  value = "  " .. value
  return row(value, { {
    col = 2,
    end_col = #value,
    group = "NeoagentMarkdownCodeBlock",
  } })
end

local function code_border(value)
  return row(value, { {
    col = 0,
    end_col = #value,
    group = "NeoagentMarkdownCodeBorder",
  } })
end

local function options(value)
  value = value or {}
  return {
    width = math.max(1, value.width or 80),
    preserve_markers = value.preserve_markers == true,
  }
end

local function same_options(left, right)
  return left and right and left.width == right.width
    and left.preserve_markers == right.preserve_markers
end

local function render_line(line, opts, previous)
  local hashes, heading = line:match("^%s*(#+)%s+(.+)$")
  if hashes and #hashes > 6 then hashes = nil end
  local quote = line:match("^%s*>%s?(.*)$")
  local indent, bullet, item = line:match("^(%s*)([-+*])%s+(.+)$")
  local ordered
  if not bullet then
    indent, ordered, item = line:match("^(%s*)(%d+[.)])%s+(.+)$")
  end

  if hashes then
    local value = parse_inline(heading:gsub("%s+#+%s*$", ""))
    local prefix = #hashes >= 3 and hashes .. " " or ""
    local spans = shift_spans(value.spans, #prefix,
      "NeoagentMarkdownHeading")
    spans[#spans + 1] = {
      col = 0,
      end_col = #prefix + #value.text,
      group = "NeoagentMarkdownHeading",
    }
    spans[#spans + 1] = {
      col = 0,
      end_col = #prefix + #value.text,
      group = "NeoagentMarkdownBold",
    }
    if #hashes == 1 then
      spans[#spans + 1] = {
        col = 0,
        end_col = #prefix + #value.text,
        group = "NeoagentMarkdownUnderline",
      }
    end
    return row(prefix .. value.text, spans), "heading"
  elseif quote ~= nil then
    local value = parse_inline(quote)
    local prefix = "│ "
    local spans = shift_spans(value.spans, #prefix,
      "NeoagentMarkdownQuoteBorder")
    spans[#spans + 1] = {
      col = #prefix,
      end_col = #prefix + #value.text,
      group = "NeoagentMarkdownQuote",
    }
    spans[#spans + 1] = {
      col = #prefix,
      end_col = #prefix + #value.text,
      group = "NeoagentMarkdownItalic",
    }
    return row(prefix .. value.text, spans), "quote"
  elseif bullet or ordered then
    local marker = ordered
    if bullet then marker = opts.preserve_markers and bullet or "-" end
    local task, rest = item:match("^%[([ xX])%]%s*(.*)$")
    if task then
      item = "[" .. (task:lower() == "x" and "x" or " ") .. "] " .. rest
    end
    local prefix = indent .. marker .. " "
    local value = parse_inline(item)
    local spans = shift_spans(value.spans, #prefix)
    spans[#spans + 1] = {
      col = #indent,
      end_col = #prefix,
      group = "NeoagentMarkdownListBullet",
    }
    return row(prefix .. value.text, spans), "list"
  elseif line:match("^%s*([-*_])%s*%1%s*%1[%s%1]*$") then
    local value = string.rep("─", math.min(opts.width, 80))
    return row(value, { {
      col = 0,
      end_col = #value,
      group = "NeoagentMarkdownHr",
    } }), "rule"
  elseif line == "" then
    return row(""), "blank"
  end

  local prior = previous and previous.syntax == "plain"
    and previous.inline or nil
  local value = update_inline(prior, line)
  return row(value.text, value.spans), "plain", value
end

local function append_rows(target, values)
  for _, value in ipairs(values) do target[#target + 1] = value end
end

local parse_blocks

local function render_fence(source, first, marker, language, rows)
  local output_first = #rows + 1
  rows[#rows + 1] = code_border("```" .. language)
  local close = first + 1
  while close <= #source and not closing_fence(source[close], marker) do
    close = close + 1
  end
  local open = close > #source
  local source_last = open and #source or close
  local tail_source = open and math.max(first + 1, #source) or close
  local last_code = open and #source or close - 1
  if open and last_code >= first + 1
      and partial_fence(source[last_code], marker) then
    last_code = last_code - 1
  end

  for source_row = first + 1, math.min(last_code, tail_source - 1) do
    rows[#rows + 1] = code_row(source[source_row])
  end
  local tail_output_first = #rows + 1
  for source_row = math.max(first + 1, tail_source), last_code do
    rows[#rows + 1] = code_row(source[source_row])
  end
  rows[#rows + 1] = code_border("```")
  return {
    kind = "fence",
    marker = marker,
    language = language,
    source_first = first,
    source_last = source_last,
    output_first = output_first,
    output_last = #rows,
    tail_source = tail_source,
    tail_output_first = tail_output_first,
    open = open,
  }, open and #source + 1 or close + 1
end

parse_blocks = function(source, first, opts, blocks, rows, previous)
  local index = first
  while index <= #source do
    local line = source[index]
    local marker, language = fence(line)
    if marker then
      local block, next_index = render_fence(
        source, index, marker, language, rows)
      blocks[#blocks + 1] = block
      index = next_index
    elseif index < #source and line:find("|", 1, true)
        and table_separator(source[index + 1]) then
      local output_first = #rows + 1
      local rendered, last = render_table(source, index, opts.width)
      if rendered then
        append_rows(rows, rendered)
        blocks[#blocks + 1] = {
          kind = "table",
          source_first = index,
          source_last = last,
          output_first = output_first,
          output_last = #rows,
          depends_on_next = true,
        }
        index = last + 1
      else
        local value, syntax, inline = render_line(line, opts, previous)
        rows[#rows + 1] = value
        blocks[#blocks + 1] = {
          kind = "line",
          syntax = syntax,
          inline = inline,
          source_first = index,
          source_last = index,
          output_first = output_first,
          output_last = #rows,
          depends_on_next = line:find("|", 1, true) ~= nil,
        }
        index = index + 1
      end
    else
      local output_first = #rows + 1
      local prior = previous and index == first and previous or nil
      local value, syntax, inline = render_line(line, opts, prior)
      rows[#rows + 1] = value
      blocks[#blocks + 1] = {
        kind = "line",
        syntax = syntax,
        inline = inline,
        source_first = index,
        source_last = index,
        output_first = output_first,
        output_last = #rows,
        depends_on_next = line:find("|", 1, true) ~= nil,
      }
      index = index + 1
    end
  end
end

local function split_append(lines, value)
  local parts = vim.split(value, "\n", { plain = true })
  lines[#lines] = lines[#lines] .. parts[1]
  for index = 2, #parts do lines[#lines + 1] = parts[index] end
end

local function truncate(values, last)
  for index = #values, last + 1, -1 do values[index] = nil end
end

local function extend_fence(document, block_index)
  local previous = document.blocks[block_index]
  local blocks, rows = document.blocks, document.rows
  truncate(blocks, block_index - 1)
  truncate(rows, previous.tail_output_first - 1)
  local source, marker = document.source_lines, previous.marker
  local close = previous.tail_source
  while close <= #source and not closing_fence(source[close], marker) do
    close = close + 1
  end
  local open = close > #source
  local source_last = open and #source or close
  local tail_source = open and math.max(previous.source_first + 1, #source)
    or close
  local last_code = open and #source or close - 1
  if open and last_code >= previous.source_first + 1
      and partial_fence(source[last_code], marker) then
    last_code = last_code - 1
  end
  for source_row = previous.tail_source, math.min(last_code, tail_source - 1) do
    rows[#rows + 1] = code_row(source[source_row])
  end
  local tail_output_first = #rows + 1
  for source_row = math.max(previous.tail_source, tail_source), last_code do
    rows[#rows + 1] = code_row(source[source_row])
  end
  rows[#rows + 1] = code_border("```")
  blocks[#blocks + 1] = {
    kind = "fence",
    marker = marker,
    language = previous.language,
    source_first = previous.source_first,
    source_last = source_last,
    output_first = previous.output_first,
    output_last = #rows,
    tail_source = tail_source,
    tail_output_first = tail_output_first,
    open = open,
  }
  if not open then
    parse_blocks(source, close + 1, document.options, blocks, rows)
  end
  return previous.tail_output_first
end

local semantic_kinds = {
  plain = "paragraph",
  heading = "heading",
  quote = "quote",
  list = "list",
  rule = "thematic_break",
  blank = "blank",
}

local mergeable_blocks = {
  blank = true,
  list = true,
  paragraph = true,
  quote = true,
}

local function block_splittable(block)
  if block.kind == "fence" then return true end
  if block.kind ~= "line" then return false end
  return mergeable_blocks[semantic_kinds[block.syntax]] == true
end

local function semantic_block(block)
  local kind = block.kind == "line" and semantic_kinds[block.syntax]
    or block.kind
  return {
    kind = kind,
    first = block.output_first - 1,
    last = block.output_last,
    splittable = block_splittable(block),
  }
end

local function semantic_blocks(blocks, first, last)
  local result = {}
  first, last = first or 1, last or math.huge
  for _, source in ipairs(blocks) do
    local block = semantic_block(source)
    local block_first = math.max(first - 1, block.first)
    local block_last = math.min(last, block.last)
    if block_last > block_first then
      block.first = block_first - (first - 1)
      block.last = block_last - (first - 1)
      local previous = result[#result]
      if mergeable_blocks[block.kind] and previous
          and previous.kind == block.kind
          and previous.last == block.first then
        previous.last = block.last
      else
        result[#result + 1] = block
      end
    end
  end
  return result
end

local function content_slice(rows, blocks, first, last)
  local lines, highlights = {}, {}
  first = math.max(1, first or 1)
  last = math.min(#rows, last or #rows)
  for source_index = first, last do
    local value = rows[source_index]
    local target_index = source_index - first + 1
    lines[target_index] = value.text
    for _, span in ipairs(value.spans) do
      highlights[#highlights + 1] = {
        row = target_index - 1,
        col = span.col,
        end_col = span.end_col,
        group = span.group,
      }
    end
  end
  return {
    lines = lines,
    highlights = highlights,
    markdown_blocks = semantic_blocks(blocks, first, last),
  }
end

local function count_words(value)
  return select(2, (value or ""):gsub("%S+", ""))
end

local function region_rows(rows, first, last)
  local result = {}
  for index = first, last do result[#result + 1] = rows[index] end
  return result
end

function Document.new()
  return setmetatable({
    raw = "",
    source_lines = { "" },
    options = options(),
    blocks = {},
    rows = {},
    nonblank = false,
    words = 0,
    region_caches = {},
    next_region_revision = 0,
  }, Document)
end

function Document:_rebuild(raw, source, opts, append_epoch)
  self.raw, self.append_epoch = raw, append_epoch
  self.source_lines, self.options = source, opts
  self.nonblank = trim(raw) ~= ""
  self.words = count_words(raw)
  self.blocks, self.rows = {}, {}
  self.region_caches = {}
  if self.nonblank then
    parse_blocks(source, 1, opts, self.blocks, self.rows)
  end
  return self
end

function Document:update(value, raw_opts, append_epoch)
  value = value or ""
  local opts = options(raw_opts)
  if value == self.raw and same_options(opts, self.options) then
    self.append_epoch = append_epoch
    return self
  end

  local appended = same_options(opts, self.options)
    and #value >= #self.raw and (
      append_epoch ~= nil and append_epoch == self.append_epoch
      or append_epoch == nil and self.append_epoch == nil
        and value:find(self.raw, 1, true) == 1)
  if not appended then
    local normalized = value:gsub("\t", "   ")
    return self:_rebuild(value,
      vim.split(normalized, "\n", { plain = true }), opts, append_epoch)
  end

  local delta = value:sub(#self.raw + 1)
  local normalized_delta = delta:gsub("\t", "   ")
  local joined_word = self.raw:sub(-1):match("%S") ~= nil
    and delta:sub(1, 1):match("%S") ~= nil
  self.words = self.words + count_words(delta) - (joined_word and 1 or 0)
  self.raw, self.append_epoch = value, append_epoch
  split_append(self.source_lines, normalized_delta)
  local nonblank = self.nonblank or normalized_delta:find("%S") ~= nil
  if not nonblank then
    return self
  end
  if not self.nonblank or #self.blocks == 0 then
    return self:_rebuild(value, self.source_lines, opts, append_epoch)
  end

  self.nonblank = true
  local last_index = #self.blocks
  local last = self.blocks[last_index]
  local opener_stable = last.kind == "fence"
    and last.source_last > last.source_first
  local changed_output
  if opener_stable then
    changed_output = extend_fence(self, last_index)
  else
    local start_index = last_index
    if last.kind == "line" and last_index > 1
        and self.blocks[last_index - 1].depends_on_next
        and self.blocks[last_index - 1].source_last + 1
          == last.source_first then
      start_index = last_index - 1
    end
    local changed = self.blocks[start_index]
    local blocks, rows = self.blocks, self.rows
    truncate(blocks, start_index - 1)
    truncate(rows, changed.output_first - 1)
    parse_blocks(self.source_lines, changed.source_first, opts,
      blocks, rows, start_index == last_index and changed or nil)
    changed_output = changed.output_first
  end
  for _, cache in pairs(self.region_caches) do
    cache.dirty_first = math.min(
      cache.dirty_first or changed_output, changed_output)
  end
  return self
end

function Document:snapshot()
  return content_slice(self.rows, self.blocks)
end

function Document:slice(first, last)
  return content_slice(self.rows, self.blocks, first, last)
end

function Document:finish()
  local finish = #self.rows
  while finish > 0 and self.rows[finish].text == "" do finish = finish - 1 end
  return finish
end

function Document:tail(maximum)
  assert(type(maximum) == "number" and maximum >= 1
    and maximum % 1 == 0, "maximum must be a positive integer")
  local finish = self:finish()
  local first = math.max(1, finish - maximum + 1)
  return self:slice(first, finish), first - 1
end

function Document:word_count()
  return self.words
end

function Document:regions(target)
  assert(type(target) == "number" and target >= 1 and target % 1 == 0,
    "target must be a positive integer")
  local cache = self.region_caches[target]
  if not cache then
    cache = { regions = {}, dirty_first = 1 }
    self.region_caches[target] = cache
  elseif not cache.dirty_first then
    return cache.regions
  end

  local regions = cache.regions
  local start_row, start_block = 1, 1
  if #regions > 0 then
    local invalid
    for index, region in ipairs(regions) do
      if region.last >= cache.dirty_first then
        invalid = index
        break
      end
    end
    invalid = invalid or #regions
    local region = regions[invalid]
    start_row, start_block = region.first, region.start_block
    truncate(regions, invalid - 1)
  end

  local pending_first, pending_last, pending_block
  local function emit(first, last, block_index)
    if last < first then return end
    self.next_region_revision = self.next_region_revision + 1
    regions[#regions + 1] = {
      first = first,
      last = last,
      start_block = block_index,
      revision = self.next_region_revision,
      rows = region_rows(self.rows, first, last),
    }
  end
  local function emit_pending()
    if pending_first then
      emit(pending_first, pending_last, pending_block)
    end
    pending_first, pending_last, pending_block = nil, nil, nil
  end

  for block_index = start_block, #self.blocks do
    local block = self.blocks[block_index]
    local first = math.max(start_row, block.output_first)
    local last = block.output_last
    if last >= first then
      local size = last - first + 1
      if block_splittable(block) and size > target then
        emit_pending()
        while last - first + 1 > target do
          emit(first, first + target - 1, block_index)
          first = first + target
        end
        if first <= last then
          pending_first, pending_last = first, last
          pending_block = block_index
        end
      elseif size > target then
        emit_pending()
        emit(first, last, block_index)
      else
        if pending_first and pending_last - pending_first + 1 + size > target then
          emit_pending()
        end
        pending_first = pending_first or first
        pending_block = pending_block or block_index
        pending_last = last
        if pending_last - pending_first + 1 == target then
          emit_pending()
        end
      end
    end
  end
  emit_pending()
  cache.dirty_first = nil
  return regions
end

function M.new()
  return Document.new()
end

function M.render(value, opts)
  return Document.new():update(value, opts):snapshot()
end

return M
