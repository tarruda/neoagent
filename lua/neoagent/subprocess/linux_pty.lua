local ffi = require("ffi")
local validate = require("neoagent.subprocess.validate")
local environment = require("neoagent.subprocess.environment")
local executable = require("neoagent.subprocess.posix_executable")
local streams = require("neoagent.subprocess.streams")
local children = require("neoagent.subprocess.posix_child")
local M = {}

-- Public glibc/musl spawn.h layouts. The accessors interpret the attributes;
-- keeping both layouts explicit documents the ABI used for their allocation.
ffi.cdef([[
typedef struct { unsigned long bits[128 / sizeof(unsigned long)]; } NeoagentSpawnSignals;
typedef struct {
  int flags, pgrp;
  NeoagentSpawnSignals defaults, mask;
  int priority, policy;
  void *function_pointer;
  char padding[64 - sizeof(void *)];
} NeoagentMuslSpawnAttributes;
typedef struct {
  short flags;
  int pgrp;
  NeoagentSpawnSignals defaults, mask;
  int priority, policy;
  int padding[16];
} NeoagentGlibcSpawnAttributes;
typedef struct { int allocated, used; void *actions; int padding[16]; } NeoagentSpawnActions;
typedef struct { unsigned short rows, columns, xpixel, ypixel; } NeoagentPtySize;
const char *gnu_get_libc_version(void);
int posix_openpt(int);
int grantpt(int);
int unlockpt(int);
int ptsname_r(int, char *, size_t);
int ioctl(int, unsigned long, ...);
int fcntl(int, int, ...);
int close(int);
int sigemptyset(NeoagentSpawnSignals *);
int sigfillset(NeoagentSpawnSignals *);
int posix_spawnattr_init(void *);
int posix_spawnattr_destroy(void *);
int posix_spawnattr_setflags(void *, short);
int posix_spawnattr_setsigmask(void *, const NeoagentSpawnSignals *);
int posix_spawnattr_setsigdefault(void *, const NeoagentSpawnSignals *);
int posix_spawn_file_actions_init(NeoagentSpawnActions *);
int posix_spawn_file_actions_destroy(NeoagentSpawnActions *);
int posix_spawn_file_actions_addopen(NeoagentSpawnActions *, int, const char *, int, unsigned int);
int posix_spawn_file_actions_adddup2(NeoagentSpawnActions *, int, int);
int posix_spawn_file_actions_addchdir_np(NeoagentSpawnActions *, const char *);
int posix_spawn(int *, const char *, const NeoagentSpawnActions *, const void *, const char *const *, const char *const *);
]])

---@alias Neoagent.PtyLibc {
--- gnu_get_libc_version: (fun(): ffi.cdata*),
--- posix_openpt: (fun(flags: integer): integer),
--- grantpt: (fun(fd: integer): integer),
--- unlockpt: (fun(fd: integer): integer),
--- ptsname_r: (fun(fd: integer, name: ffi.cdata*, size: integer): integer),
--- ioctl: (fun(fd: integer, request: integer, value: ffi.cdata*): integer),
--- fcntl: (fun(fd: integer, request: integer, value: ffi.cdata*): integer),
--- close: (fun(fd: integer): integer),
--- sigemptyset: (fun(set: ffi.cdata*): integer),
--- sigfillset: (fun(set: ffi.cdata*): integer),
--- posix_spawnattr_init: (fun(attrs: ffi.cdata*): integer),
--- posix_spawnattr_destroy: (fun(attrs: ffi.cdata*): integer),
--- posix_spawnattr_setflags: (fun(attrs: ffi.cdata*, flags: integer): integer),
--- posix_spawnattr_setsigmask: (fun(attrs: ffi.cdata*, signals: ffi.cdata*): integer),
--- posix_spawnattr_setsigdefault: (fun(attrs: ffi.cdata*, signals: ffi.cdata*): integer),
--- posix_spawn_file_actions_init: (fun(actions: ffi.cdata*): integer),
--- posix_spawn_file_actions_destroy: (fun(actions: ffi.cdata*): integer),
--- posix_spawn_file_actions_addopen: (fun(actions: ffi.cdata*, fd: integer, path: ffi.cdata*, flags: integer, mode: integer): integer),
--- posix_spawn_file_actions_adddup2: (fun(actions: ffi.cdata*, old: integer, new: integer): integer),
--- posix_spawn_file_actions_addchdir_np: (fun(actions: ffi.cdata*, cwd: string): integer),
--- posix_spawn: (fun(pid: ffi.cdata*, path: string, actions: ffi.cdata*, attrs: ffi.cdata*, argv: ffi.cdata*, env: ffi.cdata*): integer),
---}
local C = ffi.C --[[@as Neoagent.PtyLibc]]

