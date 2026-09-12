local bit = require("bit")

local M = {}
-- Handles are opaque values: only the owning native backend interprets them.
---@alias Neoagent.WindowsProcessHandle unknown

---@class Neoagent.WindowsProcessBackend
---@field create fun(): Neoagent.WindowsProcessHandle?, string?
---@field open fun(pid: integer): Neoagent.WindowsProcessHandle?, string?
---@field assign fun(job: Neoagent.WindowsProcessHandle, process: Neoagent.WindowsProcessHandle): true?, string?
---@field terminate fun(job: Neoagent.WindowsProcessHandle, code: integer): true?, string?
---@field close fun(handle: Neoagent.WindowsProcessHandle)

---@alias Neoagent.WindowsJobLimits {BasicLimitInformation: {LimitFlags: integer}}
---@alias Neoagent.WindowsProcessKernel {
---  GetLastError: (fun(): integer),
---  CreateJobObjectW: (fun(attributes: nil, name: nil): Neoagent.WindowsProcessHandle?),
---  SetInformationJobObject: (fun(job: Neoagent.WindowsProcessHandle, class: integer, limits: Neoagent.WindowsJobLimits, size: integer): integer),
---  OpenProcess: (fun(access: integer, inherit: integer, pid: integer): Neoagent.WindowsProcessHandle?),
---  AssignProcessToJobObject: (fun(job: Neoagent.WindowsProcessHandle, process: Neoagent.WindowsProcessHandle): integer),
---  TerminateJobObject: (fun(job: Neoagent.WindowsProcessHandle, code: integer): integer),
---  CloseHandle: (fun(handle: Neoagent.WindowsProcessHandle): integer),
---}
---@alias Neoagent.WindowsProcessFfi {
---  cdef: (fun(declarations: string)),
---  new: (fun(name: string): Neoagent.WindowsJobLimits),
---  sizeof: (fun(value: Neoagent.WindowsJobLimits): integer),
---  load: (fun(name: string): Neoagent.WindowsProcessKernel),
---}
---@class Neoagent.WindowsProcessNativeOptions
---@field ffi? Neoagent.WindowsProcessFfi
---@field kernel? Neoagent.WindowsProcessKernel

---@class Neoagent.WindowsProcessTree
---@field backend Neoagent.WindowsProcessBackend
---@field job Neoagent.WindowsProcessHandle
---@field closed? boolean
---@field attached? boolean
local Tree = {}
Tree.__index = Tree
---@type table<Neoagent.WindowsProcessFfi, boolean>
local declared = {}

---@param opts? Neoagent.WindowsProcessNativeOptions
---@return Neoagent.WindowsProcessBackend
local function native_backend(opts)
  opts = opts or {}
  local ffi = opts.ffi or require("ffi")
  ---@cast ffi Neoagent.WindowsProcessFfi
  if not declared[ffi] then
    ffi.cdef([[
typedef struct {
  unsigned long long ReadOperationCount;
  unsigned long long WriteOperationCount;
  unsigned long long OtherOperationCount;
  unsigned long long ReadTransferCount;
  unsigned long long WriteTransferCount;
  unsigned long long OtherTransferCount;
} NEOAGENT_IO_COUNTERS;
typedef struct {
  long long PerProcessUserTimeLimit;
  long long PerJobUserTimeLimit;
  unsigned long LimitFlags;
  uintptr_t MinimumWorkingSetSize;
  uintptr_t MaximumWorkingSetSize;
  unsigned long ActiveProcessLimit;
  uintptr_t Affinity;
  unsigned long PriorityClass;
  unsigned long SchedulingClass;
} NEOAGENT_JOB_BASIC_LIMIT_INFORMATION;
typedef struct {
  NEOAGENT_JOB_BASIC_LIMIT_INFORMATION BasicLimitInformation;
  NEOAGENT_IO_COUNTERS IoInfo;
  uintptr_t ProcessMemoryLimit;
  uintptr_t JobMemoryLimit;
  uintptr_t PeakProcessMemoryUsed;
  uintptr_t PeakJobMemoryUsed;
} NEOAGENT_JOB_EXTENDED_LIMIT_INFORMATION;
void * __stdcall CreateJobObjectW(void *, const unsigned short *);
int __stdcall SetInformationJobObject(void *, int, void *, unsigned long);
void * __stdcall OpenProcess(unsigned long, int, unsigned long);
int __stdcall AssignProcessToJobObject(void *, void *);
int __stdcall TerminateJobObject(void *, unsigned int);
int __stdcall CloseHandle(void *);
unsigned long __stdcall GetLastError(void);
]])
    declared[ffi] = true
  end
  local kernel = opts.kernel or ffi.load("kernel32")
  ---@return string
  local function failure()
    return "Win32 error " .. kernel.GetLastError()
  end
  return {
    create = function()
      local job = kernel.CreateJobObjectW(nil, nil)
      if job == nil then
        return nil, failure()
      end
      local limits = ffi.new("NEOAGENT_JOB_EXTENDED_LIMIT_INFORMATION")
      limits.BasicLimitInformation.LimitFlags = 0x2000
      if kernel.SetInformationJobObject(job, 9, limits, ffi.sizeof(limits)) == 0 then
        local err = failure()
        kernel.CloseHandle(job)
        return nil, err
      end
      return job
    end,
    open = function(pid)
      local handle = kernel.OpenProcess(bit.bor(0x0001, 0x0100), 0, pid)
      if handle == nil then
        return nil, failure()
      end
      return handle
    end,
    assign = function(job, process)
      if kernel.AssignProcessToJobObject(job, process) == 0 then
        return nil, failure()
      end
      return true
    end,
    terminate = function(job, code)
      if kernel.TerminateJobObject(job, code) == 0 then
        return nil, failure()
      end
      return true
    end,
    close = function(handle)
      if handle ~= nil then
        kernel.CloseHandle(handle)
      end
    end,
  }
end

---@param pid integer
---@return true?, string?
function Tree:attach(pid)
  if self.closed then
    return nil, "process tree is closed"
  end
  if type(pid) ~= "number" or pid <= 0 then
    return true
  end
  local process, open_err = self.backend.open(pid)
  if not process then
    return nil, open_err
  end
  local assigned, assign_err = self.backend.assign(self.job, process)
  self.backend.close(process)
  if not assigned then
    return nil, assign_err
  end
  self.attached = true
  return true
end

---@param code? integer
---@return boolean
function Tree:terminate(code)
  if self.closed or not self.attached then
    return false
  end
  local terminated = self.backend.terminate(self.job, code or 125)
  return terminated ~= nil and terminated ~= false
end

---@param terminate? boolean
function Tree:close(terminate)
  if self.closed then
    return
  end
  if terminate then
    self:terminate(125)
  end
  self.closed = true
  self.backend.close(self.job)
  self.job = nil
end

---@param opts? {backend?: Neoagent.WindowsProcessBackend, native?: Neoagent.WindowsProcessNativeOptions}
---@return Neoagent.WindowsProcessTree?, string?
function M.new(opts)
  opts = opts or {}
  local backend = opts.backend or native_backend(opts.native)
  local job, err = backend.create()
  if not job then
    return nil, err
  end
  return setmetatable({ backend = backend, job = job }, Tree)
end

M.detach = false

return M
