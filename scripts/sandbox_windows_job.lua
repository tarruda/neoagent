-- The standalone host's native Job owner. Closing a named Job is never a
-- termination observation: its name can disappear while processes remain.
local ffi = require("ffi")
local M = {}
local sizeof = ffi.sizeof --[[@as fun(value: ffi.cdata*): integer]]
local STOP_MS = 5000

ffi.cdef([[
typedef struct {
  unsigned long long ReadOperationCount, WriteOperationCount, OtherOperationCount;
  unsigned long long ReadTransferCount, WriteTransferCount, OtherTransferCount;
} NASandboxJobIo;
typedef struct {
  long long PerProcessUserTimeLimit, PerJobUserTimeLimit;
  unsigned long LimitFlags;
  uintptr_t MinimumWorkingSetSize, MaximumWorkingSetSize;
  unsigned long ActiveProcessLimit;
  uintptr_t Affinity;
  unsigned long PriorityClass, SchedulingClass;
} NASandboxJobBasicLimits;
typedef struct {
  NASandboxJobBasicLimits BasicLimitInformation;
  NASandboxJobIo IoInfo;
  uintptr_t ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
} NASandboxJobLimits;
typedef struct {
  long long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
  unsigned long TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
} NASandboxJobAccounting;
void __stdcall SetLastError(unsigned long);
void * __stdcall CreateJobObjectW(void *, const unsigned short *);
void * __stdcall OpenJobObjectW(unsigned long, int, const unsigned short *);
int __stdcall SetInformationJobObject(void *, int, void *, unsigned long);
int __stdcall QueryInformationJobObject(void *, int, void *, unsigned long, unsigned long *);
int __stdcall TerminateJobObject(void *, unsigned int);
int __stdcall CloseHandle(void *);
unsigned long __stdcall GetLastError(void);
void __stdcall Sleep(unsigned long);
]])

local kernel = ffi.load("kernel32")

---@class Neoagent.WindowsSandboxJobLimits: ffi.cdata*
---@field BasicLimitInformation {LimitFlags: integer}

---@class Neoagent.WindowsSandboxJobAccounting: ffi.cdata*
---@field ActiveProcesses integer

---@class Neoagent.WindowsJobEvidence
---@field open fun(self: Neoagent.WindowsJobEvidence): boolean
---@field stop fun(self: Neoagent.WindowsJobEvidence)
---@field is_empty fun(self: Neoagent.WindowsJobEvidence): boolean
---@field close fun(self: Neoagent.WindowsJobEvidence)

---@class Neoagent.WindowsSandboxJobDependencies
---@field wide fun(text: string): ffi.cdata* UTF-16 buffer kept alive through the native call.
---@field failure fun(stage: string, code?: integer): never

---@class Neoagent.WindowsSandboxJob: Neoagent.WindowsJobEvidence
---@field handle? ffi.cdata*
---@field _namespace Neoagent.WindowsPrivateNamespace
---@field _empty boolean
---@field _created boolean
---@field _wide fun(text: string): ffi.cdata*
---@field _failure fun(stage: string, code?: integer): never
local Job = {}
Job.__index = Job

-- A failed stop or journal write cannot drop the only observation handle.
-- The standalone process may still be killed; its journal then remains the
-- authority owner, and recovery must independently establish termination.
---@type table<Neoagent.WindowsSandboxJob, true>
local retained = {}

function Job:create()
  assert(not self.handle and not self._empty, "Job already started or finalized")
  self._created = true
  self._namespace:create()
  kernel.SetLastError(0)
  local handle = kernel.CreateJobObjectW(nil, self._wide(self._namespace:path("target")))
  local code = tonumber(kernel.GetLastError()) --[[@as integer]]
  if handle == nil then
    self._failure("target-job", code)
  end
  if code == 183 then -- CreateJobObject also opens an existing object.
    kernel.CloseHandle(handle)
    self._failure("target-job-identity", code)
  end
  self.handle = handle
  retained[self] = true
  local limits = ffi.new("NASandboxJobLimits") --[[@as Neoagent.WindowsSandboxJobLimits]]
  limits.BasicLimitInformation.LimitFlags = 0x2000 -- KILL_ON_JOB_CLOSE.
  if kernel.SetInformationJobObject(handle, 9, limits, sizeof(limits)) == 0 then
    self._failure("target-job")
  end
end

---@return boolean
function Job:open()
  assert(not self.handle and not self._empty, "Job already started or finalized")
  if not self._namespace:open() then
    return false
  end
  local handle = kernel.OpenJobObjectW(0x0f, 0, self._wide(self._namespace:path("target"))) -- ASSIGN | SET_ATTRIBUTES | QUERY | TERMINATE.
  if handle == nil then
    local code = (
      tonumber(kernel.GetLastError()) --[[@as integer]]
    )
    self._namespace:close(false)
    retained[self] = nil
    if code ~= 2 then
      self._failure("lease-job-open", code)
    end
    return false
  end
  self.handle = handle
  retained[self] = true
  return true
end

-- Termination requests and accounting probes never wait. The standalone
-- runtime composes them into its bounded stop; the editor observes on its loop.
function Job:terminate()
  if self.handle and not self._empty and kernel.TerminateJobObject(self.handle, 125) == 0 then
    self._failure("lease-job-stop")
  end
end

---@return boolean
function Job:observe()
  if self._empty then
    return true
  end
  if not self.handle then
    self._empty = true
    return true
  end
  local information = ffi.new("NASandboxJobAccounting") --[[@as Neoagent.WindowsSandboxJobAccounting]]
  if kernel.QueryInformationJobObject(self.handle, 1, information, sizeof(information), nil) == 0 then
    self._failure("lease-job-query")
  end
  self._empty = information.ActiveProcesses == 0
  return self._empty
end

function Job:stop()
  self:terminate()
  local deadline = vim.uv.hrtime() + STOP_MS * 1000000
  while not self:observe() do
    if vim.uv.hrtime() >= deadline then
      self._failure("lease-job-timeout", 258)
    end
    kernel.Sleep(1)
  end
end

---@return boolean
function Job:is_empty()
  return self._empty
end

-- The authority owner calls this only after saving termination evidence.
-- Native finalization cannot independently decide that the journal is ready.
function Job:close()
  assert(self._empty, "Cannot close a Job without termination evidence")
  if self.handle and kernel.CloseHandle(self.handle) == 0 then
    self._failure("lease-job-close")
  end
  self.handle = nil
  self._namespace:close(self._created)
  retained[self] = nil
end

---@param namespace Neoagent.WindowsPrivateNamespace
---@param deps Neoagent.WindowsSandboxJobDependencies
---@return Neoagent.WindowsSandboxJob
function M.new(namespace, deps)
  return setmetatable({
    _namespace = namespace,
    _empty = false,
    _created = false,
    _wide = deps.wide,
    _failure = deps.failure,
  }, Job)
end

return M
