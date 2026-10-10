-- Fail after actual SAM allocation, before cleanup permissions are installed.
-- This protects both in-process rollback and the pre-allocation journal used
-- when the standalone native host is lost during startup.
local ffi = require("ffi")
local load = ffi.load
ffi.load = function(name, global)
  local library = load(name, global)
  if name == "netapi32" and vim.env.NEOAGENT_ACCOUNT_TEST_FAILURE == "domain-controller" then
    return setmetatable({
      DsRoleGetPrimaryDomainInformation = function(server, level, buffer)
        local code = library.DsRoleGetPrimaryDomainInformation(server, level, buffer)
        if code == 0 then
          local role = ffi.cast("int *", buffer[0]) --[[@as Neoagent.FfiArray<integer>]]
          role[0] = 5 -- The actual native result owns its storage until DsRoleFreeMemory.
        end
        return code
      end,
    }, { __index = library })
  end
  if name ~= "samlib" then
    return library
  end
  return setmetatable({
    SamCreateUser2InDomain = function(domain, account, kind, access, handle, granted, rid)
      local status = library.SamCreateUser2InDomain(domain, account, kind, access, handle, granted, rid)
      if status == 0 then
        local text = {}
        for index = 0, account.Length / 2 - 1 do
          text[#text + 1] = string.char(account.Buffer[index])
        end
        local output = assert(io.open(assert(vim.env.NEOAGENT_ACCOUNT_TEST_RECORD), "wb"))
        output:write(table.concat(text))
        output:close()
        if vim.env.NEOAGENT_ACCOUNT_TEST_FAILURE == "crash" then
          os.exit(137)
        end
      end
      return status
    end,
    SamSetSecurityObject = function()
      return -1073741790 -- STATUS_ACCESS_DENIED, before the host receives a DACL grant.
    end,
  }, { __index = library })
end

local source = assert(debug.getinfo(1, "S")).source:sub(2)
local checkout = assert(vim.fs.dirname(assert(vim.fs.dirname(assert(vim.fs.dirname(source))))))
dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_runtime.lua"))
