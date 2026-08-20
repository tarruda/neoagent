local util = require("neoagent.util")

local M = {}

local operation_states = {
  queued = true,
  running = true,
  succeeded = true,
  failed = true,
  cancelled = true,
}

local levels = {
  info = true,
  success = true,
  warn = true,
  error = true,
  muted = true,
}

local function text(value, name, maximum, optional)
  if value == nil and optional then return nil end
  if optional and value == "" then return nil end
  if type(value) ~= "string" then
    return nil, util.error("provider", name .. " must be a string")
  end
  if value == "" then
    return nil, util.error("provider", name .. " must not be empty")
  end
  if #value > maximum then
    return nil, util.error("provider",
      name .. " exceeds " .. tostring(maximum) .. " bytes")
  end
  if not util.is_valid_utf8(value) then
    return nil, util.error("provider", name .. " must contain valid UTF-8")
  end
  if value:find("[%z\1-\31\127]") then
    return nil, util.error("provider",
      name .. " must not contain control characters")
  end
  return value
end

local function label(value, name)
  return text(value, name, 512, false)
end

local function detail(value, name)
  return text(value, name, 512, true)
end

local function list(value, name)
  if type(value) ~= "table" or not util.is_list(value) then
    return nil, util.error("provider", name .. " must be a list")
  end
  return value
end

local function object(value, name)
  if type(value) ~= "table"
      or (next(value) ~= nil and util.is_list(value)) then
    return nil, util.error("provider", name .. " must be an object")
  end
  return value
end

local function normalized_level(value, name, fallback)
  value = value == nil and fallback or value
  local result, err = text(value, name, 16, false)
  if not result then return nil, err end
  if not levels[result] then
    return nil, util.error("provider", "unknown " .. name .. ": " .. result)
  end
  return result
end

local function normalized_ratio(value, name, optional)
  if value == nil and optional then return nil end
  if type(value) ~= "number" or value ~= value
      or value == math.huge or value == -math.huge
      or value < 0 or value > 1 then
    return nil, util.error("provider",
      name .. " must be a finite number in [0, 1]")
  end
  return value
end

local function normalized_activity(value)
  local entries, err = list(value, "provider activity entries")
  if not entries then return nil, err end
  if #entries > 50 then
    return nil, util.error("provider",
      "provider activity exceeds 50 entries")
  end
  local result = {}
  for _, source in ipairs(entries) do
    local item, item_err = object(source, "provider activity entry")
    if not item then return nil, item_err end
    local level, level_err = normalized_level(
      item.level, "activity level", "info")
    if not level then return nil, level_err end
    local message, message_err = text(
      item.message, "activity message", 512, false)
    if not message then return nil, message_err end
    if item.timestamp ~= nil
        and (type(item.timestamp) ~= "number"
          or item.timestamp ~= item.timestamp
          or item.timestamp == math.huge
          or item.timestamp == -math.huge) then
      return nil, util.error("provider",
        "activity timestamp must be a finite number")
    end
    result[#result + 1] = {
      level = level,
      message = message,
      timestamp = item.timestamp,
    }
  end
  return result
end

local function normalized_items(value)
  local items, err = list(value, "provider list items")
  if not items then return nil, err end
  if #items > 100 then
    return nil, util.error("provider", "provider list exceeds 100 items")
  end
  local result = {}
  for _, source in ipairs(items) do
    local item, item_err = object(source, "provider list item")
    if not item then return nil, item_err end
    local item_label, label_err = label(item.label, "list item label")
    if not item_label then return nil, label_err end
    local item_detail, detail_err = detail(item.detail, "list item detail")
    if not item_detail and detail_err then return nil, detail_err end
    result[#result + 1] = {
      label = item_label,
      detail = item_detail,
    }
  end
  return result
end

