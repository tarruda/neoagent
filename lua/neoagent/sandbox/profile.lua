local util = require("neoagent.util")

local M = {}

local access = { deny = true, read = true, write = true }
local network = { restricted = true, enabled = true }
local environment_name = "^[A-Za-z_][A-Za-z0-9_]*$"

local function invalid(message)
  error(util.error("sandbox", "Invalid sandbox profile: " .. message), 0)
end

local function assert_object(value, name)
  if type(value) ~= "table" or next(value) ~= nil and util.is_list(value) then
    invalid(name .. " must be an object")
  end
end

local function assert_keys(value, allowed, name)
  for key in pairs(value) do
    if type(key) ~= "string" or not allowed[key] then
      invalid(name .. " contains unsupported field " .. tostring(key))
    end
  end
end

local function absolute_path(value, name)
  if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
    invalid(name .. " must be a non-empty absolute path without NUL bytes")
  end
  local normalized = vim.fs.normalize(value)
  if normalized:sub(1, 1) ~= "/" then invalid(name .. " must be absolute") end
  local current, suffix = normalized, {}
  local canonical = vim.uv.fs_realpath(current)
  while not canonical do
    local parent = vim.fs.dirname(current)
    if parent == current then break end
    table.insert(suffix, 1, vim.fs.basename(current))
    current = parent
    canonical = vim.uv.fs_realpath(current)
  end
  if canonical then
    for _, part in ipairs(suffix) do
      canonical = vim.fs.joinpath(canonical, part)
    end
    if vim.fs.normalize(canonical) ~= normalized then
      invalid(name .. " must use a canonical path")
    end
  end
  return normalized
end

local function normalize_filesystem(value)
  assert_object(value, "filesystem")
  assert_keys(value, { default = true, entries = true }, "filesystem")
  if value.default ~= "read" then
    invalid("filesystem.default must be read")
  end
  if type(value.entries) ~= "table" or not util.is_list(value.entries) then
    invalid("filesystem.entries must be a list")
  end
  local by_path = {}
  local precedence = { read = 1, write = 2, deny = 3 }
  for index, source in ipairs(value.entries) do
    local name = "filesystem.entries[" .. index .. "]"
    assert_object(source, name)
    assert_keys(source, { path = true, access = true }, name)
    if not access[source.access] then
      invalid(name .. ".access must be deny, read, or write")
    end
    local path = absolute_path(source.path, name .. ".path")
    if path == "/" then
      invalid(name .. ".path cannot override the filesystem default")
    end
    local stat = vim.uv.fs_stat(path)
    if source.access == "write" and not stat then
      invalid(name .. ".path must exist for write access")
    end
    local existing = by_path[path]
    if not existing
        or precedence[source.access] > precedence[existing.access] then
      by_path[path] = {
        path = path,
        access = source.access,
      }
    end
  end
  local entries = {}
  for _, entry in pairs(by_path) do entries[#entries + 1] = entry end
  table.sort(entries, function(left, right)
    if #left.path ~= #right.path then return #left.path < #right.path end
    return left.path < right.path
  end)
  return { default = "read", entries = entries }
end

local function normalize_environment(value)
  assert_object(value, "environment")
  assert_keys(value, { clear = true, inherit = true, set = true }, "environment")
  if type(value.clear) ~= "boolean" then
    invalid("environment.clear must be boolean")
  end
  if type(value.inherit) ~= "table" or not util.is_list(value.inherit) then
    invalid("environment.inherit must be a list")
  end
  local inherit, seen = {}, {}
  for index, name in ipairs(value.inherit) do
    if type(name) ~= "string" or not name:match(environment_name) then
      invalid("environment.inherit[" .. index .. "] must be a variable name")
    end
    if not seen[name] then
      seen[name] = true
      inherit[#inherit + 1] = name
    end
  end
  assert_object(value.set, "environment.set")
  local set = {}
  for name, item in pairs(value.set) do
    if type(name) ~= "string" or not name:match(environment_name) then
      invalid("environment.set contains an invalid variable name")
    end
    if type(item) ~= "string" or item:find("\0", 1, true) then
      invalid("environment.set values must be strings without NUL bytes")
    end
    set[name] = item
  end
  return { clear = value.clear, inherit = inherit, set = set }
end

function M.validate(source)
  assert_object(source, "profile")
  assert_keys(source, {
    id = true,
    filesystem = true,
    network = true,
    environment = true,
    temporary = true,
  }, "profile")
  if type(source.id) ~= "string" or source.id == "" or #source.id > 128 then
    invalid("id must be a non-empty string of at most 128 bytes")
  end
  if not network[source.network] then
    invalid("network must be restricted or enabled")
  end
  if source.temporary ~= "private" then
    invalid("temporary must be private")
  end
  local normalized = {
    id = source.id,
    filesystem = normalize_filesystem(source.filesystem),
    network = source.network,
    environment = normalize_environment(source.environment),
    temporary = "private",
  }
  return util.copy(normalized), util.json_encode(normalized)
end

function M.resolve(source, ctx)
  if type(source) == "function" then
    local ok, value = pcall(source, ctx)
    if not ok then error(util.normalize_error(value, "sandbox"), 0) end
    source = value
  end
  return M.validate(source)
end

return M
