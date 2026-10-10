local ffi = require("ffi")
local validate = require("neoagent.subprocess.validate")
local M = {}

-- Public libc layouts from Linux siginfo_t and Darwin sys/signal.h. Only
-- SIGCHLD fields are read; the complete storage and alignment are preserved.
ffi.cdef([[
typedef struct { int pid; unsigned int uid; int status; } NeoagentChildStatus;
]])
if jit.os == "OSX" then
  ffi.cdef([[
typedef struct {
  int signo, error, code;
  NeoagentChildStatus child;
  void *address;
  union { int integer; void *pointer; } value;
  long band;
  unsigned long padding[7];
} NeoagentChildInfo;
]])
elseif jit.os == "Linux" then
  ffi.cdef(string.format(
    [[
typedef struct {
  int signo, error, code;
  union {
    uintptr_t alignment;
    char padding[%d];
    NeoagentChildStatus child;
  };
} NeoagentChildInfo;
]],
    ffi.abi("64bit") and 112 or 116
  ))
end
ffi.cdef([[
int waitid(int, unsigned int, void *, int);
int waitpid(int, int *, int);
]])

---@alias Neoagent.ChildInfo {code: integer, child: {pid: integer, uid: integer, status: integer}}
---@alias Neoagent.ChildWaitApi {
--- waitid: (fun(kind: integer, pid: integer, info: Neoagent.ChildInfo, flags: integer): integer),
--- waitpid: (fun(pid: integer, status: nil, flags: integer): integer),
---}
local C = ffi.C --[[@as Neoagent.ChildWaitApi]]
local flags = 1 + 4 + (jit.os == "OSX" and 0x20 or 0x1000000) -- WNOHANG | WEXITED | WNOWAIT

---@class Neoagent.PosixChild
---@field attach fun(pid: integer)
---@field poll fun(): boolean
---@field interrupt fun(): boolean
---@field terminate fun(force: boolean): boolean
---@field close fun()

-- Inspect the native ABI without allocating a watcher or child owner.
---@return Neoagent.Error?
function M.platform_error()
  if jit.os ~= "Linux" and jit.os ~= "OSX" then
    return validate.error("process_supervision", "Unsupported native process platform: " .. jit.os)
  end
  -- siginfo_t and wait constants are architecture ABIs. In particular, Linux
  -- MIPS swaps si_errno/si_code; admitting it with this layout corrupts exits.
  local supported = jit.os == "Linux" and { x86 = true, x64 = true, arm = true, arm64 = true }
    or { x64 = true, arm64 = true }
  if not supported[jit.arch] then
    return validate.error("process_supervision", "Unsupported native process ABI: " .. jit.os .. "/" .. jit.arch)
  end
end

-- uv_close transfers reaping responsibility to the caller on POSIX. The
-- driver closes its uv_process_t without yielding after spawn, then observes
-- this child with WNOWAIT. Its PID stays reserved through the last group
-- signal; waitpid releases it only when the driver closes.
---@param callbacks Neoagent.SubprocessCallbacks
---@return Neoagent.PosixChild
function M.new(callbacks)
  local failure = M.platform_error()
  if failure then
    callbacks.released()
    error(failure, 0)
  end
  local ownership = require("neoagent.subprocess.release").new(callbacks.released)
  local resources = {}
  local function stop()
    for resource, released in pairs(resources) do
      if not resource:is_closing() then
        resource:stop()
        resource:close(released)
      end
    end
    ownership.close()
  end
  local function retain(resource)
    resources[resource] = ownership.retain()
    return resource
  end
  local allocation_error = validate.error("process_supervision", "Could not allocate process watcher")
  local allocated, info, watcher, retry = pcall(function()
    local info = ffi.new("NeoagentChildInfo") --[[@as Neoagent.ChildInfo]]
    local watcher = vim.uv.new_signal()
    if not watcher then
      error(allocation_error, 0)
    end
    retain(watcher)
    allocation_error = validate.error("process_supervision", "Could not allocate process reap timer")
    local retry = vim.uv.new_timer()
    if not retry then
      error(allocation_error, 0)
    end
    retain(retry)
    return info, watcher, retry
  end)
  if not allocated then
    stop()
    error(allocation_error, 0)
  end
  local watcher, retry = assert(watcher), assert(retry)
  ---@type integer?
  local pid
  local owned, exited, closing = false, false, false
  ---@return Neoagent.Error?
  local function release()
    if not owned then
      stop()
      return
    end
    local result
    repeat
      result = C.waitpid(assert(pid), nil, 1)
    until result >= 0 or ffi.errno() ~= 4
    if result > 0 then
      owned = false
      stop()
    elseif result < 0 then
      local errno = ffi.errno()
      if errno == 10 then -- ECHILD: ownership was lost to another reaper.
        owned = false
        stop()
      elseif not retry:is_active() then
        -- Exit may already have been observed, so no further SIGCHLD is
        -- guaranteed. Retain ownership independently of the finished caller.
        retry:start(100, 100, function()
          release()
        end)
      end
      return validate.error("process_cleanup", "Could not reap owned process (errno " .. errno .. ")")
    end
  end
  local function poll()
    if closing then
      release()
      return owned
    end
    if not owned or exited then
      return false
    end
    info.child.pid = 0
    local result
    repeat
      result = C.waitid(1, assert(pid), info, flags)
    until result == 0 or ffi.errno() ~= 4
    if result ~= 0 then
      -- Losing wait ownership must never leave a cached PID signalable.
      local errno = ffi.errno()
      if errno == 10 then -- ECHILD: another owner already reaped it.
        owned = false
        stop()
      end
      callbacks.failed("process_supervision", "Could not observe owned process (errno " .. errno .. ")")
      return false
    end
    if info.child.pid == 0 then
      return true
    end
    exited = true
    callbacks.exited(info.code == 1 and info.child.status or 0, info.code == 1 and 0 or info.child.status)
    return false
  end
  local watching, started, err = pcall(watcher.start, watcher, "sigchld", poll)
  if not watching or not started then
    stop()
    error(
      validate.error("process_supervision", "Could not watch owned process: " .. tostring(watching and err or started)),
      0
    )
  end
  local function signal(number)
    if not owned then
      return false
    end
    return vim.uv.kill(-assert(pid), number) ~= nil or vim.uv.kill(assert(pid), number) ~= nil
  end
  return {
    attach = function(value)
      pid = value
      owned = true
    end,
    poll = poll,
    interrupt = function()
      return signal(2)
    end,
    terminate = function(force)
      return signal(force and 9 or 15)
    end,
    close = function()
      -- Native ownership outlives a reported cleanup failure. A running child
      -- keeps its signal watcher; a failed final wait also arms reap retries.
      closing = true
      local err = release()
      if err then
        error(err, 0)
      end
    end,
  }
end

return M
