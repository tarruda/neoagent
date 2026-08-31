local util = require("applet.util")
local canvas = require("applet.pane.canvas")

local M = {}

local NODE_TYPES = {
  region = true,
  text = true,
  column = true,
  row = true,
  container = true,
  responsive = true,
  panel = true,
  source = true,
  image = true,
  target = true,
  scope = true,
  virtual = true,
}

local BUILT_IN_ACTIONS = {
  ["applet.target.move"] = true,
  ["applet.target.activate"] = true,
  ["applet.target.reveal"] = true,
  ["applet.close"] = true,
  ["applet.focus"] = true,
  ["applet.focus.move"] = true,
  ["applet.focus.restore"] = true,
}

local function fail(path, message)
  error(("%s: %s"):format(path, message), 0)
end

local function require_value(condition, path, message)
  if not condition then fail(path, message) end
end

local function integer(value, path, minimum)
  require_value(type(value) == "number" and value % 1 == 0 and value >= minimum,
    path, ("must be an integer >= %d"):format(minimum))
  return value
end

local function signed_integer(value, path)
  require_value(type(value) == "number" and value % 1 == 0,
    path, "must be an integer")
  return value
end

local function fragment(lines)
  return {
    lines = lines or {},
    coverage = {},
    decorations = {},
    targets = {},
    target_order = {},
    hit_order = {},
    scopes = {},
    images = {},
    source_ranges = {},
    virtuals = {},
  }
end

