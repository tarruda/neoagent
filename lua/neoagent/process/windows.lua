local bit = require("bit")

local M = {}
-- Handles are opaque values: only the owning native backend interprets them.
---@alias Neoagent.WindowsProcessHandle unknown

---@class Neoagent.WindowsProcessBackend
---@field create fun(): Neoagent.WindowsProcessHandle?, string?
---@field open fun(pid: integer): Neoagent.WindowsProcessHandle?, string?
---@field assign fun(job: Neoagent.WindowsProcessHandle, process: Neoagent.WindowsProcessHandle): true?, string?
---@field running fun(process: Neoagent.WindowsProcessHandle): boolean?, string?
---@field empty fun(job: Neoagent.WindowsProcessHandle): boolean?, string?
---@field terminate fun(job: Neoagent.WindowsProcessHandle, code: integer): true?, string?
---@field close fun(handle: Neoagent.WindowsProcessHandle)

---@alias Neoagent.WindowsJobLimits {BasicLimitInformation: {LimitFlags: integer}}
---@alias Neoagent.WindowsProcessAccounting {ActiveProcesses: integer}
---@alias Neoagent.WindowsProcessKernel {
---  GetLastError: (fun(): integer),
---  CreateJobObjectW: (fun(attributes: nil, name: nil): Neoagent.WindowsProcessHandle?),
---  SetInformationJobObject: (fun(job: Neoagent.WindowsProcessHandle, class: integer, limits: Neoagent.WindowsJobLimits, size: integer): integer),
---  QueryInformationJobObject: (fun(job: Neoagent.WindowsProcessHandle, class: integer, accounting: Neoagent.WindowsProcessAccounting, size: integer, returned: nil): integer),
---  OpenProcess: (fun(access: integer, inherit: integer, pid: integer): Neoagent.WindowsProcessHandle?),
---  AssignProcessToJobObject: (fun(job: Neoagent.WindowsProcessHandle, process: Neoagent.WindowsProcessHandle): integer),
---  WaitForSingleObject: (fun(process: Neoagent.WindowsProcessHandle, timeout: integer): integer),
---  TerminateJobObject: (fun(job: Neoagent.WindowsProcessHandle, code: integer): integer),
---  CloseHandle: (fun(handle: Neoagent.WindowsProcessHandle): integer),
---}
---@alias Neoagent.WindowsProcessFfi {
---  cdef: (fun(declarations: string)),
---  new: (fun(name: string): Neoagent.WindowsJobLimits|Neoagent.WindowsProcessAccounting),
---  sizeof: (fun(value: Neoagent.WindowsJobLimits|Neoagent.WindowsProcessAccounting): integer),
---  load: (fun(name: string): Neoagent.WindowsProcessKernel),
---}
---@class Neoagent.WindowsProcessNativeOptions
---@field ffi? Neoagent.WindowsProcessFfi
---@field kernel? Neoagent.WindowsProcessKernel

---@class Neoagent.WindowsProcessCallbacks
---@field empty fun() Native accounting confirms no associated processes remain.
---@field released fun() Native handles and the accounting observer have closed.
---@field failed fun(message: string)
---@class Neoagent.WindowsProcessOptions
---@field callbacks Neoagent.WindowsProcessCallbacks
---@field backend? Neoagent.WindowsProcessBackend
---@field native? Neoagent.WindowsProcessNativeOptions

---@class Neoagent.WindowsProcessTree
---@field backend Neoagent.WindowsProcessBackend
---@field job? Neoagent.WindowsProcessHandle
---@field process? Neoagent.WindowsProcessHandle
---@field closed? boolean
---@field attached? boolean
---@field disposed? boolean
---@field empty? boolean
---@field observation_failed? boolean
---@field termination_sent? boolean
---@field termination_failed? boolean
---@field retry_termination_ns? number
---@field retry_delay_ms? integer
---@field monitor? uv.uv_timer_t
---@field callbacks Neoagent.WindowsProcessCallbacks
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
typedef struct {
  long long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
  unsigned long TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
} NEOAGENT_JOB_ACCOUNTING_INFORMATION;
void * __stdcall CreateJobObjectW(void *, const unsigned short *);
int __stdcall SetInformationJobObject(void *, int, void *, unsigned long);
int __stdcall QueryInformationJobObject(void *, int, void *, unsigned long, unsigned long *);
void * __stdcall OpenProcess(unsigned long, int, unsigned long);
int __stdcall AssignProcessToJobObject(void *, void *);
unsigned long __stdcall WaitForSingleObject(void *, unsigned long);
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
      local limits = ffi.new("NEOAGENT_JOB_EXTENDED_LIMIT_INFORMATION") --[[@as Neoagent.WindowsJobLimits]]
      limits.BasicLimitInformation.LimitFlags = 0x2000
      local job = kernel.CreateJobObjectW(nil, nil)
      if job == nil then
        return nil, failure()
      end
      if kernel.SetInformationJobObject(job, 9, limits, ffi.sizeof(limits)) == 0 then
        local err = failure()
        kernel.CloseHandle(job)
        return nil, err
      end
      return job
    end,
    open = function(pid)
      local handle = kernel.OpenProcess(bit.bor(0x0001, 0x0100, 0x100000), 0, pid)
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
    running = function(process)
      local status = kernel.WaitForSingleObject(process, 0)
      if status == 0 then
        return false
      elseif status == 0x102 then
        return true
      end
      return nil, failure()
    end,
    empty = function(job)
      local accounting = ffi.new("NEOAGENT_JOB_ACCOUNTING_INFORMATION") --[[@as Neoagent.WindowsProcessAccounting]]
      if kernel.QueryInformationJobObject(job, 1, accounting, ffi.sizeof(accounting), nil) == 0 then
        return nil, failure()
      end
      return accounting.ActiveProcesses == 0
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

