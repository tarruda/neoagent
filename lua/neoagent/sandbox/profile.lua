local util = require("neoagent.util")
local path_module = require("neoagent.sandbox.path")

local M = {}

---@alias Neoagent.SandboxAccess "deny"|"read"|"write"
---@alias Neoagent.SandboxNetwork "restricted"|"enabled"

---@class Neoagent.SandboxFilesystemEntry
---@field path string
---@field access Neoagent.SandboxAccess

---@class Neoagent.SandboxFilesystem
---@field default "read"
---@field entries Neoagent.SandboxFilesystemEntry[]

---@class Neoagent.SandboxEnvironment
---@field clear boolean
---@field inherit string[]
---@field set table<string, string>

---@class Neoagent.SandboxAccessPolicy
---@field filesystem Neoagent.SandboxFilesystem
---@field network Neoagent.SandboxNetwork

---@class Neoagent.SandboxProfile: Neoagent.SandboxAccessPolicy
---@field id string
---@field environment Neoagent.SandboxEnvironment

---@alias Neoagent.SandboxProfileSource<C> Neoagent.SandboxProfile|(fun(ctx: C): Neoagent.SandboxProfile)

---@class Neoagent.SandboxProfileOverrides
---@field id? string
---@field filesystem? {default?: 'read', entries?: Neoagent.SandboxFilesystemEntry[]}
---@field network? Neoagent.SandboxNetwork
---@field environment? {clear?: boolean, inherit?: string[], set?: table<string, string>}

---@class Neoagent.SandboxProfileInput
---@field id? unknown
---@field filesystem? unknown
---@field network? unknown
---@field environment? unknown

---@class Neoagent.SandboxFilesystemInput
---@field default? unknown
---@field entries? unknown

---@class Neoagent.SandboxEnvironmentInput
---@field clear? unknown
---@field inherit? unknown
---@field set? unknown


---@type table<string, boolean>
local access = { deny = true, read = true, write = true }
---@type table<string, boolean>
local network = { restricted = true, enabled = true }
local environment_name = "^[A-Za-z_][A-Za-z0-9_]*$"

---@param message string
---@return never
local function invalid(message)
  error(util.error("sandbox", "Invalid sandbox profile: " .. message), 0)
end

---@param value unknown
---@param name string
---@return table<string, unknown>
local function assert_object(value, name)
  if type(value) ~= "table" or next(value) ~= nil and util.is_list(value) then
    invalid(name .. " must be an object")
  end
  return value
end

---@param value table
---@param allowed table<string, boolean>
---@param name string
local function assert_keys(value, allowed, name)
  for key in pairs(value) do
    if type(key) ~= "string" or not allowed[key] then
      invalid(name .. " contains unsupported field " .. tostring(key))
    end
  end
end

---@param value unknown
---@param name string
---@param paths Neoagent.SandboxPaths
---@return string
local function absolute_path(value, name, paths)
  if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
    invalid(name .. " must be a non-empty absolute path without NUL bytes")
  end
  local ok, normalized = pcall(paths.normalize, value)
  if not ok or not paths.is_absolute(normalized) then
    invalid(name .. " must be absolute")
  end
  local canonical = paths.canonical_candidate(normalized)
  if paths.key(canonical) ~= paths.key(normalized) then
    invalid(name .. " must use a canonical path")
  end
  return normalized
end

