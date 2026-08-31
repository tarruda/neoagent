local M = {}

local function rounded(value)
  return math.max(1, math.floor(value + 0.5))
end

function M.calculate(image, cell_width, cell_height)
  local target_columns, target_rows = image.width, image.height
  local source_width = image.resource.width
  local source_height = image.resource.height
  local fit = image.fit or "contain"
  local columns, rows = target_columns, target_rows
  local row_offset, col_offset = 0, 0
  local source_x, source_y = 0, 0
  local source_columns, source_rows = source_width, source_height
  if source_width and source_height and fit ~= "fill" then
    local source_ratio = source_width / source_height
    local target_ratio = target_columns * cell_width
      / (target_rows * cell_height)
    if fit == "contain" then
      if source_ratio >= target_ratio then
        rows = math.min(target_rows, rounded(
          target_columns * cell_width / source_ratio / cell_height))
        row_offset = math.floor((target_rows - rows) / 2)
      else
        columns = math.min(target_columns, rounded(
          target_rows * cell_height * source_ratio / cell_width))
        col_offset = math.floor((target_columns - columns) / 2)
      end
    elseif source_ratio > target_ratio then
      source_columns = math.max(1, math.floor(source_height * target_ratio))
      source_rows = source_height
      source_x = math.floor((source_width - source_columns) / 2)
    else
      source_columns = source_width
      source_rows = math.max(1, math.floor(source_width / target_ratio))
      source_y = math.floor((source_height - source_rows) / 2)
    end
  end

  local viewport = image.viewport or {
    row = 0, col = 0, width = target_columns, height = target_rows,
  }
  local first_row = math.max(row_offset, viewport.row)
  local last_row = math.min(row_offset + rows,
    viewport.row + viewport.height)
  local first_col = math.max(col_offset, viewport.col)
  local last_col = math.min(col_offset + columns,
    viewport.col + viewport.width)
  if first_row >= last_row or first_col >= last_col then return nil end

  local row_in_image = first_row - row_offset
  local col_in_image = first_col - col_offset
  local visible_rows, visible_columns = last_row - first_row, last_col - first_col

  local result = {
    columns = visible_columns,
    rows = visible_rows,
    screen_row = (image.screen_row or 1) + first_row,
    screen_col = (image.screen_col or 1) + first_col,
  }
  if source_width and source_height then
    local x = source_x + math.floor(
      col_in_image * source_columns / columns)
    local y = source_y + math.floor(
      row_in_image * source_rows / rows)
    local right = source_x + math.ceil(
      (col_in_image + visible_columns) * source_columns / columns)
    local bottom = source_y + math.ceil(
      (row_in_image + visible_rows) * source_rows / rows)
    if x > 0 or y > 0 or right < source_width or bottom < source_height then
      result.source_x = x
      result.source_y = y
      result.source_width = math.max(1, right - x)
      result.source_height = math.max(1, bottom - y)
    end
  end
  return result
end

return M
