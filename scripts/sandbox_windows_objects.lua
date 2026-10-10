-- Authenticate kernel objects before opening them. A public object name and
-- a DACL supplied to Create* cannot authenticate an already existing object.
local ffi = require("ffi")
local M = {}
local sizeof = ffi.sizeof --[[@as fun(value: ffi.cdata*): integer]]

ffi.cdef([[
typedef struct { unsigned long length; void *descriptor; int inherit; } NASandboxObjectSecurity;
void * __stdcall CreateBoundaryDescriptorW(const unsigned short *, unsigned long);
int __stdcall AddSIDToBoundaryDescriptor(void **, void *);
void __stdcall DeleteBoundaryDescriptor(void *);
void * __stdcall CreatePrivateNamespaceW(void *, void *, const unsigned short *);
void * __stdcall OpenPrivateNamespaceW(void *, const unsigned short *);
unsigned char __stdcall ClosePrivateNamespace(void *, unsigned long);
struct _SID;
int __stdcall ConvertStringSidToSidW(const unsigned short *, struct _SID **);
int __stdcall ConvertStringSecurityDescriptorToSecurityDescriptorW(const unsigned short *, unsigned long, void **, unsigned long *);
void * __stdcall LocalFree(void *);
unsigned long __stdcall GetLastError(void);
void __stdcall Sleep(unsigned long);
]])

local kernel, security = ffi.load("kernel32"), ffi.load("advapi32")

---@class Neoagent.WindowsObjectSecurity: ffi.cdata*
---@field length integer
---@field descriptor ffi.cdata*
---@field inherit integer

---@class Neoagent.WindowsObjectDependencies
---@field identity string Required SID for creation and access; no session or configurable storage boundary.
---@field wide fun(text: string): ffi.cdata*
---@field failure fun(stage: string, code?: integer): never

---@class Neoagent.WindowsPrivateNamespace
---@field name string
---@field handle? ffi.cdata*
---@field _deps Neoagent.WindowsObjectDependencies
local Namespace = {}
Namespace.__index = Namespace

---@type table<Neoagent.WindowsPrivateNamespace, true>
local retained = {}

---@param mode "create"|"open"|"join"
---@param deadline? number Required for racing coordination creation/opening.
---@return boolean
function Namespace:_connect(mode, deadline)
  if self.handle then
    assert(mode == "join", "namespace already owned")
    return true
  end
  local deps = self._deps
  local boundary = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
  local sid = ffi.new("struct _SID *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
  local descriptor = ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]]
  local ok, available = pcall(function()
    boundary[0] = kernel.CreateBoundaryDescriptorW(deps.wide(self.name), 0)
    if boundary[0] == nil then
      deps.failure("object-boundary")
    end
    if security.ConvertStringSidToSidW(deps.wide(deps.identity), sid) == 0 then
      deps.failure("object-identity")
    end
    if kernel.AddSIDToBoundaryDescriptor(boundary, sid[0]) == 0 then
      deps.failure("object-boundary")
    end
    local attributes = ffi.new("NASandboxObjectSecurity") --[[@as Neoagent.WindowsObjectSecurity]]
    if mode ~= "open" then
      -- Membership restricts creation. Opening also needs an explicit DACL:
      -- OpenPrivateNamespace does not itself require boundary membership.
      local dacl = "D:P(A;;GA;;;" .. deps.identity .. ")(A;;GA;;;SY)"
      if security.ConvertStringSecurityDescriptorToSecurityDescriptorW(deps.wide(dacl), 1, descriptor, nil) == 0 then
        deps.failure("object-namespace-security")
      end
      attributes.length, attributes.descriptor, attributes.inherit = sizeof(attributes), descriptor[0], 0
    end
    while true do
      local handle
      if mode ~= "create" then
        handle = kernel.OpenPrivateNamespaceW(boundary[0], deps.wide(self.name))
        if handle == nil then
          local code = tonumber(kernel.GetLastError()) --[[@as integer]]
          if code ~= 2 and code ~= 3 then
            deps.failure("object-namespace-open", code)
          end
          if mode == "open" then
            return false
          end
        end
      end
      if handle == nil then
        handle = kernel.CreatePrivateNamespaceW(attributes, boundary[0], deps.wide(self.name))
        if handle == nil then
          local code = tonumber(kernel.GetLastError()) --[[@as integer]]
          if mode ~= "join" or code ~= 183 then
            deps.failure("object-namespace-create", code)
          end
        end
      end
      if handle ~= nil then
        self.handle = handle
        retained[self] = true
        return true
      end
      -- A trusted creator raced with open. Never adopt an unauthenticated
      -- public fallback, and bound contention by the owning transaction.
      if vim.uv.hrtime() >= assert(deadline) then
        deps.failure("object-namespace-timeout", 258)
      end
      kernel.Sleep(1)
    end
  end)
  if boundary[0] ~= nil then
    kernel.DeleteBoundaryDescriptor(boundary[0])
  end
  if sid[0] ~= nil then
    kernel.LocalFree(sid[0])
  end
  if descriptor[0] ~= nil then
    kernel.LocalFree(descriptor[0])
  end
  if not ok then
    error(available, 0)
  end
  return available
end

function Namespace:create()
  self:_connect("create")
end

---@return boolean
function Namespace:open()
  return self:_connect("open")
end

---@param deadline number
function Namespace:join(deadline)
  self:_connect("join", deadline)
end

---@param name string
---@return string
function Namespace:path(name)
  assert(self.handle, "namespace is not owned")
  return self.name .. "\\" .. name
end

-- Shared coordination never destroys its namespace: other owners and waiters
-- retain it across creator exit. A private Job destroys only after durable
-- empty-Job evidence has made further recovery through that identity needless.
---@param destroy boolean
function Namespace:close(destroy)
  if self.handle then
    if kernel.ClosePrivateNamespace(self.handle, destroy and 1 or 0) == 0 then
      self._deps.failure("object-namespace-close")
    end
    self.handle = nil
    retained[self] = nil
  end
end

---@param name string
---@param deps Neoagent.WindowsObjectDependencies
---@return Neoagent.WindowsPrivateNamespace
function M.new(name, deps)
  return setmetatable({ name = name .. "-" .. deps.identity, _deps = deps }, Namespace)
end

return M