---@param value unknown
---@param paths Neoagent.SandboxPaths
---@return Neoagent.SandboxFilesystem
local function normalize_filesystem(value, paths)
  value = assert_object(value, "filesystem")
  ---@cast value Neoagent.SandboxFilesystemInput
  assert_keys(value, { default = true, entries = true }, "filesystem")
  if value.default ~= "read" then
    invalid("filesystem.default must be read")
  end
  if type(value.entries) ~= "table" or not util.is_list(value.entries) then
    invalid("filesystem.entries must be a list")
  end
  ---@type table<string, Neoagent.SandboxFilesystemEntry>
  local by_path = {}
  ---@type table<Neoagent.SandboxAccess, integer>
  local precedence = { read = 1, write = 2, deny = 3 }
  for index, source in ipairs(value.entries) do
    local name = "filesystem.entries[" .. index .. "]"
    source = assert_object(source, name)
    assert_keys(source, { path = true, access = true }, name)
    if not access[rawget(source, "access")] then
      invalid(name .. ".access must be deny, read, or write")
    end
    local path = absolute_path(rawget(source, "path"), name .. ".path", paths)
    if paths.key(path) == paths.key(assert(paths.root(path))) then
      invalid(name .. ".path cannot override the filesystem default")
    end
    local stat = paths.stat(path)
    if rawget(source, "access") == "write" and not stat then
      invalid(name .. ".path must exist for write access")
    end
    local key = paths.key(path)
    local existing = by_path[key]
    if not existing
        or precedence[rawget(source, "access")] > precedence[existing.access] then
      by_path[key] = {
        path = path,
        access = rawget(source, "access"),
      }
    end
  end
  ---@type Neoagent.SandboxFilesystemEntry[]
  local entries = {}
  for _, entry in pairs(by_path) do entries[#entries + 1] = entry end
  table.sort(entries, function(left, right)
    local left_depth, right_depth =
      paths.depth(left.path), paths.depth(right.path)
    if left_depth ~= right_depth then return left_depth < right_depth end
    return paths.key(left.path) < paths.key(right.path)
  end)
  return { default = "read", entries = entries }
end

---@param value unknown
---@param paths Neoagent.SandboxPaths
---@return Neoagent.SandboxEnvironment
local function normalize_environment(value, paths)
  value = assert_object(value, "environment")
  ---@cast value Neoagent.SandboxEnvironmentInput
  assert_keys(value, { clear = true, inherit = true, set = true }, "environment")
  if type(value.clear) ~= "boolean" then
    invalid("environment.clear must be boolean")
  end
  if type(value.inherit) ~= "table" or not util.is_list(value.inherit) then
    invalid("environment.inherit must be a list")
  end
  ---@type string[]
  local inherit = {}
  ---@type table<string, string>
  local seen = {}
  for index, name in ipairs(value.inherit) do
    if type(name) ~= "string" or not name:match(environment_name) then
      invalid("environment.inherit[" .. index .. "] must be a variable name")
    end
    local key = paths.environment_key(name)
    if not seen[key] then
      seen[key] = name
      inherit[#inherit + 1] = name
    end
  end
  local configured = assert_object(value.set, "environment.set")
  ---@type table<string, string>
  local set = {}
  local names = vim.tbl_keys(configured)
  table.sort(names)
  for _, name in ipairs(names) do
    local item = configured[name]
    if type(name) ~= "string" or not name:match(environment_name) then
      invalid("environment.set contains an invalid variable name")
    end
    if type(item) ~= "string" or item:find("\0", 1, true) then
      invalid("environment.set values must be strings without NUL bytes")
    end
    local key = paths.environment_key(name)
    local spelling = seen[key] or name
    set[spelling] = item
    seen[key] = spelling
  end
  return { clear = value.clear, inherit = inherit, set = set }
end

---@param source unknown
---@param opts? {paths?: Neoagent.SandboxPaths}
---@return Neoagent.SandboxProfile, string
function M.validate(source, opts)
  opts = opts or {}
  local paths = opts.paths or path_module.posix
  source = assert_object(source, "profile")
  ---@cast source Neoagent.SandboxProfileInput
  assert_keys(source, {
    id = true,
    filesystem = true,
    network = true,
    environment = true,
  }, "profile")
  if type(source.id) ~= "string" or source.id == "" or #source.id > 128 then
    invalid("id must be a non-empty string of at most 128 bytes")
  end
  local selected_network = source.network
  if not network[selected_network] then
    invalid("network must be restricted or enabled")
  end
  ---@cast selected_network Neoagent.SandboxNetwork
  ---@type Neoagent.SandboxProfile
  local normalized = {
    id = source.id,
    filesystem = normalize_filesystem(source.filesystem, paths),
    network = selected_network,
    environment = normalize_environment(source.environment, paths),
  }
  return util.copy(normalized), util.json_encode(normalized)
end

---@generic C
---@param source Neoagent.SandboxProfileSource<C>
---@param ctx C
---@param opts? {paths?: Neoagent.SandboxPaths}
---@return Neoagent.SandboxProfile, string
function M.resolve(source, ctx, opts)
  if type(source) == "function" then
    local ok, value = pcall(source, ctx)
    if not ok then error(util.normalize_error(value, "sandbox"), 0) end
    source = value
  end
  return M.validate(source, opts)
end

return M
