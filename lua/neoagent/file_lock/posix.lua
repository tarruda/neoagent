local bit = require("bit")

local M = {}
local Backend = {}
Backend.__index = Backend
local Handle = {}
Handle.__index = Handle
local declared = {}

local LOCK_EX = 2
local LOCK_NB = 4
local LOCK_UN = 8
local EAGAIN = 11
local EWOULDBLOCK_DARWIN = 35

local function backend_error(code, message, detail)
  return { code = code, message = message, detail = detail }
end

local function missing(err, code)
  return code == "ENOENT"
    or type(err) == "string" and err:find("ENOENT", 1, true) ~= nil
end

local function same_identity(left, right)
  return left and right and left.type == "file" and right.type == "file"
    and left.dev == right.dev and left.ino == right.ino
end

function Handle:_verify_identity()
  local held, held_err = self.uv.fs_fstat(self.fd)
  if not held then
    return nil, backend_error("ownership",
      "Failed to inspect held file lock", held_err)
  end
  local current, current_err, current_code = self.uv.fs_lstat(self.path)
  if not current then
    return nil, backend_error("ownership",
      missing(current_err, current_code)
          and "File lock path disappeared while held"
        or "Failed to inspect file lock path",
      current_err)
  end
  if not same_identity(held, current) then
    return nil, backend_error("ownership",
      "File lock path identity changed while held")
  end
  return held
end

function Handle:try_acquire()
  local result = self.C.flock(self.fd, bit.bor(LOCK_EX, LOCK_NB))
  if result == 0 then
    self.locked = true
    return true
  end
  local errno = self.ffi.errno()
  if errno == EAGAIN or errno == EWOULDBLOCK_DARWIN then return false end
  return nil, backend_error("lock", "Failed to acquire file lock",
    "flock error " .. tostring(errno))
end

function Handle:prepare(mode)
  local identity, identity_err = self:_verify_identity()
  if not identity then return nil, identity_err end
  local secured, secure_err = self.uv.fs_fchmod(self.fd, mode)
  if not secured then
    return nil, backend_error("mode", "Failed to secure file lock", secure_err)
  end
  local confirmed, confirmed_err = self:_verify_identity()
  if not confirmed then return nil, confirmed_err end
  if bit.band(confirmed.mode, 511) ~= mode then
    return nil, backend_error("mode",
      "File lock has an unexpected permission mode")
  end
  return true
end

function Handle:write_token(token)
  local truncated, truncate_err = self.uv.fs_ftruncate(self.fd, 0)
  if not truncated then
    return nil, backend_error("write",
      "Failed to truncate held file lock", truncate_err)
  end
  local written, write_err = self.uv.fs_write(self.fd, token, 0)
  if written ~= #token then
    return nil, backend_error("write", "Failed to write file lock token",
      write_err or "short write")
  end
  local synced, sync_err = self.uv.fs_fsync(self.fd)
  if not synced then
    return nil, backend_error("write", "Failed to sync file lock token", sync_err)
  end
  return true
end

function Handle:verify_token(token)
  local identity, identity_err = self:_verify_identity()
  if not identity then return nil, identity_err end
  local contents, read_err = self.uv.fs_read(self.fd, #token + 1, 0)
  if contents == nil then
    return nil, backend_error("release",
      "Failed to read held file lock", read_err)
  end
  if contents ~= token then
    return nil, backend_error("ownership", "File lock ownership changed")
  end
  return true
end

function Handle:release()
  if not self.locked then return true end
  if self.C.flock(self.fd, LOCK_UN) ~= 0 then
    return nil, backend_error("release", "Failed to unlock file lock",
      "flock error " .. tostring(self.ffi.errno()))
  end
  self.locked = false
  return true
end

function Handle:close()
  if self.closed then return true end
  local closed, close_err = self.uv.fs_close(self.fd)
  if not closed then
    return nil, backend_error("release", "Failed to close file lock", close_err)
  end
  self.closed = true
  self.fd = nil
  return true
end

function Backend:open(path, mode)
  local before, before_err, before_code = self.uv.fs_lstat(path)
  if before and before.type == "link" then
    return nil, backend_error("target", "File lock path is a symbolic link")
  end
  if before and before.type ~= "file" then
    return nil, backend_error("target", "File lock path is not a regular file")
  end
  if not before and not missing(before_err, before_code) then
    return nil, backend_error("open", "Failed to inspect file lock path", before_err)
  end

  local fd, open_err = self.uv.fs_open(path, "a+", mode)
  if not fd then
    return nil, backend_error("open", "Failed to open file lock", open_err)
  end
  local handle = setmetatable({
    path = path,
    fd = fd,
    uv = self.uv,
    ffi = self.ffi,
    C = self.C,
    locked = false,
    closed = false,
  }, Handle)
  local held, held_err = handle:_verify_identity()
  if not held then
    handle:close()
    return nil, held_err
  end
  return handle
end

function M.new(opts)
  opts = opts or {}
  local ffi = opts.ffi or require("ffi")
  if not declared[ffi] then
    ffi.cdef([[int flock(int fd, int operation);]])
    declared[ffi] = true
  end
  return setmetatable({
    ffi = ffi,
    C = opts.C or ffi.C,
    uv = opts.uv or vim.uv,
  }, Backend)
end

return M
