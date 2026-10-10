-- Remove the host's process-creation privileges before running the real
-- sandbox launcher. Its separate account logon must supply launch authority;
-- an elevated CI parent must not conceal dependence on its own privileges.
local ffi = require("ffi")
local load = ffi.load
local stripped = false
ffi.load = function(name, global)
  local library = load(name, global)
  if name == "advapi32" then
    return setmetatable({
      OpenProcessToken = function(...)
        -- Bind the intervention to token use, after its declarations exist;
        -- native module loading order must not supply the fixture's timing.
        if not stripped then
          stripped = true
          local kernel = load("kernel32")
          local token = ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
          assert(library.OpenProcessToken(kernel.GetCurrentProcess(), 0x28, token) ~= 0)
          for _, privilege in ipairs({ "SeAssignPrimaryTokenPrivilege", "SeIncreaseQuotaPrivilege" }) do
            local name_wide = ffi.new("WCHAR[?]", #privilege + 1) --[[@as Neoagent.FfiArray<integer>]]
            for index = 1, #privilege do name_wide[index - 1] = privilege:byte(index) end
            local value = ffi.new("TOKEN_PRIVILEGES") --[[@as Neoagent.Win32.TOKEN_PRIVILEGES]]
            value.PrivilegeCount = 1
            assert(library.LookupPrivilegeValueW(nil, name_wide, value.Privileges[0].Luid) ~= 0)
            value.Privileges[0].Attributes = 4 -- SE_PRIVILEGE_REMOVED, not merely disabled.
            assert(library.AdjustTokenPrivileges(token[0], 0, value, 0, nil, nil) ~= 0)
          end
          kernel.CloseHandle(token[0])
        end
        return library.OpenProcessToken(...)
      end,
    }, { __index = library })
  elseif name == "ntdll" then
    local security, kernel = load("advapi32"), load("kernel32")
    return setmetatable({
      NtOpenDirectoryObject = function(handle, access, attributes)
        -- Check session-directory ownership with the host's administrative
        -- group disabled too. Elevated CI must not supply the ACL authority.
        local original = ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
        local restricted = ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
        local admin = ffi.new("SID *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
        local name_wide = ffi.new("WCHAR[13]", { 83, 45, 49, 45, 53, 45, 51, 50, 45, 53, 52, 52, 0 })
        assert(security.OpenProcessToken(kernel.GetCurrentProcess(), 0xb, original) ~= 0)
        assert(security.ConvertStringSidToSidW(name_wide, admin) ~= 0)
        local disabled = ffi.new("SID_AND_ATTRIBUTES[1]") --[[@as Neoagent.FfiArray<Neoagent.Win32.SID_AND_ATTRIBUTES>]]
        disabled[0].Sid = admin[0]
        assert(security.CreateRestrictedToken(original[0], 1, 1, disabled, 0, nil, 0, nil, restricted) ~= 0)
        kernel.LocalFree(admin[0])
        kernel.CloseHandle(original[0])
        assert(security.ImpersonateLoggedOnUser(restricted[0]) ~= 0)
        local status = library.NtOpenDirectoryObject(handle, access, attributes)
        assert(security.RevertToSelf() ~= 0)
        kernel.CloseHandle(restricted[0])
        return status
      end,
    }, { __index = library })
  end
  return library
end

local source = assert(debug.getinfo(1, "S")).source:sub(2)
local checkout = assert(vim.fs.dirname(assert(vim.fs.dirname(assert(vim.fs.dirname(source))))))
dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_runtime.lua"))
