local util = require("applet.util")

local M = {}

local rasters = setmetatable({}, { __mode = "k" })

local function covered(intervals, first, last)
  local cursor = first
  for _, interval in ipairs(intervals or {}) do
    if interval.last > cursor and interval.first <= cursor then
      cursor = math.max(cursor, interval.last)
      if cursor >= last then return true end
    elseif interval.first > cursor then
      break
    end
  end
  return cursor >= last
end

local function line_raster(lines, row)
  local raster = rasters[lines]
  if not raster then
    raster = {}
    rasters[lines] = raster
  end
  local cached = raster[row + 1]
  if cached then return cached end

  local result, col, byte_col = {
    line = lines[row + 1] or "",
    offsets = { 0 },
    single_cell = true,
  }, 0, 0
  local line = result.line
  util.characters(line, "container line")
  for index = 0, vim.fn.strchars(line, 1) - 1 do
    local character = vim.fn.strcharpart(line, index, 1, 1)
    local width = util.display_width(character)
    if width > 0 then
      result[#result + 1] = {
        text = character,
        col = col,
        width = width,
      }
      col = col + width
      byte_col = byte_col + #character
      result.offsets[col + 1] = byte_col
      if width ~= 1 then result.single_cell = false end
    end
  end
  result.cell_width = col
  raster[row + 1] = result
  return result
end

local function clear_glyph(row, col, owner)
  local first = row.first[col + 1]
  if first == nil then return end
  local width = row.width[first + 1] or 1
  for index = first, first + width - 1 do
    local offset = index + 1
    row.text[offset] = " "
    row.first[offset] = index
    row.width[offset] = 1
    row.owner[offset] = owner
  end
end

local function paint_blank(row, col, owner)
  clear_glyph(row, col, owner)
  local offset = col + 1
  row.text[offset] = " "
  row.first[offset] = col
  row.width[offset] = 1
  row.owner[offset] = owner
end

local function paint_glyph(row, col, text, width, owner)
  for index = col, col + width - 1 do clear_glyph(row, index, owner) end
  local offset = col + 1
  row.text[offset] = text
  row.first[offset] = col
  row.width[offset] = width
  row.owner[offset] = owner
  for index = col + 1, col + width - 1 do
    offset = index + 1
    row.text[offset] = false
    row.first[offset] = col
    row.width[offset] = 0
    row.owner[offset] = owner
  end
end

local function paint_layer(grid, width, height, layer)
  local clip = layer.clip or { row = 0, col = 0, width = width, height = height }
  local clip_top = math.max(0, clip.row)
  local clip_left = math.max(0, clip.col)
  local clip_bottom = math.min(height, clip.row + clip.height)
  local clip_right = math.min(width, clip.col + clip.width)
  for source_row, intervals in pairs(layer.coverage or {}) do
    local target_row = layer.row + source_row
    if target_row >= clip_top and target_row < clip_bottom then
      local row = grid[target_row + 1]
      for _, interval in ipairs(intervals) do
        local first = math.max(clip_left, layer.col + interval.first)
        local last = math.min(clip_right, layer.col + interval.last)
        for col = first, last - 1 do paint_blank(row, col, layer.id) end
      end

      for _, glyph in ipairs(line_raster(layer.lines, source_row)) do
        local first = layer.col + glyph.col
        local last = first + glyph.width
        if covered(intervals, glyph.col, glyph.col + glyph.width)
            and first >= clip_left and last <= clip_right then
          paint_glyph(row, first, glyph.text, glyph.width, layer.id)
        end
      end
    end
  end
end

