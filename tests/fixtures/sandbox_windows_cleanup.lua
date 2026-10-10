-- Inject a native ACL-revocation failure in the host only. The next recovery
-- invocation uses the ordinary runtime.
local ffi = require("ffi")
local load = ffi.load
ffi.load = function(name, global)
  local library = load(name, global)
  if name ~= "advapi32" then return library end
  return setmetatable({
    SetEntriesInAclW = function(count, entries, previous, result)
      for index = 0, count - 1 do
        -- Fail final revocation of the invocation's S-1-5-5 logon identity.
        local sid = ffi.cast("const unsigned char *", entries[index].Trustee.ptstrName)
        if entries[index].grfAccessMode == 4 and sid[1] == 3 and sid[8] == 5 then -- REVOKE_ACCESS
          return 5 -- ERROR_ACCESS_DENIED
        end
      end
      return library.SetEntriesInAclW(count, entries, previous, result)
    end,
  }, { __index = library })
end

local source = assert(debug.getinfo(1, "S")).source:sub(2)
local checkout = assert(vim.fs.dirname(assert(vim.fs.dirname(assert(vim.fs.dirname(source))))))
dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_runtime.lua"))
