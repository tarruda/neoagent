local bit = require("bit")

local M = {}
local Backend = {}
Backend.__index = Backend
local Handle = {}
Handle.__index = Handle
local declared = {}

local LOCKFILE_FAIL_IMMEDIATELY = 0x00000001
local LOCKFILE_EXCLUSIVE_LOCK = 0x00000002
local GENERIC_READ = 0x80000000
local GENERIC_WRITE = 0x40000000
local FILE_READ_ATTRIBUTES = 0x00000080
local FILE_SHARE_READ = 0x00000001
local FILE_SHARE_WRITE = 0x00000002
local FILE_SHARE_DELETE = 0x00000004
local OPEN_EXISTING = 3
local OPEN_ALWAYS = 4
local FILE_ATTRIBUTE_DIRECTORY = 0x00000010
local FILE_ATTRIBUTE_NORMAL = 0x00000080
local FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400
local FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
local FILE_BEGIN = 0
local CP_UTF8 = 65001
local MB_ERR_INVALID_CHARS = 0x00000008
local ERROR_FILE_NOT_FOUND = 2
local ERROR_PATH_NOT_FOUND = 3
local ERROR_LOCK_VIOLATION = 33
local ERROR_SHARING_VIOLATION = 32

local function backend_error(code, message, detail)
  return { code = code, message = message, detail = detail }
end

local function invalid_handle(ffi, handle)
  if handle == nil then return true end
  local ok, value = pcall(ffi.cast, "intptr_t", handle)
  if ok then return tonumber(value) == -1 end
  return tonumber(handle) == -1
end

local function file_information(kernel, ffi, native)
  local info = ffi.new("NEOAGENT_BY_HANDLE_FILE_INFORMATION")
  if kernel.GetFileInformationByHandle(native, info) == 0 then return nil end
  return {
    attributes = tonumber(info.dwFileAttributes),
    identity = table.concat({
      tonumber(info.dwVolumeSerialNumber),
      tonumber(info.nFileIndexHigh),
      tonumber(info.nFileIndexLow),
    }, ":"),
  }
end

