local M = {}

function M.apply_marks(view, buffer, presentation, offset)
  offset = offset or 0
  for row, group in pairs(presentation.line_groups or {}) do
    vim.api.nvim_buf_set_extmark(buffer, view.namespace, offset + row, 0, {
      line_hl_group = group,
      priority = 50,
    })
  end
  for _, span in ipairs(presentation.highlights or {}) do
    vim.api.nvim_buf_set_extmark(
      buffer, view.namespace, offset + span.row, span.col, {
        end_row = offset + span.row,
        end_col = span.end_col,
        hl_group = span.group,
        priority = span.priority or 100,
      })
  end
end

local function virtual_line(presentation, row, default_group)
  local line = presentation.lines[row + 1]
  local boundaries = { 0, #line }
  local spans = {}
  for _, span in ipairs(presentation.highlights or {}) do
    if span.row == row and span.end_col > span.col then
      spans[#spans + 1] = span
      boundaries[#boundaries + 1] = span.col
      boundaries[#boundaries + 1] = span.end_col
    end
  end
  table.sort(boundaries)
  local unique = {}
  for _, boundary in ipairs(boundaries) do
    if unique[#unique] ~= boundary then unique[#unique + 1] = boundary end
  end
  local chunks = {}
  local base = presentation.line_groups[row] or default_group or "NormalFloat"
  for index = 1, #unique - 1 do
    local first, last = unique[index], unique[index + 1]
    if last > first then
      local group, priority = base, 0
      for _, span in ipairs(spans) do
        local candidate = span.priority or 100
        if span.col <= first and span.end_col >= last
            and candidate >= priority then
          group, priority = span.group, candidate
        end
      end
      local text = line:sub(first + 1, last)
      if chunks[#chunks] and chunks[#chunks][2] == group then
        chunks[#chunks][1] = chunks[#chunks][1] .. text
      else
        chunks[#chunks + 1] = { text, group }
      end
    end
  end
  if #chunks == 0 then chunks[1] = { "", base } end
  return chunks
end

function M.virtual_lines(presentation, default_group)
  local result = {}
  for row = 0, #presentation.lines - 1 do
    result[#result + 1] = virtual_line(
      presentation, row, default_group)
  end
  return result
end

return M
