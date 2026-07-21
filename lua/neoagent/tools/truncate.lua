local M = {
  MAX_LINES = 2000,
  MAX_BYTES = 50 * 1024,
  GREP_LINE_LENGTH = 500,
}

local function lines(content)
  if content == "" then
    return {}
  end
  local result = vim.split(content, "\n", { plain = true })
  if content:sub(-1) == "\n" then
    table.remove(result)
  end
  return result
end

local function metadata(content, output, truncated, by, opts)
  return {
    content = output,
    truncated = truncated,
    truncatedBy = by,
    totalLines = #lines(content),
    totalBytes = #content,
    outputLines = #lines(output),
    outputBytes = #output,
    maxLines = opts.max_lines,
    maxBytes = opts.max_bytes,
    firstLineExceedsLimit = false,
    lastLinePartial = false,
  }
end

function M.head(content, options)
  options = options or {}
  local opts = {
    max_lines = options.max_lines or M.MAX_LINES,
    max_bytes = options.max_bytes or M.MAX_BYTES,
  }
  local all = lines(content)
  if #all <= opts.max_lines and #content <= opts.max_bytes then
    return metadata(content, content, false, nil, opts)
  end
  if #(all[1] or "") > opts.max_bytes then
    local result = metadata(content, "", true, "bytes", opts)
    result.firstLineExceedsLimit = true
    return result
  end
  local selected = {}
  local bytes = 0
  local by = "lines"
  for index, line in ipairs(all) do
    if index > opts.max_lines then
      by = "lines"
      break
    end
    local extra = #line + (#selected > 0 and 1 or 0)
    if bytes + extra > opts.max_bytes then
      by = "bytes"
      break
    end
    selected[#selected + 1] = line
    bytes = bytes + extra
  end
  return metadata(content, table.concat(selected, "\n"), true, by, opts)
end

local function utf8_tail(value, bytes)
  local start = math.max(1, #value - bytes + 1)
  while start <= #value and value:byte(start) >= 128 and value:byte(start) < 192 do
    start = start + 1
  end
  return value:sub(start)
end

function M.tail(content, options)
  options = options or {}
  local opts = {
    max_lines = options.max_lines or M.MAX_LINES,
    max_bytes = options.max_bytes or M.MAX_BYTES,
  }
  local all = lines(content)
  if #all <= opts.max_lines and #content <= opts.max_bytes then
    return metadata(content, content, false, nil, opts)
  end
  local selected = {}
  local bytes = 0
  local by = "lines"
  local partial = false
  for index = #all, 1, -1 do
    if #selected >= opts.max_lines then
      by = "lines"
      break
    end
    local extra = #all[index] + (#selected > 0 and 1 or 0)
    if bytes + extra > opts.max_bytes then
      by = "bytes"
      if #selected == 0 then
        selected[1] = utf8_tail(all[index], opts.max_bytes)
        partial = true
      end
      break
    end
    table.insert(selected, 1, all[index])
    bytes = bytes + extra
  end
  local result = metadata(content, table.concat(selected, "\n"), true, by, opts)
  result.lastLinePartial = partial
  return result
end

function M.line(value, max_chars)
  max_chars = max_chars or M.GREP_LINE_LENGTH
  if vim.fn.strchars(value) <= max_chars then
    return value, false
  end
  return vim.fn.strcharpart(value, 0, max_chars) .. "... [truncated]", true
end

function M.format_size(bytes)
  if bytes < 1024 then
    return bytes .. "B"
  elseif bytes < 1024 * 1024 then
    return string.format("%.1fKB", bytes / 1024)
  end
  return string.format("%.1fMB", bytes / (1024 * 1024))
end

return M