local function default_encode_path(kernel, ffi, path)
  if path:find("\0", 1, true) then return nil, "path contains a NUL byte" end
  local count = kernel.MultiByteToWideChar(
    CP_UTF8, MB_ERR_INVALID_CHARS, path, #path, nil, 0)
  if count == 0 then
    return nil, "Win32 error " .. tostring(tonumber(kernel.GetLastError()))
  end
  local encoded = ffi.new("uint16_t[?]", count + 1)
  if kernel.MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, path, #path, encoded, count) ~= count then
    return nil, "Win32 error " .. tostring(tonumber(kernel.GetLastError()))
  end
  encoded[count] = 0
  return encoded
end

function Handle:_verify_identity()
  local held = file_information(self.kernel, self.ffi, self.native)
  if not held then
    return nil, backend_error("ownership",
      "Failed to inspect held file lock", self:_last_error())
  end
  if bit.band(held.attributes, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0
      or bit.band(held.attributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0 then
    return nil, backend_error("ownership",
      "Held file lock is not a regular file")
  end
  local encoded, encode_err = self.encode_path(self.path)
  if not encoded then
    return nil, backend_error("ownership",
      "Failed to encode file lock path", encode_err)
  end
  local current_handle = self.kernel.CreateFileW(
    encoded,
    FILE_READ_ATTRIBUTES,
    bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE),
    nil,
    OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT,
    nil)
  if invalid_handle(self.ffi, current_handle) then
    local code = tonumber(self.kernel.GetLastError())
    return nil, backend_error("ownership",
      (code == ERROR_FILE_NOT_FOUND or code == ERROR_PATH_NOT_FOUND)
          and "File lock path disappeared while held"
        or "Failed to open file lock path for identity verification",
      "Win32 error " .. tostring(code))
  end
  local current = file_information(self.kernel, self.ffi, current_handle)
  local inspected_error = current and nil or self:_last_error()
  local closed = self.kernel.CloseHandle(current_handle) ~= 0
  if not current then
    return nil, backend_error("ownership",
      "Failed to inspect file lock path identity", inspected_error)
  end
  if not closed then
    return nil, backend_error("ownership",
      "Failed to close file lock identity handle", self:_last_error())
  end
  if bit.band(current.attributes, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0
      or bit.band(current.attributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0
      or current.identity ~= held.identity then
    return nil, backend_error("ownership",
      "File lock path identity changed while held")
  end
  return held
end

function Handle:_last_error()
  return "Win32 error " .. tostring(tonumber(self.kernel.GetLastError()))
end

function Handle:try_acquire()
  local flags = bit.bor(LOCKFILE_FAIL_IMMEDIATELY, LOCKFILE_EXCLUSIVE_LOCK)
  if self.kernel.LockFileEx(
      self.native, flags, 0, 0xffffffff, 0xffffffff, self.overlapped) ~= 0 then
    self.locked = true
    return true
  end
  local code = tonumber(self.kernel.GetLastError())
  if code == ERROR_LOCK_VIOLATION or code == ERROR_SHARING_VIOLATION then
    return false
  end
  return nil, backend_error("lock", "Failed to acquire file lock",
    "Win32 error " .. tostring(code))
end

function Handle:prepare(mode)
  local identity, identity_err = self:_verify_identity()
  if not identity then return nil, identity_err end
  local secured, secure_err = self.uv.fs_chmod(self.path, mode)
  if not secured then
    return nil, backend_error("mode", "Failed to secure file lock", secure_err)
  end
  local verified, verify_err = self:_verify_identity()
  if not verified then return nil, verify_err end
  return true
end

function Handle:_seek_start(code)
  local offset = self.ffi.new("NEOAGENT_LARGE_INTEGER")
  offset.QuadPart = 0
  if self.kernel.SetFilePointerEx(
      self.native, offset, nil, FILE_BEGIN) == 0 then
    return nil, backend_error(code,
      "Failed to seek held file lock", self:_last_error())
  end
  return true
end

function Handle:write_token(token)
  local positioned, position_err = self:_seek_start("write")
  if not positioned then return nil, position_err end
  if self.kernel.SetEndOfFile(self.native) == 0 then
    return nil, backend_error("write",
      "Failed to truncate held file lock", self:_last_error())
  end
  local written = self.ffi.new("unsigned long[1]")
  if self.kernel.WriteFile(
      self.native, token, #token, written, nil) == 0 then
    return nil, backend_error("write", "Failed to write file lock token",
      self:_last_error())
  end
  if tonumber(written[0]) ~= #token then
    return nil, backend_error("write",
      "Failed to write file lock token", "short write")
  end
  if self.kernel.FlushFileBuffers(self.native) == 0 then
    return nil, backend_error("write",
      "Failed to sync file lock token", self:_last_error())
  end
  return true
end

function Handle:verify_token(token)
  local identity, identity_err = self:_verify_identity()
  if not identity then return nil, identity_err end
  local positioned, position_err = self:_seek_start("release")
  if not positioned then return nil, position_err end
  local buffer = self.ffi.new("uint8_t[?]", #token + 1)
  local read = self.ffi.new("unsigned long[1]")
  if self.kernel.ReadFile(
      self.native, buffer, #token + 1, read, nil) == 0 then
    return nil, backend_error("release",
      "Failed to read held file lock", self:_last_error())
  end
  local contents = self.ffi.string(buffer, tonumber(read[0]))
  if contents ~= token then
    return nil, backend_error("ownership", "File lock ownership changed")
  end
  return true
end

function Handle:release()
  if not self.locked then return true end
  if self.kernel.UnlockFileEx(
      self.native, 0, 0xffffffff, 0xffffffff, self.overlapped) == 0 then
    return nil, backend_error("release", "Failed to unlock file lock",
      self:_last_error())
  end
  self.locked = false
  return true
end

function Handle:close()
  if self.closed then return true end
  if self.kernel.CloseHandle(self.native) == 0 then
    return nil, backend_error("release",
      "Failed to close file lock", self:_last_error())
  end
  self.closed = true
  self.native = nil
  return true
end

function Backend:open(path, mode)
  local encoded, encode_err = self.encode_path(path)
  if not encoded then
    return nil, backend_error("open",
      "Failed to encode file lock path", encode_err)
  end
  local native = self.kernel.CreateFileW(
    encoded,
    GENERIC_READ + GENERIC_WRITE,
    bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE),
    nil,
    OPEN_ALWAYS,
    bit.bor(FILE_ATTRIBUTE_NORMAL, FILE_FLAG_OPEN_REPARSE_POINT),
    nil)
  if invalid_handle(self.ffi, native) then
    return nil, backend_error("open",
      "Failed to open file lock",
      "Win32 error " .. tostring(tonumber(self.kernel.GetLastError())))
  end
  local info = file_information(self.kernel, self.ffi, native)
  if not info then
    local detail = "Win32 error "
      .. tostring(tonumber(self.kernel.GetLastError()))
    self.kernel.CloseHandle(native)
    return nil, backend_error("open",
      "Failed to inspect file lock", detail)
  end
  if bit.band(info.attributes, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0
      or bit.band(info.attributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0 then
    self.kernel.CloseHandle(native)
    return nil, backend_error("target",
      "File lock path is not a regular file")
  end
  local handle = setmetatable({
    path = path,
    native = native,
    uv = self.uv,
    ffi = self.ffi,
    kernel = self.kernel,
    encode_path = self.encode_path,
    overlapped = self.ffi.new("NEOAGENT_OVERLAPPED"),
    locked = false,
    closed = false,
  }, Handle)
  local identity, identity_err = handle:_verify_identity()
  if not identity then
    handle:close()
    return nil, identity_err
  end
  return handle
end

function M.new(opts)
  opts = opts or {}
  local ffi = opts.ffi or require("ffi")
  if not declared[ffi] then
    ffi.cdef([[
typedef void *NEOAGENT_HANDLE;
typedef union {
  struct { unsigned long LowPart; long HighPart; };
  int64_t QuadPart;
} NEOAGENT_LARGE_INTEGER;
typedef struct {
  uintptr_t Internal;
  uintptr_t InternalHigh;
  union { struct { unsigned long Offset; unsigned long OffsetHigh; }; void *Pointer; };
  NEOAGENT_HANDLE hEvent;
} NEOAGENT_OVERLAPPED;
typedef struct {
  unsigned long dwFileAttributes;
  struct { unsigned long dwLowDateTime; unsigned long dwHighDateTime; } ftCreationTime;
  struct { unsigned long dwLowDateTime; unsigned long dwHighDateTime; } ftLastAccessTime;
  struct { unsigned long dwLowDateTime; unsigned long dwHighDateTime; } ftLastWriteTime;
  unsigned long dwVolumeSerialNumber;
  unsigned long nFileSizeHigh;
  unsigned long nFileSizeLow;
  unsigned long nNumberOfLinks;
  unsigned long nFileIndexHigh;
  unsigned long nFileIndexLow;
} NEOAGENT_BY_HANDLE_FILE_INFORMATION;
int __stdcall LockFileEx(NEOAGENT_HANDLE, unsigned long, unsigned long,
  unsigned long, unsigned long, NEOAGENT_OVERLAPPED *);
int __stdcall UnlockFileEx(NEOAGENT_HANDLE, unsigned long, unsigned long,
  unsigned long, NEOAGENT_OVERLAPPED *);
int __stdcall GetFileInformationByHandle(
  NEOAGENT_HANDLE, NEOAGENT_BY_HANDLE_FILE_INFORMATION *);
NEOAGENT_HANDLE __stdcall CreateFileW(
  const uint16_t *, unsigned long, unsigned long, void *, unsigned long,
  unsigned long, NEOAGENT_HANDLE);
int __stdcall CloseHandle(NEOAGENT_HANDLE);
int __stdcall SetFilePointerEx(
  NEOAGENT_HANDLE, NEOAGENT_LARGE_INTEGER,
  NEOAGENT_LARGE_INTEGER *, unsigned long);
int __stdcall SetEndOfFile(NEOAGENT_HANDLE);
int __stdcall ReadFile(
  NEOAGENT_HANDLE, void *, unsigned long, unsigned long *, void *);
int __stdcall WriteFile(
  NEOAGENT_HANDLE, const void *, unsigned long, unsigned long *, void *);
int __stdcall FlushFileBuffers(NEOAGENT_HANDLE);
int __stdcall MultiByteToWideChar(
  unsigned int, unsigned long, const char *, int, uint16_t *, int);
unsigned long __stdcall GetLastError(void);
]])
    declared[ffi] = true
  end
  local kernel = opts.kernel or ffi.load("kernel32")
  local encode_path = opts.encode_path or function(path)
    return default_encode_path(kernel, ffi, path)
  end
  return setmetatable({
    ffi = ffi,
    kernel = kernel,
    encode_path = encode_path,
    uv = opts.uv or vim.uv,
  }, Backend)
end

return M
