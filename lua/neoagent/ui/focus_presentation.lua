local M = {}

local function suffix_to_width(text, width)
  local characters = vim.fn.strchars(text)
  local low, high = 0, characters
  while low < high do
    local count = math.floor((low + high + 1) / 2)
    local candidate = vim.fn.strcharpart(
      text, characters - count, count)
    if vim.fn.strdisplaywidth(candidate) <= width then
      low = count
    else
      high = count - 1
    end
  end
  return vim.fn.strcharpart(text, characters - low, low)
end

local function fit_badge(header, width)
  local available = math.max(1, width - 1)
  if vim.fn.strdisplaywidth(header) <= available then return header end
  if available <= 3 then return suffix_to_width(header, available) end
  return "..." .. suffix_to_width(header, available - 3)
end

local function add(result, row, text, win_col, group)
  result[#result + 1] = {
    row = row,
    chunks = { { text = text, group = group or "NeoagentCardFocus" } },
    position = win_col and nil or "overlay",
    win_col = win_col,
    priority = 200,
  }
end

local function line(opts, row)
  return opts.lines[row + 1] or ""
end

local function overflow_badge(result, row, header, width)
  header = fit_badge(header, width)
  local start = math.max(0, width - 1 - vim.fn.strdisplaywidth(header))
  local chunks = {}
  if start >= 3 then
    chunks[#chunks + 1] = { text = "...", group = "NeoagentMuted" }
  end
  chunks[#chunks + 1] = { text = header, group = "NeoagentMuted" }
  result[#result + 1] = {
    row = row,
    chunks = chunks,
    position = "overlay",
    win_col = start - (start >= 3 and 3 or 0),
    priority = 200,
  }
end

function M.render(block, opts)
  local result = {}
  local card = opts.card
  if not card then return result end
  local first, last = card.first, card.last
  local focus = opts.focus or {}
  local width = math.max(2, opts.width)
  if not opts.active then
    if block.kind == "thinking" and focus.overflow
        and focus.resting_header then
      overflow_badge(result, first, focus.resting_header, width)
    end
    return result
  end

  local function horizontal(row, left, right)
    local gap = math.min(vim.fn.strdisplaywidth(line(opts, row)), width - 1)
    if gap <= 0 then
      add(result, row, left .. string.rep("─", width - 2) .. right)
    else
      add(result, row, left)
      add(result, row, string.rep("─", width - gap - 1) .. right, gap)
    end
  end
  local function bottom(row)
    if vim.fn.strdisplaywidth(line(opts, row)) > width then
      horizontal(row + 1, "╰", "╯")
    else
      horizontal(row, "╰", "╯")
    end
  end
  local function badge(row, header)
    header = fit_badge(header, width)
    local start = math.max(0, width - 1 - vim.fn.strdisplaywidth(header))
    local line_width = vim.fn.strdisplaywidth(line(opts, row))
    add(result, row, "╭")
    if line_width <= start then
      local fill = start - line_width
      if fill > 0 then add(result, row, string.rep("─", fill), line_width) end
    elseif start >= 3 then
      add(result, row, "...", start - 3)
    end
    result[#result + 1] = {
      row = row,
      chunks = { { text = header, group = "NeoagentMuted" } },
      position = "overlay",
      win_col = start,
      priority = 200,
    }
  end
  local function inline_tool_badge(row, header)
    header = fit_badge(header, width)
    local start = math.max(0, width - 1 - vim.fn.strdisplaywidth(header))
    if vim.fn.strdisplaywidth(line(opts, row)) > start and start >= 4 then
      add(result, row, " ...", start - 4, "NeoagentMuted")
    end
    result[#result + 1] = {
      row = row,
      chunks = { { text = header, group = "NeoagentMuted" } },
      position = "overlay",
      win_col = start,
      priority = 200,
    }
  end
  local function inline_tool_top(row)
    local start = math.min(
      vim.fn.strdisplaywidth(line(opts, row)), width - 1)
    add(result, row, string.rep("─", width - start - 1) .. "╮", start)
  end
  local function tool_bottom()
    local value = "╰" .. string.rep("─", width - 2) .. "╯"
    local key = opts.details_key
    if key then
      local hint = " " .. key .. " to expand "
      local remaining = width - 2 - vim.fn.strdisplaywidth(hint)
      if remaining >= 2 then
        local left = math.floor(remaining / 2)
        value = "╰" .. string.rep("─", left) .. hint
          .. string.rep("─", remaining - left) .. "╯"
      end
    end
    return value
  end
  local function response_badge(kind)
    local hint = opts.details_key
    return string.format("[%s: 0 words%s]", kind,
      hint and ", " .. hint .. " to expand" or "")
  end

  if block.kind == "thinking" then
    badge(first, focus.header or response_badge("thinking"))
    if last > first then bottom(last) end
  elseif block.kind == "assistant" then
    badge(first, focus.header or response_badge("text"))
    if last > first then bottom(last) end
  elseif block.kind == "tool" and last > first
      and focus.inline_multiline_tool_outline then
    inline_tool_top(first)
    local after = opts.separators and opts.separators.after or card.after
    if after then add(result, after, tool_bottom()) end
  elseif block.kind == "tool" and first == last
      and focus.inline_single_line_tool_hint then
    local key = opts.details_key
    if key and vim.fn.strdisplaywidth(line(opts, first)) <= width then
      inline_tool_badge(first, "[" .. key .. " to expand]")
    end
  else
    add(result, first, "╭" .. string.rep("─", width - 2) .. "╮")
    add(result, last, block.kind == "tool" and tool_bottom()
      or "╰" .. string.rep("─", width - 2) .. "╯")
  end
  return result
end

return M