local function append_interval(target, owner, row, first, last)
  target[owner] = target[owner] or {}
  target[owner][row] = target[owner][row] or {}
  local intervals = target[owner][row]
  intervals[#intervals + 1] = { first = first, last = last }
end

local function collect_row(row, width, index, visible)
  local parts, coverage = {}, {}
  local coverage_first, owner, owner_first = nil, nil, nil
  local col = 0
  while col < width do
    local offset = col + 1
    local current_owner = row.owner[offset]
    if current_owner ~= owner then
      if owner ~= nil then
        append_interval(visible, owner, index, owner_first, col)
      end
      owner, owner_first = current_owner, current_owner and col or nil
    end
    if current_owner ~= nil and coverage_first == nil then
      coverage_first = col
    elseif current_owner == nil and coverage_first ~= nil then
      coverage[#coverage + 1] = { first = coverage_first, last = col }
      coverage_first = nil
    end

    local text = row.text[offset]
    if current_owner == nil then
      parts[#parts + 1] = " "
      col = col + 1
    else
      assert(row.first[offset] == col,
        "container canvas contains a partial glyph")
      parts[#parts + 1] = text
      col = col + row.width[offset]
    end
  end
  if owner ~= nil then append_interval(visible, owner, index, owner_first, col) end
  if coverage_first ~= nil then
    coverage[#coverage + 1] = { first = coverage_first, last = width }
  end
  return table.concat(parts), coverage
end

local function rectangles_for_rows(rows, height)
  local result, active = {}, {}
  for row = 0, height - 1 do
    local continued = {}
    for _, interval in ipairs(rows and rows[row] or {}) do
      local key = interval.first .. ":" .. interval.last
      local rectangle = active[key]
      if rectangle and rectangle.row + rectangle.height == row then
        rectangle.height = rectangle.height + 1
      else
        rectangle = {
          row = row,
          col = interval.first,
          width = interval.last - interval.first,
          height = 1,
        }
        result[#result + 1] = rectangle
      end
      continued[key] = rectangle
    end
    active = continued
  end
  return result
end

local function single_cell_layers(layers, width, height)
  for _, layer in ipairs(layers) do
    local clip = layer.clip or { row = 0, col = 0, width = width, height = height }
    local top = math.max(0, clip.row)
    local bottom = math.min(height, clip.row + clip.height)
    for source_row in pairs(layer.coverage or {}) do
      local target_row = layer.row + source_row
      if target_row >= top and target_row < bottom
          and not line_raster(layer.lines, source_row).single_cell then
        return false
      end
    end
  end
  return true
end

local function single_cell_slice(lines, row, first, last)
  local width = last - first
  local raster = line_raster(lines, row)
  local bounded_first = math.min(first, raster.cell_width)
  local bounded_last = math.min(last, raster.cell_width)
  local byte_first = raster.offsets[bounded_first + 1] or #raster.line
  local byte_last = raster.offsets[bounded_last + 1] or #raster.line
  local value = raster.line:sub(byte_first + 1, byte_last)
  local cells = math.max(0, bounded_last - bounded_first)
  if cells < width then value = value .. string.rep(" ", width - cells) end
  return value
end

function M.slice(lines, row, first, last)
  assert(type(first) == "number" and type(last) == "number"
      and first >= 0 and first <= last,
    "canvas slice requires an ordered display-cell range")
  local raster = line_raster(lines, row)
  if raster.single_cell then
    return single_cell_slice(lines, row, first, last)
  end

  local parts, cursor = {}, first
  for _, glyph in ipairs(raster) do
    local glyph_last = glyph.col + glyph.width
    if glyph_last > first and glyph.col < last then
      local visible_first = math.max(first, glyph.col)
      local visible_last = math.min(last, glyph_last)
      if visible_first == glyph.col and visible_last == glyph_last then
        parts[#parts + 1] = glyph.text
      else
        parts[#parts + 1] = string.rep(" ", visible_last - visible_first)
      end
      cursor = visible_last
    end
  end
  if cursor < last then parts[#parts + 1] = string.rep(" ", last - cursor) end
  return table.concat(parts)
end

local function span_bytes(span, cells)
  local raster = line_raster(span.layer.lines, span.source_row)
  local first = math.min(span.source_first, raster.cell_width)
  local last = math.min(span.source_first + cells, raster.cell_width)
  local byte_first = raster.offsets[first + 1] or #raster.line
  local byte_last = raster.offsets[last + 1] or #raster.line
  return byte_last - byte_first + math.max(0, cells - (last - first))
end

local function clipped_span(span, first, last)
  return {
    first = first,
    last = last,
    owner = span.owner,
    layer = span.layer,
    source_row = span.source_row,
    source_first = span.source_first + first - span.first,
  }
end

local function overlay_span(
    spans, first, last, layer, source_row, source_first)
  local result = { {
    first = first,
    last = last,
    owner = layer.id,
    layer = layer,
    source_row = source_row,
    source_first = source_first,
  } }
  for _, span in ipairs(spans) do
    if span.last <= first or span.first >= last then
      result[#result + 1] = span
    elseif span.first < first then
      result[#result + 1] = clipped_span(
        span, span.first, math.min(span.last, first))
    end
    if span.first < last and span.last > last then
      result[#result + 1] = clipped_span(
        span, math.max(span.first, last), span.last)
    end
  end
  table.sort(result, function(left, right) return left.first < right.first end)
  return result
end

local function visible_spans(width, height, layers)
  local spans = {}
  for row = 1, height do spans[row] = {} end
  for _, layer in ipairs(layers) do
    local clip = layer.clip or { row = 0, col = 0, width = width, height = height }
    local clip_top = math.max(0, clip.row)
    local clip_left = math.max(0, clip.col)
    local clip_bottom = math.min(height, clip.row + clip.height)
    local clip_right = math.min(width, clip.col + clip.width)
    for source_row, intervals in pairs(layer.coverage or {}) do
      local target_row = layer.row + source_row
      if target_row >= clip_top and target_row < clip_bottom then
        for _, interval in ipairs(intervals) do
          local first = math.max(clip_left, layer.col + interval.first)
          local last = math.min(clip_right, layer.col + interval.last)
          if first < last then
            local source_first = first - layer.col
            spans[target_row + 1] = overlay_span(
              spans[target_row + 1], first, last,
              layer, source_row, source_first)
          end
        end
      end
    end
  end


  local owner_rows = {}
  for row = 0, height - 1 do
    for _, span in ipairs(spans[row + 1]) do
      append_interval(owner_rows, span.owner, row, span.first, span.last)
    end
  end
  local visible = {}
  for _, layer in ipairs(layers) do
    visible[layer.id] = rectangles_for_rows(owner_rows[layer.id], height)
  end
  return spans, visible
end

local function compose_single_cell(width, height, layers)
  local lines = {}
  local spans, visible = visible_spans(width, height, layers)

  local coverage = {}
  for row = 0, height - 1 do
    local parts, cursor = {}, 0
    coverage[row] = {}
    for _, span in ipairs(spans[row + 1]) do
      if cursor < span.first then
        parts[#parts + 1] = string.rep(" ", span.first - cursor)
      end
      parts[#parts + 1] = single_cell_slice(
        span.layer.lines, span.source_row, span.source_first,
        span.source_first + span.last - span.first)
      cursor = span.last
      local previous = coverage[row][#coverage[row]]
      if previous and previous.last == span.first then
        previous.last = span.last
      else
        coverage[row][#coverage[row] + 1] = {
          first = span.first,
          last = span.last,
        }
      end
    end
    if cursor < width then parts[#parts + 1] = string.rep(" ", width - cursor) end
    lines[row + 1] = table.concat(parts)
  end

  return {
    lines = lines,
    coverage = coverage,
    cell_map = spans,
    visible = visible,
    layers = layers,
  }
end

local function ordered_layers(values)
  local layers = vim.list_slice(values or {})
  table.sort(layers, function(left, right)
    if left.zindex ~= right.zindex then return left.zindex < right.zindex end
    return left.order < right.order
  end)
  return layers
end

function M.byte_col(cell_map, row, col)
  local display, bytes = 0, 0
  for _, span in ipairs(cell_map and cell_map[row + 1] or {}) do
    if display < span.first then
      local gap = span.first - display
      if col <= span.first then return bytes + math.max(0, col - display) end
      display, bytes = span.first, bytes + gap
    end
    if col <= span.last then
      return bytes + span_bytes(span, math.max(0, col - span.first))
    end
    local width = span.last - span.first
    display, bytes = span.last, bytes + span_bytes(span, width)
  end
  return bytes + math.max(0, col - display)
end

function M.compose(opts)
  local width, height = assert(opts.width), assert(opts.height)
  local layers = ordered_layers(opts.layers)

  if single_cell_layers(layers, width, height) then
    return compose_single_cell(width, height, layers)
  end

  local grid = {}
  for row = 1, height do
    grid[row] = { text = {}, first = {}, width = {}, owner = {} }
  end
  for _, layer in ipairs(layers) do paint_layer(grid, width, height, layer) end

  local lines, coverage, owner_rows = {}, {}, {}
  for row = 0, height - 1 do
    lines[row + 1], coverage[row] = collect_row(
      grid[row + 1], width, row, owner_rows)
  end

  local visible = {}
  for _, layer in ipairs(layers) do
    visible[layer.id] = rectangles_for_rows(owner_rows[layer.id], height)
  end
  return {
    lines = lines,
    coverage = coverage,
    visible = visible,
    layers = layers,
  }
end

return M
