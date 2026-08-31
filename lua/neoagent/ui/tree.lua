local Applet = require("applet")
local util = require("neoagent.util")
local ui = Applet.Pane.nodes
local text = Applet.Pane.text

local M = {}

local function suffix_to_width(text, width)
  return Applet.Pane.text.truncate(text, width, { marker = "", side = "left" })
end

local function fit_badge(header, width)
  local available = math.max(1, width - 1)
  if text.width(header) <= available then return header end
  if available <= 3 then return suffix_to_width(header, available) end
  return "..." .. suffix_to_width(header, available - 3)
end

local function focus_decorations(block, opts)
  local result = {}
  local card = opts.card
  if not card then return result end
  local first, last = card.first, card.last
  local focus = opts.focus or {}
  local width = math.max(2, opts.width)

  local function add(row, text, win_col, group)
    local decoration = {
      row = row,
      chunks = { { text = text, group = group or "NeoagentCardFocus" } },
      win_col = win_col,
      priority = 200,
    }
    if win_col == nil then decoration.position = "overlay" end
    result[#result + 1] = decoration
  end
  local function line(row)
    return opts.lines[row + 1] or ""
  end
  local function overflow_badge(row, header)
    header = fit_badge(header, width)
    local start = math.max(0,
      width - 1 - text.width(header))
    local chunks = {}
    if start >= 3 then
      chunks[#chunks + 1] = { text = "...", group = "NeoagentMuted" }
    end
    chunks[#chunks + 1] = { text = header, group = "NeoagentMuted" }
    result[#result + 1] = {
      row = row,
      chunks = chunks,
      win_col = start - (start >= 3 and 3 or 0),
      priority = 200,
    }
  end

  if not opts.active then
    if block.kind == "thinking" and focus.overflow
        and focus.resting_header then
      overflow_badge(first, focus.resting_header)
    end
    return result
  end

  local function horizontal(row, left, right)
    local gap = math.min(text.width(line(row)), width - 1)
    if gap <= 0 then
      add(row, left .. string.rep("─", width - 2) .. right)
    else
      add(row, left)
      add(row, string.rep("─", width - gap - 1) .. right, gap)
    end
  end
  local function bottom(row)
    if opts.attachments then
      add("end", "╰" .. string.rep("─", width - 2) .. "╯")
    elseif text.width(line(row)) > width then
      horizontal(row + 1, "╰", "╯")
    else
      horizontal(row, "╰", "╯")
    end
  end
  local function badge(row, header)
    header = fit_badge(header, width)
    local start = math.max(0,
      width - 1 - text.width(header))
    local line_width = text.width(line(row))
    add(row, "╭")
    if line_width <= start then
      local fill = start - line_width
      if fill > 0 then add(row, string.rep("─", fill), line_width) end
    elseif start >= 3 then
      add(row, "...", start - 3)
    end
    result[#result + 1] = {
      row = row,
      chunks = { { text = header, group = "NeoagentMuted" } },
      win_col = start,
      priority = 200,
    }
  end
  local function inline_tool_badge(row, header)
    header = fit_badge(header, width)
    local start = math.max(0,
      width - 1 - text.width(header))
    if text.width(line(row)) > start and start >= 4 then
      add(row, " ...", start - 4, "NeoagentMuted")
    end
    result[#result + 1] = {
      row = row,
      chunks = { { text = header, group = "NeoagentMuted" } },
      win_col = start,
      priority = 200,
    }
  end
  local function inline_tool_top(row)
    local start = math.min(
      text.width(line(row)), width - 1)
    add(row, string.rep("─", width - start - 1) .. "╮", start)
  end
  local function assistant_top(row)
    local line_width = text.width(line(row))
    add(row, "╭")
    if line_width <= width - 1 then
      add(row, string.rep("─", width - line_width - 1) .. "╮",
        line_width)
    end
  end
  local function hinted_bottom()
    local value = "╰" .. string.rep("─", width - 2) .. "╯"
    if opts.details_key then
      local hint = " " .. opts.details_key .. " to expand "
      local remaining = width - 2 - text.width(hint)
      if remaining >= 2 then
        local left = math.floor(remaining / 2)
        value = "╰" .. string.rep("─", left) .. hint
          .. string.rep("─", remaining - left) .. "╯"
      end
    end
    return value
  end
  local function thinking_badge()
    return string.format("[thinking: 0 words%s]",
      opts.details_key and ", " .. opts.details_key .. " to expand" or "")
  end

  if block.kind == "thinking" then
    badge(first, focus.header or thinking_badge())
    if last > first then bottom(last) end
  elseif block.kind == "assistant" then
    assistant_top(first)
    local after = opts.separators and opts.separators.after or card.after
    if after then add(opts.attachments and "end" or after, hinted_bottom()) end
  elseif block.kind == "tool" and (last > first or opts.attachments)
      and focus.inline_multiline_tool_outline then
    inline_tool_top(first)
    local after = opts.separators and opts.separators.after or card.after
    if after then add(opts.attachments and "end" or after, hinted_bottom()) end
  elseif block.kind == "tool" and first == last
      and focus.inline_single_line_tool_hint then
    if opts.details_key and text.width(line(first)) <= width then
      inline_tool_badge(first, "[" .. opts.details_key .. " to expand]")
    end
  else
    add(first, "╭" .. string.rep("─", width - 2) .. "╮")
    add(opts.attachments and "end" or last,
      block.kind == "tool" and hinted_bottom()
      or "╰" .. string.rep("─", width - 2) .. "╯")
  end
  return result
end

function M.focus(block, content, opts)
  if not content.card then return nil end
  opts = vim.tbl_extend("force", opts or {}, {
    lines = content.lines,
    card = content.card,
    separators = content.separators,
  })
  local result = { active = {}, inactive = {} }
  for _, state in ipairs({ "active", "inactive" }) do
    opts.active = state == "active"
    for _, decoration in ipairs(focus_decorations(block, opts)) do
      local shifted = util.copy(decoration)
      if shifted.row == "end" then
        result[state][#result[state] + 1] = shifted
      else
        shifted.row = shifted.row - content.card.first
        if shifted.row >= 0
            and shifted.row <= content.card.last - content.card.first + 1 then
          result[state][#result[state] + 1] = shifted
        end
      end
    end
  end
  return result
end

local function line_runs(line, spans)
  local boundaries = { 0, #line }
  for _, span in ipairs(spans or {}) do
    if span.end_col > span.col and span.col < #line then
      boundaries[#boundaries + 1] = math.max(0, span.col)
      boundaries[#boundaries + 1] = math.min(#line, span.end_col)
    end
  end
  table.sort(boundaries)
  local unique = {}
  for _, boundary in ipairs(boundaries) do
    if unique[#unique] ~= boundary then unique[#unique + 1] = boundary end
  end
  local runs = {}
  for index = 1, #unique - 1 do
    local first, last = unique[index], unique[index + 1]
    if last > first then
      local groups = {}
      for _, span in ipairs(spans or {}) do
        if span.col <= first and span.end_col >= last
            and span.group then
          groups[#groups + 1] = {
            group = span.group,
            priority = span.priority,
          }
        end
      end
      local text = line:sub(first + 1, last)
      runs[#runs + 1] = #groups > 0
        and { text = text, groups = groups } or { text = text }
    end
  end
  if #runs == 0 then runs[1] = { text = "" } end
  return runs
end

local function line_node(key, content, row, wrap, spans_by_row)
  local spans = spans_by_row[row] or {}
  local value = content.lines[row + 1] or ""
  local options = {
    key = key .. ":line:" .. row,
    runs = line_runs(value, spans),
    wrap = wrap or "native",
    background = content.line_groups and content.line_groups[row] or nil,
  }
  if value:find("\t", 1, true) then options.tabstop = 8 end
  return ui.text(options)
end

local function lines_node(key, content, first, last, wrap, spans_by_row)
  local children = {}
  local source = content.source
  local row = first
  while row < last do
    if source and source.path and row == source.first
        and source.last < last then
      local source_children = {}
      for source_row = row, source.last do
        source_children[#source_children + 1] = line_node(
          key .. ":source", content, source_row, wrap, spans_by_row)
      end
      children[#children + 1] = ui.source({
        key = key .. ":source:" .. row,
        path = source.path,
        child = ui.column({
          key = key .. ":source:" .. row .. ":lines",
          children = source_children,
        }),
      })
      row = source.last + 1
    else
      children[#children + 1] = line_node(
        key, content, row, wrap, spans_by_row)
      row = row + 1
    end
  end
  return ui.column({ key = key .. ":lines:" .. first, children = children })
end

local function markdown_ranges(content, target)
  local blocks = content.markdown_blocks
  if type(blocks) ~= "table" or #blocks == 0 then return nil end
  if type(target) ~= "number" or target < 1 or target % 1 ~= 0 then
    error("partition_rows must be a positive integer", 0)
  end
  local ranges = {}
  local covered = 0
  local pending_first, pending_last
  local function emit(first, last)
    if last <= first then return end
    ranges[#ranges + 1] = { first = first, last = last }
  end
  local function emit_pending()
    if pending_first then emit(pending_first, pending_last) end
    pending_first, pending_last = nil, nil
  end
  for _, block in ipairs(blocks) do
    if type(block) ~= "table" or type(block.first) ~= "number"
        or type(block.last) ~= "number" or block.first % 1 ~= 0
        or block.last % 1 ~= 0 or block.first ~= covered
        or block.last <= block.first or block.last > #content.lines then
      error("Markdown block ranges must cover rendered lines in order", 0)
    end
    covered = block.last
    local size = block.last - block.first
    if block.splittable == true and size > target then
      emit_pending()
      local first = block.first
      while block.last - first > target do
        emit(first, first + target)
        first = first + target
      end
      if first < block.last then
        pending_first, pending_last = first, block.last
      end
    elseif size > target then
      emit_pending()
      emit(block.first, block.last)
    else
      if pending_first and pending_last - pending_first + size > target then
        emit_pending()
      end
      pending_first = pending_first or block.first
      pending_last = block.last
      if pending_last - pending_first == target then emit_pending() end
    end
  end
  if covered ~= #content.lines then
    error("Markdown block ranges must cover rendered lines in order", 0)
  end
  emit_pending()
  return ranges
end

local function revision_field(parts, value)
  if value == nil then
    parts[#parts + 1] = "-"
    return
  end
  local encoded = tostring(value)
  parts[#parts + 1] = type(value) .. ":" .. #encoded .. ":" .. encoded
end

local function range_revision(content, range, wrap, spans_by_row)
  local parts = {}
  revision_field(parts, wrap or "native")
  for row = range.first, range.last - 1 do
    revision_field(parts, content.lines[row + 1])
    revision_field(parts, content.line_groups[row])
    local spans = spans_by_row[row] or {}
    revision_field(parts, #spans)
    for _, span in ipairs(spans) do
      revision_field(parts, span.col)
      revision_field(parts, span.end_col)
      revision_field(parts, span.group)
      revision_field(parts, span.priority)
    end
  end
  return table.concat(parts, "\0")
end

local function partitioned_markdown_node(
    key, content, opts, spans_by_row, has_attachments)
  if opts.partition_rows == nil or content.card or content.source
      or has_attachments then
    return nil
  end
  local ranges = markdown_ranges(content, opts.partition_rows)
  if not ranges then return nil end
  local regions = {}
  for index, range in ipairs(ranges) do
    regions[index] = ui.region({
      key = key .. ":region:" .. index,
      revision = range_revision(content, range, opts.wrap, spans_by_row),
      child = lines_node(key .. ":region:" .. index, content,
        range.first, range.last, opts.wrap, spans_by_row),
    })
  end
  return ui.column({ key = key .. ":regions", children = regions })
end

local function retained_signature(opts)
  local parts = { opts.wrap or "native", opts.line_group or "" }
  for _, group in ipairs(opts.groups or {}) do
    parts[#parts + 1] = tostring(#group) .. ":" .. group
  end
  return table.concat(parts, "\0")
end

function M.retained_markdown(key, view, opts, retained)
  opts = opts or {}
  local target = opts.partition_rows
  if type(target) ~= "number" or target < 1 or target % 1 ~= 0 then
    error("partition_rows must be a positive integer", 0)
  end
  local document = assert(view.markdown_document,
    "retained Markdown content requires a document")
  local first = math.max(1, view.markdown_first or 1)
  local last = math.min(document:finish(),
    view.markdown_last or document:finish())
  local attachments = opts.attachments
  if type(attachments) == "table" and #attachments > 0 then
    local content = document:slice(first, last)
    content.line_groups = {}
    for row, line in ipairs(content.lines) do
      if line ~= "" then
        for _, group in ipairs(view.markdown_groups or {}) do
          content.highlights[#content.highlights + 1] = {
            row = row - 1,
            col = 0,
            end_col = #line,
            group = group,
          }
        end
      end
      if opts.line_group then
        content.line_groups[row - 1] = opts.line_group
      end
    end
    return M.content(key, content, {
      wrap = opts.wrap,
      attachments = attachments,
    }), {}
  end
  local signature = retained_signature({
    wrap = opts.wrap,
    line_group = opts.line_group,
    groups = view.markdown_groups,
  })
  local previous = type(retained) == "table" and retained or {}
  local next_retained, children = {}, {}
  for index, region in ipairs(document:regions(target)) do
    local region_first = math.max(first, region.first)
    local region_last = math.min(last, region.last)
    if region_last >= region_first then
      local cached = previous[index]
      if cached and cached.region == region
          and cached.signature == signature
          and cached.first == region_first
          and cached.last == region_last then
        next_retained[index] = cached
        children[#children + 1] = cached.node
      else
        local content = { lines = {}, highlights = {}, line_groups = {} }
        for source_row = region_first, region_last do
          local row = region.rows[source_row - region.first + 1]
          local target_row = #content.lines
          content.lines[#content.lines + 1] = row.text
          for _, span in ipairs(row.spans or {}) do
            content.highlights[#content.highlights + 1] = {
              row = target_row,
              col = span.col,
              end_col = span.end_col,
              group = span.group,
              priority = span.priority,
            }
          end
          if row.text ~= "" then
            for _, group in ipairs(view.markdown_groups or {}) do
              content.highlights[#content.highlights + 1] = {
                row = target_row,
                col = 0,
                end_col = #row.text,
                group = group,
              }
            end
          end
          if opts.line_group then
            content.line_groups[target_row] = opts.line_group
          end
        end
        local node = ui.region({
          key = key .. ":region:" .. index,
          revision = tostring(region.revision) .. "\0" .. signature,
          child = M.content(key .. ":region:" .. index, content, {
            wrap = opts.wrap,
          }),
        })
        local entry = {
          region = region,
          signature = signature,
          first = region_first,
          last = region_last,
          node = node,
        }
        next_retained[index] = entry
        children[#children + 1] = node
      end
    end
  end
  return ui.column({ key = key .. ":regions", children = children }),
    next_retained
end

function M.content(key, content, opts)
  opts = opts or {}
  local submitted = content or {}
  content = {
    lines = submitted.lines or {},
    highlights = submitted.highlights or {},
    line_groups = submitted.line_groups or {},
    card = submitted.card,
    source = submitted.source,
    markdown_blocks = submitted.markdown_blocks,
  }
  local spans_by_row = {}
  for _, span in ipairs(content.highlights) do
    local spans = spans_by_row[span.row]
    if not spans then spans = {} spans_by_row[span.row] = spans end
    spans[#spans + 1] = span
  end
  local card = content.card
  local attachments = opts.attachments
  local has_attachments = type(attachments) == "table" and #attachments > 0
  local partitioned = partitioned_markdown_node(
    key, content, opts, spans_by_row, has_attachments)
  if partitioned then return partitioned end
  if not card or card.last < card.first then
    local body = lines_node(
      key, content, 0, #content.lines, opts.wrap, spans_by_row)
    if not has_attachments then return body end
    local children = { body }
    vim.list_extend(children, attachments)
    return ui.column({
      key = key .. ":with-attachments",
      gap = 1,
      children = children,
    })
  end
  local children = {}
  if card.first > 0 then
    children[#children + 1] = lines_node(
      key .. ":before", content, 0, card.first, opts.wrap, spans_by_row)
  end
  local body = lines_node(
    key .. ":card", content, card.first, card.last + 1, opts.wrap,
    spans_by_row)
  if has_attachments then
    local target_children = { body }
    vim.list_extend(target_children, attachments)
    body = ui.column({
      key = key .. ":with-attachments",
      gap = 1,
      children = target_children,
    })
  end
  children[#children + 1] = ui.target({
    key = opts.target_key or key .. ":target",
    group = opts.group or "transcript.cards",
    role = "document",
    action = opts.action,
    focus_style = opts.focus == nil and (opts.focus_style or "selected") or nil,
    focus = opts.focus,
    child = body,
  })
  if card.last + 1 < #content.lines then
    children[#children + 1] = lines_node(
      key .. ":after", content, card.last + 1, #content.lines,
      opts.wrap, spans_by_row)
  end
  return ui.column({ key = key .. ":content", children = children })
end

function M.theme(highlights)
  return Applet.Theme.new({
    name = "NeoagentAnsi",
    groups = {
      accent = "NeoagentAccent",
      error = "NeoagentError",
      muted = "NeoagentMuted",
      menu_selected = "PmenuSel",
      selected = "NeoagentCardFocus",
      strong = "NeoagentMarkdownBold",
      window_title = "NeoagentWindowTitle",
      dialog_action = "NeoagentDialogAction",
      dialog_background = "NeoagentDialogBackground",
      dialog_title = "NeoagentDialogTitle",
    },
    highlights = highlights,
    max_derived_highlights = 256,
  })
end

return M