---@class Neoagent.NativeArgumentVector: ffi.cdata*
---@field [integer] string|ffi.cdata*|nil

---@class Neoagent.NativePid: ffi.cdata*
---@field [integer] integer

---@param operation string
---@param code integer
local function check(operation, code)
  if code ~= 0 then
    error(validate.error("process_start", "Process " .. operation .. " failed (errno " .. code .. ")"), 0)
  end
end

---@param values string[]
---@return ffi.cdata*
local function strings(values)
  local result = ffi.new("const char *[?]", #values + 1) --[[@as Neoagent.NativeArgumentVector]]
  for index, value in ipairs(values) do
    result[index - 1] = value
  end
  return result
end

---@param spec Neoagent.SubprocessSpec
---@param env table<string, string>
---@param callbacks Neoagent.SubprocessCallbacks
---@return Neoagent.SubprocessDriver
function M.new(spec, env, callbacks)
  local failure = children.platform_error()
  if failure then
    error(validate.error("pty_unavailable", failure.message), 0)
  end
  local available = pcall(function()
    return C.posix_spawn_file_actions_addchdir_np
  end)
  if not available then
    error(validate.error("pty_unavailable", "Native PTYs require libc spawn working-directory support"), 0)
  end
  local glibc = pcall(function()
    return C.gnu_get_libc_version()
  end)
  -- execvp treats these as missing PATH candidates, preserving an earlier
  -- EACCES only if the entire search fails without a more definitive error.
  local missing = { [2] = true, [20] = true } -- ENOENT, ENOTDIR
  if glibc then
    missing[19], missing[110], missing[116] = true, true, true -- ENODEV, ETIMEDOUT, ESTALE
  end
  local attributes = ffi.new(glibc and "NeoagentGlibcSpawnAttributes[1]" or "NeoagentMuslSpawnAttributes[1]")
  local actions = ffi.new("NeoagentSpawnActions[1]")
  local attrs_ready, actions_ready, started = false, false, false
  -- Native pointers do not keep their backing Lua strings alive. Retain the
  -- complete launch allocation until all spawn attempts have finished.
  ---@type {argv: ffi.cdata*, env: ffi.cdata*, strings: string[][]}?
  local arguments
  local io = streams.new(callbacks)
  ---@type Neoagent.PosixChild?
  local child
  ---@type uv.uv_pipe_t?
  local output
  ---@type table<integer, boolean>
  local descriptors = {}
  ---@type integer?
  local master

  local function release_setup()
    if attrs_ready then
      C.posix_spawnattr_destroy(attributes)
      attrs_ready = false
    end
    if actions_ready then
      C.posix_spawn_file_actions_destroy(actions)
      actions_ready = false
    end
    for fd in pairs(descriptors) do
      C.close(fd)
      descriptors[fd] = nil
    end
    arguments = nil
  end

  local function dispose()
    release_setup()
    local ok, err = pcall(function()
      if child then
        child.terminate(true)
        child.close()
      end
    end)
    io.dispose()
    if not ok then
      error(err, 0)
    end
  end

  local function resize(columns, rows)
    local size = ffi.new("NeoagentPtySize[1]", { { rows, columns, 0, 0 } })
    if not output or output:is_closing() or C.ioctl(assert(master), 0x5414, size) ~= 0 then
      error(validate.error("process_terminal", "Could not resize process terminal"), 0)
    end
    return true
  end

  local function start()
    local paths = executable.candidates(assert(spec.argv[1]), env.PATH)
    child = children.new({
      exited = function(code, signal)
        callbacks.exited(code, signal)
        io.exited()
      end,
      output = callbacks.output,
      closed = callbacks.closed,
      failed = callbacks.failed,
    })
    -- These master descriptors are never inherited by the target. The slave
    -- is opened by posix_spawn after SETSID, which acquires its controlling
    -- terminal without ever returning into Lua in the forked child.
    local fd = C.posix_openpt(2 + 0x100 + 0x80000) -- RDWR | NOCTTY | CLOEXEC
    if fd < 0 then
      check("terminal allocation", ffi.errno())
    end
    descriptors[fd] = true
    check("terminal grant", C.grantpt(fd) == 0 and 0 or ffi.errno())
    check("terminal unlock", C.unlockpt(fd) == 0 and 0 or ffi.errno())
    local name = ffi.new("char[256]")
    check("terminal name", C.ptsname_r(fd, name, 256))
    local input_fd = C.fcntl(fd, 1030, ffi.new("int", 3)) -- F_DUPFD_CLOEXEC
    if input_fd < 0 then
      check("terminal descriptor", ffi.errno())
    end
    descriptors[input_fd] = true
    output = io.pipe()
    assert(output:open(fd))
    descriptors[fd] = nil
    master = fd
    local input = io.pipe()
    assert(input:open(input_fd))
    descriptors[input_fd] = nil
    io.input(input)
    resize(spec.stdio.columns, spec.stdio.rows)

    check("spawn attributes", C.posix_spawnattr_init(attributes))
    attrs_ready = true
    check("spawn actions", C.posix_spawn_file_actions_init(actions))
    actions_ready = true
    local signals = ffi.new("NeoagentSpawnSignals[1]")
    check("default signals", C.sigfillset(signals) == 0 and 0 or ffi.errno())
    check("default signals", C.posix_spawnattr_setsigdefault(attributes, signals))
    check("signal mask", C.sigemptyset(signals) == 0 and 0 or ffi.errno())
    check("signal mask", C.posix_spawnattr_setsigmask(attributes, signals))
    check("spawn flags", C.posix_spawnattr_setflags(attributes, 128 + 4 + 8)) -- SETSID | SETSIGDEF | SETSIGMASK
    check("terminal input", C.posix_spawn_file_actions_addopen(actions, 0, name, 2, 0))
    check("terminal output", C.posix_spawn_file_actions_adddup2(actions, 0, 1))
    check("terminal error", C.posix_spawn_file_actions_adddup2(actions, 0, 2))
    check("working directory", C.posix_spawn_file_actions_addchdir_np(actions, spec.cwd))

    local entries = environment.list(env)
    arguments = { argv = strings(spec.argv), env = strings(entries), strings = { spec.argv, entries } }
    local pid = ffi.new("int[1]") --[[@as Neoagent.NativePid]]
    local function execute(path)
      local backing = assert(arguments)
      local result = C.posix_spawn(pid, path, actions, attributes, backing.argv, backing.env)
      if result == 8 and glibc then -- Match glibc execvp's ENOEXEC behavior.
        local shell = { "/bin/sh", path }
        for index = 2, #spec.argv do
          shell[#shell + 1] = spec.argv[index]
        end
        backing.strings[#backing.strings + 1] = shell
        return C.posix_spawn(pid, "/bin/sh", actions, attributes, strings(shell), backing.env)
      end
      return result
    end
    local result = 2
    local denied = false
    -- Attempt execution before rejecting a PATH candidate: a missing shebang
    -- interpreter must not hide a usable executable later in the search.
    for _, path in ipairs(paths) do
      result = execute(path)
      if result == 0 then
        break
      elseif result == 13 then
        denied = true
      elseif not missing[result] then
        break
      end
    end
    if denied and missing[result] then
      result = 13
    end
    if result == 0 then
      child.attach(pid[0])
      started = true
    end
    release_setup()
    check("execution", result)
    io.read(output, "pty")
    child.poll()
    return true
  end

  local function terminate(force)
    if not started then
      dispose()
      io.exited()
      return true
    end
    return assert(child).terminate(force)
  end

  return {
    start = start,
    observe = function(done)
      done(assert(child).poll())
    end,
    cleanup_ms = validate.REAP_MS,
    delivery_delay_ns = io.delivery_delay_ns,
    write = io.write,
    flush = io.flush,
    writable = io.writable,
    close_stdin = function()
      error(validate.error("unsupported_control", "PTY stdin cannot be closed portably"), 0)
    end,
    resize = resize,
    stop = function()
      return terminate(false)
    end,
    kill = function()
      return terminate(true)
    end,
    dispose = dispose,
  }
end

return M
