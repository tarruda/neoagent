local bit = require("bit")

local M = {}
local Tree = {}
Tree.__index = Tree
local declared = {}

local function native_backend(opts)
  opts = opts or {}
  local ffi = opts.ffi or require("ffi")
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
  local function failure()
    return "Win32 error " .. tonumber(kernel.GetLastError())
  end
  return {
    create = function()
      local job = kernel.CreateJobObjectW(nil, nil)
      if job == nil then return nil, failure() end
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
      if handle == nil then return nil, failure() end
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
      if handle ~= nil then kernel.CloseHandle(handle) end
    end,
  }
end

function Tree:attach(pid)
  if self.closed then return nil, "process tree is closed" end
  if type(pid) ~= "number" or pid <= 0 then return true end
  local process, open_err = self.backend.open(pid)
  if not process then return nil, open_err end
  local assigned, assign_err = self.backend.assign(self.job, process)
  self.backend.close(process)
  if not assigned then return nil, assign_err end
  self.attached = true
  return true
end

function Tree:terminate(code)
  if self.closed or not self.attached then return false end
  local terminated = self.backend.terminate(self.job, code or 125)
  return terminated ~= nil and terminated ~= false
end

function Tree:close(terminate)
  if self.closed then return end
  if terminate then self:terminate(125) end
  self.closed = true
  self.backend.close(self.job)
  self.job = nil
end

function M.new(opts)
  opts = opts or {}
  local backend = opts.backend or native_backend(opts.native)
  local job, err = backend.create()
  if not job then return nil, err end
  return setmetatable({ backend = backend, job = job }, Tree)
end

M.detach = false

return M
