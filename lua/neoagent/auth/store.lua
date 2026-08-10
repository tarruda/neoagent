local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local Store = {}
Store.__index = Store
local DELETE = {}
local DEFAULT_LOCK_TIMEOUT_MS = 30000
local DEFAULT_LOCK_POLL_MS = 50
local DEFAULT_LOCK_STALE_MS = 120000

local function failure(message, detail)
  return util.error("auth", message, detail)
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:stop()
    handle:close()
  end
end

local function error_code(err, code)
  if type(code) == "string" and code ~= "" then return code end
  return type(err) == "string" and err:match("^([A-Z][A-Z0-9_]+):") or nil
end

local function is_error(err, code, expected)
  return error_code(err, code) == expected
end

local function mtime_ms(stat)
  local mtime = stat and stat.mtime or {}
  return (tonumber(mtime.sec) or 0) * 1000
    + math.floor((tonumber(mtime.nsec) or 0) / 1000000)
end

function Store:_lock()
  local lock_path = self.path .. ".lock"
  return async.await(function(done)
    local timer = vim.uv.new_timer()
    local heartbeat = vim.uv.new_timer()
    local started_at = vim.uv.hrtime() / 1000000
    local settled = false
    local acquired = false

    local function release()
      if not acquired then return end
      acquired = false
      close_handle(heartbeat)
      vim.uv.fs_unlink(lock_path)
    end

    local function reject(err)
      if settled then return end
      settled = true
      close_handle(timer)
      close_handle(heartbeat)
      done.reject(err)
    end

    local attempt
    local function retry()
      local elapsed = vim.uv.hrtime() / 1000000 - started_at
      if elapsed >= self.lock_timeout_ms then
        reject(failure("Timed out acquiring credential lock"))
        return
      end
      timer:start(math.min(self.lock_poll_ms,
        math.max(1, self.lock_timeout_ms - elapsed)), 0, attempt)
    end

    attempt = function()
      if settled then return end
      local fd, open_err, open_code = vim.uv.fs_open(lock_path, "wx", 384)
      if fd then
        vim.uv.fs_close(fd)
        acquired = true
        settled = true
        close_handle(timer)
        heartbeat:start(self.lock_refresh_ms, self.lock_refresh_ms, function()
          if not acquired then return end
          local now = util.now_ms() / 1000
          vim.uv.fs_utime(lock_path, now, now)
        end)
        done.resolve(release)
        return
      end
      if not is_error(open_err, open_code, "EEXIST") then
        reject(failure("Failed to acquire credential lock", open_err))
        return
      end
      local stat, stat_err, stat_code = vim.uv.fs_stat(lock_path)
      if not stat then
        if is_error(stat_err, stat_code, "ENOENT") then attempt() else
          reject(failure("Failed to inspect credential lock", stat_err))
        end
        return
      end
      if util.now_ms() - mtime_ms(stat) > self.lock_stale_ms then
        local removed, remove_err, remove_code = vim.uv.fs_unlink(lock_path)
        if removed or is_error(remove_err, remove_code, "ENOENT") then
          attempt()
        else
          reject(failure("Failed to recover stale credential lock", remove_err))
        end
        return
      end
      retry()
    end

    attempt()
    return function()
      close_handle(timer)
      release()
    end
  end)
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
  local directory_exists = vim.uv.fs_stat(directory) ~= nil
  local ok, err
  ok, err = fs.mkdirp(directory)
  if not ok then return nil, failure("Failed to create credential directory", err) end
  if not directory_exists then vim.uv.fs_chmod(directory, 448) end
  local suffix = vim.uv.random(8):gsub(".", function(char) return string.format("%02x", char:byte()) end)
  local temporary = self.path .. "." .. suffix .. ".tmp"
  local encoded = next(values) == nil and vim.empty_dict() or values
  ok, err = fs.write_all(temporary, vim.json.encode(encoded) .. "\n", "wx", 384)
  if not ok then return nil, failure("Failed to write credentials", err) end
  ok, err = vim.uv.fs_rename(temporary, self.path)
  if not ok then
    vim.uv.fs_unlink(temporary)
    return nil, failure("Failed to replace credentials", err)
  end
  vim.uv.fs_chmod(self.path, 384)
  return true
end

function Store:write(id, credential)
  local values, err = self:_read_all()
  if not values then return nil, err end
  values[id] = util.copy(credential)
  return self:_write_all(values)
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
    local existed = vim.uv.fs_stat(directory) ~= nil
    local created, create_err = fs.mkdirp(directory)
    if not created then error(failure("Failed to create credential directory", create_err), 0) end
    if not existed then vim.uv.fs_chmod(directory, 448) end
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
    release()
    if not ok then error(result, 0) end
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
  local lock_stale_ms = positive_integer(
    opts.lock_stale_ms or DEFAULT_LOCK_STALE_MS, "lock_stale_ms")
  return setmetatable({
    path = fs.normalize(path),
    lock_timeout_ms = lock_timeout_ms,
    lock_poll_ms = lock_poll_ms,
    lock_stale_ms = lock_stale_ms,
    lock_refresh_ms = math.max(1, math.floor(lock_stale_ms / 4)),
  }, Store)
end

return M
