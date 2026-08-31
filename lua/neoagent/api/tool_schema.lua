local util = require("neoagent.util")

local M = {}

local MAX_ISSUES = 20

local function is_object(value)
  return type(value) == "table"
    and (next(value) == nil or not util.is_list(value))
end

local function is_array(value)
  return type(value) == "table"
    and (next(value) == nil or util.is_list(value))
end

local type_checks = {
  array = is_array,
  boolean = function(value) return type(value) == "boolean" end,
  integer = function(value)
    return type(value) == "number" and value % 1 == 0
  end,
  ["null"] = function(value) return value == vim.NIL end,
  number = function(value) return type(value) == "number" end,
  object = is_object,
  string = function(value) return type(value) == "string" end,
}

local type_labels = {
  array = "an array",
  boolean = "a boolean",
  integer = "an integer",
  ["null"] = "null",
  number = "a number",
  object = "a JSON object",
  string = "a string",
}

local function declared_types(schema)
  if type(schema.type) == "string" then return { schema.type } end
  if type(schema.type) == "table" and util.is_list(schema.type) then
    return schema.type
  end
  return {}
end

local function join_choices(values)
  if #values == 1 then return values[1] end
  if #values == 2 then return values[1] .. " or " .. values[2] end
  return table.concat(values, ", ", 1, #values - 1)
    .. ", or " .. values[#values]
end

local function matches_type(value, types)
  for _, name in ipairs(types) do
    local check = type_checks[name]
    if not check or check(value) then return true end
  end
  return #types == 0
end

local function declares(types, name)
  for _, declared in ipairs(types) do
    if declared == name then return true end
  end
  return false
end

local function sorted_keys(value)
  local keys = {}
  for key in pairs(value or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  return keys
end

local function child_path(path, key)
  local name = tostring(key)
  local suffix
  if type(key) == "string" and key:match("^[%a_][%w_]*$") then
    suffix = name
  else
    suffix = "[" .. vim.json.encode(name) .. "]"
  end
  return path == "" and suffix or path .. "." .. suffix
end

local function shown_path(path)
  return path == "" and "arguments" or path
end

local function enum_value(value)
  local encoded, text = pcall(util.json_encode, value)
  return encoded and text or tostring(value)
end

local function add_issue(state, message)
  if #state.issues < MAX_ISSUES then
    state.issues[#state.issues + 1] = message
  else
    state.truncated = true
  end
end

local function validate_value(schema, value, path, state)
  if state.truncated or type(schema) ~= "table" then return end

  local types = declared_types(schema)
  if not matches_type(value, types) then
    local labels = {}
    for _, name in ipairs(types) do
      labels[#labels + 1] = type_labels[name] or name
    end
    add_issue(state, shown_path(path) .. " must be " .. join_choices(labels))
    return
  end

  if type(schema.enum) == "table" and util.is_list(schema.enum) then
    local matched = false
    for _, candidate in ipairs(schema.enum) do
      if vim.deep_equal(value, candidate) then matched = true break end
    end
    if not matched then
      local choices = {}
      for _, candidate in ipairs(schema.enum) do
        choices[#choices + 1] = enum_value(candidate)
      end
      local allowed = #choices > 0 and join_choices(choices)
        or "an allowed value"
      add_issue(state, shown_path(path) .. " must be one of " .. allowed)
    end
  end

  local array_value = is_array(value)
  local object_value = is_object(value)
  local prefer_array = array_value and declares(types, "array")
    and not declares(types, "object")
  if object_value and not prefer_array then
    local properties = type(schema.properties) == "table"
        and schema.properties or {}
    for _, key in ipairs(schema.required or {}) do
      if value[key] == nil then
        add_issue(state, child_path(path, key) .. " is required")
      end
    end
    for _, key in ipairs(sorted_keys(properties)) do
      if value[key] ~= nil then
        validate_value(properties[key], value[key], child_path(path, key), state)
      end
    end
    for _, key in ipairs(sorted_keys(value)) do
      if properties[key] == nil then
        if schema.additionalProperties == false then
          add_issue(state, child_path(path, key) .. " is not allowed")
        elseif type(schema.additionalProperties) == "table" then
          validate_value(schema.additionalProperties, value[key],
            child_path(path, key), state)
        end
      end
    end
  elseif array_value then
    if type(schema.minItems) == "number" and #value < schema.minItems then
      add_issue(state, shown_path(path) .. " must contain at least "
        .. schema.minItems .. (schema.minItems == 1 and " item" or " items"))
    end
    if type(schema.maxItems) == "number" and #value > schema.maxItems then
      add_issue(state, shown_path(path) .. " must contain at most "
        .. schema.maxItems .. (schema.maxItems == 1 and " item" or " items"))
    end
    if type(schema.items) == "table" then
      for index, item in ipairs(value) do
        validate_value(schema.items, item,
          path .. "[" .. index .. "]", state)
      end
    end
  end
end

function M.normalize(schema)
  assert(type(schema) == "table", "tool input_schema must be a table")
  local normalized = util.copy(schema)
  if next(normalized) == nil then return vim.empty_dict() end
  if normalized.type == "object" and type(normalized.properties) == "table"
      and next(normalized.properties) == nil then
    normalized.properties = vim.empty_dict()
  end
  return normalized
end

function M.validate(schema, value)
  assert(type(schema) == "table", "tool input_schema must be a table")
  local state = { issues = {}, truncated = false }
  validate_value(schema, value, "", state)
  if #state.issues == 0 then return true end

  local lines = { "Tool call arguments do not match the declared schema:" }
  for _, issue in ipairs(state.issues) do
    lines[#lines + 1] = "- " .. issue
  end
  if state.truncated then
    lines[#lines + 1] = "- Further schema mismatches were omitted"
  end
  return false, table.concat(lines, "\n")
end

return M
