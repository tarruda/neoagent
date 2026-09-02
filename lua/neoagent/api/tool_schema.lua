local util = require("neoagent.util")

local M = {}

local MAX_ISSUES = 20
local schema_fields = {
  type = true,
  properties = true,
  required = true,
  additionalProperties = true,
  items = true,
  enum = true,
  minItems = true,
  maxItems = true,
  description = true,
}

local function is_object(value)
  return type(value) == "table" and not util.is_list(value)
end

local function is_array(value)
  return type(value) == "table" and util.is_list(value)
end

local function is_schema_object(value)
  return type(value) == "table"
    and (next(value) == nil or not util.is_list(value))
end

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local type_checks = {
  array = is_array,
  boolean = function(value) return type(value) == "boolean" end,
  integer = function(value)
    return finite_number(value) and value % 1 == 0
  end,
  ["null"] = function(value) return value == vim.NIL end,
  number = finite_number,
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

local function validate_schema(schema, path, active)
  path = path or "input_schema"
  if not is_schema_object(schema) then
    return nil, path .. " must be an object"
  end
  active = active or {}
  if active[schema] then return nil, path .. " must not contain cycles" end
  active[schema] = true
  for key in pairs(schema) do
    if not schema_fields[key] then
      active[schema] = nil
      return nil, path .. " has unsupported field: " .. tostring(key)
    end
  end
  local declared = schema.type
  if declared ~= nil then
    declared = type(declared) == "string" and { declared } or declared
    if type(declared) ~= "table" or not util.is_list(declared)
        or #declared == 0 then
      active[schema] = nil
      return nil, path .. ".type must be a type name or non-empty list"
    end
    local seen = {}
    for _, name in ipairs(declared) do
      if not type_checks[name] or seen[name] then
        active[schema] = nil
        return nil, path .. ".type contains an invalid or duplicate type"
      end
      seen[name] = true
    end
  end
  if schema.description ~= nil
      and (type(schema.description) ~= "string"
        or not util.is_valid_utf8(schema.description)) then
    active[schema] = nil
    return nil, path .. ".description must be a UTF-8 string"
  end
  if schema.properties ~= nil then
    if not is_schema_object(schema.properties) then
      active[schema] = nil
      return nil, path .. ".properties must be an object"
    end
    for key, child in pairs(schema.properties) do
      if type(key) ~= "string" or key == "" then
        active[schema] = nil
        return nil, path .. ".properties keys must be non-empty strings"
      end
      local ok, err = validate_schema(
        child, path .. ".properties." .. key, active)
      if not ok then active[schema] = nil return nil, err end
    end
  end
  if schema.required ~= nil then
    if type(schema.required) ~= "table" or not util.is_list(schema.required) then
      active[schema] = nil
      return nil, path .. ".required must be a list"
    end
    local seen = {}
    for _, key in ipairs(schema.required) do
      if type(key) ~= "string" or key == "" or seen[key] then
        active[schema] = nil
        return nil, path .. ".required must contain unique non-empty strings"
      end
      seen[key] = true
    end
  end
  local additional = schema.additionalProperties
  if additional ~= nil and type(additional) ~= "boolean" then
    local ok, err = validate_schema(
      additional, path .. ".additionalProperties", active)
    if not ok then active[schema] = nil return nil, err end
  end
  if schema.items ~= nil then
    local ok, err = validate_schema(schema.items, path .. ".items", active)
    if not ok then active[schema] = nil return nil, err end
  end
  if schema.enum ~= nil then
    if type(schema.enum) ~= "table" or not util.is_list(schema.enum)
        or #schema.enum == 0 then
      active[schema] = nil
      return nil, path .. ".enum must be a non-empty list"
    end
    local encoded = pcall(util.json_encode, schema.enum)
    if not encoded then
      active[schema] = nil
      return nil, path .. ".enum must contain JSON values"
    end
  end
  for _, key in ipairs({ "minItems", "maxItems" }) do
    local value = schema[key]
    if value ~= nil and (type(value) ~= "number" or value < 0
        or value % 1 ~= 0 or value == math.huge) then
      active[schema] = nil
      return nil, path .. "." .. key .. " must be a non-negative integer"
    end
  end
  if schema.minItems ~= nil and schema.maxItems ~= nil
      and schema.minItems > schema.maxItems then
    active[schema] = nil
    return nil, path .. ".minItems must not exceed maxItems"
  end
  active[schema] = nil
  return true
end

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
  local valid, err = validate_schema(schema)
  assert(valid, err)
  local normalized = util.copy(schema)
  if next(normalized) == nil then return vim.empty_dict() end
  if normalized.type == "object" and type(normalized.properties) == "table"
      and next(normalized.properties) == nil then
    normalized.properties = vim.empty_dict()
  end
  return normalized
end

function M.validate_definition(schema)
  local valid, err = validate_schema(schema)
  if not valid then return nil, err end
  return M.normalize(schema)
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
