local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local Store = {}
Store.__index = Store

local function failure(message, detail)
  return util.error("auth", message, detail)
end

local function close_handle(handle)
  if handle and not handle:is_closing() then handle:close() end
end

function Store:_lock()
  local lock_path = self.path .. ".lock"
  return async.await(function(done)
    local timer = vim.uv.new_timer()
    local acquired = false
    local function attempt()
      local fd = vim.uv.fs_open(lock_path, "wx", 384)
      if fd then
        vim.uv.fs_close(fd)
        acquired = true
        close_handle(timer)
        done.resolve(function() vim.uv.fs_unlink(lock_path) end)
        return
      end
      local stat = vim.uv.fs_stat(lock_path)
      if stat and util.now_ms() - stat.mtime.sec * 1000 > 120000 then
        local removed = vim.uv.fs_unlink(lock_path)
        if removed then
          attempt()
          return
        end
      end
      timer:start(50, 0, attempt)
    end
    attempt()
    return function()
      close_handle(timer)
      if acquired then vim.uv.fs_unlink(lock_path) end
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

function Store:_write_all(values)
  local directory = vim.fs.dirname(self.path)
  local directory_exists = vim.uv.fs_stat(directory) ~= nil
  local ok, err
  ok, err = fs.mkdirp(directory)
  if not ok then return nil, failure("Failed to create credential directory", err) end
  if not directory_exists then vim.uv.fs_chmod(directory, 448) end
  local suffix = vim.uv.random(8):gsub(".", function(char) return string.format("%02x", char:byte()) end)
  local temporary = self.path .. "." .. suffix .. ".tmp"
  ok, err = fs.write_all(temporary, vim.json.encode(values) .. "\n", "wx", 384)
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
  if not vim.uv.fs_stat(self.path) then return true end
  local values, err = self:_read_all()
  if not values then return nil, err end
  values[id] = nil
  return self:_write_all(values)
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
      if next_value ~= nil then
        values[id] = util.copy(next_value)
        local written, write_err = self:_write_all(values)
        if not written then error(write_err, 0) end
      end
      return next_value or values[id]
    end)
    release()
    if not ok then error(result, 0) end
    return { ok = true, credential = result }
  end, { error_kind = "auth" })
end

function M.new(path)
  assert(type(path) == "string" and path ~= "", "credential path is required")
  return setmetatable({ path = fs.normalize(path) }, Store)
end

return M
