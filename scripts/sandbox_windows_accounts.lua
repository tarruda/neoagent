-- Private account ownership for the standalone Windows sandbox host. Setup
-- delegates ordinary account creation and one offline group's membership to
-- the host user. Every invocation receives a new SID, retired after its Job
-- and filesystem authority have been released; identities are never pooled.
local ffi = require("ffi")
local bit = require("bit")
local M = {}
-- All allocations passed here have concrete sizes.
local sizeof = ffi.sizeof --[[@as fun(value: ffi.cdata*): integer]]

ffi.cdef([[
typedef struct { unsigned short Length, MaximumLength; unsigned short *Buffer; } NASamString;
typedef struct { unsigned short *password; } NASamPassword;
typedef struct { unsigned long flags; } NASamFlags;
typedef struct { unsigned short *name, *comment; } NASamGroup;
long __stdcall SamConnect(NASamString *, void **, unsigned long, void *);
long __stdcall SamOpenDomain(void *, unsigned long, void *, void **);
long __stdcall SamCreateUser2InDomain(void *, NASamString *, unsigned long, unsigned long,
                                    void **, unsigned long *, unsigned long *);
long __stdcall SamOpenUser(void *, unsigned long, unsigned long, void **);
long __stdcall SamDeleteUser(void *);
long __stdcall SamOpenAlias(void *, unsigned long, unsigned long, void **);
long __stdcall SamAddMemberToAlias(void *, void *);
long __stdcall SamQuerySecurityObject(void *, unsigned long, void **);
long __stdcall SamSetSecurityObject(void *, unsigned long, void *);
long __stdcall SamCloseHandle(void *);
long __stdcall SamFreeMemory(void *);
unsigned long __stdcall NetLocalGroupAdd(const unsigned short *, unsigned long, void *, unsigned long *);
unsigned long __stdcall NetUserDel(const unsigned short *, const unsigned short *);
unsigned long __stdcall DsRoleGetPrimaryDomainInformation(const unsigned short *, int, unsigned char **);
void __stdcall DsRoleFreeMemory(void *);
]])

---@class Neoagent.WindowsSamString: ffi.cdata*
---@field Length integer
---@field MaximumLength integer
---@field Buffer ffi.cdata*
---@class Neoagent.WindowsSamPassword: ffi.cdata*
---@field password ffi.cdata*
---@class Neoagent.WindowsSamFlags: ffi.cdata*
---@field flags integer
---@class Neoagent.WindowsSamGroup: ffi.cdata*
---@field name ffi.cdata*
---@field comment ffi.cdata*
---@class Neoagent.WindowsPrivateAccount
---@field name string Reserved before native allocation.
---@field sid? string Set immediately after allocation; absent during interrupted creation.
---@field absent? boolean Creation failed without allocating an account.
---@class Neoagent.WindowsOfflineGroup
---@field name string
---@field sid string
---@class Neoagent.WindowsAccountDependencies
---@field wide fun(text: string): Neoagent.FfiArray<integer>
---@field sid fun(text: string): ffi.cdata*
---@field lookup fun(name: string): string?, integer?
---@field access fun(sid: ffi.cdata*, mask: integer, mode: integer, inheritance: integer): Neoagent.Win32.EXPLICIT_ACCESS_W
---@field random fun(bytes: integer): string
---@field failure fun(stage: string, code?: integer): never

