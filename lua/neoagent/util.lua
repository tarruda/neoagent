local M = {}

local list_mt = { __neoagent_list = true }

function M.list(values)
  return setmetatable(values or {}, list_mt)
end

function M.is_list(value)
  if type(value) ~= "table" then
    return false
  end
  if getmetatable(value) == list_mt then
    return true
  end
  if vim.islist then
    return vim.islist(value)
  end
  return vim.tbl_islist(value)
end

local function encode_json(value, stack)
  if type(value) ~= "table" then return vim.json.encode(value) end
  if stack[value] then error("cannot encode circular JSON value", 0) end
  stack[value] = true
  local parts = {}
  if M.is_list(value) then
    for index = 1, #value do parts[index] = encode_json(value[index], stack) end
    stack[value] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then error("JSON object keys must be strings", 0) end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = vim.json.encode(key) .. ":" .. encode_json(value[key], stack)
  end
  stack[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.json_encode(value)
  return encode_json(value, {})
end

local function utf8_sequence_length(value, index)
  local first = value:byte(index)
  if not first then return nil end
  if first < 0x80 then return 1 end
  local second = value:byte(index + 1)
  if first >= 0xC2 and first <= 0xDF then
    return second and second >= 0x80 and second <= 0xBF and 2 or nil
  end
  local third = value:byte(index + 2)
  if first == 0xE0 then
    return second and second >= 0xA0 and second <= 0xBF
      and third and third >= 0x80 and third <= 0xBF and 3 or nil
  end
  if (first >= 0xE1 and first <= 0xEC) or (first >= 0xEE and first <= 0xEF) then
    return second and second >= 0x80 and second <= 0xBF
      and third and third >= 0x80 and third <= 0xBF and 3 or nil
  end
  if first == 0xED then
    return second and second >= 0x80 and second <= 0x9F
      and third and third >= 0x80 and third <= 0xBF and 3 or nil
  end
  local fourth = value:byte(index + 3)
  if first == 0xF0 then
    return second and second >= 0x90 and second <= 0xBF
      and third and third >= 0x80 and third <= 0xBF
      and fourth and fourth >= 0x80 and fourth <= 0xBF and 4 or nil
  end
  if first >= 0xF1 and first <= 0xF3 then
    return second and second >= 0x80 and second <= 0xBF
      and third and third >= 0x80 and third <= 0xBF
      and fourth and fourth >= 0x80 and fourth <= 0xBF and 4 or nil
  end
  if first == 0xF4 then
    return second and second >= 0x80 and second <= 0x8F
      and third and third >= 0x80 and third <= 0xBF
      and fourth and fourth >= 0x80 and fourth <= 0xBF and 4 or nil
  end
end

local non_ascii_pattern = "[\128-\255]"

function M.is_valid_utf8(value)
  if type(value) ~= "string" then return false end
  if not value:find(non_ascii_pattern) then return true end
  local index = 1
  while index <= #value do
    local length = utf8_sequence_length(value, index)
    if not length then return false end
    index = index + length
  end
  return true
end

local function escaped_byte(value)
  return string.format("\\x%02X", value)
end

local unsafe_text_byte_pattern = "[^\t\n -~]"

function M.text_from_bytes(value)
  assert(type(value) == "string", "value must be a string")
  if not value:find(unsafe_text_byte_pattern) then return value, 0 end
  local parts = {}
  local escaped = 0
  local index = 1
  while index <= #value do
    local first = value:byte(index)
    local length = utf8_sequence_length(value, index)
    local ascii_control = length == 1 and first ~= 0x09 and first ~= 0x0A
      and (first < 0x20 or first == 0x7F)
    local c1_control = length == 2 and first == 0xC2
      and value:byte(index + 1) <= 0x9F
    if not length or ascii_control or c1_control then
      local count = length or 1
      for offset = 0, count - 1 do
        parts[#parts + 1] = escaped_byte(value:byte(index + offset))
      end
      escaped = escaped + count
      index = index + count
    else
      parts[#parts + 1] = value:sub(index, index + length - 1)
      index = index + length
    end
  end
  return table.concat(parts), escaped
end

function M.copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local result = {}
  seen[value] = result
  for key, child in pairs(value) do
    result[M.copy(key, seen)] = M.copy(child, seen)
  end
  return setmetatable(result, getmetatable(value))
end

function M.deep_merge(base, override, key_normalizer)
  local result = M.copy(base or {})
  for key, value in pairs(override or {}) do
    local target_key = key
    if key_normalizer then
      local normalized = key_normalizer(key)
      for existing in pairs(result) do
        if key_normalizer(existing) == normalized then
          target_key = existing
          break
        end
      end
    end
    if type(value) == "table" and type(result[target_key]) == "table"
        and not M.is_list(value) and not M.is_list(result[target_key]) then
      result[target_key] = M.deep_merge(result[target_key], value, key_normalizer)
    else
      result[target_key] = M.copy(value)
    end
  end
  return result
end

function M.error(kind, message, detail)
  local err = { kind = kind, message = message }
  if detail ~= nil and detail ~= "" then
    err.detail = detail
  end
  return err
end

local function utf8_prefix(value, maximum)
  local index, characters = 1, 0
  while index <= #value and characters < maximum do
    index = index + (utf8_sequence_length(value, index) or 1)
    characters = characters + 1
  end
  return value:sub(1, index - 1), index <= #value
end

function M.safe_message(value, opts)
  opts = type(opts) == "table" and opts or {}
  local maximum = type(opts.max_characters) == "number"
      and opts.max_characters >= 1 and opts.max_characters ~= math.huge
      and math.floor(opts.max_characters) or 1024
  local maximum_bytes = type(opts.max_source_bytes) == "number"
      and opts.max_source_bytes >= 1 and opts.max_source_bytes ~= math.huge
      and math.floor(opts.max_source_bytes)
      or maximum * 4
  local fallback = type(opts.fallback) == "string"
      and opts.fallback or "Error value could not be rendered"
  local rendered_ok, rendered = pcall(tostring, value)
  if not rendered_ok or type(rendered) ~= "string" then rendered = fallback end
  local source = rendered:sub(1, maximum_bytes)
  local message = M.text_from_bytes(source)
  local truncated = #rendered > #source
  local _, character_truncated = utf8_prefix(message, maximum)
  truncated = truncated or character_truncated
  if truncated then
    message = utf8_prefix(message, math.max(0, maximum - 1)) .. "…"
  end
  return message
end

local MAX_ERROR_DEPTH = 8
local MAX_ERROR_TABLES = 64
local MAX_ERROR_KEYS = 256
local MAX_ERROR_STRING_CHARACTERS = 1024

local function plain_error_scalar(value, key)
  if value == vim.NIL then return vim.NIL end
  local value_type = type(value)
  if value_type == "string" then
    return M.safe_message(value, {
      max_characters = key and 128 or MAX_ERROR_STRING_CHARACTERS,
      max_source_bytes = key and 512 or MAX_ERROR_STRING_CHARACTERS * 4,
    })
  end
  if value_type == "number" then
    if value == value and value ~= math.huge and value ~= -math.huge then
      return value
    end
    return nil
  end
  if value_type == "boolean" then return value end
  return nil
end

local function plain_error_copy(value, state, depth)
  local scalar = plain_error_scalar(value, false)
  if scalar ~= nil or value == vim.NIL then return scalar end
  if type(value) ~= "table" or depth >= MAX_ERROR_DEPTH
      or state.active[value] or state.seen[value] then
    return nil
  end
  state.tables = state.tables + 1
  if state.tables > MAX_ERROR_TABLES then return nil end
  state.active[value] = true
  state.seen[value] = true
  local result = {}
  local cursor
  local had_entries = false
  while state.keys < (state.key_limit or MAX_ERROR_KEYS) do
    local advanced, key, child = pcall(next, value, cursor)
    if not advanced or key == nil then break end
    had_entries = true
    cursor = key
    local copied_key = plain_error_scalar(key, true)
    if copied_key ~= nil then
      local copied_child = plain_error_copy(child, state, depth + 1)
      if copied_child ~= nil or child == vim.NIL then
        result[copied_key] = copied_child
        state.keys = state.keys + 1
      end
    end
  end
  state.active[value] = nil
  if had_entries and next(result) == nil then return nil end
  return result
end

function M.normalize_error(err, kind)
  if type(err) == "table"
      and type(rawget(err, "kind")) == "string"
      and type(rawget(err, "message")) == "string" then
    local copy_state = {
      active = {},
      seen = {},
      tables = 0,
      keys = 0,
      key_limit = MAX_ERROR_KEYS - 18,
    }
    local copied_ok, copied = pcall(
      plain_error_copy, err, copy_state, 0)
    if not copied_ok or type(copied) ~= "table" then copied = {} end
    copied.kind = M.safe_message(rawget(err, "kind"), {
      fallback = kind or "tool",
      max_characters = 64,
      max_source_bytes = 256,
    })
    copied.message = M.safe_message(rawget(err, "message"))
    local priority_state = {
      active = {},
      seen = {},
      tables = 0,
      keys = copy_state.keys,
      key_limit = MAX_ERROR_KEYS - 2,
    }
    for _, name in ipairs({
      "code", "status", "retry_after_ms", "retryable",
      "provider_status", "provider_status_details", "stream_max_retries",
    }) do
      local selected = rawget(err, name)
      local safe = plain_error_copy(selected, priority_state, 0)
      if safe ~= nil or selected == vim.NIL then copied[name] = safe end
    end
    return copied
  end
  return M.error(kind or "tool", M.safe_message(err))
end

M.MAX_ERROR_DEPTH = MAX_ERROR_DEPTH
M.MAX_ERROR_TABLES = MAX_ERROR_TABLES
M.MAX_ERROR_KEYS = MAX_ERROR_KEYS
M.MAX_ERROR_STRING_CHARACTERS = MAX_ERROR_STRING_CHARACTERS

function M.schedule(fn)
  vim.schedule(fn)
end

function M.now_ms()
  local seconds, microseconds = vim.uv.gettimeofday()
  return seconds * 1000 + math.floor(microseconds / 1000)
end

function M.trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.text_content(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      parts[#parts + 1] = block.text or ""
    end
  end
  return table.concat(parts)
end

function M.content_blocks(content)
  if type(content) == "string" then
    return { { type = "text", text = content } }
  end
  return M.copy(content or {})
end

return M
