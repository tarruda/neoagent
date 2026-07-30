local ffi = require("ffi")
local bit = require("bit")

if jit.os ~= "Linux" then
  io.stderr:write("sandbox-ffi-probe: Linux is required\n")
  os.exit(2)
end

local platform = {
  x64 = {
    audit_arch = 0xC000003E,
    getppid = 110,
  },
  arm64 = {
    audit_arch = 0xC00000B7,
    getppid = 173,
  },
}

local abi = platform[jit.arch]
if not abi then
  io.stderr:write("sandbox-ffi-probe: unsupported architecture: ", jit.arch, "\n")
  os.exit(2)
end

ffi.cdef([[
typedef int pid_t;
typedef long ssize_t;
typedef unsigned long size_t;

struct sock_filter {
  unsigned short code;
  unsigned char jt;
  unsigned char jf;
  unsigned int k;
};

struct sock_fprog {
  unsigned short len;
  struct sock_filter *filter;
};

pid_t fork(void);
pid_t waitpid(pid_t pid, int *status, int options);
int unshare(int flags);
int mount(
  const char *source,
  const char *target,
  const char *filesystemtype,
  unsigned long mountflags,
  const void *data
);
int prctl(
  int option,
  unsigned long arg2,
  unsigned long arg3,
  unsigned long arg4,
  unsigned long arg5
);
long syscall(long number, ...);
int execvp(const char *file, char *const argv[]);
ssize_t write(int fd, const void *buffer, size_t count);
void _exit(int status);
]])

local C = ffi.C
local EINTR = 4
local EPERM = 1
local CLONE_NEWNS = 0x00020000
local CLONE_NEWUSER = 0x10000000
local MS_REC = 0x00004000
local MS_PRIVATE = 0x00040000
local PR_SET_SECCOMP = 22
local PR_SET_NO_NEW_PRIVS = 38
local SECCOMP_MODE_FILTER = 2
local SECCOMP_RET_KILL_PROCESS = 0x80000000
local SECCOMP_RET_ERRNO = 0x00050000
local SECCOMP_RET_ALLOW = 0x7FFF0000
local BPF_LD_W_ABS = 0x20
local BPF_JMP_JEQ_K = 0x15
local BPF_RET_K = 0x06

local function get_thread_count()
  local file = io.open("/proc/self/status", "r")
  if not file then return nil end

  for line in file:lines() do
    local count = line:match("^Threads:%s*(%d+)")
    if count then
      file:close()
      return tonumber(count)
    end
  end

  file:close()
  return nil
end

local threads = get_thread_count()
if threads ~= 1 then
  io.stderr:write(
    ("sandbox-ffi-probe: runtime must have one thread, found %s\n"):format(
      tostring(threads)
    )
  )
  os.exit(78)
end
io.stdout:write("sandbox-ffi-probe: runtime_threads=1\n")
io.stdout:flush()

local command = {}
for index = 1, #arg do
  command[index] = arg[index]
end
if command[1] == "--" then table.remove(command, 1) end
if #command == 0 then
  io.stderr:write(
    "usage: nvim --headless -u NONE -i NONE -l scripts/sandbox_ffi_probe.lua",
    " -- command [arguments]\n"
  )
  os.exit(2)
end

local command_storage = {}
local command_argv = ffi.new("char *[?]", #command + 1)
for index, value in ipairs(command) do
  if (index == 1 and value == "") or value:find("\0", 1, true) then
    io.stderr:write(
      "sandbox-ffi-probe: program must be non-empty and argv must be NUL-free\n"
    )
    os.exit(2)
  end
  local storage = ffi.new("char[?]", #value + 1)
  ffi.copy(storage, value)
  command_storage[index] = storage
  command_argv[index - 1] = storage
end
command_argv[#command] = nil

local filter = ffi.new("struct sock_filter[7]")
local function instruction(index, code, value, yes, no)
  filter[index].code = code
  filter[index].jt = yes or 0
  filter[index].jf = no or 0
  filter[index].k = value
end

instruction(0, BPF_LD_W_ABS, 4)
instruction(1, BPF_JMP_JEQ_K, abi.audit_arch, 1, 0)
instruction(2, BPF_RET_K, SECCOMP_RET_KILL_PROCESS)
instruction(3, BPF_LD_W_ABS, 0)
instruction(4, BPF_JMP_JEQ_K, abi.getppid, 0, 1)
instruction(5, BPF_RET_K, bit.bor(SECCOMP_RET_ERRNO, EPERM))
instruction(6, BPF_RET_K, SECCOMP_RET_ALLOW)

local program = ffi.new("struct sock_fprog")
program.len = 7
program.filter = filter

local function write_message(fd, message)
  C.write(fd, message, #message)
end

local function child_error(stage, errno)
  write_message(2, string.format(
    "sandbox-ffi-probe: %s failed: errno=%d\n",
    stage,
    errno or ffi.errno()
  ))
  C._exit(70)
end

local function wait_for(child)
  local status = ffi.new("int[1]")
  while true do
    local waited = C.waitpid(child, status, 0)
    if waited == child then break end
    if waited < 0 and ffi.errno() ~= EINTR then
      error("waitpid failed: errno=" .. ffi.errno())
    end
  end
  local value = tonumber(status[0])
  local signal = bit.band(value, 0x7F)
  if signal == 0 then return bit.band(bit.rshift(value, 8), 0xFF) end
  return 128 + signal
end

local function probe_user_namespace()
  local child = C.fork()
  if child < 0 then error("fork failed: errno=" .. ffi.errno()) end
  if child == 0 then
    if C.unshare(bit.bor(CLONE_NEWUSER, CLONE_NEWNS)) == 0
        and C.mount(nil, "/", nil, bit.bor(MS_REC, MS_PRIVATE), nil) == 0 then
      write_message(
        1,
        "sandbox-ffi-probe: user_mount_namespaces=available\n"
      )
      C._exit(0)
    end
    write_message(1, string.format(
      "sandbox-ffi-probe: user_mount_namespaces=unavailable errno=%d\n",
      ffi.errno()
    ))
    C._exit(77)
  end
  return wait_for(child)
end

local function probe_seccomp_and_exec()
  local child = C.fork()
  if child < 0 then error("fork failed: errno=" .. ffi.errno()) end
  if child == 0 then
    if C.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ~= 0 then
      child_error("PR_SET_NO_NEW_PRIVS")
    end
    local pointer =
      ffi.cast("unsigned long", ffi.cast("uintptr_t", ffi.cast("void *", program)))
    if C.prctl(
      PR_SET_SECCOMP,
      SECCOMP_MODE_FILTER,
      pointer,
      0,
      0
    ) ~= 0 then
      child_error("PR_SET_SECCOMP")
    end
    ffi.errno(0)
    local parent = C.syscall(abi.getppid)
    local denied_errno = ffi.errno()
    if parent ~= -1 or denied_errno ~= EPERM then
      write_message(2, string.format(
        "sandbox-ffi-probe: seccomp verification failed: result=%d errno=%d\n",
        tonumber(parent),
        denied_errno
      ))
      C._exit(71)
    end
    write_message(1, "sandbox-ffi-probe: seccomp=active exec=starting\n")
    C.execvp(command_argv[0], command_argv)
    child_error("execvp")
  end
  return wait_for(child)
end

local namespace_status = probe_user_namespace()
local command_status = probe_seccomp_and_exec()
io.stdout:write(string.format(
  "sandbox-ffi-probe: namespace_status=%d command_status=%d\n",
  namespace_status,
  command_status
))

if command_status ~= 0 then os.exit(command_status) end
if namespace_status ~= 0 then os.exit(namespace_status) end
