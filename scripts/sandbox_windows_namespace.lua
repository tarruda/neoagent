-- Session named objects are a distinct Windows authority boundary from the
-- filesystem and window station. Private target accounts need permission to
-- create their own objects, without control over the directory or peer DACLs.
local ffi = require("ffi")
local M = {}
local sizeof = ffi.sizeof --[[@as fun(value: ffi.cdata*): integer]]

ffi.cdef([[
typedef struct { unsigned short Length, MaximumLength; unsigned short *Buffer; } NANamespaceString;
typedef struct {
  unsigned long Length;
  void *RootDirectory;
  NANamespaceString *ObjectName;
  unsigned long Attributes;
  void *SecurityDescriptor, *SecurityQualityOfService;
} NANamespaceAttributes;
long __stdcall NtOpenDirectoryObject(void **, unsigned long, NANamespaceAttributes *);
unsigned long __stdcall GetSecurityInfo(void *, int, unsigned long, void **, void **, ACL **, ACL **, void **);
]])

---@class Neoagent.WindowsNamespaceString: ffi.cdata*
---@field Length integer
---@field MaximumLength integer
---@field Buffer ffi.cdata*
---@class Neoagent.WindowsNamespaceAttributes: ffi.cdata*
---@field Length integer
---@field ObjectName Neoagent.WindowsNamespaceString
---@field Attributes integer

---@class Neoagent.WindowsNamespaceDependencies
---@field wide fun(text: string): Neoagent.FfiArray<integer>
---@field sid fun(text: string): ffi.cdata*
---@field access fun(sid: ffi.cdata*, mask: integer, mode: integer, inheritance: integer): Neoagent.Win32.EXPLICIT_ACCESS_W
---@field failure fun(stage: string, code?: integer): never

---@param deps Neoagent.WindowsNamespaceDependencies
function M.new(deps)
  local native, security, kernel = ffi.load("ntdll"), ffi.load("advapi32"), ffi.load("kernel32")
  return {
    ---@param path string
    ---@param identity string
    ---@param grant boolean
    change = function(path, identity, grant)
      local encoded = deps.wide(path)
      local name = ffi.new("NANamespaceString") --[[@as Neoagent.WindowsNamespaceString]]
      name.Buffer, name.Length, name.MaximumLength = encoded, sizeof(encoded) - 2, sizeof(encoded)
      local attributes = ffi.new("NANamespaceAttributes") --[[@as Neoagent.WindowsNamespaceAttributes]]
      attributes.Length, attributes.ObjectName, attributes.Attributes = sizeof(attributes), name, 0x40
      local handle = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local status = native.NtOpenDirectoryObject(handle, 0x60000, attributes) -- READ_CONTROL | WRITE_DAC.
      if status ~= 0 then
        local code = security.LsaNtStatusToWinError(status)
        if not grant and (code == 2 or code == 3) then
          return -- The original session namespace no longer exists.
        end
        deps.failure("namespace-open", code)
      end
      local sid = deps.sid(identity)
      local original = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local acl = ffi.new("ACL *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local updated = ffi.new("ACL *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local ok, err = pcall(function()
        local code = security.GetSecurityInfo(handle[0], 6, 4, nil, nil, acl, nil, original)
        if code ~= 0 then
          deps.failure("namespace-security-read", code)
        end
        local entries = ffi.new("EXPLICIT_ACCESS_W[1]") --[[@as Neoagent.FfiArray<Neoagent.Win32.EXPLICIT_ACCESS_W>]]
        -- Query, traverse, create objects and subdirectories. No permission
        -- editing or inheritance into another principal's created objects.
        entries[0] = deps.access(sid, grant and 0xf or 0, grant and 1 or 4, 0)
        code = security.SetEntriesInAclW(1, entries, acl[0], updated)
        if code ~= 0 then
          deps.failure("namespace-security-build", code)
        end
        code = security.SetSecurityInfo(handle[0], 6, 4, nil, nil, updated[0], nil)
        if code ~= 0 then
          deps.failure("namespace-security-write", code)
        end
      end)
      if updated[0] ~= nil then
        kernel.LocalFree(updated[0])
      end
      if original[0] ~= nil then
        kernel.LocalFree(original[0])
      end
      kernel.LocalFree(sid)
      kernel.CloseHandle(handle[0])
      if not ok then
        error(err, 0)
      end
    end,
  }
end

return M
