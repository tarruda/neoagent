local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.WorkspaceSettingsOptions
---@field directory string
---@field root string

---@class Neoagent.WorkspaceSettingsMetadata
---@field root string
---@field directory string
---@field settings_path string
---@field sessions_directory string

---@class Neoagent.WorkspaceSettings: Neoagent.WorkspaceSettingsMetadata
local Settings = {}
Settings.__index = Settings

---@param message string
---@param detail? unknown
---@return Neoagent.Error
local function settings_error(message, detail)
  return util.error("settings", message, detail)
end

---@return Neoagent.WorkspaceSettingsMetadata
function Settings:metadata()
  return {
    root = self.root,
    directory = self.directory,
    settings_path = self.settings_path,
    sessions_directory = self.sessions_directory,
  }
end

---@return Neoagent.JsonObject?, Neoagent.Error?
function Settings:load()
  if not vim.uv.fs_stat(self.settings_path) then return {} end
  local content, read_err = fs.read(self.settings_path)
  if not content then return nil, settings_error("Failed to read workspace settings", read_err) end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" or util.is_list(decoded) then
    return nil, settings_error("Invalid workspace settings", ok and "expected an object" or decoded)
  end
  ---@cast decoded Neoagent.JsonObject
  return util.copy(decoded)
end

---@param defaults? Neoagent.JsonObject
---@return Neoagent.JsonObject?, Neoagent.JsonObject|Neoagent.Error|nil
function Settings:merge(defaults)
  local overrides, err = self:load()
  if not overrides then return nil, err end
  return util.deep_merge(defaults or {}, overrides), overrides
end

---@param settings Neoagent.JsonObject
---@return Neoagent.JsonObject?, string?, Neoagent.Error?
---@return_overload Neoagent.JsonObject, string
---@return_overload nil, nil, Neoagent.Error
local function encoded_settings(settings)
  assert(type(settings) == "table" and (next(settings) == nil or not util.is_list(settings)),
    "workspace settings must be an object")
  if next(settings) == nil then settings = vim.empty_dict() end
  local encoded_ok, encoded = pcall(vim.json.encode, settings)
  if not encoded_ok then
    return nil, nil, settings_error("Failed to encode workspace settings", encoded)
  end
  return settings, encoded
end

---@param value unknown
---@return TypeGuard<Neoagent.JsonObject>
local function object(value)
  return type(value) == "table"
    and (next(value) == nil or not util.is_list(value))
end

---@param current? Neoagent.JsonObject
---@param patch? Neoagent.JsonObject
---@return Neoagent.JsonObject
local function merge_patch(current, patch)
  local result = util.copy(current or {})
  for key, value in pairs(patch or {}) do
    if value == vim.NIL then
      result[key] = nil
    elseif object(value) and object(result[key]) then
      result[key] = merge_patch(result[key], value)
    else
      result[key] = util.copy(value)
    end
  end
  return result
end

---@param settings Neoagent.JsonObject
---@return Neoagent.JsonObject
local function prune_agent_scopes(settings)
  local agents = settings.agents
  if not object(agents) then return settings end
  for name, scope in pairs(agents) do
    if object(scope) and next(scope) == nil then agents[name] = nil end
  end
  if next(agents) == nil then settings.agents = nil end
  return settings
end

---@param self Neoagent.WorkspaceSettings
---@return true?, Neoagent.Error?
local function prepare_directory(self)
  local ok, err = fs.ensure_private_directory(self.directory, 448)
  if not ok then return nil, settings_error("Failed to create workspace directory", err) end
  return true
end

---@param self Neoagent.WorkspaceSettings
---@param settings Neoagent.JsonObject
---@param encoded string
---@return Neoagent.JsonObject?, Neoagent.Error?
local function replace(self, settings, encoded)
  local ok, err, stage = fs.atomic_replace(
    self.settings_path, encoded .. "\n", { mode = 384 })
  if not ok then
    local action = stage == "temporary"
        and "create workspace settings temporary file"
      or stage == "rename" and "replace workspace settings"
      or "write workspace settings"
    return nil, settings_error("Failed to " .. action, err)
  end
  return util.copy(settings)
end

---@param self Neoagent.WorkspaceSettings
---@param fn fun(): Neoagent.JsonObject?, Neoagent.Error?
---@return Neoagent.JsonObject?, Neoagent.Error?
local function with_lock(self, fn)
  local result, err = file_lock.new({
    path = self.settings_path .. ".lock",
  }):with(fn)
  if not result and type(err) == "table" and err.kind == "file_lock" then
    local releasing = err.code == "release" or err.code == "ownership"
    local action = releasing and "release" or "acquire"
    return nil, settings_error("Failed to " .. action .. " workspace settings lock",
      rawget(err, "detail") or err.message)
  end
  return result, err
end

---@param settings Neoagent.JsonObject
---@return Neoagent.JsonObject?, Neoagent.Error?
function Settings:write(settings)
  local normalized, encoded, encode_err = encoded_settings(settings)
  if not normalized then return nil, encode_err end
  local prepared, prepare_err = prepare_directory(self)
  if not prepared then return nil, prepare_err end
  return with_lock(self, function() return replace(self, normalized, encoded) end)
end

---@param patch Neoagent.JsonObject
---@return Neoagent.JsonObject?, Neoagent.Error?
function Settings:update(patch)
  assert(type(patch) == "table" and (next(patch) == nil or not util.is_list(patch)),
    "workspace settings patch must be an object")
  local prepared, prepare_err = prepare_directory(self)
  if not prepared then return nil, prepare_err end
  return with_lock(self, function()
    local current, read_err = self:load()
    if not current then return nil, read_err end
    local merged = prune_agent_scopes(merge_patch(current, patch))
    local normalized, encoded, encode_err = encoded_settings(merged)
    if not normalized then return nil, encode_err end
    return replace(self, normalized, encoded)
  end)
end

---@param opts Neoagent.WorkspaceSettingsOptions
---@return Neoagent.WorkspaceSettings
function M.new(opts)
  opts = opts or {}
  assert(type(opts.directory) == "string" and opts.directory ~= "", "directory is required")
  assert(type(opts.root) == "string" and opts.root ~= "", "root is required")
  local root = fs.canonical(opts.root)
  local basename = assert(vim.fs.basename(root)):gsub('[%c<>:"/\\|?*]', "-")
  if basename == "" or basename == "." or basename == ".." then
    basename = "root"
  end
  local directory = fs.join(fs.normalize(opts.directory),
    basename .. "-" .. vim.fn.sha256(root))
  return setmetatable({
    root = root,
    directory = directory,
    settings_path = fs.join(directory, "settings.json"),
    sessions_directory = fs.join(directory, "sessions"),
  }, Settings)
end

return M
