local source = require("applet.pane.source")
local scene = require("applet.pane.scene")
local util = require("applet.util")

local M = {}

local function same_region_geometry(left, right)
  if rawequal(left, right) then return true end
  if #left ~= #right then return false end
  for index, region in ipairs(left) do
    local other = right[index]
    if not other or region.key ~= other.key
        or region.first ~= other.first or region.last ~= other.last then
      return false
    end
  end
  return true
end

local function retained_document_changes(previous, layout)
  local document = layout.region_document
  local prior = previous.region_document
  if not document or not prior
      or not util.equal(document.shape, prior.shape) then
    return nil
  end
  local changed = {
    content = false,
    decorations = false,
    interaction = not util.equal(previous.edit, layout.edit),
    images = false,
    regions = false,
    sources = false,
    virtuals = false,
  }
  local first = document.changed_first
  if first then
    for index = first, math.max(#previous.regions, #layout.regions) do
      local left, right = previous.regions[index], layout.regions[index]
      if not left or not right then
        changed.content = true
        changed.decorations = true
        changed.interaction = true
        changed.images = true
        changed.regions = true
        changed.sources = true
        changed.virtuals = true
      else
        local shifted = left.first ~= right.first
          or left.last ~= right.last
        local content_changed = not util.equal(left.lines, right.lines)
        changed.content = changed.content or content_changed
        local decorations_changed = not util.equal(
          left.decorations, right.decorations)
          or shifted and (#left.decorations > 0 or #right.decorations > 0)
        changed.decorations = changed.decorations or decorations_changed
        local interaction_changed = not util.equal(left.targets, right.targets)
          or not util.equal(left.target_order, right.target_order)
          or not util.equal(left.hit_order, right.hit_order)
          or not util.equal(left.scopes, right.scopes)
          or shifted and (next(left.targets) ~= nil or next(right.targets) ~= nil
            or next(left.scopes) ~= nil or next(right.scopes) ~= nil)
        changed.interaction = changed.interaction or interaction_changed
        local images_changed = not util.equal(left.images, right.images)
          or shifted and (next(left.images) ~= nil or next(right.images) ~= nil)
        changed.images = changed.images or images_changed
        local sources_changed = not util.equal(
          left.source_ranges, right.source_ranges)
          or shifted and (#left.source_ranges > 0 or #right.source_ranges > 0)
        changed.sources = changed.sources or sources_changed
        local virtuals_changed = not util.equal(left.virtuals, right.virtuals)
          or shifted and (#left.virtuals > 0 or #right.virtuals > 0)
        changed.virtuals = changed.virtuals or virtuals_changed
        changed.regions = changed.regions or left.key ~= right.key or shifted
      end
    end
  end
  changed.scene = previous.scene ~= layout.scene
  changed.chrome = not util.equal(previous.chrome, layout.chrome)
  changed.view = not util.equal(previous.view, layout.view)
  changed.any = changed.content or changed.decorations
    or changed.interaction or changed.images or changed.regions
    or changed.sources or changed.virtuals or changed.scene
    or changed.chrome or changed.view
  return changed
end

function M.changes(previous, layout)
  if not previous then
    return {
      any = true,
      content = true,
      decorations = true,
      interaction = true,
      images = true,
      regions = true,
      sources = true,
      virtuals = true,
      scene = layout.scene ~= nil,
      chrome = true,
      view = true,
    }
  end
  local retained = retained_document_changes(previous, layout)
  if retained then return retained end
  local changed = {
    content = not util.equal(previous.lines, layout.lines),
    decorations = not util.equal(previous.decorations, layout.decorations),
    interaction = not (util.equal(previous.targets, layout.targets)
      and util.equal(previous.target_order, layout.target_order)
      and util.equal(previous.hit_order, layout.hit_order)
      and util.equal(previous.scopes, layout.scopes)
      and util.equal(previous.binding_pairs, layout.binding_pairs)
      and util.equal(previous.edit, layout.edit)),
    images = not util.equal(previous.images, layout.images),
    regions = not same_region_geometry(previous.regions, layout.regions),
    sources = not util.equal(previous.source_ranges, layout.source_ranges),
    virtuals = not util.equal(previous.virtuals, layout.virtuals),
    scene = previous.scene ~= layout.scene,
    chrome = not util.equal(previous.chrome, layout.chrome),
    view = not util.equal(previous.view, layout.view),
  }
  changed.any = changed.content or changed.decorations
    or changed.interaction or changed.images or changed.regions
    or changed.sources or changed.virtuals or changed.scene
    or changed.chrome or changed.view
  return changed
end

local function valid_window(surface)
  local window = surface.window and surface.window()
  if window and vim.api.nvim_win_is_valid(window)
      and vim.api.nvim_win_get_buf(window) == surface.buffer then
    return window
  end
end

local function region_at(layout, row)
  local regions = layout and layout.regions or {}
  local first, last = 1, #regions
  while first <= last do
    local index = math.floor((first + last) / 2)
    local region = regions[index]
    if row < region.first then
      last = index - 1
    elseif row >= region.last then
      first = index + 1
    else
      return { key = region.key, row = row - region.first, index = index }
    end
  end
end

local function target_at(layout, row, col)
  local region = layout and layout.region_document and region_at(layout, row)
  local selected = region and layout.regions[region.index]
  local order = selected and (selected.hit_order or selected.target_order)
    or layout and (layout.hit_order or layout.target_order) or {}
  for _, key in ipairs(order) do
    local target = layout.targets[key]
    for index, rect in ipairs(target and target.rectangles or {}) do
      if row >= rect.row and row < rect.row + rect.height
          and col >= rect.col and col < rect.col + rect.width then
        return {
          key = key,
          rectangle = index,
          row = row - rect.row,
          col = col - rect.col,
        }
      end
    end
  end
end

local function save_view(surface, layout, previous, namespace)
  local window = valid_window(surface)
  if not window then return nil end
  local result
  vim.api.nvim_win_call(window, function()
    result = {
      cursor = vim.api.nvim_win_get_cursor(0),
      view = vim.fn.winsaveview(),
      at_end = vim.api.nvim_win_get_cursor(0)[1]
        >= vim.api.nvim_buf_line_count(surface.buffer),
      current = vim.api.nvim_get_current_win() == window,
      mode = vim.api.nvim_get_mode().mode,
    }
  end)
  result.follow = layout.view.scroll == "follow_end" and result.at_end
  local row, col = result.cursor[1] - 1, result.cursor[2]
  local line = vim.api.nvim_buf_get_lines(surface.buffer, row, row + 1, false)[1] or ""
  result.target = target_at(previous, row,
    util.display_width(line:sub(1, col)))
  result.region = region_at(previous, row)
  result.top_region = region_at(previous,
    math.max(0, result.view.topline - 1))
  result.cursor_mark = vim.api.nvim_buf_set_extmark(
    surface.buffer, namespace, row, col, { right_gravity = false })
  result.top_mark = vim.api.nvim_buf_set_extmark(
    surface.buffer, namespace, math.max(0, result.view.topline - 1), 0,
    { right_gravity = false })
  return result
end

local function restore_view(surface, saved, layout, namespace)
  local window = valid_window(surface)
  if not window or not saved then return end
  local cursor = vim.api.nvim_buf_get_extmark_by_id(
    surface.buffer, namespace, saved.cursor_mark, {})
  local top = vim.api.nvim_buf_get_extmark_by_id(
    surface.buffer, namespace, saved.top_mark, {})
  if #top > 0 then saved.view.topline = top[1] + 1 end
  if saved.top_region then
    for _, region in ipairs(layout.regions or {}) do
      if region.key == saved.top_region.key and region.last > region.first then
        saved.view.topline = region.first + math.min(saved.top_region.row,
          region.last - region.first - 1) + 1
        break
      end
    end
  end
  if saved.target and layout.targets[saved.target.key] then
    local target = layout.targets[saved.target.key]
    local rect = target.rectangles[
      math.min(saved.target.rectangle, #target.rectangles)]
    if rect then
      local row = rect.row + math.min(saved.target.row, rect.height - 1)
      local display_col = rect.col + math.min(saved.target.col, rect.width - 1)
      local line = vim.api.nvim_buf_get_lines(
        surface.buffer, row, row + 1, false)[1] or ""
      cursor = { row, util.byte_col(line, display_col) }
    end
  elseif saved.region then
    for _, region in ipairs(layout.regions or {}) do
      if region.key == saved.region.key and region.last > region.first then
        cursor = {
          region.first + math.min(saved.region.row,
            region.last - region.first - 1),
          saved.cursor[2],
        }
        break
      end
    end
  end
  vim.api.nvim_win_call(window, function()
    if saved.follow then
      local line = vim.api.nvim_buf_line_count(surface.buffer)
      pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
      vim.cmd("normal! zb")
    else
      pcall(vim.fn.winrestview, saved.view)
      local row = #cursor > 0 and cursor[1] or saved.cursor[1] - 1
      local line = math.min(row + 1, vim.api.nvim_buf_line_count(surface.buffer))
      local text = vim.api.nvim_buf_get_lines(surface.buffer, line - 1, line, false)[1] or ""
      local col = #cursor > 0 and cursor[2] or saved.cursor[2]
      pcall(vim.api.nvim_win_set_cursor, 0, { line, math.min(col, #text) })
    end
  end)
  pcall(vim.api.nvim_buf_del_extmark, surface.buffer, namespace, saved.cursor_mark)
  pcall(vim.api.nvim_buf_del_extmark, surface.buffer, namespace, saved.top_mark)
end

local function same_region_order(old, new)
  if not old or #old.regions ~= #new.regions then return false end
  for index, region in ipairs(new.regions) do
    if old.regions[index].key ~= region.key then return false end
  end
  return true
end

local function common_lines(old, new, old_first, old_last, new_first, new_last)
  local prefix = 0
  while old_first + prefix < old_last and new_first + prefix < new_last
      and old.lines[old_first + prefix + 1]
        == new.lines[new_first + prefix + 1] do
    prefix = prefix + 1
  end
  local suffix = 0
  while old_last - suffix > old_first + prefix
      and new_last - suffix > new_first + prefix
      and old.lines[old_last - suffix]
        == new.lines[new_last - suffix] do
    suffix = suffix + 1
  end
  return prefix, suffix
end

local function splice_changed_lines(
    buffer, old, new, old_first, old_last, new_first, new_last, changes)
  local prefix, suffix = common_lines(
    old, new, old_first, old_last, new_first, new_last)
  local replace_first = old_first + prefix
  local replace_last = old_last - suffix
  local replacement = {}
  for index = new_first + prefix + 1, new_last - suffix do
    replacement[#replacement + 1] = new.lines[index]
  end
  if replace_first == replace_last and #replacement == 0 then return false end
  vim.api.nvim_buf_set_lines(
    buffer, replace_first, replace_last, false, replacement)
  changes.line_splices = changes.line_splices + 1
  return true
end

local function replace_content(buffer, old, new, changes)
  if not old then
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, new.lines)
    changes.line_splices = changes.line_splices + 1
    changes.full_rebuilds = changes.full_rebuilds + 1
    return "rebuild"
  end
  local document = new.region_document
  local changed_first = document and document.changed_first or nil
  local retained_order = changed_first ~= nil
    and #old.regions == #new.regions
  if retained_order then
    for index = changed_first, #new.regions do
      if old.regions[index].key ~= new.regions[index].key then
        retained_order = false
        break
      end
    end
  end
  if retained_order or same_region_order(old, new) then
    local changed = false
    for index = #new.regions, changed_first or 1, -1 do
      local previous, current = old.regions[index], new.regions[index]
      local old_first = index == 1 and 0 or old.regions[index - 1].last
      local new_first = index == 1 and 0 or new.regions[index - 1].last
      changed = splice_changed_lines(buffer, old, new,
        old_first, previous.last, new_first, current.last, changes)
        or changed
    end
    return changed and "regions" or "unchanged"
  end
  local prefix = 0
  while prefix < #old.regions and prefix < #new.regions
      and old.regions[prefix + 1].key == new.regions[prefix + 1].key
      and util.equal(old.regions[prefix + 1].lines,
        new.regions[prefix + 1].lines) do
    prefix = prefix + 1
  end
  local suffix = 0
  while suffix < #old.regions - prefix and suffix < #new.regions - prefix
      and old.regions[#old.regions - suffix].key == new.regions[#new.regions - suffix].key
      and util.equal(old.regions[#old.regions - suffix].lines,
        new.regions[#new.regions - suffix].lines) do
    suffix = suffix + 1
  end
  local old_first = prefix == 0 and 0 or old.regions[prefix].last
  local new_first = prefix == 0 and 0 or new.regions[prefix].last
  local old_last = suffix == 0 and #old.lines or old.regions[#old.regions - suffix + 1].first
  local new_last = suffix == 0 and #new.lines or new.regions[#new.regions - suffix + 1].first
  splice_changed_lines(buffer, old, new,
    old_first, old_last, new_first, new_last, changes)
  return "island"
end

local function delete_marks(buffer, namespace, marks)
  for _, id in ipairs(marks or {}) do
    pcall(vim.api.nvim_buf_del_extmark, buffer, namespace, id)
  end
end

local function continuation_context(surface, layout)
  local window = valid_window(surface)
  if not window then return nil end
  local desired = util.copy(layout.chrome.options)
  for name, value in pairs(surface.window_options or {}) do
    desired[name] = value
  end
  local function option(name)
    if desired[name] ~= nil then return desired[name] end
    local ok, value = pcall(vim.api.nvim_get_option_value,
      name, { win = window })
    return ok and value or nil
  end
  local showbreak = option("showbreak")
  if option("wrap") ~= true or showbreak == nil
      or showbreak == "" or showbreak == "NONE" then
    return nil
  end
  return {
    showbreak = showbreak,
    breakindent = option("breakindent") == true,
    linebreak = option("linebreak") == true,
    breakat = vim.o.breakat,
    width = vim.api.nvim_win_get_width(window),
  }
end

local function continuation_prefix(context, region, decoration)
  if not context or not decoration.continuation then return nil end
  local line = region.lines[decoration.row + 1] or ""
  if util.display_width(line) <= context.width then return nil end
  local indent = 0
  if context.breakindent then
    indent = util.display_width(line:match("^ *") or "")
    indent = math.min(indent, math.max(0, context.width - 20))
  end
  return string.rep(" ", indent) .. context.showbreak
end

local function continuation_col(context, line, fallback)
  if not context then return fallback end
  if not context.linebreak then return util.byte_col(line, context.width) end
  local byte_col, display_col, last_break = 0, 0, nil
  local result = fallback
  for _, character in ipairs(util.characters(line, "continuation line")) do
    local width = util.display_width(character)
    if display_col + width > context.width then
      result = last_break or byte_col
      break
    end
    byte_col = byte_col + #character
    display_col = display_col + width
    if context.breakat:find(character, 1, true) then
      last_break = byte_col
    end
  end
  return result
end

local function write_decoration(
    buffer, namespace, region, decoration, context)
  local options = { priority = decoration.priority or 100 }
  if decoration.whole_line then
    options.line_hl_group = decoration.group
  else
    options.end_row = region.first + decoration.row
    options.end_col = decoration.end_col
    options.hl_group = decoration.group
  end
  local prefix = continuation_prefix(context, region, decoration)
  if prefix then
    options.virt_text = { { prefix, { "NonText", decoration.group } } }
    options.virt_text_pos = "overlay"
    options.virt_text_win_col = 0
    options.virt_text_repeat_linebreak = true
    options.hl_mode = "replace"
  end
  local line = region.lines[decoration.row + 1] or ""
  local col = decoration.col
  if prefix then
    col = continuation_col(context, line, decoration.col)
  end
  return vim.api.nvim_buf_set_extmark(buffer, namespace,
    region.first + decoration.row, col, options)
end

local function write_decorations(buffer, namespace, region, context)
  local records = {}
  for _, decoration in ipairs(region.decorations) do
    records[#records + 1] = write_decoration(
      buffer, namespace, region, decoration, context)
  end
  return records
end

local function decoration_signature(decoration)
  return table.concat({
    tostring(decoration.col),
    tostring(decoration.end_col or ""),
    tostring(decoration.group),
    tostring(decoration.priority or ""),
    tostring(decoration.continuation or ""),
    decoration.whole_line and "1" or "0",
  }, "\0")
end

local function stable_decoration_row(decoration, previous, current, prefix, suffix)
  if decoration.row < prefix then return decoration.row end
  if suffix > 0 and decoration.row >= #previous.lines - suffix then
    return decoration.row + #current.lines - #previous.lines
  end
end

local function reconcile_decorations(
    buffer, namespace, records, previous, current, retain, context)
  if not retain or type(records) ~= "table"
      or #records ~= #previous.decorations then
    delete_marks(buffer, namespace, records)
    local written = write_decorations(buffer, namespace, current, context)
    return written, #written
  end

  local prefix, suffix = common_lines(previous, current,
    0, #previous.lines, 0, #current.lines)
  local available = {}
  for index, decoration in ipairs(previous.decorations) do
    local row = stable_decoration_row(
      decoration, previous, current, prefix, suffix)
    if row ~= nil then
      local key = row .. "\0" .. decoration_signature(decoration)
      available[key] = available[key] or {}
      available[key][#available[key] + 1] = records[index]
    end
  end

  local result, kept = {}, {}
  local writes = 0
  for _, decoration in ipairs(current.decorations) do
    local key = decoration.row .. "\0" .. decoration_signature(decoration)
    local candidates = available[key]
    local id = candidates and table.remove(candidates)
    if id then
      kept[id] = true
      result[#result + 1] = id
    else
      result[#result + 1] = write_decoration(
        buffer, namespace, current, decoration, context)
      writes = writes + 1
    end
  end
  for _, id in ipairs(records) do
    if not kept[id] then
      pcall(vim.api.nvim_buf_del_extmark, buffer, namespace, id)
    end
  end
  return result, writes
end

local function sync_decorations(
    buffer, namespace, state, previous, layout, context, first)
  state.decoration_marks = state.decoration_marks or {}
  local context_changed = not util.equal(
    state.continuation_context, context)
  if context_changed then first = nil end
  local old = {}
  local previous_regions = previous and previous.regions or {}
  for index = first or 1, #previous_regions do
    local region = previous_regions[index]
    old[region.key] = region
  end
  local active, writes = {}, 0
  local retain = not context_changed
  if retain then
    if first and #previous_regions == #layout.regions then
      for index = first, #layout.regions do
        if previous_regions[index].key ~= layout.regions[index].key then
          retain = false
          break
        end
      end
    else
      retain = same_region_order(previous, layout)
    end
  end
  for index = first or 1, #layout.regions do
    local region = layout.regions[index]
    active[region.key] = true
    local prior = old[region.key]
    if not prior or not retain or not util.equal(prior.lines, region.lines)
        or not util.equal(prior.decorations, region.decorations) then
      local records, count
      if prior then
        records, count = reconcile_decorations(buffer, namespace,
          state.decoration_marks[region.key], prior, region, retain, context)
      else
        records = write_decorations(buffer, namespace, region, context)
        count = #records
      end
      state.decoration_marks[region.key] = records
      writes = writes + count
    end
  end
  for key in pairs(old) do
    local marks = state.decoration_marks[key]
    if marks and not active[key] then
      delete_marks(buffer, namespace, marks)
      state.decoration_marks[key] = nil
    end
  end
  state.continuation_context = context and util.copy(context) or nil
  return writes
end

local function apply_virtuals(buffer, namespace, layout)
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  local writes, line_count = 0, vim.api.nvim_buf_line_count(buffer)
  for _, virtual in ipairs(layout.virtuals) do
    local row = math.max(0, math.min(virtual.row, line_count - 1))
    local above = virtual.placement == "above" or virtual.placement == "above-end"
    if virtual.placement == "above-end" or virtual.placement == "below-end" then
      row = line_count - 1
    end
    vim.api.nvim_buf_set_extmark(buffer, namespace, row, 0, {
      virt_lines = virtual.lines,
      virt_lines_above = above,
    })
    writes = writes + 1
  end
  return writes
end

local function sync_region_marks(buffer, namespace, state, layout, first)
  state.region_marks = state.region_marks or {}
  local active, count = {}, 0
  local previous = state.layout and state.layout.regions or {}
  local old = {}
  for index = first or 1, #previous do old[previous[index].key] = true end
  for index = first or 1, #layout.regions do
    local region = layout.regions[index]
    active[region.key] = true
    local mark = state.region_marks[region.key]
    if not mark or mark.first ~= region.first or mark.last ~= region.last then
      local position = mark and vim.api.nvim_buf_get_extmark_by_id(
        buffer, namespace, mark.id, { details = true }) or {}
      local current_last = position[3] and position[3].end_row or position[1]
      if not mark or position[1] ~= region.first or current_last ~= region.last then
        if mark then pcall(vim.api.nvim_buf_del_extmark, buffer, namespace, mark.id) end
        local row = math.min(region.first, vim.api.nvim_buf_line_count(buffer) - 1)
        local options = { right_gravity = true }
        if region.last > region.first then
          options.end_row = math.min(region.last, vim.api.nvim_buf_line_count(buffer))
          options.end_col = 0
          options.end_right_gravity = false
        end
        state.region_marks[region.key] = {
          first = region.first,
          last = region.last,
          id = vim.api.nvim_buf_set_extmark(buffer, namespace, row, 0, options),
        }
        count = count + 1
      else
        mark.first = region.first
        mark.last = region.last
      end
    end
  end
  for key in pairs(old) do
    local mark = state.region_marks[key]
    if mark and not active[key] then
      pcall(vim.api.nvim_buf_del_extmark, buffer, namespace, mark.id)
      state.region_marks[key] = nil
    end
  end
  return count
end

local function restore_chrome(state)
  local chrome = state.chrome
  if not chrome then return end
  if chrome.adapter then
    pcall(chrome.adapter.restore)
    state.chrome = nil
    return
  end
  if not vim.api.nvim_win_is_valid(chrome.window) then
    state.chrome = nil
    return
  end
  for option, state in pairs(chrome.options) do
    local current = vim.api.nvim_get_option_value(option, { win = chrome.window })
    if util.equal(current, state.written) then
      pcall(vim.api.nvim_set_option_value, option, state.original,
        { win = chrome.window })
    end
  end
  if chrome.floating then
    local config = vim.api.nvim_win_get_config(chrome.window)
    if util.equal(config.title, chrome.written_title) then
      config.title = chrome.title or ""
    end
    if util.equal(config.title_pos, chrome.written_title_pos) then
      config.title_pos = chrome.title_pos
    end
    if util.equal(config.footer, chrome.written_footer) then
      config.footer = chrome.footer or ""
    end
    if util.equal(config.footer_pos, chrome.written_footer_pos) then
      config.footer_pos = chrome.footer_pos
    end
    pcall(vim.api.nvim_win_set_config, chrome.window, config)
  end
  state.chrome = nil
end

local function apply_chrome(surface, layout, state)
  if surface.chrome then
    if state.chrome and state.chrome.adapter ~= surface.chrome then
      restore_chrome(state)
    end
    state.chrome = state.chrome or { adapter = surface.chrome }
    surface.chrome.apply(layout.chrome, surface.window_options or {})
    return
  end
  local window = valid_window(surface)
  if not window then restore_chrome(state) return end
  if state.chrome and state.chrome.window ~= window then restore_chrome(state) end
  if not state.chrome then
    local config = vim.api.nvim_win_get_config(window)
    state.chrome = {
      window = window,
      options = {},
      floating = config.relative and config.relative ~= "",
      title = config.title,
      title_pos = config.title_pos,
      footer = config.footer,
      footer_pos = config.footer_pos,
    }
  end
  local chrome = state.chrome
  local desired = util.copy(layout.chrome.options)
  for option, value in pairs(surface.window_options or {}) do desired[option] = value end
  for option, state in pairs(util.copy(chrome.options)) do
    if desired[option] == nil then
      local current = vim.api.nvim_get_option_value(option, { win = window })
      if util.equal(current, state.written) then
        pcall(vim.api.nvim_set_option_value, option, state.original,
          { win = window })
      end
      chrome.options[option] = nil
    end
  end
  for option, value in pairs(desired) do
    if chrome.options[option] == nil then
      local ok, original = pcall(vim.api.nvim_get_option_value, option, { win = window })
      if ok then chrome.options[option] = { original = original } end
    end
    pcall(vim.api.nvim_set_option_value, option, value, { win = window })
    if chrome.options[option] then
      chrome.options[option].written = type(value) == "table"
          and util.copy(value) or value
    end
  end
  if chrome.floating then
    local config = vim.api.nvim_win_get_config(window)
    config.title = layout.chrome.title or chrome.title or ""
    config.title_pos = layout.chrome.title_pos or chrome.title_pos
    config.footer = layout.chrome.footer or chrome.footer or ""
    config.footer_pos = layout.chrome.footer_pos or chrome.footer_pos
    pcall(vim.api.nvim_win_set_config, window, config)
    chrome.written_title = type(config.title) == "table"
        and util.copy(config.title) or config.title
    chrome.written_title_pos = config.title_pos
    chrome.written_footer = type(config.footer) == "table"
        and util.copy(config.footer) or config.footer
    chrome.written_footer_pos = config.footer_pos
  end
end

local function image_redraw_provider(state, namespace)
  if state.image_redraw_provider then return state.image_redraw_provider end
  local provider = { ranges = {} }
  vim.api.nvim_set_decoration_provider(namespace, {
    on_win = function(_, window, buffer)
      local target = provider.surface and valid_window(provider.surface)
      return target == window and provider.surface.buffer == buffer
        and provider.callback ~= nil and #provider.ranges > 0
    end,
    on_line = function(_, _, buffer, row)
      if not provider.surface or provider.surface.buffer ~= buffer then return end
      if not provider.callback then return end
      for _, range in ipairs(provider.ranges) do
        if row < range.first then return end
        if row < range.last then
          provider.redrawn = true
          return
        end
      end
    end,
    on_end = function()
      local callback = provider.redrawn and provider.callback or nil
      provider.redrawn = false
      if not callback or provider.scheduled then return end
      provider.scheduled = true
      vim.schedule(function()
        provider.scheduled = false
        if provider.callback == callback then pcall(callback) end
      end)
    end,
  })
  state.image_redraw_provider = provider
  return provider
end

local function update_image_redraw_ranges(state, layout, visible)
  local provider = state.image_redraw_provider
  if not provider then return end
  local ranges = {}
  for key in pairs(visible or {}) do
    local image = layout.images[key]
    if image and image.height > 0 then
      for _, rectangle in ipairs(image.visible or { {
        row = 0,
        col = 0,
        width = image.width,
        height = image.height,
      } }) do
        ranges[#ranges + 1] = {
          first = image.row + rectangle.row,
          last = image.row + rectangle.row + rectangle.height,
        }
      end
    end
  end
  table.sort(ranges, function(left, right) return left.first < right.first end)
  local merged = {}
  for _, range in ipairs(ranges) do
    local previous = merged[#merged]
    if previous and range.first <= previous.last then
      previous.last = math.max(previous.last, range.last)
    else
      merged[#merged + 1] = range
    end
  end
  provider.ranges = merged
end

local function intersect_rectangle(rectangle, boundary)
  local left = math.max(rectangle.left, boundary.left)
  local top = math.max(rectangle.top, boundary.top)
  local right = math.min(
    rectangle.left + rectangle.width, boundary.left + boundary.width)
  local bottom = math.min(
    rectangle.top + rectangle.height, boundary.top + boundary.height)
  if left >= right or top >= bottom then return nil end
  return {
    left = left,
    top = top,
    width = right - left,
    height = bottom - top,
  }
end

local function unique_sorted(values)
  table.sort(values)
  local result = {}
  for _, value in ipairs(values) do
    if result[#result] ~= value then result[#result + 1] = value end
  end
  return result
end

local function visible_rectangles(rectangle, occluders)
  local clipped = {}
  local boundaries = {
    rectangle.top,
    rectangle.top + rectangle.height,
  }
  for _, occluder in ipairs(occluders) do
    local intersection = intersect_rectangle(occluder, rectangle)
    if intersection then
      clipped[#clipped + 1] = intersection
      boundaries[#boundaries + 1] = intersection.top
      boundaries[#boundaries + 1] = intersection.top + intersection.height
    end
  end
  if #clipped == 0 then return { rectangle } end

  boundaries = unique_sorted(boundaries)
  local result, active = {}, {}
  local rectangle_right = rectangle.left + rectangle.width
  for index = 1, #boundaries - 1 do
    local top, bottom = boundaries[index], boundaries[index + 1]
    local covered = {}
    for _, occluder in ipairs(clipped) do
      if occluder.top < bottom
          and occluder.top + occluder.height > top then
        covered[#covered + 1] = {
          left = occluder.left,
          right = occluder.left + occluder.width,
        }
      end
    end
    table.sort(covered, function(left, right)
      if left.left == right.left then return left.right < right.right end
      return left.left < right.left
    end)

    local spans = {}
    local cursor = rectangle.left
    for _, interval in ipairs(covered) do
      if interval.left > cursor then
        spans[#spans + 1] = { left = cursor, right = interval.left }
      end
      cursor = math.max(cursor, interval.right)
    end
    if cursor < rectangle_right then
      spans[#spans + 1] = { left = cursor, right = rectangle_right }
    end

    local continued = {}
    for _, span in ipairs(spans) do
      local key = span.left .. ":" .. span.right
      local current = active[key]
      if current and current.top + current.height == top then
        current.height = current.height + bottom - top
      else
        current = {
          left = span.left,
          top = top,
          width = span.right - span.left,
          height = bottom - top,
        }
        result[#result + 1] = current
      end
      continued[key] = current
    end
    active = continued
  end
  table.sort(result, function(left, right)
    if left.top ~= right.top then return left.top < right.top end
    return left.left < right.left
  end)
  return result
end

local function border_cell(border, indexes)
  if type(border) ~= "table" then return 0 end
  for _, index in ipairs(indexes) do
    local value = border[index]
    if type(value) == "table" then value = value[1] end
    if type(value) == "string" and vim.fn.strdisplaywidth(value) > 0 then
      return 1
    end
  end
  return 0
end

local function floating_rectangle(window, config)
  local position = vim.fn.win_screenpos(window)
  return {
    left = position[2],
    top = position[1],
    width = vim.api.nvim_win_get_width(window)
      + border_cell(config.border, { 1, 7, 8 })
      + border_cell(config.border, { 3, 4, 5 }),
    height = vim.api.nvim_win_get_height(window)
      + border_cell(config.border, { 1, 2, 3 })
      + border_cell(config.border, { 5, 6, 7 }),
  }
end

local function image_cells(image)
  return image.visible or { {
    row = 0,
    col = 0,
    width = image.width,
    height = image.height,
  } }
end

local function screen_image_rectangle(
    window, buffer, image, rectangle, view, text_width)
  local document_col = image.col + rectangle.col
  local first_col = math.max(document_col, view.leftcol)
  local last_col = math.min(
    document_col + rectangle.width, view.leftcol + text_width)
  if first_col >= last_col then return nil end

  local document_row = image.row + rectangle.row
  local first_row, last_row, visible_top, visible_left
  local previous_screen_row
  for row = document_row, document_row + rectangle.height - 1 do
    if row >= 0 and row < vim.api.nvim_buf_line_count(buffer) then
      local line = vim.api.nvim_buf_get_lines(
        buffer, row, row + 1, false)[1] or ""
      local position = vim.fn.screenpos(
        window, row + 1, util.byte_col(line, first_col) + 1)
      if position.row and position.row > 0 then
        if first_row == nil then
          first_row = row
          visible_top, visible_left = position.row, position.col
        elseif position.row ~= previous_screen_row + 1
            or position.col ~= visible_left then
          return nil
        end
        previous_screen_row = position.row
        last_row = row + 1
      elseif first_row ~= nil then
        break
      end
    end
  end
  if first_row == nil then return nil end
  return {
    first_col = first_col,
    first_row = first_row,
    left = visible_left,
    top = visible_top,
    width = last_col - first_col,
    height = last_row - first_row,
  }
end

local function image_fragments(window, buffer, image, view)
  local info = vim.fn.getwininfo(window)[1] or {}
  local text_width = math.max(1,
    vim.api.nvim_win_get_width(window) - (info.textoff or 0))
  for _, rectangle in ipairs(image_cells(image)) do
    local first = math.max(0, image.row + rectangle.row)
    local last = math.min(vim.api.nvim_buf_line_count(buffer),
      image.row + rectangle.row + rectangle.height)
    for row = first, last - 1 do
      if vim.fn.foldclosed(row + 1) ~= -1 then return {} end
    end
  end

  local current_config = vim.api.nvim_win_get_config(window)
  if current_config.hide then return {} end
  local current_zindex = current_config.zindex or 0
  local occluders = {}
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if other ~= window and vim.api.nvim_win_is_valid(other) then
      local config = vim.api.nvim_win_get_config(other)
      if config.relative and config.relative ~= "" and not config.hide
          and (config.zindex or 50) >= current_zindex then
        occluders[#occluders + 1] = floating_rectangle(other, config)
      end
    end
  end
  if vim.fn.pumvisible() == 1 and vim.fn.exists("*pum_getpos") == 1 then
    local popup = vim.fn.pum_getpos()
    occluders[#occluders + 1] = {
      left = popup.col + 1,
      top = popup.row + 1,
      width = popup.width,
      height = popup.height,
    }
  end
  local fragments = {}
  for _, cell_rectangle in ipairs(image_cells(image)) do
    local screen = screen_image_rectangle(
      window, buffer, image, cell_rectangle, view, text_width)
    local bounded = screen and intersect_rectangle(screen, {
      left = 1,
      top = 1,
      width = vim.o.columns,
      height = vim.o.lines,
    }) or nil
    for _, rectangle in ipairs(
        bounded and visible_rectangles(bounded, occluders) or {}) do
      local viewport = {
        row = screen.first_row - image.row
          + rectangle.top - screen.top,
        col = screen.first_col - image.col
          + rectangle.left - screen.left,
        width = rectangle.width,
        height = rectangle.height,
      }
      fragments[#fragments + 1] = {
        screen_row = rectangle.top - viewport.row,
        screen_col = rectangle.left - viewport.col,
        viewport = viewport,
      }
    end
  end
  table.sort(fragments, function(left, right)
    if left.viewport.row == right.viewport.row then
      return left.viewport.col < right.viewport.col
    end
    return left.viewport.row < right.viewport.row
  end)
  return fragments
end

local function image_plan(surface, layout, window, view)
  local keys = {}
  for key in pairs(layout.images) do keys[#keys + 1] = key end
  table.sort(keys)
  local result = { slots = {}, placements = {} }
  local visible = {}
  for _, key in ipairs(keys) do
    local image = layout.images[key]
    result.slots[key] = image.source_identity
    local fragments = vim.api.nvim_win_call(window, function()
      return image_fragments(window, surface.buffer, image, view)
    end)
    for _, fragment in ipairs(fragments) do
      result.placements[#result.placements + 1] = {
        key = key,
        width = image.width,
        height = image.height,
        fit = image.fit,
        cell_width = image.cell_width,
        cell_height = image.cell_height,
        screen_row = fragment.screen_row,
        screen_col = fragment.screen_col,
        viewport = fragment.viewport,
      }
      visible[key] = true
    end
  end
  return result, visible
end

local function hidden_image_plan(layout)
  local result = { slots = {}, placements = {} }
  for key, image in pairs(layout.images) do
    result.slots[key] = image.source_identity
  end
  return result
end

local function paint_images(
    surface, layout, state, image_system, image_owner, force)
  local plan, visible = hidden_image_plan(layout), {}
  local window = valid_window(surface)
  if window and (not surface.visible or surface.visible()) then
    local view = vim.api.nvim_win_call(window, function()
      return vim.fn.winsaveview()
    end)
    plan, visible = image_plan(surface, layout, window, view)
  end
  local changed = image_system:present(image_owner, plan)
  if force and not changed and next(visible)
      and type(image_system.redraw) == "function" then
    image_system:redraw(image_owner)
  end
  update_image_redraw_ranges(state, layout, visible)
  local snapshot = image_system:snapshot(image_owner)
  if snapshot.generation ~= layout.image_generation
      and util.equal(snapshot.presented, plan.slots) then
    layout = util.copy(layout)
    layout.image_generation = snapshot.generation
  end
  return changed and 1 or 0, layout
end

local function clear_scene_provider(state)
  if state.scene_provider then scene.clear(state.scene_provider) end
  state.scene_provider = nil
  state.scene_size = nil
end

local function apply_scene_content(
    buffer, surface, state, layout, namespace, changes)
  local size = layout.scene.width .. ":" .. layout.scene.height
  if not state.scene_provider then
    state.scene_provider = scene.attach(namespace)
  end
  if state.unknown or state.scene_size ~= size then
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false,
      scene.lines(layout.scene))
    changes.line_splices = changes.line_splices + 1
    changes.full_rebuilds = changes.full_rebuilds + 1
    state.scene_size = size
    state.content_result = "scene"
  else
    state.content_result = "unchanged"
  end
  scene.update(state.scene_provider, surface, layout)
  state.runtime_scene = layout.scene
end

function M.apply(opts)
  local surface, layout = assert(opts.surface), assert(opts.layout)
  local buffer, namespace = surface.buffer, assert(opts.namespace)
  assert(vim.api.nvim_buf_is_valid(buffer), "Applet buffer is invalid")
  local state = opts.state or {}
  local previous = state.layout
  local differences = opts.changes or M.changes(previous, layout)
  local document = layout.region_document
  local changed_first = document and document.changed_first or nil
  local saved = save_view(surface, layout, previous, opts.cursor_namespace)
  local changes = {
    line_splices = 0,
    full_rebuilds = 0,
    extmark_writes = 0,
    image_presentation_changes = 0,
  }
  local modifiable = vim.bo[buffer].modifiable
  local readonly = vim.bo[buffer].readonly
  if state.unknown then
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
    vim.api.nvim_buf_clear_namespace(buffer, opts.virtual_namespace, 0, -1)
    vim.api.nvim_buf_clear_namespace(buffer, opts.region_namespace, 0, -1)
    state.decoration_marks, state.region_marks = {}, {}
    state.continuation_context = nil
  end
  local ok, result = xpcall(function()
    local continuation = not layout.scene
      and continuation_context(surface, layout) or nil
    if opts.buffer_mode == "managed" then
      vim.bo[buffer].readonly = false
      vim.bo[buffer].modifiable = true
      if layout.scene then
        apply_scene_content(buffer, surface, state, layout,
          assert(opts.scene_namespace), changes)
      elseif state.unknown or not previous or differences.content then
        clear_scene_provider(state)
        local content_previous = previous
        if state.unknown then content_previous = nil end
        state.content_result = replace_content(
          buffer, content_previous, layout, changes)
      else
        state.content_result = "unchanged"
      end
    else
      state.content_result = "unchanged"
    end
    if not layout.scene and (not previous or differences.content
        or differences.decorations or differences.regions
        or not util.equal(state.continuation_context, continuation)) then
      changes.extmark_writes = changes.extmark_writes
        + sync_decorations(buffer, namespace, state, previous, layout,
          continuation, changed_first)
    end
    if not layout.scene and (not previous or state.content_result ~= "unchanged"
        or differences.virtuals) then
      changes.extmark_writes = changes.extmark_writes
        + apply_virtuals(buffer, opts.virtual_namespace, layout)
    end
    if not layout.scene and (not previous or state.content_result ~= "unchanged"
        or differences.sources) then
      source.apply(buffer, layout.source_ranges,
        opts.buffer_mode == "managed" and layout.lines
          or vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    end
    changes.extmark_writes = changes.extmark_writes
      + sync_region_marks(buffer, opts.region_namespace, state, layout,
        changed_first)
    if opts.window_changed or not previous or differences.chrome then
      apply_chrome(surface, layout, state)
    end
    if opts.image_system and (opts.force_images or not previous
        or differences.images or differences.content) then
      local presented
      changes.image_presentation_changes, presented = paint_images(
        surface, layout, state, opts.image_system,
        assert(opts.image_owner), opts.force_images)
      layout = presented or layout
    end
  end, debug.traceback)
  if opts.buffer_mode == "managed" then
    vim.bo[buffer].modifiable = modifiable
    vim.bo[buffer].readonly = readonly
  end
  if not ok then
    if saved then
      pcall(vim.api.nvim_buf_del_extmark, buffer,
        opts.cursor_namespace, saved.cursor_mark)
      pcall(vim.api.nvim_buf_del_extmark, buffer,
        opts.cursor_namespace, saved.top_mark)
    end
    state.unknown = true
    error(result, 0)
  end
  state.unknown = false
  state.layout = layout
  restore_view(surface, saved, layout, opts.cursor_namespace)
  return state, changes, layout
end

function M.clear(opts)
  local surface, state = opts.surface, opts.state or {}
  clear_scene_provider(state)
  if opts.image_system then
    opts.image_system:clear(assert(opts.image_owner))
  end
  if state.image_redraw_provider then
    state.image_redraw_provider.callback = nil
    state.image_redraw_provider.surface = nil
    state.image_redraw_provider.ranges = {}
    vim.api.nvim_set_decoration_provider(opts.image_namespace, {})
    state.image_redraw_provider = nil
  end
  restore_chrome(state)
  if vim.api.nvim_buf_is_valid(surface.buffer)
      and vim.api.nvim_buf_is_loaded(surface.buffer) then
    vim.api.nvim_buf_clear_namespace(surface.buffer, opts.namespace, 0, -1)
    vim.api.nvim_buf_clear_namespace(surface.buffer, opts.virtual_namespace, 0, -1)
    vim.api.nvim_buf_clear_namespace(surface.buffer, opts.region_namespace, 0, -1)
    vim.api.nvim_buf_clear_namespace(surface.buffer, opts.cursor_namespace, 0, -1)
    if opts.mask_namespace then
      vim.api.nvim_buf_clear_namespace(surface.buffer, opts.mask_namespace, 0, -1)
    end
    source.clear(surface.buffer)
  end
  state.layout = nil
  state.runtime_scene = nil
  state.decoration_marks, state.region_marks = {}, {}
  state.continuation_context = nil
  return state
end

function M.retain(opts)
  local surface, layout = assert(opts.surface), assert(opts.layout)
  local state = assert(opts.state)
  assert(not state.unknown, "Applet reconciliation state is unknown")
  local previous = state.layout
  local differences = opts.changes or M.changes(previous, layout)
  local retained_scene = opts.scene or layout.scene
  if opts.window_changed or not previous
      or differences.chrome then
    apply_chrome(surface, layout, state)
  end
  if retained_scene and (opts.window_changed or not previous
      or differences.scene) then
    if not state.scene_provider then
      state.scene_provider = scene.attach(assert(opts.scene_namespace))
    end
    scene.update(state.scene_provider, surface, retained_scene)
    state.runtime_scene = retained_scene
  elseif not retained_scene then
    clear_scene_provider(state)
    state.runtime_scene = nil
    if previous and (opts.window_changed or differences.chrome)
        and vim.api.nvim_buf_is_loaded(surface.buffer) then
      sync_decorations(surface.buffer, assert(opts.namespace), state,
        previous, layout, continuation_context(surface, layout))
    end
  end
  state.layout = layout
  return state
end

function M.refresh_chrome(opts)
  if not opts.state.layout then return end
  apply_chrome(opts.surface, opts.state.layout, opts.state)
end

function M.refresh_virtuals(opts)
  if not opts.state.layout or not vim.api.nvim_buf_is_loaded(opts.surface.buffer) then
    return 0
  end
  return apply_virtuals(
    opts.surface.buffer, opts.virtual_namespace, opts.state.layout)
end

function M.refresh_images(opts)
  if not opts.image_system or not opts.state.layout then return 0 end
  local changes, layout = paint_images(
    opts.surface, opts.state.layout, opts.state, opts.image_system,
    assert(opts.image_owner), true)
  opts.state.layout = layout or opts.state.layout
  return changes, opts.state.layout
end

function M.set_image_redraw_handler(opts)
  assert(type(opts.callback) == "function",
    "image redraw callback must be a function")
  local provider = image_redraw_provider(
    assert(opts.state), assert(opts.image_namespace))
  provider.surface = assert(opts.surface)
  provider.callback = opts.callback
end

return M
