local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local Store = {}
Store.__index = Store

local DIRECTORY_MODE = 448
local FILE_MODE = 384

local function valid_id(id)
  if type(id) ~= "string" or id == "" then return false end
  if id:find("[/\\]") then return false end
  return true
end

local function lock(path)
  return file_lock.new({
    path = path .. ".lock",
    timeout_ms = 15000,
    poll_ms = 50,
  })
end

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

function Store:path(id)
  assert(valid_id(id), "state store ids must be non-empty names without path separators")
  return fs.join(self.directory, id .. ".json")
end

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
  return value
end

function Store:write(id, entry)
  if self.directory_error then return nil, util.copy(self.directory_error) end
  local path = self:path(id)
  local encoded, err = encode(entry)
  if not encoded then return nil, err end
  local lease, lock_err = lock(path):acquire()
  if not lease then return nil, lock_err end
  return lease:run(function()
    return fs.atomic_replace(path, encoded .. "\n", { mode = FILE_MODE })
  end)
end

function Store:delete(id)
  if self.directory_error then return nil, util.copy(self.directory_error) end
  local path = self:path(id)
  local lease, lock_err = lock(path):acquire()
  if not lease then return nil, lock_err end
  return lease:run(function()
    local removed, remove_err, remove_code = vim.uv.fs_unlink(path)
    if not removed and remove_code ~= "ENOENT" then
      return nil, remove_err
    end
    return true
  end)
end

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