local function normalized_block(value)
  local block, err = object(value, "provider block")
  if not block then return nil, err end
  local block_type, type_err = text(
    block.type, "provider block type", 32, false)
  if not block_type then return nil, type_err end

  if block_type == "status" then
    local status_text, status_err = text(
      block.text, "status text", 512, false)
    if not status_text then return nil, status_err end
    local level, level_err = normalized_level(
      block.level, "status level", "info")
    if not level then return nil, level_err end
    return { type = block_type, text = status_text, level = level }
  end

  if block_type == "field" then
    local field_label, label_err = label(block.label, "field label")
    if not field_label then return nil, label_err end
    local field_value, value_err = text(
      block.value, "field value", 512, false)
    if not field_value then return nil, value_err end
    return { type = block_type, label = field_label, value = field_value }
  end

  if block_type == "progress" then
    local progress_label, label_err = label(block.label, "progress label")
    if not progress_label then return nil, label_err end
    local value_ratio, ratio_err = normalized_ratio(
      block.value, "progress value", true)
    if not value_ratio and ratio_err then return nil, ratio_err end
    local progress_detail, detail_err = detail(
      block.detail, "progress detail")
    if not progress_detail and detail_err then return nil, detail_err end
    local level, level_err = normalized_level(
      block.level, "progress level", "info")
    if not level then return nil, level_err end
    return {
      type = block_type,
      label = progress_label,
      value = value_ratio,
      detail = progress_detail,
      level = level,
    }
  end

  if block_type == "limit" then
    local limit_label, label_err = label(block.label, "limit label")
    if not limit_label then return nil, label_err end
    local remaining, ratio_err = normalized_ratio(
      block.remaining, "limit remaining", false)
    if not remaining then return nil, ratio_err end
    if block.resets_at ~= nil
        and (type(block.resets_at) ~= "number"
          or block.resets_at ~= block.resets_at
          or block.resets_at == math.huge
          or block.resets_at == -math.huge) then
      return nil, util.error("provider",
        "limit resets_at must be a finite Unix timestamp")
    end
    local limit_detail, detail_err = detail(block.detail, "limit detail")
    if not limit_detail and detail_err then return nil, detail_err end
    local level, level_err = normalized_level(
      block.level, "limit level", "info")
    if not level then return nil, level_err end
    return {
      type = block_type,
      label = limit_label,
      remaining = remaining,
      resets_at = block.resets_at,
      detail = limit_detail,
      level = level,
    }
  end

  if block_type == "list" then
    local title, title_err = label(block.title, "list title")
    if not title then return nil, title_err end
    local items, items_err = normalized_items(block.items)
    if not items then return nil, items_err end
    return { type = block_type, title = title, items = items }
  end

  if block_type == "activity" then
    local title, title_err = label(
      block.title or "Recent activity", "activity title")
    if not title then return nil, title_err end
    local entries, entries_err = normalized_activity(block.entries)
    if not entries then return nil, entries_err end
    return { type = block_type, title = title, entries = entries }
  end

  return nil, util.error("provider",
    "unknown provider block type: " .. block_type)
end

local function normalized_operation(value)
  if value == nil then return nil end
  local operation, err = object(value, "provider operation")
  if not operation then return nil, err end
  local id, id_err = text(operation.id, "operation id", 128, false)
  if not id then return nil, id_err end
  local name, name_err = text(
    operation.label, "operation label", 128, false)
  if not name then return nil, name_err end
  local state, state_err = text(
    operation.state, "operation state", 32, false)
  if not state then return nil, state_err end
  if not operation_states[state] then
    return nil, util.error("provider", "unknown operation state: " .. state)
  end
  local message, message_err = detail(
    operation.message, "operation message")
  if not message and message_err then return nil, message_err end
  local ratio, ratio_err = normalized_ratio(
    operation.ratio, "operation ratio", true)
  if not ratio and ratio_err then return nil, ratio_err end
  local operation_detail, detail_err = detail(
    operation.detail, "operation detail")
  if not operation_detail and detail_err then return nil, detail_err end
  return {
    id = id,
    label = name,
    state = state,
    message = message,
    ratio = ratio,
    detail = operation_detail,
  }
