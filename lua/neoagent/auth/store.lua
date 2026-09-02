local async = require("neoagent.async")
local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local Store = {}
Store.__index = Store
local DELETE = {}
local DEFAULT_LOCK_TIMEOUT_MS = 30000
local DEFAULT_LOCK_POLL_MS = 50

local function failure(message, detail)
  return util.error("auth", message, detail)
end

local function credential_lock_error(err, releasing)
  err = util.normalize_error(err, "file_lock")
  if err.kind == "cancelled" then return err end
  if releasing then
    return failure("Failed to release credential lock", err.detail or err.message)
  end
  if err.code == "timeout" then
    return failure("Timed out acquiring credential lock", err.detail)
  end
  return failure("Failed to acquire credential lock", err.detail or err.message)
end

function Store:_file_lock()
  return file_lock.new({
    path = self.path .. ".lock",
    timeout_ms = self.lock_timeout_ms,
    poll_ms = self.lock_poll_ms,
  })
end

function Store:_lock()
  local ok, lease = pcall(function()
    return self:_file_lock():acquire_async()
  end)
  if not ok then error(credential_lock_error(lease, false), 0) end
  return function()
    local released, release_err = lease:release()
    if not released then return nil, credential_lock_error(release_err, true) end
    return true
  end
end

function Store:_read_all()
  local stat = vim.uv.fs_stat(self.path)
  if not stat then return {} end
  local content, err = fs.read(self.path)
  if not content then return nil, failure("Failed to read credentials", err) end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" or util.is_list(decoded) then
    return nil, failure("Invalid credential file", ok and "expected an object" or decoded)
  end
  return decoded
end

function Store:read(id)
  local values, err = self:_read_all()
  if not values then return nil, err end
  return util.copy(values[id])
end

function Store:list()
  local values, err = self:_read_all()
  if not values then return nil, err end
  local result = {}
  for id, credential in pairs(values) do
    local kind = type(credential) == "table" and credential.type or nil
    if kind == nil and type(credential) == "table" and credential.access ~= nil then kind = "oauth" end
    result[#result + 1] = { id = id, type = kind or "invalid" }
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

function Store:_write_all(values)
  local directory = vim.fs.dirname(self.path)
  local ok, err
  ok, err = fs.ensure_private_directory(directory, 448)
  if not ok then return nil, failure("Failed to create credential directory", err) end
  local encoded = next(values) == nil and vim.empty_dict() or values
  local stage
  ok, err, stage = fs.atomic_replace(
    self.path, vim.json.encode(encoded) .. "\n", { mode = 384 })
  if not ok then
    local action = stage == "temporary" and "create credential temporary file"
      or (stage == "write" or stage == "mode") and "write credentials"
      or "replace credentials"
    return nil, failure("Failed to " .. action, err)
  end
  return true
end

function Store:write(id, credential)
  local directory = vim.fs.dirname(self.path)
  local created, create_err = fs.ensure_private_directory(directory, 448)
  if not created then return nil, failure("Failed to create credential directory", create_err) end
  local result, err = self:_file_lock():with(function()
    local values, read_err = self:_read_all()
    if not values then return nil, read_err end
    values[id] = util.copy(credential)
    return self:_write_all(values)
  end)
  if not result and type(err) == "table" and err.kind == "file_lock" then
    return nil, credential_lock_error(err, err.code == "release" or err.code == "ownership")
  end
  return result, err
end

function Store:delete(id)
  if not vim.uv.fs_stat(self.path) then
    return async.run(function() return { ok = true } end, { error_kind = "auth" })
  end
  return self:modify(id, function() return DELETE end)
end

function Store:modify(id, fn)
  assert(type(fn) == "function", "credential modifier is required")
  return async.run(function()
    local directory = vim.fs.dirname(self.path)
    local created, create_err = fs.ensure_private_directory(directory, 448)
    if not created then error(failure("Failed to create credential directory", create_err), 0) end
    local release = self:_lock()
    local ok, result = pcall(function()
      local values, read_err = self:_read_all()
      if not values then error(read_err, 0) end
      local next_value = fn(util.copy(values[id]))
      local post
      if next_value == DELETE then
        local existed = values[id] ~= nil
        values[id] = nil
        if existed then
          local written, write_err = self:_write_all(values)
          if not written then error(write_err, 0) end
        end
      elseif next_value ~= nil then
        values[id] = util.copy(next_value)
        local written, write_err = self:_write_all(values)
        if not written then error(write_err, 0) end
        post = next_value
      else
        post = values[id]
      end
      return post
    end)
    local released, release_err = release()
    if not ok then error(result, 0) end
    if not released then error(release_err, 0) end
    return { ok = true, credential = result }
  end, { error_kind = "auth" })
end

local function positive_integer(value, name)
  assert(type(value) == "number" and value > 0 and value % 1 == 0,
    name .. " must be a positive integer")
  return value
end

function M.new(path, opts)
  assert(type(path) == "string" and path ~= "", "credential path is required")
  opts = opts or {}
  local lock_timeout_ms = positive_integer(
    opts.lock_timeout_ms or DEFAULT_LOCK_TIMEOUT_MS, "lock_timeout_ms")
  local lock_poll_ms = positive_integer(
    opts.lock_poll_ms or DEFAULT_LOCK_POLL_MS, "lock_poll_ms")
  return setmetatable({
    path = fs.normalize(path),
    lock_timeout_ms = lock_timeout_ms,
    lock_poll_ms = lock_poll_ms,
  }, Store)
end

return M
