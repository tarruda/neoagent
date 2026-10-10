-- The machine registration selects the authority inventory. Configurable
-- storage, Neovim profiles, and terminal sessions cannot select another one.
local ffi = require("ffi")
local M = {
  namespace = "NeoagentSandboxAuthority",
  setup_namespace = "NeoagentSandboxSetup",
  administrators = "S-1-5-32-544",
}
local sizeof = ffi.sizeof --[[@as fun(value: ffi.cdata*): integer]]

ffi.cdef([[
long __stdcall RegOpenKeyExW(void *, const unsigned short *, unsigned long, unsigned long, void **);
long __stdcall RegCreateKeyExW(void *, const unsigned short *, unsigned long, unsigned short *,
                            unsigned long, unsigned long, void *, void **, unsigned long *);
long __stdcall RegQueryValueExW(void *, const unsigned short *, unsigned long *, unsigned long *,
                              unsigned char *, unsigned long *);
long __stdcall RegSetValueExW(void *, const unsigned short *, unsigned long, unsigned long,
                            const unsigned char *, unsigned long);
long __stdcall RegFlushKey(void *);
long __stdcall RegDeleteKeyExW(void *, const unsigned short *, unsigned long, unsigned long);
long __stdcall RegSetKeySecurity(void *, unsigned long, void *);
int __stdcall ConvertStringSecurityDescriptorToSecurityDescriptorW(const unsigned short *, unsigned long, void **, unsigned long *);
void * __stdcall LocalFree(void *);
typedef struct { unsigned long length; void *descriptor; int inherit; } NASandboxCoordinatorSecurity;
long __stdcall RegCloseKey(void *);
]])

---@class Neoagent.WindowsCoordinatorRegistration
---@field v 1
---@field id string
---@field owner_sid string
---@field directory string
---@field initialized boolean An authority journal has been published for this registration.
---@field volume integer
---@field high integer
---@field low integer

---@class Neoagent.WindowsCoordinatorDependencies
---@field wide fun(text: string): Neoagent.FfiArray<integer>
---@field utf8 fun(value: ffi.cdata*, length: integer): string?
---@field failure fun(stage: string, code?: integer): never

---@param deps Neoagent.WindowsCoordinatorDependencies
function M.new(deps)
  local security = ffi.load("advapi32")
  -- Predefined HKEY constants are sign-extended on 64-bit Windows.
  local machine = ffi.cast("void *", ffi.cast("intptr_t", -2147483646))
  local path = deps.wide("SOFTWARE\\Neoagent\\Sandbox")
  local name = deps.wide("Authority")
  local maximum = 65536
  local executions = deps.wide("SOFTWARE\\Neoagent\\Sandbox\\Executions")
  local function execution_root()
    local key = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
    local code = security.RegOpenKeyExW(machine, executions, 0, 0x10f, key) -- QUERY | SET | CREATE_SUB_KEY | ENUMERATE | WOW64.
    if code ~= 0 then deps.failure("execution-inventory-open", code) end
    return key[0]
  end
  local function execution_name(id)
    assert(type(id) == "string" and #id == 32 and id:match("^%x+$"), "Invalid execution identity")
    return deps.wide(id)
  end
  return {
    -- A volatile HKLM key survives handle/process loss and hibernation. Windows
    -- discards it only when unloading the system hive at a full shutdown.
    -- Its protected persistent parent belongs to machine setup. Missing that
    -- parent is corruption, never evidence that an execution ended.
    -- https://learn.microsoft.com/windows/win32/api/winreg/nf-winreg-regcreatekeyexw
    prepare_executions = function(owner)
      local key = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local descriptor = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local dacl = "D:P(A;CI;KA;;;" .. owner .. ")(A;CI;KA;;;SY)(A;CI;KA;;;BA)"
      if security.ConvertStringSecurityDescriptorToSecurityDescriptorW(deps.wide(dacl), 1, descriptor, nil) == 0 then
        deps.failure("execution-inventory-security", 0)
      end
      local attributes = ffi.new("NASandboxCoordinatorSecurity") --[[@as {length: integer, descriptor: ffi.cdata*, inherit: integer}]]
      attributes.length, attributes.descriptor = sizeof(attributes), descriptor[0]
      local code = security.RegCreateKeyExW(machine, executions, 0, nil, 0, 0xf013f, attributes, key, nil)
      if code == 0 then
        code = security.RegSetKeySecurity(key[0], 0x80000004, descriptor[0])
        security.RegCloseKey(key[0])
      end
      ffi.load("kernel32").LocalFree(descriptor[0])
      if code ~= 0 then deps.failure("execution-inventory-create", code) end
    end,
    mark_execution = function(id)
      local key = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local root = execution_root()
      local code = security.RegCreateKeyExW(root, execution_name(id), 0, nil, 1, 0x101, nil, key, nil)
      security.RegCloseKey(root)
      if code ~= 0 then deps.failure("execution-create", code) end
      security.RegCloseKey(key[0])
    end,
    execution_exists = function(id)
      local key = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local root = execution_root()
      local code = security.RegOpenKeyExW(root, execution_name(id), 0, 0x101, key)
      security.RegCloseKey(root)
      if code == 2 then return false end
      if code ~= 0 then deps.failure("execution-open", code) end
      security.RegCloseKey(key[0])
      return true
    end,
    clear_execution = function(id)
      local root = execution_root()
      local code = security.RegDeleteKeyExW(root, execution_name(id), 0x100, 0)
      security.RegCloseKey(root)
      if code ~= 0 and code ~= 2 then deps.failure("execution-retire", code) end
    end,
    read = function()
      local key = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local kind = ffi.new("unsigned long[1]") --[[@as Neoagent.FfiArray<integer>]]
      local count = ffi.new("unsigned long[1]", maximum) --[[@as Neoagent.FfiArray<integer>]]
      local value = ffi.new("unsigned short[?]", maximum / 2) --[[@as Neoagent.FfiArray<integer>]]
      local code = security.RegOpenKeyExW(machine, path, 0, 0x101, key) -- QUERY_VALUE | WOW64_64KEY.
      if code == 2 then
        return nil
      end
      if code ~= 0 then
        deps.failure("coordinator-open", code)
      end
      code = security.RegQueryValueExW(key[0], name, nil, kind, ffi.cast("unsigned char *", value), count)
      security.RegCloseKey(key[0])
      if code == 2 then
        return nil
      end
      if code ~= 0 then
        deps.failure("coordinator-read", code)
      end
      if kind[0] ~= 1 or count[0] < 2 or count[0] > maximum or count[0] % 2 ~= 0 or value[count[0] / 2 - 1] ~= 0 then
        deps.failure("coordinator-format", 0)
      end
      return deps.utf8(value, math.floor(count[0] / 2) - 1)
    end,
    -- Called only by elevated setup while holding the authority mutex, before
    -- allocating accounts or permissions. Flush registration before publishing
    -- the first journal so a successful setup has a durable coordinator.
    ---@param text string
    write = function(text)
      local value = deps.wide(text)
      local count = sizeof(value)
      if count > maximum then
        deps.failure("coordinator-format", 0)
      end
      local key = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local code = security.RegCreateKeyExW(machine, path, 0, nil, 0, 0x103, nil, key, nil)
      if code ~= 0 then
        deps.failure("coordinator-create", code)
      end
      code = security.RegSetValueExW(key[0], name, 0, 1, ffi.cast("const unsigned char *", value), count)
      if code == 0 then
        code = security.RegFlushKey(key[0])
      end
      security.RegCloseKey(key[0])
      if code ~= 0 then
        deps.failure("coordinator-write", code)
      end
    end,
  }
end

return M
