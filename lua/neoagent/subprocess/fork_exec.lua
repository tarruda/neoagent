local ffi = require("ffi")
local validate = require("neoagent.subprocess.validate")
local M = {}

ffi.cdef([[
int fork(void);
int login_tty(int);
int chdir(const char *);
int execve(const char *, const char *const *, const char *const *);
long write(int, const void *, unsigned long);
void _exit(int);
int pthread_sigmask(int, const void *, void *);
int sigfillset(void *);
void (*signal(int, void (*)(int)))(int);
typedef struct { long seconds; int microseconds; } NeoagentDarwinTimeval;
typedef struct { NeoagentDarwinTimeval interval, value; } NeoagentDarwinTimer;
int getitimer(int, NeoagentDarwinTimer *);
]])

---@alias Neoagent.ForkApi {
--- fork: (fun(): integer), login_tty: (fun(fd: integer): integer),
--- chdir: (fun(path: string): integer),
--- execve: (fun(path: string, argv: ffi.cdata*, env: ffi.cdata*): integer),
--- write: (fun(fd: integer, bytes: ffi.cdata*, count: integer): ffi.cdata*),
--- _exit: (fun(code: integer)), sigfillset: (fun(set: ffi.cdata*): integer),
--- pthread_sigmask: (fun(how: integer, set: ffi.cdata*, previous: ffi.cdata*?): integer),
--- signal: (fun(number: integer, handler: ffi.cdata*): ffi.cdata*),
--- getitimer: (fun(kind: integer, timer: ffi.cdata*): integer),
--- }
local C = ffi.C --[[@as Neoagent.ForkApi]]

---@class Neoagent.DarwinTimer: ffi.cdata*
---@field value { seconds: integer, microseconds: integer }

---@param operation string
---@param code integer
local function check(operation, code)
  if code ~= 0 then
    error(validate.error("process_start", "Process " .. operation .. " failed (errno " .. code .. ")"), 0)
  end
end

-- All symbols, closures, buffers and arguments are prepared before fork.
-- This function and its child routine stay interpreted, without recording a
-- JIT trace. The child always execs or _exits; it never returns to the editor.
---@param slave integer
---@param report integer
---@param paths string[]
---@param cwd string
---@param argv ffi.cdata*
---@param env ffi.cdata*
---@param attach fun(pid: integer)
---@return integer errno
function M.launch(slave, report, paths, cwd, argv, env, attach)
  local fork, login, chdir, exec, write, exit = C.fork, C.login_tty, C.chdir, C.execve, C.write, C._exit
  local signal, mask, errno, protected, require_value = C.signal, C.pthread_sigmask, ffi.errno, pcall, assert
  local result = ffi.new("int[1]") --[[@as Neoagent.FfiArray<integer>]]
  local all, previous, empty = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
  check("signal set", C.sigfillset(all) == 0 and 0 or errno())
  local default, failed = ffi.cast("void (*)(int)", 0), ffi.cast("void (*)(int)", -1)
  local timer = ffi.new("NeoagentDarwinTimer") --[[@as Neoagent.DarwinTimer]]
  check("profiling state", C.getitimer(2, timer) == 0 and 0 or errno()) -- ITIMER_PROF
  if timer.value.seconds ~= 0 or timer.value.microseconds ~= 0 then
    error(validate.error("process_start", "macOS PTY startup requires sampling profiling to be stopped"), 0)
  end
  local hook, hook_mask, hook_count = debug.gethook()
  if hook ~= nil and type(hook) ~= "function" then
    error(validate.error("process_start", "macOS PTY startup cannot suspend an external native debug hook"), 0)
  end
  local count = #paths
  ---@return integer
  local function child()
    -- This routine only runs after fork with hooks suspended. The narrow
    -- coverage exception is documented in AGENTS.md; native tests exercise it.
    -- luacov: disable
    for number = 1, 31 do
      if number ~= 9 and number ~= 17 and signal(number, default) == failed then
        return errno()
      end
    end
    if login(slave) ~= 0 or chdir(cwd) ~= 0 then
      return errno()
    end
    local restored = mask(3, empty, nil) -- SIG_SETMASK
    if restored ~= 0 then
      return restored
    end
    local denied, failure = false, 2
    for index = 1, count do
      exec(require_value(paths[index]), argv, env)
      failure = errno()
      if failure == 13 then
        denied = true
      elseif failure ~= 2 and failure ~= 20 then
        return failure
      end
    end
    return denied and 13 or failure
    -- luacov: enable
  end
  jit.off(child, true)
  local collecting = collectgarbage("isrunning")
  debug.sethook()
  -- No Lua coverage hook can observe the critical section while suspended.
  -- luacov: disable
  collectgarbage("stop")
  local blocked = mask(1, all, previous) -- SIG_BLOCK
  local pid, saved_errno = -1, blocked
  local attached, attach_error = true, nil
  if blocked == 0 then
    pid = fork()
    saved_errno = errno()
    if pid == 0 then
      local ok, code = protected(child)
      result[0] = ok and code or 14 -- EFAULT; do not format a Lua error here.
      -- ssize_t results can allocate cdata. GC stays stopped, preventing
      -- inherited finalizers, and write failure still ends through _exit.
      protected(write, report, result, 4)
      exit(127)
    end
    if pid > 0 then
      attached, attach_error = protected(attach, pid)
    end
  end
  local restored = blocked == 0 and mask(3, previous, nil) or blocked
  if collecting then
    collectgarbage("restart")
  end
  debug.sethook(hook, hook_mask, hook_count)
  -- luacov: enable
  if not attached then
    error(attach_error, 0)
  end
  if pid < 0 then
    check("fork", saved_errno)
  end
  return restored
end
jit.off(M.launch, true)

return M