-- The owner is published before native allocation. Its accounting observer is
-- reserved before the target can start and survives a caller's cleanup deadline.
---@return true?, string?
function Tree:start()
  self.monitor = vim.uv.new_timer()
  if not self.monitor then
    return nil, "could not allocate Job observer"
  end
  local job, err = self.backend.create()
  if not job then
    return nil, err
  end
  self.job = job
  local started, start_err = self.monitor:start(20, 20, function()
    self:poll()
  end)
  if not started then
    return nil, start_err
  end
  return true
end

function Tree:poll()
  if self.closed then
    return
  end
  if not self.empty then
    if self.disposed and self.job ~= nil and not self.termination_sent then
      local now = vim.uv.hrtime()
      if not self.retry_termination_ns or now >= self.retry_termination_ns then
        local stopped, err = self.backend.terminate(self.job, 125)
        if stopped then
          self.termination_sent = true
        else
          local delay = self.retry_delay_ms or 20
          self.retry_termination_ns = now + delay * 1000000
          self.retry_delay_ms = math.min(delay * 2, 1000)
          if not self.termination_failed then
            self.termination_failed = true
            self.callbacks.failed("Could not terminate process Job (" .. assert(err) .. ")")
          end
        end
      end
    end
    if self.job ~= nil and (self.attached or self.disposed) then
      local empty, err = self.backend.empty(assert(self.job))
      if empty == nil then
        if not self.observation_failed then
          self.observation_failed = true
          self.callbacks.failed("Could not observe process Job completion (" .. assert(err) .. ")")
        end
        return
      end
      if not empty then
        return
      end
    elseif not self.disposed then
      return
    end
    self.empty = true
    if self.monitor then
      self.monitor:stop()
    end
    self.callbacks.empty()
  end
  if self.disposed and not self.closed then
    self.closed = true
    if self.process ~= nil then
      self.backend.close(self.process)
      self.process = nil
    end
    if self.job ~= nil then
      self.backend.close(self.job)
      self.job = nil
    end
    if self.monitor then
      self.monitor:close(self.callbacks.released)
      self.monitor = nil
    else
      self.callbacks.released()
    end
  end
end

---@param pid integer
---@return true?, string?
function Tree:attach(pid)
  if self.disposed then
    return nil, "process tree is closed"
  end
  if type(pid) ~= "number" or pid <= 0 then
    return true
  end
  if self.attached then
    return nil, "process tree already has a root"
  end
  local process, open_err = self.backend.open(pid)
  if not process then
    return nil, open_err
  end
  local assigned, assign_err = self.backend.assign(assert(self.job), process)
  if not assigned then
    self.backend.close(process)
    return nil, assign_err
  end
  -- Retain the root's native identity until this owner releases the Job.
  self.process = process
  self.attached = true
  return true
end

-- A native launcher can assign the Job atomically in CreateProcessW and
-- transfer its already-open process handle without reopening a cached PID.
---@param process Neoagent.WindowsProcessHandle
function Tree:adopt(process)
  assert(not self.attached, "process tree already has an owner")
  if self.closed then
    self.backend.close(process)
    error("process tree is closed")
  end
  self.process = process
  self.attached = true
  if self.disposed then
    self.termination_sent = nil
    self.retry_termination_ns = nil
    self:poll()
  end
end

---@return boolean?, string?
function Tree:running()
  if self.closed or self.process == nil then
    return false
  end
  return self.backend.running(self.process)
end

---@param code? integer
---@return boolean
function Tree:terminate(code)
  if self.closed or self.job == nil or not self.attached and not self.disposed then
    return false
  end
  local terminated = self.backend.terminate(assert(self.job), code or 125)
  return terminated ~= nil and terminated ~= false
end

function Tree:close()
  if self.disposed then
    return
  end
  self.disposed = true
  self:poll()
end

---@param opts Neoagent.WindowsProcessOptions
---@return Neoagent.WindowsProcessTree
function M.new(opts)
  local backend = opts.backend or native_backend(opts.native)
  return setmetatable({ backend = backend, callbacks = opts.callbacks }, Tree)
end

return M
