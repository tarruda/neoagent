local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.StateStore: Neoagent.CatalogStorage
---@field directory string
---@field directory_error? Neoagent.Error
local Store = {}
Store.__index = Store

local DIRECTORY_MODE = 448
local FILE_MODE = 384

---@param id unknown
---@return TypeGuard<string>
local function valid_id(id)
  if type(id) ~= "string" or id == "" then return false end
  if id:find("[/\\]") then return false end
  return true
end

---@param path string
---@return Neoagent.FileLock
local function lock(path)
  return file_lock.new({
    path = path .. ".lock",
    timeout_ms = 15000,
    poll_ms = 50,
  })
end

---@param entry unknown
---@return string?, Neoagent.Error?
local function encode(entry)
  if type(entry) ~= "table" or util.is_list(entry) then
    return nil, util.error("state_store", "entry must be an object")
  end
  local ok, encoded = pcall(util.json_encode, entry)
  if not ok then
    return nil, util.error("state_store", "entry is not JSON-encodable", encoded)
  end
  if not util.is_valid_utf8(encoded) then
    return nil, util.error("state_store", "entry must contain valid UTF-8")
  end
  return encoded
end

---@param id string
---@return string
function Store:path(id)
  assert(valid_id(id), "state store ids must be non-empty names without path separators")
  return fs.join(self.directory, id .. ".json")
end

---@param id string
---@return Neoagent.JsonObject?, Neoagent.Error?
function Store:read(id)
  local path = self:path(id)
  local data, err = fs.read(path)
  if not data then
    if type(err) == "string" and err:find("ENOENT", 1, true) then
      return nil
    end
    return nil, util.error("state_store", "failed to read " .. id, err)
  end
  local ok, value = pcall(vim.json.decode, data)
  if not ok or type(value) ~= "table" or util.is_list(value) then
    return nil, util.error("state_store", "invalid JSON for " .. id)
  end
  ---@cast value Neoagent.JsonObject
  return value
end

---@param id string
---@param entry unknown
---@return true?, Neoagent.Error?
function Store:write(id, entry)
  if self.directory_error then return nil, util.copy(self.directory_error) end
  local path = self:path(id)
  local encoded, err = encode(entry)
  if not encoded then return nil, err end
  local lease, lock_err = lock(path):acquire()
  if not lease then return nil, lock_err end
  local written, write_err = lease:run(
  ---@return true?, string?
  function()
    local replaced, replace_err = fs.atomic_replace(
      path, encoded .. "\n", { mode = FILE_MODE })
    if not replaced then return nil, replace_err end
    return true
  end)
  if not written then
    return nil, util.normalize_error(write_err, "state_store")
  end
  return true
end

---@param id string
---@return true?, Neoagent.Error?
function Store:delete(id)
  if self.directory_error then return nil, util.copy(self.directory_error) end
  local path = self:path(id)
  local lease, lock_err = lock(path):acquire()
  if not lease then return nil, lock_err end
  local deleted, delete_err = lease:run(
  ---@return true?, string?
  function()
    local removed, remove_err, remove_code = vim.uv.fs_unlink(path)
    if not removed and remove_code ~= "ENOENT" then
      return nil, remove_err
    end
    return true
  end)
  if not deleted then
    return nil, util.normalize_error(delete_err, "state_store")
  end
  return true
end

---@param opts {directory: string}
---@return Neoagent.StateStore
function M.new(opts)
  opts = opts or {}
  assert(type(opts.directory) == "string" and opts.directory ~= "",
    "state store directory is required")
  local directory = fs.normalize(opts.directory)
  local prepared, prepare_err = fs.ensure_private_directory(
    directory, DIRECTORY_MODE)
  return setmetatable({
    directory = directory,
    directory_error = not prepared and util.error(
      "state_store", "failed to prepare private state directory", prepare_err)
      or nil,
  }, Store)
end

return M