local function add_coverage(value, row, first, last)
  if first >= last then return end
  local intervals = value.coverage[row] or {}
  intervals[#intervals + 1] = { first = first, last = last }
  table.sort(intervals, function(left, right)
    if left.first == right.first then return left.last < right.last end
    return left.first < right.first
  end)
  local merged = {}
  for _, interval in ipairs(intervals) do
    local previous = merged[#merged]
    if previous and interval.first <= previous.last then
      previous.last = math.max(previous.last, interval.last)
    else
      merged[#merged + 1] = {
        first = interval.first,
        last = interval.last,
      }
    end
  end
  value.coverage[row] = merged
end

local function shift_rectangles(rectangles, row, col)
  local result = {}
  for index, rect in ipairs(rectangles or {}) do
    result[index] = {
      row = rect.row + row,
      col = rect.col + col,
      width = rect.width,
      height = rect.height,
    }
  end
  return result
end

local function shift_target_decorations(decorations, row, col)
  local result = {}
  for index, decoration in ipairs(decorations or {}) do
    result[index] = util.copy(decoration)
    result[index].row = decoration.row + row
    result[index].col = decoration.col + col
    if decoration.win_col ~= nil then
      result[index].win_col = decoration.win_col + col
    end
  end
  return result
end

local function append_metadata(
    destination, source, row, display_col, byte_cols, preserve_linewise)
  for source_row, intervals in pairs(source.coverage or {}) do
    for _, interval in ipairs(intervals) do
      add_coverage(destination, source_row + row,
        interval.first + display_col, interval.last + display_col)
    end
  end
  for _, decoration in ipairs(source.decorations) do
    local shifted = util.copy(decoration)
    shifted.row = decoration.row + row
    shifted.col = decoration.col + (byte_cols[decoration.row + 1] or 0)
    if decoration.end_col then
      shifted.end_col = decoration.end_col + (byte_cols[decoration.row + 1] or 0)
    end
    destination.decorations[#destination.decorations + 1] = shifted
  end
  for key, target in pairs(source.targets) do
    require_value(destination.targets[key] == nil, "tree", ("duplicate target key %q"):format(key))
    local shifted = util.copy(target)
    shifted.rectangles = shift_rectangles(target.rectangles, row, display_col)
    shifted.point = {
      row = target.point.row + row,
      col = target.point.col + display_col,
    }
    shifted.focus = {}
    for _, state in ipairs({ "active", "inactive" }) do
      shifted.focus[state] = shift_target_decorations(
        target.focus and target.focus[state], row, display_col)
    end
    destination.targets[key] = shifted
  end
  for _, key in ipairs(source.target_order) do
    destination.target_order[#destination.target_order + 1] = key
  end
  for _, key in ipairs(source.hit_order or source.target_order) do
    destination.hit_order[#destination.hit_order + 1] = key
  end
  for key, scope in pairs(source.scopes) do
    require_value(destination.scopes[key] == nil, "tree", ("duplicate scope key %q"):format(key))
    local shifted = util.copy(scope)
    shifted.rectangles = shift_rectangles(scope.rectangles, row, display_col)
    destination.scopes[key] = shifted
  end
  for key, image in pairs(source.images) do
    require_value(destination.images[key] == nil, "tree", ("duplicate image key %q"):format(key))
    local shifted = util.copy(image)
    shifted.row = image.row + row
    shifted.col = image.col + display_col
    destination.images[key] = shifted
  end
  for _, range in ipairs(source.source_ranges) do
    local shifted = util.copy(range)
    shifted.first = range.first + row
    shifted.last = range.last + row
    shifted.rectangles = shift_rectangles(
      range.rectangles, row, display_col)
    if preserve_linewise == false then shifted.linewise = false end
    destination.source_ranges[#destination.source_ranges + 1] = shifted
  end
  for _, virtual in ipairs(source.virtuals) do
    local shifted = util.copy(virtual)
    shifted.row = virtual.row + row
    destination.virtuals[#destination.virtuals + 1] = shifted
  end
end

local function append_vertical(destination, source, gap)
  if #source.lines == 0 and #source.virtuals == 0 then return end
  local row = #destination.lines
  if #destination.lines > 0 and #source.lines > 0 then
    for _ = 1, gap do destination.lines[#destination.lines + 1] = "" end
    row = #destination.lines
  end
  for _, line in ipairs(source.lines) do destination.lines[#destination.lines + 1] = line end
  local byte_cols = {}
  for index = 1, math.max(#source.lines, 1) do byte_cols[index] = 0 end
  append_metadata(destination, source, row, 0, byte_cols, true)
end

local function placed_metadata(source, row)
  local result = fragment()
  local byte_cols = {}
  for index = 1, math.max(#source.lines, 1) do byte_cols[index] = 0 end
  append_metadata(result, source, row, 0, byte_cols, true)
  return result
end

local function append_placed_metadata(destination, source)
  for row, intervals in pairs(source.coverage or {}) do
    for _, interval in ipairs(intervals) do
      add_coverage(destination, row, interval.first, interval.last)
    end
  end
  for _, decoration in ipairs(source.decorations) do
    destination.decorations[#destination.decorations + 1] = decoration
  end
  for key, target in pairs(source.targets) do
    require_value(destination.targets[key] == nil, "tree",
      ("duplicate target key %q"):format(key))
    destination.targets[key] = target
  end
  for _, key in ipairs(source.target_order) do
    destination.target_order[#destination.target_order + 1] = key
  end
  for _, key in ipairs(source.hit_order or source.target_order) do
    destination.hit_order[#destination.hit_order + 1] = key
  end
  for key, scope in pairs(source.scopes) do
    require_value(destination.scopes[key] == nil, "tree",
      ("duplicate scope key %q"):format(key))
    destination.scopes[key] = scope
  end
  for key, image in pairs(source.images) do
    require_value(destination.images[key] == nil, "tree",
      ("duplicate image key %q"):format(key))
    destination.images[key] = image
  end
  for _, range in ipairs(source.source_ranges) do
    destination.source_ranges[#destination.source_ranges + 1] = range
  end
  for _, virtual in ipairs(source.virtuals) do
    destination.virtuals[#destination.virtuals + 1] = virtual
  end
end

local function append_region(destination, source, gap, cache_entry)
  if #source.lines == 0 and #source.virtuals == 0 then
    return #destination.lines
  end
  local row = #destination.lines
  if #destination.lines > 0 and #source.lines > 0 then
    for _ = 1, gap do destination.lines[#destination.lines + 1] = "" end
    row = #destination.lines
  end
  for _, line in ipairs(source.lines) do
    destination.lines[#destination.lines + 1] = line
  end
  local placement = cache_entry and cache_entry.placement
  if not placement or placement.row ~= row then
    placement = { row = row, metadata = placed_metadata(source, row) }
    if cache_entry then cache_entry.placement = placement end
  end
  append_placed_metadata(destination, placement.metadata)
  return row
end

local function validate_plain(value, path, seen, revised_regions)
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "string" then return end
  if kind == "number" then
    require_value(value == value and value ~= math.huge and value ~= -math.huge,
      path, "must be finite")
    return
  end
  require_value(kind == "table", path, "must contain plain data")
  require_value(getmetatable(value) == nil, path, "must contain plain data")
  require_value(not seen[value], path, "must not be cyclic")
  seen[value] = true
  for key, item in pairs(value) do
    local key_kind = type(key)
    require_value(key_kind == "string" or key_kind == "number",
      path, "has a non-data key")
    if not (revised_regions and value.type == "region"
        and value.revision ~= nil and key == "child") then
      validate_plain(item, path .. "." .. tostring(key), seen, revised_regions)
    end
  end
  seen[value] = nil
end

local function validate_action(action, path)
  require_value(type(action) == "table", path, "must be an action reference")
  require_value(util.nonempty_string(action.action), path .. ".action",
    "must be a non-empty string")
  if action.payload ~= nil then validate_plain(action.payload, path .. ".payload", {}) end
  if action.action:match("^applet%.") then
    require_value(BUILT_IN_ACTIONS[action.action], path .. ".action",
      "is not a known built-in action")
    require_value(action.payload == nil or type(action.payload) == "table",
      path .. ".payload", "must be a table")
  end
  local payload = action.payload or {}
  if action.action == "applet.target.move" then
    require_value(payload.direction == "previous" or payload.direction == "next",
      path .. ".payload.direction", "must be previous or next")
    require_value(payload.group == nil or util.nonempty_string(payload.group),
      path .. ".payload.group", "must be a non-empty string")
    require_value(payload.wrap == nil or type(payload.wrap) == "boolean",
      path .. ".payload.wrap", "must be a boolean")
    require_value(payload.entry == nil or payload.entry == "first",
      path .. ".payload.entry", "must be first")
  elseif action.action == "applet.target.activate" then
    require_value(payload.target == nil or util.nonempty_string(payload.target),
      path .. ".payload.target", "must be a non-empty string")
  elseif action.action == "applet.target.reveal" then
    require_value(util.nonempty_string(payload.target), path .. ".payload.target",
      "must be a non-empty string")
  elseif action.action == "applet.focus" then
    require_value(util.nonempty_string(payload.pane), path .. ".payload.pane",
      "must be a non-empty string")
  elseif action.action == "applet.focus.move" then
    require_value(payload.direction == "left" or payload.direction == "right"
        or payload.direction == "up" or payload.direction == "down",
      path .. ".payload.direction", "must be left, right, up, or down")
    require_value(payload.wrap == nil or type(payload.wrap) == "boolean",
      path .. ".payload.wrap", "must be a boolean")
  end
end

local function resolve_group(run, theme, path)
  require_value(type(run) == "table", path, "must be a table")
  require_value(type(run.text) == "string", path .. ".text", "must be a string")
  require_value(not (run.style and run.group), path,
    "may specify style or group, not both")
  if run.group ~= nil then
    require_value(util.nonempty_string(run.group), path .. ".group",
      "must be a non-empty string")
    return run.group
  end
  if run.style ~= nil then return theme:group(run.style) end
end

local function resolve_run_groups(run, theme, path)
  require_value(not (run.groups and (run.style or run.group)), path,
    "may specify groups or one style/group, not both")
  if run.groups == nil then
    local group = resolve_group(run, theme, path)
    return group and { { group = group } } or {}
  end
  require_value(type(run.groups) == "table" and vim.islist(run.groups)
      and #run.groups > 0,
    path .. ".groups", "must be a non-empty list")
  local result, claimed = {}, {}
  for index, value in ipairs(run.groups) do
    local item_path = ("%s.groups[%d]"):format(path, index)
    local descriptor = type(value) == "string" and { group = value }
      or util.copy(value)
    require_value(type(descriptor) == "table", item_path,
      "must be a group name or descriptor")
    descriptor.text = ""
    local group = resolve_group(descriptor, theme, item_path)
    require_value(group ~= nil, item_path, "must specify a style or group")
    local priority = descriptor.priority
    if priority ~= nil then integer(priority, item_path .. ".priority", 0) end
    local id = group .. "\0" .. tostring(priority or "")
    if not claimed[id] then
      claimed[id] = true
      result[#result + 1] = { group = group, priority = priority }
    end
  end
  return result
end

local function text_tokens(node, ctx, path)
  local runs = node.runs
  if runs == nil and node.text ~= nil then runs = { { text = node.text } } end
  require_value(type(runs) == "table" and #runs > 0, path .. ".runs",
    "must be a non-empty list")
  local tabstop = node.tabstop
  if tabstop ~= nil then integer(tabstop, path .. ".tabstop", 1) end
  local lines = { {} }
  local display_col = 0
  for run_index, run in ipairs(runs) do
    local groups = resolve_run_groups(run, ctx.theme,
      ("%s.runs[%d]"):format(path, run_index))
    for _, character in ipairs(util.characters(run.text,
      ("%s.runs[%d].text"):format(path, run_index))) do
      if character == "\n" then
        lines[#lines + 1] = {}
        display_col = 0
      elseif character == "\t" then
        require_value(tabstop ~= nil, path, "contains a tab without tabstop")
        local count = tabstop - (display_col % tabstop)
        for _ = 1, count do
          lines[#lines][#lines[#lines] + 1] = {
            text = " ", width = 1, groups = groups,
          }
          display_col = display_col + 1
        end
      else
        local width = util.display_width(character)
        lines[#lines][#lines[#lines] + 1] = {
          text = character,
          width = width,
          groups = groups,
        }
        display_col = display_col + width
      end
    end
  end
  return lines
end

local function token_width(tokens, first, last)
  local width = 0
  for index = first, last do width = width + tokens[index].width end
  return width
end

local function wrap_tokens(tokens, width, mode)
  if #tokens == 0 then return { {} } end
  if mode == "native" then return { vim.list_slice(tokens) }, false end
  if mode == "none" then
    local last, used = 0, 0
    for index, token in ipairs(tokens) do
      if used + token.width > width then break end
      last, used = index, used + token.width
    end
    local row = {}
    for index = 1, last do row[#row + 1] = tokens[index] end
    return { row }, last < #tokens
  end
  local rows, first = {}, 1
  while first <= #tokens do
    local last, used = first - 1, 0
    while last + 1 <= #tokens and used + tokens[last + 1].width <= width do
      last = last + 1
      used = used + tokens[last].width
    end
    if last < first then last = first end
    if mode == "word" and last < #tokens then
      local boundary
      for index = last, first, -1 do
        if tokens[index].text:match("^%s$") then boundary = index break end
      end
      if boundary and boundary > first then last = boundary end
    end
    local row = {}
    for index = first, last do row[#row + 1] = tokens[index] end
    rows[#rows + 1] = row
    first = last + 1
    if mode == "word" then
      while first <= #tokens and tokens[first].text:match("^%s$") do first = first + 1 end
    end
  end
  return rows, false
end

local function ellipsize(tokens, width)
  local ellipsis = { text = "…", width = 1 }
  while #tokens > 0 and token_width(tokens, 1, #tokens) + 1 > width do
    table.remove(tokens)
  end
  if width >= 1 then tokens[#tokens + 1] = ellipsis end
end

local function native_text_rows(node, ctx, path)
  local runs = node.runs
  if runs == nil and node.text ~= nil then runs = { { text = node.text } } end
  require_value(type(runs) == "table" and #runs > 0, path .. ".runs",
    "must be a non-empty list")
  local tabstop = node.tabstop
  if tabstop ~= nil then integer(tabstop, path .. ".tabstop", 1) end
  local rows = { {} }
  local display_col = 0
  local function add(text, groups)
    if text == "" then return end
    local value = {
      text = text,
      width = util.display_width(text),
      groups = groups,
    }
    rows[#rows][#rows[#rows] + 1] = value
    display_col = display_col + value.width
  end
  for run_index, run in ipairs(runs) do
    local run_path = ("%s.runs[%d]"):format(path, run_index)
    local groups = resolve_run_groups(run, ctx.theme, run_path)
    util.validate_text(run.text, run_path .. ".text")
    local first = 1
    while first <= #run.text do
      local special = run.text:find("[\n\t]", first)
      if not special then
        add(run.text:sub(first), groups)
        break
      end
      add(run.text:sub(first, special - 1), groups)
      local character = run.text:sub(special, special)
      if character == "\n" then
        rows[#rows + 1] = {}
        display_col = 0
      else
        require_value(tabstop ~= nil, path, "contains a tab without tabstop")
        add(string.rep(" ", tabstop - (display_col % tabstop)), groups)
      end
      first = special + 1
    end
  end
  return rows
end

local function compile_text(node, ctx, path)
  local mode = node.wrap or "word"
  require_value(mode == "word" or mode == "character" or mode == "none"
      or mode == "native",
    path .. ".wrap", "must be word, character, none, or native")
  if node.max_lines ~= nil then integer(node.max_lines, path .. ".max_lines", 1) end
  local overflow = node.overflow or "clip"
  require_value(overflow == "clip" or overflow == "ellipsis",
    path .. ".overflow", "must be clip or ellipsis")
  local rows, truncated = {}, false
  if mode == "native" and not (node.max_lines and overflow == "ellipsis") then
    rows = native_text_rows(node, ctx, path)
  else
    for _, logical in ipairs(text_tokens(node, ctx, path)) do
      local wrapped, clipped = wrap_tokens(logical, ctx.width, mode)
      truncated = truncated or clipped
      for _, row in ipairs(wrapped) do rows[#rows + 1] = row end
    end
  end
  if node.max_lines and #rows > node.max_lines then
    while #rows > node.max_lines do table.remove(rows) end
    truncated = true
  end
  if truncated and overflow == "ellipsis" then ellipsize(rows[#rows], ctx.width) end
  local result = fragment()
  for row_index, tokens in ipairs(rows) do
    local parts, ordered, descriptors = {}, {}, {}
    for _, token in ipairs(tokens) do
      parts[#parts + 1] = token.text
      for _, descriptor in ipairs(token.groups or {}) do
        local id = descriptor.group .. "\0" .. tostring(descriptor.priority or "")
        if not descriptors[id] then
          descriptors[id] = descriptor
          ordered[#ordered + 1] = id
        end
      end
    end
    for _, id in ipairs(ordered) do
      local descriptor = descriptors[id]
      local start_col, byte_col = nil, 0
      for _, token in ipairs(tokens) do
        local present = false
        for _, candidate in ipairs(token.groups or {}) do
          if candidate.group == descriptor.group
              and candidate.priority == descriptor.priority then
            present = true
            break
          end
        end
        if present and start_col == nil then start_col = byte_col end
        if not present and start_col ~= nil then
          result.decorations[#result.decorations + 1] = {
            row = row_index - 1,
            col = start_col,
            end_col = byte_col,
            group = descriptor.group,
            priority = descriptor.priority,
          }
          start_col = nil
        end
        byte_col = byte_col + #token.text
      end
      if start_col ~= nil then
        result.decorations[#result.decorations + 1] = {
          row = row_index - 1,
          col = start_col,
          end_col = byte_col,
          group = descriptor.group,
          priority = descriptor.priority,
        }
      end
    end
    result.lines[#result.lines + 1] = table.concat(parts)
    add_coverage(result, row_index - 1, 0,
      token_width(tokens, 1, #tokens))
  end
  if node.background ~= nil then
    local group = ctx.theme:group(node.background)
    for row = 0, #result.lines - 1 do
      local line = result.lines[row + 1]
      add_coverage(result, row, 0, ctx.width)
      result.decorations[#result.decorations + 1] = {
        row = row,
        col = mode == "native" and util.byte_col(line, ctx.width) or 0,
        group = group,
        whole_line = true,
        continuation = mode == "native" or nil,
      }
    end
  end
  return result
end

local compile_node

local function padding(value, path)
  if value == nil then return { left = 0, right = 0, top = 0, bottom = 0 } end
  if type(value) == "number" then
    integer(value, path, 0)
    return { left = value, right = value, top = value, bottom = value }
  end
  require_value(type(value) == "table", path, "must be an integer or table")
  local result = {}
  for _, side in ipairs({ "left", "right", "top", "bottom" }) do
    result[side] = integer(value[side] or 0, path .. "." .. side, 0)
  end
  return result
end

local function content_rectangles(value)
  local rectangles = {}
  for row, line in ipairs(value.lines) do
    rectangles[#rectangles + 1] = {
      row = row - 1,
      col = 0,
      width = math.max(1, util.display_width(line)),
      height = 1,
    }
  end
  if #rectangles == 0 then
    rectangles[1] = { row = 0, col = 0, width = 1, height = 1 }
  end
  return rectangles
end

local function binding_id(binding)
  return (binding.mode or "n") .. "\0" .. binding.lhs
end

local function compile_scope(node, ctx, path)
  require_value(type(node.bindings or {}) == "table", path .. ".bindings",
    "must be a list")
  local bindings, claimed = {}, {}
  for index, binding in ipairs(node.bindings or {}) do
    local binding_path = ("%s.bindings[%d]"):format(path, index)
    require_value(type(binding) == "table", binding_path, "must be a table")
    local mode = binding.mode or "n"
    require_value(util.nonempty_string(mode), binding_path .. ".mode",
      "must be a non-empty string")
    require_value(util.nonempty_string(binding.lhs), binding_path .. ".lhs",
      "must be a non-empty string")
    validate_action(binding.action, binding_path .. ".action")
    require_value(binding.count == nil or type(binding.count) == "boolean",
      binding_path .. ".count", "must be a boolean")
    if binding.desc ~= nil then
      require_value(type(binding.desc) == "string", binding_path .. ".desc",
        "must be a string")
    end
    local normalized = util.copy(binding)
    normalized.mode = mode
    normalized.count = binding.count or false
    local id = binding_id(normalized)
    require_value(not claimed[id], binding_path, "duplicates a binding in this scope")
    claimed[id] = true
    bindings[#bindings + 1] = normalized
  end
  local child_ctx = util.copy(ctx)
  child_ctx.scope = node.key
  local child = compile_node(node.child, child_ctx, path .. ".child")
  child.scopes[node.key] = {
    key = node.key,
    parent = ctx.scope,
    modal = node.modal == true,
    rectangles = content_rectangles(child),
    bindings = bindings,
  }
  for key, scope in pairs(child.scopes) do
    if key ~= node.key and scope.parent == nil then scope.parent = node.key end
  end
  return child
end

local function compile_column(node, ctx, path)
  require_value(type(node.children) == "table", path .. ".children", "must be a list")
  local gap = integer(node.gap or 0, path .. ".gap", 0)
  local result = fragment()
  for index, child in ipairs(node.children) do
    append_vertical(result, compile_node(child, ctx,
      ("%s.children[%d]"):format(path, index)), gap)
  end
  return result
end

local function row_widths(children, available, gap, path)
  local widths, grow_total, minimum_total = {}, 0, 0
  for index, descriptor in ipairs(children) do
    local item = descriptor.node and descriptor or { node = descriptor }
    local minimum = integer(item.min_width or 1,
      ("%s.children[%d].min_width"):format(path, index), 1)
    local grow = item.grow == nil and 1 or item.grow
    require_value(type(grow) == "number" and grow >= 0,
      ("%s.children[%d].grow"):format(path, index), "must be a number >= 0")
    widths[index] = minimum
    minimum_total = minimum_total + minimum
    grow_total = grow_total + grow
  end
  local remaining = available - gap * math.max(0, #children - 1) - minimum_total
  require_value(remaining >= 0, path, "minimum row widths do not fit")
  for index, descriptor in ipairs(children) do
    local item = descriptor.node and descriptor or { node = descriptor }
    local grow = item.grow == nil and 1 or item.grow
    local share = 0
    if grow_total > 0 then share = math.floor(remaining * grow / grow_total) end
    widths[index] = widths[index] + share
  end
  local used = gap * math.max(0, #children - 1)
  for _, allocated in ipairs(widths) do used = used + allocated end
  local index = 1
  while used < available and #widths > 0 do
    widths[index] = widths[index] + 1
    used, index = used + 1, (index % #widths) + 1
  end
  return widths
end

local function compile_row(node, ctx, path)
  require_value(type(node.children) == "table" and #node.children > 0,
    path .. ".children", "must be a non-empty list")
  local gap = integer(node.gap or 0, path .. ".gap", 0)
  local width = node.width and integer(node.width, path .. ".width", 1)
    or ctx.width
  require_value(width >= ctx.width, path .. ".width",
    "must cover the available width")
  local widths = row_widths(node.children, width, gap, path)
  local children, height = {}, 0
  for index, descriptor in ipairs(node.children) do
    local child_node = descriptor.node and descriptor.node or descriptor
    require_value(child_node.type ~= "region",
      ("%s.children[%d]"):format(path, index), "regions cannot appear in rows")
    local child_ctx = util.copy(ctx)
    child_ctx.width = widths[index]
    children[index] = compile_node(child_node, child_ctx,
      ("%s.children[%d]"):format(path, index))
    height = math.max(height, #children[index].lines)
  end
  local result = fragment()
  for _ = 1, height do result.lines[#result.lines + 1] = "" end
  local display_col = 0
  for index, child in ipairs(children) do
    local byte_cols = {}
    for row = 1, height do
      local prefix = result.lines[row]
      byte_cols[row] = #prefix
      local line = child.lines[row] or ""
      local padding_width = widths[index] - util.display_width(line)
      result.lines[row] = prefix .. line .. string.rep(" ", math.max(0, padding_width))
      if index < #children then result.lines[row] = result.lines[row] .. string.rep(" ", gap) end
    end
    append_metadata(result, child, 0, display_col, byte_cols, false)
    display_col = display_col + widths[index] + (index < #children and gap or 0)
  end
  return result
end

local function compile_panel(node, ctx, path)
  local pad = padding(node.padding, path .. ".padding")
  require_value(pad.left + pad.right < ctx.width, path .. ".padding",
    "horizontal padding leaves no content width")
  local child_ctx = util.copy(ctx)
  child_ctx.width = ctx.width - pad.left - pad.right
  if node.background ~= nil then
    child_ctx.background_group = ctx.theme:group(node.background)
  end
  local child = compile_node(node.child, child_ctx, path .. ".child")
  local result = fragment()
  for _ = 1, pad.top do result.lines[#result.lines + 1] = string.rep(" ", ctx.width) end
  local start = #result.lines
  for _, line in ipairs(child.lines) do
    local right = child_ctx.width - util.display_width(line)
    result.lines[#result.lines + 1] = string.rep(" ", pad.left) .. line
      .. string.rep(" ", math.max(0, right + pad.right))
  end
  for _ = 1, pad.bottom do result.lines[#result.lines + 1] = string.rep(" ", ctx.width) end
  local byte_cols = {}
  for index = 1, math.max(#child.lines, 1) do byte_cols[index] = pad.left end
  append_metadata(result, child, start, pad.left, byte_cols, true)
  if node.background ~= nil then
    local group = ctx.theme:group(node.background)
    for row = 0, #result.lines - 1 do
      add_coverage(result, row, 0, ctx.width)
      result.decorations[#result.decorations + 1] = {
        row = row, col = 0, group = group, whole_line = true,
      }
    end
  end
  return result
end

local function intersect_rectangle(left, right)
  local row = math.max(left.row, right.row)
  local col = math.max(left.col, right.col)
  local bottom = math.min(left.row + left.height, right.row + right.height)
  local edge = math.min(left.col + left.width, right.col + right.width)
  if row >= bottom or col >= edge then return nil end
  return {
    row = row,
    col = col,
    width = edge - col,
    height = bottom - row,
  }
end

local function canonical_rectangles(rectangles)
  local rows, first_row, last_row = {}, nil, nil
  for _, rectangle in ipairs(rectangles) do
    first_row = math.min(first_row or rectangle.row, rectangle.row)
    last_row = math.max(
      last_row or rectangle.row, rectangle.row + rectangle.height)
    for row = rectangle.row, rectangle.row + rectangle.height - 1 do
      rows[row] = rows[row] or {}
      rows[row][#rows[row] + 1] = {
        first = rectangle.col,
        last = rectangle.col + rectangle.width,
      }
    end
  end
  local result, active = {}, {}
  for row = first_row or 0, (last_row or 0) - 1 do
    local intervals = rows[row] or {}
    table.sort(intervals, function(left, right)
      if left.first == right.first then return left.last < right.last end
      return left.first < right.first
    end)
    local merged = {}
    for _, interval in ipairs(intervals) do
      local previous = merged[#merged]
      if previous and interval.first <= previous.last then
        previous.last = math.max(previous.last, interval.last)
      else
        merged[#merged + 1] = interval
      end
    end
    local continued = {}
    for _, interval in ipairs(merged) do
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
  table.sort(result, function(left, right)
    if left.row ~= right.row then return left.row < right.row end
    return left.col < right.col
  end)
  return result
end

local function visible_rectangles(rectangles, row, col, visible)
  local result = {}
  for _, rectangle in ipairs(rectangles or {}) do
    local shifted = {
      row = rectangle.row + row,
      col = rectangle.col + col,
      width = rectangle.width,
      height = rectangle.height,
    }
    for _, boundary in ipairs(visible or {}) do
      local intersection = intersect_rectangle(shifted, boundary)
      if intersection then result[#result + 1] = intersection end
    end
  end
  return canonical_rectangles(result)
end

local function visible_spans(rectangles, row, first, last)
  local spans = {}
  for _, rectangle in ipairs(rectangles or {}) do
    if row >= rectangle.row and row < rectangle.row + rectangle.height then
      local left = math.max(first, rectangle.col)
      local right = math.min(last, rectangle.col + rectangle.width)
      if left < right then spans[#spans + 1] = { first = left, last = right } end
    end
  end
  table.sort(spans, function(left, right) return left.first < right.first end)
  return spans
end

local function display_col(line, byte_col)
  return util.display_width(line:sub(1, byte_col))
end

local function output_byte_col(result, row, col)
  if result.cell_map then return canvas.byte_col(result.cell_map, row, col) end
  return util.byte_col(result.lines[row + 1] or "", col)
end

local function project_decorations(result, source, row, col, width, visible)
  for _, decoration in ipairs(source.decorations) do
    local line = source.lines[decoration.row + 1] or ""
    local first = col + display_col(line, decoration.col)
    local last
    if decoration.whole_line or decoration.end_col == nil then
      last = col + width
    else
      last = col + display_col(line, decoration.end_col)
    end
    local output_row = row + decoration.row
    for _, span in ipairs(visible_spans(
        visible, output_row, first, last)) do
      local projected = util.copy(decoration)
      projected.row = output_row
      projected.col = output_byte_col(result, output_row, span.first)
      projected.end_col = output_byte_col(result, output_row, span.last)
      projected.whole_line = nil
      if projected.col < projected.end_col then
        result.decorations[#result.decorations + 1] = projected
      end
    end
  end
end

local function project_metadata(
    result, source, row, col, width, visible, include_decorations)
  if include_decorations ~= false then
    project_decorations(result, source, row, col, width, visible)
  end
  for key, target in pairs(source.targets) do
    require_value(result.targets[key] == nil, "tree",
      ("duplicate target key %q"):format(key))
    local rectangles = visible_rectangles(
      target.rectangles, row, col, visible)
    if #rectangles > 0 then
      local shifted = util.copy(target)
      shifted.rectangles = rectangles
      shifted.point = {
        row = target.point.row + row,
        col = target.point.col + col,
      }
      local point_visible = false
      for _, rectangle in ipairs(rectangles) do
        if shifted.point.row >= rectangle.row
            and shifted.point.row < rectangle.row + rectangle.height
            and shifted.point.col >= rectangle.col
            and shifted.point.col < rectangle.col + rectangle.width then
          point_visible = true
          break
        end
      end
      if not point_visible then
        shifted.point = { row = rectangles[1].row, col = rectangles[1].col }
      end
      shifted.focus = {}
      for _, state in ipairs({ "active", "inactive" }) do
        shifted.focus[state] = shift_target_decorations(
          target.focus and target.focus[state], row, col)
      end
      result.targets[key] = shifted
    end
  end
  for _, key in ipairs(source.target_order) do
    if result.targets[key] then result.target_order[#result.target_order + 1] = key end
  end
  for key, scope in pairs(source.scopes) do
    require_value(result.scopes[key] == nil, "tree",
      ("duplicate scope key %q"):format(key))
    local rectangles = visible_rectangles(
      scope.rectangles, row, col, visible)
    if #rectangles > 0 or scope.root or scope.modal then
      local shifted = util.copy(scope)
      shifted.rectangles = rectangles
      result.scopes[key] = shifted
    end
  end
  for key, image in pairs(source.images) do
    require_value(result.images[key] == nil, "tree",
      ("duplicate image key %q"):format(key))
    local candidates = {}
    for _, rectangle in ipairs(image.visible) do
      candidates[#candidates + 1] = {
        row = image.row + rectangle.row,
        col = image.col + rectangle.col,
        width = rectangle.width,
        height = rectangle.height,
      }
    end
    local clipped = visible_rectangles(candidates, row, col, visible)
    if #clipped > 0 then
      local shifted = util.copy(image)
      shifted.row, shifted.col = image.row + row, image.col + col
      shifted.visible = {}
      for _, rectangle in ipairs(clipped) do
        shifted.visible[#shifted.visible + 1] = {
          row = rectangle.row - shifted.row,
          col = rectangle.col - shifted.col,
          width = rectangle.width,
          height = rectangle.height,
        }
      end
      result.images[key] = shifted
    end
  end
  for _, range in ipairs(source.source_ranges) do
    local rectangles = visible_rectangles(
      range.rectangles, row, col, visible)
    if #rectangles > 0 then
      local shifted = util.copy(range)
      shifted.rectangles = rectangles
      shifted.linewise = false
      shifted.first, shifted.last = rectangles[1].row,
        rectangles[1].row + rectangles[1].height
      for _, rectangle in ipairs(rectangles) do
        shifted.first = math.min(shifted.first, rectangle.row)
        shifted.last = math.max(
          shifted.last, rectangle.row + rectangle.height)
      end
      result.source_ranges[#result.source_ranges + 1] = shifted
    end
  end
end

local function project_scene(scene)
  local composed = canvas.compose({
    width = scene.width,
    height = scene.height,
    layers = scene.layers,
  })
  local result = fragment(composed.lines)
  result.coverage = composed.coverage
  result.cell_map = composed.cell_map
  result.scene = scene
  for _, layer in ipairs(scene.layers) do
    project_metadata(result, layer.fragment, layer.row, layer.col,
      layer.width, composed.visible[layer.id])
  end
  for index = #composed.layers, 1, -1 do
    local layer = composed.layers[index]
    for _, key in ipairs(layer.fragment.hit_order) do
      if result.targets[key] then result.hit_order[#result.hit_order + 1] = key end
    end
  end
  return result
end

local function scene_lines(scene)
  local line = string.rep(" ", scene.width)
  local result = {}
  for _ = 1, scene.height do result[#result + 1] = line end
  return result
end

local function fragment_has_spatial_metadata(value)
  return next(value.targets) ~= nil
    or next(value.scopes) ~= nil
    or next(value.images) ~= nil
    or #value.source_ranges > 0
end

local function subtract_intervals(values, blockers)
  local result = values
  for _, blocker in ipairs(blockers or {}) do
    local remaining = {}
    for _, value in ipairs(result) do
      if blocker.last <= value.first or blocker.first >= value.last then
        remaining[#remaining + 1] = value
      else
        if value.first < blocker.first then
          remaining[#remaining + 1] = {
            first = value.first,
            last = math.min(value.last, blocker.first),
          }
        end
        if value.last > blocker.last then
          remaining[#remaining + 1] = {
            first = math.max(value.first, blocker.last),
            last = value.last,
          }
        end
      end
    end
    result = remaining
    if #result == 0 then break end
  end
  return result
end

local function retained_layer_visibility(scene, layers, index)
  local layer = layers[index]
  local clip = layer.clip or {
    row = 0,
    col = 0,
    width = scene.width,
    height = scene.height,
  }
  local clip_top = math.max(0, clip.row)
  local clip_left = math.max(0, clip.col)
  local clip_bottom = math.min(scene.height, clip.row + clip.height)
  local clip_right = math.min(scene.width, clip.col + clip.width)
  local rectangles = {}
  for source_row, intervals in pairs(layer.coverage) do
    local row = layer.row + source_row
    if row >= clip_top and row < clip_bottom then
      local visible = {}
      for _, interval in ipairs(intervals) do
        local first = math.max(clip_left, layer.col + interval.first)
        local last = math.min(clip_right, layer.col + interval.last)
        if first < last then
          visible[#visible + 1] = { first = first, last = last }
        end
      end
      for higher_index = index + 1, #layers do
        local higher = layers[higher_index]
        local higher_clip = higher.clip or {
          row = 0,
          col = 0,
          width = scene.width,
          height = scene.height,
        }
        if row >= higher_clip.row
            and row < higher_clip.row + higher_clip.height then
          local blockers = {}
          for _, interval in ipairs(
              higher.coverage[row - higher.row] or {}) do
            local first = math.max(0, higher_clip.col,
              higher.col + interval.first)
            local last = math.min(scene.width,
              higher_clip.col + higher_clip.width,
              higher.col + interval.last)
            if first < last then
              blockers[#blockers + 1] = { first = first, last = last }
            end
          end
          visible = subtract_intervals(visible, blockers)
          if #visible == 0 then break end
        end
      end
      for _, interval in ipairs(visible) do
        rectangles[#rectangles + 1] = {
          row = row,
          col = interval.first,
          width = interval.last - interval.first,
          height = 1,
        }
      end
    end
  end
  return canonical_rectangles(rectangles)
end

local function project_retained_scene(scene, previous)
  local result = fragment(previous and previous.lines or scene_lines(scene))
  result.scene = scene
  if previous then
    result.coverage = previous.coverage
  else
    for row = 0, scene.height - 1 do
      result.coverage[row] = { { first = 0, last = scene.width } }
    end
  end
  local layers = vim.list_slice(scene.layers)
  table.sort(layers, function(left, right)
    if left.zindex ~= right.zindex then return left.zindex < right.zindex end
    return left.order < right.order
  end)
  for index, layer in ipairs(layers) do
    if fragment_has_spatial_metadata(layer.fragment) then
      project_metadata(result, layer.fragment, layer.row, layer.col,
        layer.width, retained_layer_visibility(scene, layers, index), false)
    end
  end
  for index = #layers, 1, -1 do
    local layer = layers[index]
    for _, key in ipairs(layer.fragment.hit_order) do
      if result.targets[key] then result.hit_order[#result.hit_order + 1] = key end
    end
  end
  return result
end

local BORDER_CHARACTERS = {
  single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
  rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
  double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
}

local function box_group(value, ctx, path)
  if value.style == nil and value.group == nil then return nil end
  return resolve_group({
    text = "",
    style = value.style,
    group = value.group,
  }, ctx.theme, path)
end

local function border_spec(value, ctx, path)
  if value == nil or value == false or value == "none" then return nil end
  if type(value) == "string" then value = { kind = value } end
  require_value(type(value) == "table", path, "must be a table or border name")
  local characters = value.characters
  if characters == nil then
    local kind = value.kind or "single"
    require_value(BORDER_CHARACTERS[kind] ~= nil, path .. ".kind",
      "must be single, rounded, or double")
    characters = BORDER_CHARACTERS[kind]
  end
  require_value(type(characters) == "table" and vim.islist(characters)
      and #characters == 8, path .. ".characters",
    "must contain eight cells")
  local result = {}
  for index, character in ipairs(characters) do
    require_value(type(character) == "string"
        and util.display_width(character) == 1,
      ("%s.characters[%d]"):format(path, index),
      "must be one display cell")
    result[index] = character
  end
  local title = value.title
  if title ~= nil then
    require_value(type(title) == "string", path .. ".title",
      "must be a string")
    for _, character in ipairs(util.characters(title, path .. ".title")) do
      require_value(character ~= "\n", path .. ".title",
        "must occupy one line")
    end
  end
  local title_pos = value.title_pos or "center"
  require_value(title_pos == "left" or title_pos == "center"
      or title_pos == "right", path .. ".title_pos",
    "must be left, center, or right")
  local title_group
  if value.title_group ~= nil or value.title_style ~= nil then
    title_group = resolve_group({
      text = "",
      group = value.title_group,
      style = value.title_style,
    }, ctx.theme, path .. ".title")
  end
  return {
    characters = result,
    group = box_group(value, ctx, path),
    title = title,
    title_pos = title_pos,
    title_group = title_group,
    path = path,
  }
end

local function solid_fragment(width, height, character, group)
  local result = fragment()
  for row = 0, height - 1 do
    result.lines[row + 1] = string.rep(character, width)
    add_coverage(result, row, 0, width)
    if group then
      result.decorations[#result.decorations + 1] = {
        row = row,
        col = 0,
        end_col = #result.lines[row + 1],
        group = group,
      }
    end
  end
  return result
end

local function border_fragment(width, height, spec)
  local result = fragment()
  local chars = spec.characters
  local title = spec.title or ""
  local title_width = util.display_width(title)
  require_value(title_width <= width, spec.path .. ".title",
    "exceeds the border width")
  local remaining = width - title_width
  local left = spec.title_pos == "right" and remaining
    or spec.title_pos == "center" and math.floor(remaining / 2) or 0
  result.lines[1] = chars[1] .. string.rep(chars[2], left)
    .. title .. string.rep(chars[2], remaining - left) .. chars[3]
  add_coverage(result, 0, 0, width + 2)
  for row = 1, height do
    result.lines[row + 1] = chars[8] .. string.rep(" ", width) .. chars[4]
    add_coverage(result, row, 0, 1)
    add_coverage(result, row, width + 1, width + 2)
  end
  result.lines[height + 2] = chars[7]
    .. string.rep(chars[6], width) .. chars[5]
  add_coverage(result, height + 1, 0, width + 2)
  if spec.group then
    for row, line in ipairs(result.lines) do
      result.decorations[#result.decorations + 1] = {
        row = row - 1,
        col = 0,
        end_col = #line,
        group = spec.group,
      }
    end
  end
  if title ~= "" and spec.title_group then
    result.decorations[#result.decorations + 1] = {
      row = 0,
      col = #chars[1] + left * #chars[2],
      end_col = #chars[1] + left * #chars[2] + #title,
      group = spec.title_group,
      priority = 101,
    }
  end
  return result
end

local function same_positioned_content(left, right)
  if rawequal(left, right) then return true end
  local left_count, right_count = 0, 0
  for key, value in pairs(left) do
    if key ~= "position" then
      left_count = left_count + 1
      if not util.equal(value, right[key]) then return false end
    end
  end
  for key in pairs(right) do
    if key ~= "position" then right_count = right_count + 1 end
  end
  return left_count == right_count
end

local function layer_constraints(ctx)
  return {
    width = ctx.width,
    height = ctx.height,
    extent = ctx.extent,
    background_group = ctx.background_group,
    theme_generation = ctx.theme.generation or 0,
    image_generation = ctx.images.generation or 0,
    image_status = ctx.images.status,
    image_cell_width = ctx.images.cell_width,
    image_cell_height = ctx.images.cell_height,
  }
end

local function activate_layer_cache(ctx, key, descendants)
  ctx.active_layer_cache[key] = true
  for descendant in pairs(descendants or {}) do
    ctx.active_layer_cache[descendant] = true
  end
  for _, capture in ipairs(ctx.layer_cache_captures) do
    capture[key] = true
    for descendant in pairs(descendants or {}) do capture[descendant] = true end
  end
end

local function claim_fragment_images(ctx, value, path)
  for image_key in pairs(value.images) do
    require_value(not ctx.image_keys[image_key], path,
      ("duplicate image key %q"):format(image_key))
    ctx.image_keys[image_key] = true
  end
end

local function compile_positioned_layer(node, ctx, path, cache_key)
  local cache = ctx.layer_cache
  local constraints = layer_constraints(ctx)
  local cached = cache and cache[cache_key]
  if cached and same_positioned_content(cached.content, node)
      and util.equal(cached.constraints, constraints) then
    activate_layer_cache(ctx, cache_key, cached.descendants)
    claim_fragment_images(ctx, cached.fragment, path)
    if ctx.stats then
      ctx.stats.layer_reuses = (ctx.stats.layer_reuses or 0) + 1
    end
    return cached.fragment
  end

  activate_layer_cache(ctx, cache_key)
  local descendants = {}
  ctx.layer_cache_captures[#ctx.layer_cache_captures + 1] = descendants
  local value = compile_node(node, ctx, path)
  ctx.layer_cache_captures[#ctx.layer_cache_captures] = nil
  if ctx.stats then
    ctx.stats.layer_compilations = (ctx.stats.layer_compilations or 0) + 1
  end
  if cache then
    cache[cache_key] = {
      content = node,
      constraints = constraints,
      descendants = descendants,
      fragment = value,
    }
  end
  return value
end

local function compile_container(node, ctx, path)
  require_value(node.position == nil or ctx.positioned == true,
    path .. ".position", "is only valid in a parent container's layers")
  local border = border_spec(node.border, ctx, path .. ".border")
  local border_size = border and 1 or 0
  local shadow
  if node.shadow ~= nil and node.shadow ~= false then
    require_value(type(node.shadow) == "table", path .. ".shadow",
      "must be a table")
    local character = node.shadow.character or " "
    require_value(type(character) == "string"
        and util.display_width(character) == 1,
      path .. ".shadow.character", "must be one display cell")
    shadow = {
      row = integer(node.shadow.row or 1, path .. ".shadow.row", 0),
      col = integer(node.shadow.col or 2, path .. ".shadow.col", 0),
      character = character,
      group = box_group(node.shadow, ctx, path .. ".shadow"),
    }
    require_value(shadow.group ~= nil, path .. ".shadow",
      "must specify a style or group")
  end

  local reserved_width = border_size * 2 + (shadow and shadow.col or 0)
  local width = node.width == nil
      and math.max(1, ctx.width - reserved_width)
    or integer(node.width, path .. ".width", 1)
  local box_width = width + border_size * 2
  local outer_width = box_width + (shadow and shadow.col or 0)
  if not ctx.positioned then
    require_value(outer_width <= ctx.width, path .. ".width",
      "exceeds available width")
  end
  local explicit_height = node.height
  if explicit_height ~= nil then
    explicit_height = integer(explicit_height, path .. ".height", 1)
  end
  require_value(node.child ~= nil or explicit_height ~= nil,
    path .. ".height", "is required without a child")
  require_value(node.layers == nil or type(node.layers) == "table"
      and vim.islist(node.layers), path .. ".layers", "must be a list")

  local pad = padding(node.padding, path .. ".padding")
  require_value(pad.left + pad.right < width, path .. ".padding",
    "horizontal padding leaves no content width")

  local child_ctx = util.copy(ctx)
  child_ctx.width = width - pad.left - pad.right
  child_ctx.positioned = nil
  child_ctx.scene_path = ctx.scene_path .. "/" .. node.key .. "/child"
  if node.background ~= nil then
    child_ctx.background_group = ctx.theme:group(node.background)
  end
  local child = node.child and compile_node(
    node.child, child_ctx, path .. ".child") or fragment()
  require_value(#child.virtuals == 0, path .. ".child",
    "cannot contain virtual lines")
  local height = explicit_height or math.max(
    1, #child.lines + pad.top + pad.bottom)
  require_value(pad.top + pad.bottom < height, path .. ".padding",
    "vertical padding leaves no content height")
  local box_height = height + border_size * 2
  local outer_height = box_height + (shadow and shadow.row or 0)
  local content_clip = {
    row = border_size,
    col = border_size,
    width = width,
    height = height,
  }

  local layers, next_id, next_order = {}, 0, 0
  local function add_layer(value)
    next_id = next_id + 1
    value.id = next_id
    value.order = value.order or next_order
    next_order = next_order + 1
    layers[#layers + 1] = value
    return value
  end
  if shadow then
    local shadow_fragment = solid_fragment(
      box_width, box_height, shadow.character, shadow.group)
    add_layer({
      row = shadow.row,
      col = shadow.col,
      zindex = -math.huge,
      width = box_width,
      lines = shadow_fragment.lines,
      coverage = shadow_fragment.coverage,
      fragment = shadow_fragment,
    })
  end
  if node.background ~= nil then
    local background = solid_fragment(
      width, height, " ", ctx.theme:group(node.background))
    add_layer({
      row = border_size,
      col = border_size,
      zindex = -math.huge,
      width = width,
      lines = background.lines,
      coverage = background.coverage,
      fragment = background,
    })
  end
  add_layer({
    row = border_size + pad.top,
    col = border_size + pad.left,
    zindex = 0,
    width = child_ctx.width,
    lines = child.lines,
    coverage = child.coverage,
    fragment = child,
    clip = content_clip,
  })
  local layer_keys = {}
  local container_path = ctx.scene_path .. "/" .. node.key
  for index, layer_node in ipairs(node.layers or {}) do
    local layer_path = ("%s.layers[%d]"):format(path, index)
    require_value(type(layer_node) == "table"
        and layer_node.type == "container", layer_path,
      "must be a container")
    local position = layer_node.position
    require_value(type(position) == "table"
        and position.mode == "absolute", layer_path .. ".position",
      "must be absolute")
    require_value(not layer_keys[layer_node.key], layer_path .. ".key",
      "must be unique within its parent container")
    layer_keys[layer_node.key] = true
    local layer_width = integer(
      layer_node.width, layer_path .. ".width", 1)
    local layer_height = integer(
      layer_node.height, layer_path .. ".height", 1)
    local layer_ctx = util.copy(ctx)
    layer_ctx.width = layer_width
    layer_ctx.height = layer_height
    layer_ctx.positioned = true
    layer_ctx.scene_path = container_path .. "/layers"
    local compiled = compile_positioned_layer(
      layer_node, layer_ctx, layer_path,
      container_path .. "/layer:" .. layer_node.key)
    require_value(#compiled.virtuals == 0, layer_path,
      "cannot contain virtual lines")
    local layer_row = signed_integer(
      position.row, layer_path .. ".position.row")
    local layer_col = signed_integer(
      position.col, layer_path .. ".position.col")
    add_layer({
      key = layer_node.key,
      row = border_size + layer_row,
      col = border_size + layer_col,
      zindex = position.zindex == nil and 0
        or signed_integer(position.zindex, layer_path .. ".position.zindex"),
      position_offset = border_size,
      width = vim.fn.strdisplaywidth(compiled.lines[1] or ""),
      lines = compiled.lines,
      coverage = compiled.coverage,
      fragment = compiled,
      clip = content_clip,
    })
  end
  if border then
    local border_value = border_fragment(width, height, border)
    add_layer({
      row = 0,
      col = 0,
      zindex = math.huge,
      width = box_width,
      lines = border_value.lines,
      coverage = border_value.coverage,
      fragment = border_value,
    })
  end

  local scene = {
    key = node.key,
    width = outer_width,
    height = outer_height,
    layers = layers,
    positions = {},
    retained = node == ctx.retained_scene_root,
  }
  for index, layer in ipairs(layers) do
    if layer.key then scene.positions[layer.key] = index end
    if fragment_has_spatial_metadata(layer.fragment) then
      scene.spatial = true
    end
  end
  local result
  if scene.retained then
    result = project_retained_scene(scene)
  else
    result = project_scene(scene)
  end
  if ctx.stats and not scene.retained then
    ctx.stats.composed_cells = (ctx.stats.composed_cells or 0)
      + outer_width * outer_height
  end
  return result
end

local function compile_responsive(node, ctx, path)
  require_value(type(node.variants) == "table" and #node.variants > 0,
    path .. ".variants", "must be a non-empty list")
  for index, variant in ipairs(node.variants) do
    local variant_path = ("%s.variants[%d]"):format(path, index)
    require_value(type(variant) == "table", variant_path, "must be a table")
    local matches = true
    for _, dimension in ipairs({ "width", "height" }) do
      local value = ctx[dimension]
      local minimum = variant["min_" .. dimension]
      local maximum = variant["max_" .. dimension]
      if minimum ~= nil then
        integer(minimum, variant_path .. ".min_" .. dimension, 1)
        matches = matches and value ~= nil and value >= minimum
      end
      if maximum ~= nil then
        integer(maximum, variant_path .. ".max_" .. dimension, 1)
        matches = matches and value ~= nil and value <= maximum
      end
    end
    if matches then return compile_node(variant.node, ctx, variant_path .. ".node") end
  end
  fail(path, "no responsive variant matches the current dimensions")
end

local function compile_source(node, ctx, path)
  if node.path ~= nil then require_value(type(node.path) == "string", path .. ".path", "must be a string") end
  if node.language ~= nil then
    require_value(type(node.language) == "string", path .. ".language", "must be a string")
  end
  local child = compile_node(node.child, ctx, path .. ".child")
  child.source_ranges[#child.source_ranges + 1] = {
    key = node.key,
    first = 0,
    last = #child.lines,
    rectangles = content_rectangles(child),
    linewise = true,
    path = node.path,
    language = node.language,
  }
  return child
end

local function image_fallback(node, ctx, path, width, height, reserve_height)
  local fallback = node.fallback or {
    type = "text",
    key = node.key .. ":fallback",
    runs = { { text = "[Image unavailable: " .. node.alt .. "]", style = "muted" } },
    wrap = "word",
  }
  require_value(fallback.type ~= "image", path .. ".fallback", "must not be an image")
  local child_ctx = util.copy(ctx)
  child_ctx.width = width
  local result = compile_node(fallback, child_ctx, path .. ".fallback")
  while #result.lines > height do table.remove(result.lines) end
  for row in pairs(result.coverage) do
    if row >= height then result.coverage[row] = nil end
  end
  local decorations = {}
  for _, decoration in ipairs(result.decorations) do
    if decoration.row < height then
      if decoration.end_col then
        decoration.end_col = math.min(
          decoration.end_col, #(result.lines[decoration.row + 1] or ""))
      end
      if decoration.whole_line or decoration.end_col == nil
          or decoration.end_col > decoration.col then
        decorations[#decorations + 1] = decoration
      end
    end
  end
  result.decorations = decorations
  for _, values in ipairs({ result.targets, result.scopes }) do
    for key, value in pairs(values) do
      local rectangles = {}
      for _, rect in ipairs(value.rectangles) do
        if rect.row < height then
          rect.height = math.min(rect.height, height - rect.row)
          rectangles[#rectangles + 1] = rect
        end
      end
      if #rectangles == 0 then
        values[key] = nil
      else
        value.rectangles = rectangles
        if value.point and value.point.row >= height then
          value.point = { row = rectangles[1].row, col = rectangles[1].col }
        end
      end
    end
  end
  local ranges = {}
  for _, range in ipairs(result.source_ranges) do
    if range.first < height then
      local rectangles = {}
      for _, rectangle in ipairs(range.rectangles or {}) do
        local bottom = math.min(
          rectangle.row + rectangle.height, height)
        if rectangle.row < bottom then
          rectangles[#rectangles + 1] = {
            row = rectangle.row,
            col = rectangle.col,
            width = rectangle.width,
            height = bottom - rectangle.row,
          }
        end
      end
      if range.rectangles == nil or #rectangles > 0 then
        range.last = math.min(range.last, height)
        range.rectangles = range.rectangles and rectangles or nil
        ranges[#ranges + 1] = range
      end
    end
  end
  result.source_ranges = ranges
  if reserve_height then
    while #result.lines < height do result.lines[#result.lines + 1] = "" end
  end
  for index, line in ipairs(result.lines) do
    local missing = width - util.display_width(line)
    result.lines[index] = line .. string.rep(" ", math.max(0, missing))
    add_coverage(result, index - 1, 0, width)
  end
  return result
end

local function rounded(value)
  return math.max(1, math.floor(value + 0.5))
end

local function image_size(node, ctx, path, resource)
  local width_mode = node.width
  require_value(width_mode == "fill" or width_mode == "native"
      or type(width_mode) == "number",
    path .. ".width", "must be an integer, fill, or native")
  local width
  if width_mode == "fill" then
    width = ctx.width
  elseif width_mode == "native" then
    width = resource and math.max(1, math.ceil(
      resource.width / ctx.images.cell_width)) or ctx.width
    width = math.min(width, ctx.width)
  else
    width = integer(width_mode, path .. ".width", 1)
    require_value(width <= ctx.width, path .. ".width",
      "exceeds available width")
  end

  local height_mode = node.height
  require_value(height_mode == "auto" or type(height_mode) == "number",
    path .. ".height", "must be an integer or auto")
  local maximum = node.max_height
  if maximum ~= nil then
    maximum = integer(maximum, path .. ".max_height", 1)
    require_value(height_mode == "auto", path .. ".max_height",
      "requires auto height")
  end
  local height
  if height_mode == "auto" then
    height = resource and rounded(resource.height / resource.width
      * width * ctx.images.cell_width / ctx.images.cell_height) or 1
    if maximum and height > maximum then
      height = maximum
      if type(width_mode) ~= "number" then
        width = math.min(width, rounded(resource.width / resource.height
          * height * ctx.images.cell_height / ctx.images.cell_width))
      end
    end
  else
    height = integer(height_mode, path .. ".height", 1)
  end
  return width, height
end

local function compile_image(node, ctx, path)
  require_value(not ctx.image_keys[node.key], path .. ".key", "duplicates an image key")
  ctx.image_keys[node.key] = true
  require_value(type(node.source) == "table", path .. ".source", "must be a table")
  require_value(util.nonempty_string(node.alt), path .. ".alt", "must be a non-empty string")
  local desired_identity = require("applet.image.source").identity(node.source)
  local identity = desired_identity
  local resource = ctx.images.resources
    and ctx.images.resources[desired_identity]
  if not resource and ctx.images.status == "available" then
    local presented = ctx.images.presented[node.key]
    local presented_identity = type(presented) == "string"
      and presented or nil
    local presented_resource = presented_identity and ctx.images.resources
      and ctx.images.resources[presented_identity] or nil
    if presented_resource then
      identity, resource = presented_identity, presented_resource
    end
  end
  local available = ctx.images.status == "available" and resource ~= nil
  if available and (node.width == "native" or node.height == "auto") then
    require_value(type(resource.width) == "number" and resource.width > 0
        and type(resource.height) == "number" and resource.height > 0,
      path .. ".source", "has invalid prepared dimensions")
  end
  local width, height = image_size(
    node, ctx, path, available and resource or nil)
  local fit = node.fit or "contain"
  require_value(fit == "contain" or fit == "cover" or fit == "fill",
    path .. ".fit", "must be contain, cover, or fill")
  local align = node.align or "center"
  require_value(align == "left" or align == "center" or align == "right",
    path .. ".align", "must be left, center, or right")
  local fallback = image_fallback(
    node, ctx, path, width, height, available)
  local col = align == "right" and (ctx.width - width)
    or (align == "center" and math.floor((ctx.width - width) / 2) or 0)
  local result = fragment()
  local byte_cols = {}
  for index, line in ipairs(fallback.lines) do
    byte_cols[index] = col
    result.lines[index] = string.rep(" ", col) .. line
      .. string.rep(" ", ctx.width - col - width)
  end
  append_metadata(result, fallback, 0, col, byte_cols, true)
  if available then
    for row = 0, height - 1 do
      add_coverage(result, row, col, col + width)
    end
    result.images[node.key] = {
      source_identity = identity,
      row = 0,
      col = col,
      width = width,
      height = height,
      cell_width = ctx.images.cell_width,
      cell_height = ctx.images.cell_height,
      fit = fit,
      visible = { { row = 0, col = 0, width = width, height = height } },
    }
  end
  return result
end

local function compile_virtual(node, ctx, path)
  local placement = node.placement or "above-end"
  require_value(placement == "above" or placement == "below"
      or placement == "above-end" or placement == "below-end",
    path .. ".placement", "has an unknown placement")
  require_value(type(node.lines) == "table", path .. ".lines", "must be a list")
  local lines = {}
  for line_index, runs in ipairs(node.lines) do
    require_value(type(runs) == "table", ("%s.lines[%d]"):format(path, line_index),
      "must be a list")
    local chunks = {}
    for run_index, run in ipairs(runs) do
      local run_path = ("%s.lines[%d][%d]"):format(path, line_index, run_index)
      local group = resolve_group(run, ctx.theme, run_path)
      util.characters(run.text, run_path .. ".text")
      chunks[#chunks + 1] = { run.text, group }
    end
    lines[#lines + 1] = chunks
  end
  local result = fragment()
  result.virtuals[1] = { key = node.key, row = 0, placement = placement, lines = lines }
  return result
end

local focus_positions = {
  overlay = true,
  eol = true,
  right_align = true,
  inline = true,
}

local function compile_target_decorations(value, child, ctx, path)
  if value == nil then return {} end
  require_value(type(value) == "table" and vim.islist(value), path,
    "must be a list")
  local result = {}
  for index, decoration in ipairs(value) do
    local item_path = ("%s[%d]"):format(path, index)
    require_value(type(decoration) == "table", item_path,
      "must be a table")
    local row
    if decoration.row == "end" then
      row = #child.lines
    else
      row = integer(decoration.row, item_path .. ".row", 0)
      require_value(row <= #child.lines, item_path .. ".row",
        "must address the target or its following boundary")
    end
    local col = decoration.col == nil and 0
      or integer(decoration.col, item_path .. ".col", 0)
    require_value(decoration.position == nil
        or focus_positions[decoration.position],
      item_path .. ".position", "is unknown")
    local win_col = decoration.win_col
    if win_col ~= nil then
      integer(win_col, item_path .. ".win_col", 0)
      require_value(decoration.position == nil,
        item_path, "cannot combine position and win_col")
    end
    local priority = decoration.priority == nil and 200
      or integer(decoration.priority, item_path .. ".priority", 0)
    require_value(type(decoration.chunks) == "table"
        and vim.islist(decoration.chunks) and #decoration.chunks > 0,
      item_path .. ".chunks", "must be a non-empty list")
    local chunks = {}
    for chunk_index, run in ipairs(decoration.chunks) do
      local run_path = ("%s.chunks[%d]"):format(item_path, chunk_index)
      local group = resolve_group(run, ctx.theme, run_path)
      util.characters(run.text, run_path .. ".text")
      chunks[#chunks + 1] = { run.text, group }
    end
    result[#result + 1] = {
      row = row,
      col = col,
      chunks = chunks,
      position = decoration.position,
      win_col = win_col,
      priority = priority,
    }
  end
  return result
end

compile_node = function(node, ctx, path)
  require_value(type(node) == "table", path, "must be a node")
  require_value(NODE_TYPES[node.type], path .. ".type", "is unknown")
  require_value(util.nonempty_string(node.key), path .. ".key", "must be a non-empty string")
  if node.type == "region" then fail(path, "region is only valid at the Tree root") end
  if node.type == "text" then return compile_text(node, ctx, path) end
  if node.type == "column" then return compile_column(node, ctx, path) end
  if node.type == "row" then return compile_row(node, ctx, path) end
  if node.type == "container" then return compile_container(node, ctx, path) end
  if node.type == "responsive" then return compile_responsive(node, ctx, path) end
  if node.type == "panel" then return compile_panel(node, ctx, path) end
  if node.type == "source" then return compile_source(node, ctx, path) end
  if node.type == "image" then return compile_image(node, ctx, path) end
  if node.type == "virtual" then return compile_virtual(node, ctx, path) end
  if node.type == "target" then
    require_value(node.disabled == nil or type(node.disabled) == "boolean",
      path .. ".disabled", "must be a boolean")
    if node.group ~= nil then require_value(util.nonempty_string(node.group), path .. ".group", "must be non-empty") end
    if node.role ~= nil then require_value(util.nonempty_string(node.role), path .. ".role", "must be non-empty") end
    if node.action ~= nil then validate_action(node.action, path .. ".action") end
    local child = compile_node(node.child, ctx, path .. ".child")
    require_value(node.focus == nil or type(node.focus) == "table",
      path .. ".focus", "must be a table")
    local focus = node.focus or {}
    local point = { row = 0, col = 0 }
    for index, line in ipairs(child.lines) do
      if line:find("%S") then
        point.row = index - 1
        break
      end
    end
    child.targets[node.key] = {
      key = node.key,
      group = node.group,
      role = node.role,
      disabled = node.disabled == true,
      action = node.action,
      focus_style = node.focus_style and ctx.theme:group(node.focus_style) or nil,
      focus = {
        active = compile_target_decorations(
          focus.active, child, ctx, path .. ".focus.active"),
        inactive = compile_target_decorations(
          focus.inactive, child, ctx, path .. ".focus.inactive"),
      },
      point = point,
      rectangles = content_rectangles(child),
    }
    child.target_order[#child.target_order + 1] = node.key
    child.hit_order[#child.hit_order + 1] = node.key
    return child
  end
  if node.type == "scope" then return compile_scope(node, ctx, path) end
end

local function compile_chrome(chrome, theme)
  chrome = chrome or {}
  require_value(type(chrome) == "table", "tree.chrome", "must be a table")
  require_value(chrome.options == nil or type(chrome.options) == "table",
    "tree.chrome.options", "must be a table")
  local result = { options = util.copy(chrome.options) }
  local positions = { left = true, center = true, right = true }
  for _, field in ipairs({ "title_pos", "footer_pos" }) do
    if chrome[field] ~= nil then
      require_value(positions[chrome[field]] == true,
        "tree.chrome." .. field, "must be left, center, or right")
      result[field] = chrome[field]
    end
  end
  for _, field in ipairs({ "title", "footer" }) do
    if chrome[field] ~= nil then
      require_value(type(chrome[field]) == "table", "tree.chrome." .. field, "must be a list")
      result[field] = {}
      for index, run in ipairs(chrome[field]) do
        local path = ("tree.chrome.%s[%d]"):format(field, index)
        local group = resolve_group(run, theme, path)
        util.characters(run.text, path .. ".text")
        result[field][#result[field] + 1] = { run.text, group }
      end
    end
  end
  return result
end

local presentation_rows

local function slice_fragment(value, first, last)
  local result = fragment()
  for index = first + 1, last do result.lines[#result.lines + 1] = value.lines[index] end
  for row, intervals in pairs(value.coverage or {}) do
    if row >= first and row < last then
      for _, interval in ipairs(intervals) do
        add_coverage(result, row - first, interval.first, interval.last)
      end
    end
  end
  for _, decoration in ipairs(value.decorations) do
    if decoration.row >= first and decoration.row < last then
      local shifted = util.copy(decoration)
      shifted.row = shifted.row - first
      result.decorations[#result.decorations + 1] = shifted
    end
  end
  local function slice_rectangles(rectangles)
    local sliced = {}
    for _, rect in ipairs(rectangles) do
      local top = math.max(rect.row, first)
      local bottom = math.min(rect.row + rect.height, last)
      if top < bottom then
        sliced[#sliced + 1] = {
          row = top - first,
          col = rect.col,
          width = rect.width,
          height = bottom - top,
        }
      end
    end
    return sliced
  end
  for key, target in pairs(value.targets) do
    local rectangles = slice_rectangles(target.rectangles)
    if #rectangles > 0 then
      result.targets[key] = util.copy(target)
      result.targets[key].rectangles = rectangles
      if target.point.row >= first and target.point.row < last then
        result.targets[key].point = {
          row = target.point.row - first,
          col = target.point.col,
        }
      else
        result.targets[key].point = {
          row = rectangles[1].row,
          col = rectangles[1].col,
        }
      end
      result.targets[key].focus = {}
      for _, state in ipairs({ "active", "inactive" }) do
        local decorations = {}
        for _, decoration in ipairs(target.focus and target.focus[state] or {}) do
          if decoration.row >= first and decoration.row < last then
            local shifted = util.copy(decoration)
            shifted.row = shifted.row - first
            decorations[#decorations + 1] = shifted
          end
        end
        result.targets[key].focus[state] = decorations
      end
    end
  end
  for _, key in ipairs(value.target_order) do
    if result.targets[key] then result.target_order[#result.target_order + 1] = key end
  end
  for _, key in ipairs(value.hit_order or value.target_order) do
    if result.targets[key] then result.hit_order[#result.hit_order + 1] = key end
  end
  for key, scope in pairs(value.scopes) do
    local rectangles = slice_rectangles(scope.rectangles)
    if #rectangles > 0 or scope.root or scope.modal then
      result.scopes[key] = util.copy(scope)
      result.scopes[key].rectangles = rectangles
    end
  end
  for key, image in pairs(value.images) do
    local visible = {}
    for _, rectangle in ipairs(image.visible or { {
      row = 0,
      col = 0,
      width = image.width,
      height = image.height,
    } }) do
      local top = math.max(image.row + rectangle.row, first)
      local bottom = math.min(
        image.row + rectangle.row + rectangle.height, last)
      if top < bottom then
        visible[#visible + 1] = {
          row = top - image.row,
          col = rectangle.col,
          width = rectangle.width,
          height = bottom - top,
        }
      end
    end
    if #visible > 0 then
      result.images[key] = util.copy(image)
      result.images[key].row = image.row - first
      result.images[key].visible = canonical_rectangles(visible)
    end
  end
  for _, range in ipairs(value.source_ranges) do
    local rectangles = slice_rectangles(range.rectangles)
    if #rectangles > 0 then
      local shifted = util.copy(range)
      shifted.rectangles = rectangles
      shifted.first, shifted.last = rectangles[1].row,
        rectangles[1].row + rectangles[1].height
      for _, rectangle in ipairs(rectangles) do
        shifted.first = math.min(shifted.first, rectangle.row)
        shifted.last = math.max(
          shifted.last, rectangle.row + rectangle.height)
      end
      result.source_ranges[#result.source_ranges + 1] = shifted
    end
  end
  return result
end

local function reset_regions(value, key)
  value.regions = { {
    key = key,
    first = 0,
    last = #value.lines,
    lines = value.lines,
    decorations = value.decorations,
    coverage = value.coverage,
    targets = value.targets,
    scopes = value.scopes,
    images = value.images,
    source_ranges = value.source_ranges,
    virtuals = value.virtuals,
  } }
end

local function ensure_physical_line(value)
  if #value.lines > 0 then return end
  value.lines = { "" }
  local region = value.regions[#value.regions]
  if region then
    region.last = 1
    region.lines = value.lines
  end
end

local function apply_viewport_overflow(value, root, ctx, height)
  if presentation_rows(value) <= height then return value end
  local policy = root.overflow or "error"
  require_value(policy == "error" or policy == "clip" or policy == "collapse",
    "tree.root.overflow", "must be error, clip, or collapse")
  if policy == "error" then return value end
  if policy == "collapse" then
    require_value(type(root.collapse) == "table", "tree.root.collapse",
      "is required for collapse overflow")
    local collapsed = compile_node(root.collapse, ctx, "tree.root.collapse")
    require_value(presentation_rows(collapsed) <= height, "tree.root.collapse",
      "exceeds the viewport height")
    reset_regions(collapsed, root.key .. ":collapsed")
    return collapsed
  end
  local marker = root.overflow_marker or {
    type = "text",
    key = root.key .. ":overflow",
    runs = { { text = "…", style = "muted" } },
    wrap = "none",
  }
  local compiled_marker = compile_node(marker, ctx, "tree.root.overflow_marker")
  require_value(#compiled_marker.virtuals == 0, "tree.root.overflow_marker",
    "must use physical lines")
  local virtual_rows = presentation_rows(value) - #value.lines
  local budget = height - virtual_rows - #compiled_marker.lines
  require_value(budget >= 0, "tree.root.overflow_marker",
    "leaves no viewport space")
  local from = root.clip_from or "end"
  require_value(from == "start" or from == "end", "tree.root.clip_from",
    "must be start or end")
  local result = fragment()
  if from == "end" then
    append_vertical(result, slice_fragment(value, 0, math.min(budget, #value.lines)), 0)
    append_vertical(result, compiled_marker, 0)
  else
    append_vertical(result, compiled_marker, 0)
    append_vertical(result, slice_fragment(value,
      math.max(0, #value.lines - budget), #value.lines), 0)
  end
  result.virtuals = value.virtuals
  reset_regions(result, root.key .. ":clipped")
  return result
end

local function normalize_regions(root)
  local wrappers = {}
  while root.type == "scope" do
    wrappers[#wrappers + 1] = root
    root = root.child
  end
  if root.type == "region" then return { root }, wrappers end
  if root.type == "column" then
    local has_region, has_other = false, false
    for _, child in ipairs(root.children or {}) do
      if child.type == "region" then has_region = true else has_other = true end
    end
    if has_region and has_other then
      fail("tree.root.children", "cannot mix region and non-region nodes")
    end
    if has_region then return root.children, wrappers, root.gap or 0 end
  end
  return nil, wrappers
end

local function add_root_scopes(value, wrappers)
  for index = #wrappers, 1, -1 do
    local wrapper = wrappers[index]
    require_value(util.nonempty_string(wrapper.key), "tree.root.scope.key", "must be non-empty")
    local bindings, claimed = {}, {}
    for binding_index, binding in ipairs(wrapper.bindings or {}) do
      local path = ("tree.root.bindings[%d]"):format(binding_index)
      local mode = binding.mode or "n"
      require_value(util.nonempty_string(mode), path .. ".mode", "must be non-empty")
      require_value(util.nonempty_string(binding.lhs), path .. ".lhs", "must be non-empty")
      validate_action(binding.action, path .. ".action")
      local normalized = util.copy(binding)
      normalized.mode, normalized.count = mode, binding.count or false
      local id = binding_id(normalized)
      require_value(not claimed[id], path, "duplicates a binding in this scope")
      claimed[id], bindings[#bindings + 1] = true, normalized
    end
    require_value(value.scopes[wrapper.key] == nil, "tree", "duplicate scope key " .. wrapper.key)
    value.scopes[wrapper.key] = {
      key = wrapper.key,
      parent = index > 1 and wrappers[index - 1].key or nil,
      modal = wrapper.modal == true,
      root = index == 1,
      rectangles = index == 1 and {} or content_rectangles(value),
      bindings = bindings,
    }
    for key, scope in pairs(value.scopes) do
      if key ~= wrapper.key and scope.parent == nil then
        local nested = util.copy(scope)
        nested.parent = wrapper.key
        value.scopes[key] = nested
      end
    end
  end
end

local function dependency_resource(resource)
  return resource and {
    id = resource.id,
    width = resource.width,
    height = resource.height,
  } or false
end

local function image_dependency(key, identity, images)
  local desired = images.resources and images.resources[identity]
  local presented = not desired and images.presented
    and images.presented[key] or nil
  local presented_resource = type(presented) == "string"
    and images.status == "available" and images.resources
    and images.resources[presented] or nil
  return {
    desired_identity = identity,
    status = images.status,
    cell_width = images.cell_width,
    cell_height = images.cell_height,
    desired = dependency_resource(desired),
    presented = presented_resource and {
      source_identity = presented,
      resource = dependency_resource(presented_resource),
    } or false,
  }
end

local function image_dependencies(node, images, result, seen)
  if type(node) ~= "table" or seen[node] then return end
  seen[node] = true
  if node.type == "image" then
    local ok, identity = pcall(require("applet.image.source").identity, node.source)
    if ok then
      local key = node.key or "?"
      result[key] = image_dependency(key, identity, images)
    else
      result[node.key or "?"] = "invalid"
    end
  end
  for key, value in pairs(node) do
    if key ~= "source" or node.type ~= "image" then
      if type(value) == "table" then image_dependencies(value.node or value, images, result, seen) end
    end
  end
  seen[node] = nil
end

local function dependency_keys(dependencies)
  local result = {}
  for key, dependency in pairs(dependencies) do
    result[key] = type(dependency) == "table" and {
      desired_identity = dependency.desired_identity,
    } or dependency
  end
  return result
end

local function resolve_image_dependencies(keys, images)
  local result = {}
  for key, dependency in pairs(keys) do
    result[key] = image_dependency(
      key, dependency.desired_identity, images)
  end
  return result
end

local function region_constraints(ctx, dependencies)
  return {
    width = ctx.width,
    height = ctx.height,
    extent = ctx.extent,
    theme_generation = ctx.theme.generation or 0,
    images = next(dependencies) and dependencies or false,
  }
end

local function same_constraints(left, right)
  return left and right
    and left.width == right.width
    and left.height == right.height
    and left.extent == right.extent
    and left.theme_generation == right.theme_generation
    and util.equal(left.images, right.images)
end

presentation_rows = function(value)
  local count = #value.lines
  for _, virtual in ipairs(value.virtuals) do count = count + #virtual.lines end
  return count
end

local function rectangles_overlap(left, right)
  for _, a in ipairs(left) do
    for _, b in ipairs(right) do
      if a.row < b.row + b.height and b.row < a.row + a.height
          and a.col < b.col + b.width and b.col < a.col + a.width then
        return true
      end
    end
  end
  return false
end

local function validate_layout(value, extent, height)
  local modal = {}
  local pairs_union = {}
  for key, scope in pairs(value.scopes) do
    if scope.modal then
      modal[#modal + 1] = key
    end
    for _, binding in ipairs(scope.bindings) do
      pairs_union[binding_id(binding)] = { mode = binding.mode, lhs = binding.lhs }
    end
  end
  local function ancestor(parent, child)
    local current = value.scopes[child]
    while current and current.parent do
      if current.parent == parent then return true end
      current = value.scopes[current.parent]
    end
    return false
  end
  for left = 1, #modal do
    for right = left + 1, #modal do
      require_value(ancestor(modal[left], modal[right])
          or ancestor(modal[right], modal[left]), "tree",
        "contains more than one modal scope outside one nested path")
    end
  end
  local scope_keys = {}
  for key in pairs(value.scopes) do scope_keys[#scope_keys + 1] = key end
  table.sort(scope_keys)
  for left_index = 1, #scope_keys do
    local left = value.scopes[scope_keys[left_index]]
    if not left.modal then
      local claims = {}
      for _, binding in ipairs(left.bindings) do claims[binding_id(binding)] = true end
      for right_index = left_index + 1, #scope_keys do
        local right = value.scopes[scope_keys[right_index]]
        if not right.modal and left.parent == right.parent
            and rectangles_overlap(left.rectangles, right.rectangles) then
          for _, binding in ipairs(right.bindings) do
            require_value(not claims[binding_id(binding)], "tree",
              ("sibling scopes %q and %q claim the same mapping"):format(
                left.key, right.key))
          end
        end
      end
    end
  end
  if extent == "viewport" then
    require_value(height ~= nil, "layout.height", "is required for viewport extent")
    require_value(presentation_rows(value) <= height, "tree.root",
      "viewport content exceeds its height")
  end
  value.binding_pairs = {}
  for _, pair in pairs(pairs_union) do value.binding_pairs[#value.binding_pairs + 1] = pair end
  table.sort(value.binding_pairs, function(left, right)
    return left.mode == right.mode and left.lhs < right.lhs or left.mode < right.mode
  end)
end

local function compile_view(tree, targets)
  local view = tree.view or {}
  require_value(type(view) == "table", "tree.view", "must be a table")
  validate_plain(view, "tree.view", {})
  local scroll = view.scroll or "preserve"
  require_value(scroll == "preserve" or scroll == "follow_end",
    "tree.view.scroll", "must be preserve or follow_end")
  if view.initial_target ~= nil then
    require_value(util.nonempty_string(view.initial_target),
      "tree.view.initial_target", "must be a non-empty string")
    require_value(targets[view.initial_target] ~= nil,
      "tree.view.initial_target", "must name a target")
  end
  if view.target_intent ~= nil then
    require_value(type(view.target_intent) == "table", "tree.view.target_intent",
      "must be a table")
    require_value(util.nonempty_string(view.target_intent.key),
      "tree.view.target_intent.key", "must be a non-empty string")
    for field in pairs(view.target_intent) do
      require_value(field == "key" or field == "select" or field == "reveal",
        "tree.view.target_intent." .. tostring(field),
        "is not a recognized field")
    end
    require_value(util.nonempty_string(view.target_intent.select),
      "tree.view.target_intent.select", "must be a non-empty string")
    require_value(targets[view.target_intent.select] ~= nil,
      "tree.view.target_intent.select", "must name a target")
    if view.target_intent.reveal ~= nil then
      require_value(util.nonempty_string(view.target_intent.reveal),
        "tree.view.target_intent.reveal", "must be a non-empty string")
      require_value(targets[view.target_intent.reveal] ~= nil,
        "tree.view.target_intent.reveal", "must name a target")
    end
  end
  local result = util.copy(view)
  result.scroll = scroll
  return result
end

local function compile_edit(tree)
  if tree.edit == nil then return nil end
  require_value(type(tree.edit) == "table", "tree.edit", "must be a table")
  validate_plain(tree.edit, "tree.edit", {})
  for key in pairs(tree.edit) do
    require_value(key == "on_change" or key == "mask", "tree.edit." .. tostring(key),
      "is not a recognized field")
  end
  if tree.edit.on_change ~= nil then
    validate_action(tree.edit.on_change, "tree.edit.on_change")
  end
  if tree.edit.mask ~= nil then
    require_value(type(tree.edit.mask) == "string"
        and util.display_width(tree.edit.mask) == 1,
      "tree.edit.mask", "must be one display cell")
  end
  return util.copy(tree.edit)
end

local function scene_scope_keys(scene)
  local result = {}
  for _, layer in ipairs(scene.layers) do
    for key in pairs(layer.fragment.scopes) do result[key] = true end
  end
  return result
end

local function replace_scene_projection(layout, scene)
  local projected = project_retained_scene(scene, layout)
  local dynamic_scopes = scene_scope_keys(scene)
  for key, scope in pairs(layout.scopes) do
    if not dynamic_scopes[key] then projected.scopes[key] = scope end
  end

  local result = util.copy(layout)
  for _, field in ipairs({
    "lines", "coverage", "cell_map", "decorations", "targets",
    "target_order", "hit_order", "scopes", "images", "source_ranges",
    "virtuals", "scene",
  }) do
    result[field] = projected[field]
  end
  result.regions = {}
  for index, region in ipairs(layout.regions) do
    local replacement = util.copy(region)
    replacement.first = index == 1 and 0 or region.first
    replacement.last = replacement.first + #projected.lines
    for _, field in ipairs({
      "lines", "coverage", "decorations", "targets", "scopes", "images",
      "source_ranges", "virtuals",
    }) do
      replacement[field] = projected[field]
    end
    result.regions[index] = replacement
  end
  return result
end

function M.project_scene(opts)
  opts = opts or {}
  require_value(type(opts) == "table", "project_scene",
    "options must be a table")
  local layout = opts.layout
  require_value(type(layout) == "table" and type(layout.scene) == "table",
    "project_scene.layout", "must be a retained container Layout")
  local scene = opts.scene
  require_value(type(scene) == "table" and scene.retained == true,
    "project_scene.scene", "must be retained placement state")
  return replace_scene_projection(layout, scene)
end

function M.reuse(opts)
  opts = opts or {}
  require_value(type(opts) == "table", "reuse", "options must be a table")
  local previous = opts.previous
  require_value(type(previous) == "table", "reuse.previous", "must be a Layout")
  local tree = opts.tree
  if tree and tree.type then tree = { root = tree } end
  require_value(type(tree) == "table", "tree", "must be a table")
  require_value(type(tree.root) == "table", "tree.root", "must be a node")
  local theme = opts.theme or require("applet.theme").new()
  local value = util.copy(previous)
  value.chrome = compile_chrome(tree.chrome, theme)
  value.view = compile_view(tree, value.targets)
  value.edit = compile_edit(tree)
  return value
end

function M.compile(opts)
  opts = opts or {}
  require_value(type(opts) == "table", "compile", "options must be a table")
  local width = integer(opts.width, "layout.width", 1)
  local extent = opts.extent or "document"
  require_value(extent == "document" or extent == "viewport",
    "layout.extent", "must be document or viewport")
  local height = opts.height
  if height ~= nil then integer(height, "layout.height", 1) end
  if extent == "viewport" then
    require_value(height ~= nil, "layout.height", "is required for viewport extent")
  end
  local tree = opts.tree
  if tree and tree.type then tree = { root = tree } end
  require_value(type(tree) == "table", "tree", "must be a table")
  validate_plain(tree, "tree", {}, true)
  require_value(type(tree.root) == "table", "tree.root", "must be a node")
  local theme = opts.theme or require("applet.theme").new()
  local supplied_images = opts.images or {
    status = "unavailable",
    generation = 0,
    resources = {},
  }
  local images = {
    status = supplied_images.status,
    generation = supplied_images.generation,
    cell_width = supplied_images.cell_width or 1,
    cell_height = supplied_images.cell_height or 1,
    resources = supplied_images.resources,
    presented = supplied_images.presented,
  }
  if images.presented == nil then images.presented = {} end
  require_value(type(images.presented) == "table",
    "images.presented", "must be a table")
  require_value(type(images.cell_width) == "number" and images.cell_width > 0,
    "images.cell_width", "must be positive")
  require_value(type(images.cell_height) == "number" and images.cell_height > 0,
    "images.cell_height", "must be positive")
  local stats = opts.stats
  require_value(opts.retain_scene == nil
      or type(opts.retain_scene) == "boolean",
    "compile.retain_scene", "must be a boolean")
  local cache = opts.cache
  if cache then
    require_value(type(cache) == "table", "compile.cache", "must be a table")
    cache.regions = cache.regions or {}
    cache.layers = cache.layers or {}
  end
  local retained_scene_root = tree.root
  while retained_scene_root.type == "scope" do
    retained_scene_root = retained_scene_root.child
  end
  if not opts.retain_scene or retained_scene_root.type ~= "container" then
    retained_scene_root = nil
  end
  local ctx = {
    width = width,
    height = height,
    extent = extent,
    theme = theme,
    images = images,
    image_keys = {},
    layer_cache = cache and cache.layers or nil,
    active_layer_cache = {},
    layer_cache_captures = {},
    scene_path = "root",
    retained_scene_root = retained_scene_root,
    stats = stats,
  }
  local explicit, wrappers, gap = normalize_regions(tree.root)
  local value = fragment()
  value.regions = {}
  if explicit then
    gap = integer(gap or 0, "tree.root.gap", 0)
    local region_keys = {}
    local active_cache = {}
    for index, region in ipairs(explicit) do
      local path = ("tree.root.regions[%d]"):format(index)
      require_value(util.nonempty_string(region.key), path .. ".key", "must be non-empty")
      require_value(not region_keys[region.key], path .. ".key", "must be unique")
      region_keys[region.key] = true
      if region.revision ~= nil then
        local kind = type(region.revision)
        require_value(kind == "string" or kind == "number", path .. ".revision",
          "must be a string or number")
      end
      local child, cache_entry
      local cached = cache and cache.regions[region.key]
      local dependencies, dependencies_keys
      if cached and cached.revision == region.revision
          and cached.dependency_keys then
        dependencies_keys = cached.dependency_keys
        dependencies = resolve_image_dependencies(dependencies_keys, images)
      else
        dependencies = {}
        image_dependencies(region.child, images, dependencies, {})
        dependencies_keys = dependency_keys(dependencies)
      end
      local constraints = region_constraints(ctx, dependencies)
      if region.revision ~= nil and cached
          and cached.revision == region.revision
          and same_constraints(cached.constraints, constraints)
          and cached.fragment then
        child = cached.fragment
        cache_entry = cached
        for image_key in pairs(cached.image_keys) do
          require_value(not ctx.image_keys[image_key], path,
            ("duplicate image key %q"):format(image_key))
          ctx.image_keys[image_key] = true
        end
        if stats then stats.region_reuses = stats.region_reuses + 1 end
      else
        validate_plain(region.child, path .. ".child", {})
        local region_ctx = util.copy(ctx)
        region_ctx.image_keys = {}
        child = compile_node(region.child, region_ctx, path .. ".child")
        for image_key in pairs(region_ctx.image_keys) do
          require_value(not ctx.image_keys[image_key], path,
            ("duplicate image key %q"):format(image_key))
          ctx.image_keys[image_key] = true
        end
        if stats then stats.region_compilations = stats.region_compilations + 1 end
        if region.revision ~= nil and cache then
          cache_entry = {
            revision = region.revision,
            constraints = constraints,
            fragment = child,
            image_keys = util.copy(region_ctx.image_keys),
            dependency_keys = dependencies_keys,
          }
          cache.regions[region.key] = cache_entry
        end
      end
      active_cache[region.key] = true
      local first = append_region(value, child, gap, cache_entry)
      local region_value = {
        key = region.key,
        revision = region.revision,
        first = first,
        last = first + #child.lines,
        lines = child.lines,
        decorations = child.decorations,
        coverage = child.coverage,
        targets = child.targets,
        scopes = child.scopes,
        images = child.images,
        source_ranges = child.source_ranges,
        virtuals = child.virtuals,
      }
      value.regions[#value.regions + 1] = region_value
    end
    if cache then
      for key in pairs(cache.regions) do
        if not active_cache[key] then cache.regions[key] = nil end
      end
    end
    add_root_scopes(value, wrappers)
  else
    if stats then stats.region_compilations = stats.region_compilations + 1 end
    local child = compile_node(tree.root, ctx, "tree.root")
    value = child
    value.regions = {}
    local key = tree.root.key
    value.regions[1] = {
      key = key,
      first = 0,
      last = #value.lines,
      lines = value.lines,
      decorations = value.decorations,
      coverage = value.coverage,
      targets = value.targets,
      scopes = value.scopes,
      images = value.images,
      source_ranges = value.source_ranges,
      virtuals = value.virtuals,
    }
  end
  if cache then
    for key in pairs(cache.layers) do
      if not ctx.active_layer_cache[key] then cache.layers[key] = nil end
    end
  end
  if extent == "viewport" then
    value = apply_viewport_overflow(value, tree.root, ctx, height)
  end
  ensure_physical_line(value)
  value.chrome = compile_chrome(tree.chrome, theme)
  value.view = compile_view(tree, value.targets)
  local root_scope = tree.root
  while root_scope and root_scope.type == "scope" do
    if value.scopes[root_scope.key] then
      value.scopes[root_scope.key].root = true
    end
    root_scope = root_scope.child
  end
  value.edit = compile_edit(tree)
  value.width, value.height, value.extent = width, height, extent
  value.theme_generation = theme.generation or 0
  value.image_generation = images.generation or 0
  value.image_cell_width = images.cell_width
  value.image_cell_height = images.cell_height
  validate_layout(value, extent, height)
  return value
end

return M