end

local function legacy_blocks(source)
  local blocks = {}
  if source.summary ~= nil and source.summary ~= "" then
    blocks[#blocks + 1] = {
      type = "status", text = source.summary, level = "info",
    }
  end
  local fields, fields_err = list(source.fields or {}, "provider fields")
  if not fields then return nil, fields_err end
  for _, field in ipairs(fields) do
    local item, item_err = object(field, "provider field")
    if not item then return nil, item_err end
    blocks[#blocks + 1] = {
      type = "field", label = item.label, value = item.value,
    }
  end
  local sections, sections_err = list(
    source.sections or {}, "provider sections")
  if not sections then return nil, sections_err end
  for _, section in ipairs(sections) do
    local item, item_err = object(section, "provider section")
    if not item then return nil, item_err end
    blocks[#blocks + 1] = {
      type = "list", title = item.title, items = item.rows,
    }
  end
  local activity, activity_err = list(
    source.activity or {}, "provider activity")
  if not activity then return nil, activity_err end
  if #activity > 0 then
    blocks[#blocks + 1] = {
      type = "activity",
      title = "Recent activity",
      entries = activity,
    }
  end
  return blocks
end

function M.normalize(value)
  if value == false then return false end
  local source, err = object(value, "provider state")
  if not source then return nil, err end
  local blocks = source.blocks
  if blocks == nil then
    local legacy_err
    blocks, legacy_err = legacy_blocks(source)
    if not blocks then return nil, legacy_err end
  end
  local block_list, blocks_err = list(blocks, "provider blocks")
  if not block_list then return nil, blocks_err end
  if #block_list > 64 then
    return nil, util.error("provider", "provider blocks exceed 64 entries")
  end
  local normalized_blocks = {}
  for _, block in ipairs(block_list) do
    local normalized, block_err = normalized_block(block)
    if not normalized then return nil, block_err end
    normalized_blocks[#normalized_blocks + 1] = normalized
  end
  local operation
  if source.operation ~= nil then
    local operation_err
    operation, operation_err = normalized_operation(source.operation)
    if not operation then return nil, operation_err end
  end
  local result = { blocks = normalized_blocks }
  if operation ~= nil then result.operation = operation end
  return result
end

function M.normalize_operation(value)
  return normalized_operation(value)
end

function M.new(initial)
  local snapshot, err = M.normalize(initial or {})
  assert(snapshot and snapshot ~= false,
    err and err.message or "provider dashboard state must be an object")
  local listeners = {}
  local dashboard = {}

  function dashboard:state()
    return util.copy(snapshot)
  end

  function dashboard:push(value)
    local normalized, normalize_err = M.normalize(value)
    if not normalized or normalized == false then
      return nil, normalize_err or util.error(
        "provider", "provider dashboard state must be an object")
    end
    snapshot = normalized
    local published = util.copy(snapshot)
    local function notify_listeners()
      for _, listener in ipairs(listeners) do
        local ok, listener_err = pcall(listener, util.copy(published))
        if not ok then
          vim.notify("neoagent provider subscriber failed: "
            .. tostring(listener_err), vim.log.levels.ERROR)
        end
      end
    end
    if vim.in_fast_event() then
      vim.schedule(notify_listeners)
    else
      notify_listeners()
    end
    return true
  end

  function dashboard:subscribe(listener)
    assert(type(listener) == "function",
      "provider dashboard listener must be a function")
    listeners[#listeners + 1] = listener
    local active = true
    return function()
      if not active then return end
      active = false
      for index, candidate in ipairs(listeners) do
        if candidate == listener then
          table.remove(listeners, index)
          return
        end
      end
    end
  end

  function dashboard:destroy()
    listeners = {}
    snapshot = { blocks = {} }
  end

  return dashboard
end

return M