---@param deps Neoagent.WindowsAccountDependencies
function M.new(deps)
  local sam, kernel = ffi.load("samlib"), ffi.load("kernel32")
  local security, net = ffi.load("advapi32"), ffi.load("netapi32")
  local wide, failure = deps.wide, deps.failure

  ---@param status integer
  ---@param stage string
  local function check(status, stage)
    if status ~= 0 then
      failure(stage, security.LsaNtStatusToWinError(status))
    end
  end

  ---@generic T
  ---@param domain_sid string
  ---@param access integer
  ---@param callback fun(domain: ffi.cdata*): T
  ---@return T
  local function with_domain(domain_sid, access, callback)
    local server = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
    local domain = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
    local sid = deps.sid(domain_sid)
    local ok, result = pcall(function()
      check(sam.SamConnect(nil, server, 0x21, nil), "account-server-open")
      check(sam.SamOpenDomain(server[0], access, sid, domain), "account-domain-open")
      return callback(domain[0])
    end)
    kernel.LocalFree(sid)
    if domain[0] ~= nil then
      sam.SamCloseHandle(domain[0])
    end
    if server[0] ~= nil then
      sam.SamCloseHandle(server[0])
    end
    if not ok then
      error(result, 0)
    end
    return result
  end

  -- Add narrowly delegated rights without replacing the SAM object's existing
  -- descriptor. BuildSecurityDescriptor produces the self-relative form SAM
  -- requires and preserves the owner's and other principals' permissions.
  ---@param handle ffi.cdata*
  ---@param owner string
  ---@param mask integer
  local function grant(handle, owner, mask)
    local old = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
    local updated = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
    local length = ffi.new("unsigned long[1]") --[[@as Neoagent.FfiArray<integer>]]
    local sid = deps.sid(owner)
    local ok, err = pcall(function()
      check(sam.SamQuerySecurityObject(handle, 4, old), "account-security-read")
      local entries = ffi.new("EXPLICIT_ACCESS_W[1]") --[[@as Neoagent.FfiArray<Neoagent.Win32.EXPLICIT_ACCESS_W>]]
      entries[0] = deps.access(sid, mask, 1, 0)
      local code = security.BuildSecurityDescriptorW(nil, nil, 1, entries, 0, nil, old[0], length, updated)
      if code ~= 0 then
        failure("account-security-build", code)
      end
      check(sam.SamSetSecurityObject(handle, 4, updated[0]), "account-security-write")
    end)
    kernel.LocalFree(sid)
    if updated[0] ~= nil then
      kernel.LocalFree(updated[0])
    end
    if old[0] ~= nil then
      sam.SamFreeMemory(old[0])
    end
    if not ok then
      error(err, 0)
    end
  end

  ---@param sid string
  ---@return string, integer
  local function split_sid(sid)
    local domain, rid = sid:match("^(S%-1%-5%-21%-%d+%-%d+%-%d+)%-(%d+)$")
    if not domain then
      failure("account-domain-identity", 0)
    end
    return domain, assert(tonumber(rid)) --[[@as integer]]
  end

  ---@param domain ffi.cdata*
  ---@param group Neoagent.WindowsOfflineGroup
  ---@param access integer
  ---@param callback fun(alias: ffi.cdata*)
  local function with_group(domain, group, access, callback)
    local _, rid = split_sid(group.sid)
    local handle = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
    check(sam.SamOpenAlias(domain, access, rid, handle), "account-group-open")
    local ok, err = pcall(callback, handle[0])
    sam.SamCloseHandle(handle[0])
    if not ok then
      error(err, 0)
    end
  end

  return {
    -- Domain controllers expose domain accounts through these SAM entrypoints.
    -- Delegated authority here is deliberately limited to a local database.
    check_host = function()
      local info = ffi.new("unsigned char *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
      local code = net.DsRoleGetPrimaryDomainInformation(nil, 1, info)
      if code ~= 0 then
        failure("account-machine-role", code)
      end
      local role = (ffi.cast("int *", info[0]) --[[@as Neoagent.FfiArray<integer>]])[0]
      net.DsRoleFreeMemory(info[0])
      if role < 0 or role > 3 then
        failure("account-local-database", 50) -- ERROR_NOT_SUPPORTED.
      end
    end,

    ---@param owner string
    ---@param launcher_sid string
    ---@param existing? Neoagent.WindowsOfflineGroup
    ---@return Neoagent.WindowsOfflineGroup
    setup = function(owner, launcher_sid, existing)
      local domain_sid = split_sid(launcher_sid)
      local group = existing
      if not group then
        local name = "neoagent_net_" .. deps.random(3)
        local encoded, comment = wide(name), wide("Neoagent offline sandbox invocations")
        local info = ffi.new("NASamGroup") --[[@as Neoagent.WindowsSamGroup]]
        info.name, info.comment = encoded, comment
        local code = net.NetLocalGroupAdd(nil, 1, info, nil)
        if code ~= 0 then
          failure("account-group-create", code)
        end
        group = { name = name, sid = assert(deps.lookup(name)) }
      elseif deps.lookup(group.name) ~= group.sid then
        failure("account-group-identity", 5)
      end
      with_domain(domain_sid, 0x60200, function(domain)
        grant(domain, owner, 0x210) -- DOMAIN_CREATE_USER | DOMAIN_LOOKUP.
        with_group(domain, assert(group), 0x60000, function(alias)
          grant(alias, owner, 0x7) -- Membership only; no group policy changes.
        end)
      end)
      return assert(group)
    end,

    ---@param account Neoagent.WindowsPrivateAccount
    ---@param launcher_sid string
    ---@param owner string
    ---@param password string
    ---@param offline? Neoagent.WindowsOfflineGroup
    ---@param registered fun() Persist the allocated SID before enabling the account.
    create = function(account, launcher_sid, owner, password, offline, registered)
      local domain_sid = split_sid(launcher_sid)
      with_domain(domain_sid, 0x210, function(domain)
        local encoded = wide(account.name)
        local name = ffi.new("NASamString") --[[@as Neoagent.WindowsSamString]]
        name.Buffer = encoded
        name.Length, name.MaximumLength = sizeof(encoded) - 2, sizeof(encoded)
        local handle = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
        local granted = ffi.new("unsigned long[1]") --[[@as Neoagent.FfiArray<integer>]]
        local rid = ffi.new("unsigned long[1]") --[[@as Neoagent.FfiArray<integer>]]
        local status = sam.SamCreateUser2InDomain(domain, name, 0x10, 0xf07ff, handle, granted, rid)
        if status ~= 0 then
          account.absent = true
          registered()
          check(status, "account-create")
        end
        -- A disabled ordinary user exists now. Its journal already reserves the
        -- name. A host crash before grant() can require elevated setup to
        -- recover it; the journal remains, and admission fails closed.
        account.sid = domain_sid .. "-" .. tostring(rid[0])
        local ok, err = pcall(function()
          grant(handle[0], owner, 0xf07ff)
          registered()
          local secret = wide(password)
          local info = ffi.new("NASamPassword") --[[@as Neoagent.WindowsSamPassword]]
          info.password = secret
          local code = net.NetUserSetInfo(nil, encoded, 1003, ffi.cast("BYTE *", info), nil)
          ffi.fill(secret, sizeof(secret), 0)
          if code ~= 0 then
            failure("account-password", code)
          end
          if offline then
            local sid = deps.sid(assert(account.sid))
            local added, add_error = pcall(with_group, domain, offline, 1, function(alias)
              check(sam.SamAddMemberToAlias(alias, sid), "account-group-join")
            end)
            kernel.LocalFree(sid)
            if not added then
              error(add_error, 0)
            end
          end
          local flags = ffi.new("NASamFlags") --[[@as Neoagent.WindowsSamFlags]]
          flags.flags = 0x10201 -- Normal, enabled, non-expiring random password.
          code = net.NetUserSetInfo(nil, encoded, 1008, ffi.cast("BYTE *", flags), nil)
          if code ~= 0 then
            failure("account-enable", code)
          end
        end)
        if not ok then
          -- The allocation handle can delete even before the creator's DACL
          -- has been installed. Keep that authority through partial setup.
          if sam.SamDeleteUser(handle[0]) ~= 0 then
            sam.SamCloseHandle(handle[0])
          end
          error(err, 0)
        end
        sam.SamCloseHandle(handle[0])
      end)
    end,

    ---@param account Neoagent.WindowsPrivateAccount
    retire = function(account)
      if account.absent then
        return
      end
      local identity = account.sid
      if not identity then
        local code
        identity, code = deps.lookup(account.name)
        if not identity then
          if code == 1332 or code == 2221 then
            return
          end
          failure("account-recovery-lookup", code)
        end
      end
      local domain_sid, rid = split_sid(identity)
      with_domain(domain_sid, 0x200, function(domain)
        local handle = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
        local status = sam.SamOpenUser(domain, 0x10000, rid, handle)
        if bit.tobit(status) == bit.tobit(0xc0000064) then
          return -- Already deleted before an interrupted journal commit.
        end
        check(status, "account-retire-open")
        status = sam.SamDeleteUser(handle[0])
        if status ~= 0 then
          sam.SamCloseHandle(handle[0])
          check(status, "account-retire")
        end
      end)
    end,
  }
end

return M
