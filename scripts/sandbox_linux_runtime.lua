local ffi = require("ffi")
local bit = require("bit")

if jit.os ~= "Linux" then
  io.stderr:write("neoagent Linux sandbox runtime requires Linux\n")
  os.exit(2)
end

ffi.cdef([[
typedef int pid_t;
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef unsigned long size_t;
typedef long ssize_t;
typedef long off_t;
typedef struct {
  unsigned long __bits[16];
} sigset_t;

struct pollfd {
  int fd;
  short events;
  short revents;
};
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
struct __user_cap_header_struct {
  unsigned int version;
  int pid;
};
struct __user_cap_data_struct {
  unsigned int effective;
  unsigned int permitted;
  unsigned int inheritable;
};
struct mount_attr {
  unsigned long long attr_set;
  unsigned long long attr_clr;
  unsigned long long propagation;
  unsigned long long userns_fd;
};
struct iovec {
  void *iov_base;
  size_t iov_len;
};
struct msghdr {
  void *msg_name;
  unsigned int msg_namelen;
  struct iovec *msg_iov;
  size_t msg_iovlen;
  void *msg_control;
  size_t msg_controllen;
  int msg_flags;
};
struct cmsghdr {
  size_t cmsg_len;
  int cmsg_level;
  int cmsg_type;
};
struct seccomp_data {
  int nr;
  unsigned int arch;
  unsigned long long instruction_pointer;
  unsigned long long args[6];
};
struct seccomp_notif {
  unsigned long long id;
  unsigned int pid;
  unsigned int flags;
  struct seccomp_data data;
};
struct seccomp_notif_resp {
  unsigned long long id;
  long long val;
  int error;
  unsigned int flags;
};
struct seccomp_notif_addfd {
  unsigned long long id;
  unsigned int flags;
  unsigned int srcfd;
  unsigned int newfd;
  unsigned int newfd_flags;
};
struct open_how {
  unsigned long long flags;
  unsigned long long mode;
  unsigned long long resolve;
};

pid_t fork(void);
pid_t waitpid(pid_t pid, int *status, int options);
pid_t getpid(void);
pid_t getppid(void);
uid_t getuid(void);
gid_t getgid(void);
int unshare(int flags);
int mount(const char *, const char *, const char *, unsigned long, const void *);
int umount2(const char *, int);
int chdir(const char *);
int fchdir(int);
int chmod(const char *, unsigned int);
int mkdir(const char *, unsigned int);
int symlink(const char *, const char *);
int open(const char *, int, ...);
int openat(int, const char *, int, ...);
int mkdirat(int, const char *, unsigned int);
int mknodat(int, const char *, unsigned int, unsigned long);
int unlinkat(int, const char *, int);
int linkat(int, const char *, int, const char *, int);
int symlinkat(const char *, int, const char *);
int renameat(int, const char *, int, const char *);
int renameat2(int, const char *, int, const char *, unsigned int);
int close(int);
int dup(int);
ssize_t read(int, void *, size_t);
ssize_t write(int, const void *, size_t);
ssize_t process_vm_readv(pid_t, const struct iovec *, unsigned long,
  const struct iovec *, unsigned long, unsigned long);
int pipe2(int [2], int);
int socketpair(int, int, int, int [2]);
ssize_t sendmsg(int, const struct msghdr *, int);
ssize_t recvmsg(int, struct msghdr *, int);
int dup2(int, int);
int poll(struct pollfd *, unsigned long, int);
int ioctl(int, unsigned long, ...);
int bind(int, const void *, unsigned int);
int kill(pid_t, int);
pid_t setsid(void);
int sigemptyset(sigset_t *);
int sigaddset(sigset_t *, int);
int sigprocmask(int, const sigset_t *, sigset_t *);
int signalfd(int, const sigset_t *, int);
int sethostname(const char *, size_t);
int setgroups(size_t, const gid_t *);
int setresuid(uid_t, uid_t, uid_t);
int setresgid(gid_t, gid_t, gid_t);
int prctl(int, unsigned long, unsigned long, unsigned long, unsigned long);
int capset(struct __user_cap_header_struct *, struct __user_cap_data_struct *);
long sysconf(int);
long syscall(long, ...);
int execve(const char *, char *const [], char *const []);
void _exit(int);
]])

local C = ffi.C
local function finish(code)
  C._exit(code)
end

local E = {
  EPERM = 1,
  ENOENT = 2,
  EIO = 5,
  EBADF = 9,
  EAGAIN = 11,
  EACCES = 13,
  EFAULT = 14,
  EINTR = 4,
  ECHILD = 10,
  EEXIST = 17,
  ENAMETOOLONG = 36,
  ENOSYS = 38,
  EOPNOTSUPP = 95,
}
local O = {
  RDONLY = 0,
  WRONLY = 1,
  CREAT = 64,
  TRUNC = 512,
  APPEND = 1024,
  NONBLOCK = 2048,
  PATH = 2097152,
  NOFOLLOW = 131072,
  DIRECTORY = 65536,
  CLOEXEC = 524288,
  TMPFILE = 0x410000,
}
local SIG = {
  HUP = 1,
  INT = 2,
  QUIT = 3,
  KILL = 9,
  TERM = 15,
}
local CLONE = {
  NEWNS = 0x00020000,
  NEWUTS = 0x04000000,
  NEWIPC = 0x08000000,
  NEWUSER = 0x10000000,
  NEWPID = 0x20000000,
  NEWNET = 0x40000000,
}
local MS = {
  RDONLY = 1,
  NOSUID = 2,
  NODEV = 4,
  NOEXEC = 8,
  REMOUNT = 32,
  BIND = 4096,
  REC = 16384,
  SILENT = 32768,
  PRIVATE = 262144,
  NOATIME = 1024,
  NODIRATIME = 2048,
  RELATIME = 2097152,
}
local MNT_DETACH = 2
local AT_FDCWD = -100
local AT_REMOVEDIR = 0x200
local AT_RECURSIVE = 0x8000
local MOUNT_ATTR_RDONLY = 0x1
local MOUNT_ATTR_NOSUID = 0x2
local MOUNT_ATTR_NODEV = 0x4
local PR_SET_PDEATHSIG = 1
local PR_CAPBSET_DROP = 24
local PR_CAP_AMBIENT = 47
local PR_CAP_AMBIENT_CLEAR_ALL = 4
local PR_SET_SECCOMP = 22
local PR_SET_NO_NEW_PRIVS = 38
local SECCOMP_MODE_FILTER = 2
local SECCOMP_RET_KILL_PROCESS = 0x80000000
local SECCOMP_RET_ERRNO = 0x00050000
local SECCOMP_RET_USER_NOTIF = 0x7fc00000
local SECCOMP_RET_ALLOW = 0x7fff0000
local SECCOMP_SET_MODE_FILTER = 1
local SECCOMP_FILTER_FLAG_NEW_LISTENER = 8
local SECCOMP_IOCTL_NOTIF_RECV = 0xc0502100
local SECCOMP_IOCTL_NOTIF_SEND = 0xc0182101
local SECCOMP_IOCTL_NOTIF_ID_VALID = 0x40082102
local SECCOMP_IOCTL_NOTIF_ADDFD = 0x40182103
local SECCOMP_ADDFD_FLAG_SEND = 2
local EPERM = 1
local PIPE_CLOEXEC = O.CLOEXEC
local POLLIN, POLLHUP = 1, 16
local SIG_BLOCK, SIG_UNBLOCK = 0, 1
local WNOHANG = 1
local SC_OPEN_MAX = 4

local abi_by_arch = {
  x64 = {
    audit_arch = 0xC000003E,
    pivot_root = 155,
    mount_setattr = 442,
    close_range = 436,
    clone = 56,
    clone3 = 435,
    open = 2,
    rename = 82,
    mkdir = 83,
    rmdir = 84,
    creat = 85,
    link = 86,
    unlink = 87,
    symlink = 88,
    mknod = 133,
    openat = 257,
    mkdirat = 258,
    mknodat = 259,
    unlinkat = 263,
    renameat = 264,
    linkat = 265,
    symlinkat = 266,
    renameat2 = 316,
    seccomp = 317,
    pidfd_open = 434,
    pidfd_getfd = 438,
    openat2 = 437,
    socket = 41,
    socketpair = 53,
    bind = 49,
    x32 = true,
    network_deny = {
      42, 43, 44, 48, 49, 50, 51, 52, 54, 55, 288, 299, 307,
    },
    deny = {
      101, 165, 166, 169, 175, 176, 246, 248, 249, 250, 272, 275,
      278, 298, 304, 308, 310, 311, 313, 321, 323, 425, 426, 427,
      428, 429, 430, 431, 432, 433, 438, 440, 442,
    },
  },
  arm64 = {
    audit_arch = 0xC00000B7,
    pivot_root = 41,
    mount_setattr = 442,
    close_range = 436,
    clone = 220,
    clone3 = 435,
    openat = 56,
    mkdirat = 34,
    mknodat = 33,
    unlinkat = 35,
    renameat = 38,
    linkat = 37,
    symlinkat = 36,
    renameat2 = 276,
    seccomp = 277,
    pidfd_open = 434,
    pidfd_getfd = 438,
    openat2 = 437,
    socket = 198,
    socketpair = 199,
    bind = 200,
    network_deny = {
      200, 201, 202, 203, 204, 205, 206, 208, 209, 210, 242, 243,
      269,
    },
    deny = {
      39, 40, 97, 104, 105, 106, 117, 142, 217, 218, 219, 241,
      265, 268, 270, 271, 273, 280, 282, 425, 426, 427, 428, 429,
      430, 431, 432, 433, 438, 440, 442,
    },
  },
}
local abi = abi_by_arch[jit.arch]

local function write_all(fd, data)
  local offset = 0
  while offset < #data do
    local count = C.write(fd, data:sub(offset + 1), #data - offset)
    if count < 0 then
      if ffi.errno() ~= E.EINTR then return nil end
    else
      offset = offset + tonumber(count)
    end
  end
  return true
end

local function frame(value)
  local payload = vim.mpack.encode(value)
  local length = #payload
  local header = string.char(
    math.floor(length / 16777216) % 256,
    math.floor(length / 65536) % 256,
    math.floor(length / 256) % 256,
    length % 256)
  write_all(1, header .. payload)
end

local function terminal_error(stage, errno)
  frame({ v = 1, type = "error", stage = stage, errno = errno or ffi.errno() })
  finish(125)
end

local function child_error(fd, stage, errno)
  write_all(fd, string.format("error %s %d\n", stage, errno or ffi.errno()))
  finish(125)
end

local function close_descriptors(preserve, error_fd)
  local first, first_errno = 0, 0
  if preserve > 3 then
    first = C.syscall(abi.close_range,
      ffi.cast("unsigned int", 3),
      ffi.cast("unsigned int", preserve - 1),
      ffi.cast("unsigned int", 0))
    first_errno = ffi.errno()
  end
  local last = C.syscall(abi.close_range,
    ffi.cast("unsigned int", preserve + 1),
    ffi.cast("unsigned int", 0xffffffff),
    ffi.cast("unsigned int", 0))
  local last_errno = ffi.errno()
  if first == 0 and last == 0 then return end
  if first_errno ~= E.ENOSYS or last_errno ~= E.ENOSYS then
    child_error(error_fd, "close-range",
      first ~= 0 and first_errno or last_errno)
  end
  local maximum = tonumber(C.sysconf(SC_OPEN_MAX))
  if not maximum or maximum < 0 then
    child_error(error_fd, "open-max")
  end
  for descriptor = 3, maximum - 1 do
    if descriptor ~= preserve then C.close(descriptor) end
  end
end

local function threads()
  local file = io.open("/proc/self/status", "r")
  if not file then return nil end
  for line in file:lines() do
    local count = line:match("^Threads:%s*(%d+)")
    if count then file:close() return tonumber(count) end
  end
  file:close()
end

local function wait_for_single_thread(timeout_ms)
  local deadline = vim.uv.hrtime() + timeout_ms * 1000000
  local count = threads()
  while count ~= 1 and vim.uv.hrtime() < deadline do
    vim.uv.sleep(1)
    count = threads()
  end
  return count == 1, count
end

local function bootstrap_single_thread()
  -- CLONE_NEWUSER accepts only a single-threaded caller. fork() retains the
  -- calling thread in the child while hosted Neovim helper threads remain in
  -- this parent. The runtime reaches this boundary before scheduling its own
  -- asynchronous work, and the calling thread owns the active Lua state.
  local parent_pid = C.getpid()
  local child = C.fork()
  if child < 0 then terminal_error("thread-bootstrap") end
  if child == 0 then
    -- Close the fork-to-parent-death race before continuing namespace setup.
    if C.prctl(PR_SET_PDEATHSIG, SIG.KILL, 0, 0, 0) ~= 0
        or C.getppid() ~= parent_pid then
      terminal_error("thread-bootstrap-parent")
    end
    return
  end

  -- Retain the launched process lifetime and status while the single-threaded
  -- child writes the sandbox protocol directly to the inherited descriptors.
  local status = ffi.new("int[1]")
  while C.waitpid(child, status, 0) < 0 do
    if ffi.errno() ~= E.EINTR then
      terminal_error("thread-bootstrap-wait")
    end
  end
  -- waitpid stores a terminating signal in the low seven bits and a normal
  -- exit code in bits 8-15.
  local raw = tonumber(status[0])
  local signal = bit.band(raw, 0x7f)
  if signal ~= 0 then finish(128 + signal) end
  finish(bit.band(bit.rshift(raw, 8), 0xff))
end

local encoded = vim.uv.os_getenv("NEOAGENT_SANDBOX_SPEC", 512 * 1024 + 1)
vim.uv.os_unsetenv("NEOAGENT_SANDBOX_SPEC")
if not abi then terminal_error("architecture", 0) end
if type(encoded) ~= "string" then terminal_error("specification-environment", 0) end
if #encoded > 512 * 1024 then terminal_error("specification-size", 0) end
local decoded, spec = pcall(vim.json.decode, encoded)
if not decoded then terminal_error("specification-json", 0) end
if type(spec) ~= "table" then terminal_error("specification-type", 0) end
if spec.v ~= 1 then terminal_error("specification-version", 0) end
if spec.mode ~= "probe" and spec.mode ~= "exec" and spec.mode ~= "fs" then
  terminal_error("specification-mode", 0)
end
if type(spec.root) ~= "string" or spec.root:sub(1, 1) ~= "/"
    or spec.root:find("\0", 1, true) then
  terminal_error("specification-root", 0)
end
if type(spec.root_identity) ~= "table"
    or type(spec.root_identity.dev) ~= "number"
    or type(spec.root_identity.ino) ~= "number" then
  terminal_error("specification-root-identity", 0)
end
if type(spec.profile) ~= "table" then terminal_error("specification-profile", 0) end
if spec.procfs ~= "fresh" and spec.procfs ~= "host" then
  terminal_error("specification-procfs", 0)
end
if type(spec.cwd) ~= "string" or spec.cwd:sub(1, 1) ~= "/"
    or spec.cwd:find("\0", 1, true) then
  terminal_error("specification-cwd", 0)
end
local command = {}
for index = 1, #arg do command[index] = arg[index] end
if command[1] == "--" then table.remove(command, 1) end
if spec.mode == "exec" and #command == 0
    or spec.mode ~= "exec" and #command ~= 0 then
  terminal_error("command-argv", 0)
end
for index, value in ipairs(command) do
  if type(value) ~= "string" or value:find("\0", 1, true)
      or index == 1 and value == "" then
    terminal_error("command-argv", 0)
  end
end
if type(spec.env) ~= "table" or vim.islist(spec.env) and next(spec.env) then
  terminal_error("specification-environment", 0)
end
for name, value in pairs(spec.env) do
  if type(name) ~= "string"
      or not name:match("^[A-Za-z_][A-Za-z0-9_]*$")
      or type(value) ~= "string" or value:find("\0", 1, true) then
    terminal_error("specification-environment", 0)
  end
end
if spec.profile.network ~= "restricted"
    and spec.profile.network ~= "enabled" then
  terminal_error("specification-profile", 0)
end
if type(spec.profile.filesystem) ~= "table"
    or spec.profile.filesystem.default ~= "read"
    or type(spec.profile.filesystem.entries) ~= "table"
    or not vim.islist(spec.profile.filesystem.entries) then
  terminal_error("specification-profile", 0)
end
if type(spec.protected_create) ~= "table"
    or not vim.islist(spec.protected_create) then
  terminal_error("specification-protected-create", 0)
end
for _, entry in ipairs(spec.protected_create) do
  if type(entry) ~= "table" or type(entry.path) ~= "string"
      or entry.path:sub(1, 1) ~= "/" or entry.path:find("\0", 1, true)
      or entry.access ~= "read" and entry.access ~= "deny" then
    terminal_error("specification-protected-create", 0)
  end
end
-- Transient startup helpers may quiesce naturally. A persistent helper uses
-- the supervised fork boundary while namespace setup stays single-threaded.
local single_threaded, thread_count = wait_for_single_thread(250)
if not single_threaded and thread_count and thread_count > 1 then
  bootstrap_single_thread()
  single_threaded, thread_count = wait_for_single_thread(0)
end
-- Missing or malformed /proc thread data remains a hard failure; the fork
-- path applies only when a real additional thread was observed.
if not single_threaded then
  terminal_error("threads", thread_count or 0)
end

local editor_pid = C.getppid()
if C.prctl(PR_SET_PDEATHSIG, SIG.KILL, 0, 0, 0) ~= 0
    or C.getppid() ~= editor_pid then
  terminal_error("parent-death")
end
local blocked_signals = ffi.new("sigset_t")
if C.sigemptyset(blocked_signals) ~= 0 then
  terminal_error("signal-mask")
end
for _, signal in ipairs({ SIG.HUP, SIG.INT, SIG.QUIT, SIG.TERM }) do
  if C.sigaddset(blocked_signals, signal) ~= 0 then
    terminal_error("signal-mask")
  end
end
if C.sigprocmask(SIG_BLOCK, blocked_signals, nil) ~= 0 then
  terminal_error("signal-block")
end
local signal_fd = C.signalfd(-1, blocked_signals, O.CLOEXEC)
if signal_fd < 0 then terminal_error("signal-fd") end

local function cwrite(path, data)
  local fd = C.open(path, bit.bor(O.WRONLY, O.CLOEXEC))
  if fd < 0 then return nil end
  local ok = write_all(fd, data)
  C.close(fd)
  return ok
end

local host_uid, host_gid = tonumber(C.getuid()), tonumber(C.getgid())
local flags = bit.bor(CLONE.NEWUSER, CLONE.NEWNS,
  CLONE.NEWIPC, CLONE.NEWUTS)
if spec.profile.network == "restricted" then flags = bit.bor(flags, CLONE.NEWNET) end
if C.unshare(flags) ~= 0 then terminal_error("unshare") end
cwrite("/proc/self/setgroups", "deny\n")
if not cwrite("/proc/self/uid_map", "0 " .. host_uid .. " 1\n") then
  terminal_error("uid-map")
end
if not cwrite("/proc/self/gid_map", "0 " .. host_gid .. " 1\n") then
  terminal_error("gid-map")
end
if C.setgroups(0, nil) ~= 0 and ffi.errno() ~= 1 then
  terminal_error("setgroups")
end
if C.setresgid(0, 0, 0) ~= 0 or C.setresuid(0, 0, 0) ~= 0 then
  terminal_error("setresuid")
end
if C.unshare(CLONE.NEWPID) ~= 0 then terminal_error("unshare-pid") end
if C.mount(nil, "/", nil, bit.bor(MS.REC, MS.PRIVATE), nil) ~= 0 then
  terminal_error("mount-private")
end
C.sethostname("neoagent", 8)

local function mkdir(path, mode)
  if C.mkdir(path, mode or 493) == 0 or ffi.errno() == E.EEXIST then return true end
  return nil
end

local function create_file(path)
  local fd = C.open(path, bit.bor(O.WRONLY, O.CREAT, O.CLOEXEC),
    ffi.cast("unsigned int", 384))
  if fd < 0 then return nil end
  C.close(fd)
  return true
end

local function same_inode(left, right)
  return left and right and left.dev == right.dev and left.ino == right.ino
end

local function readonly(path, enabled)
  local attr = ffi.new("struct mount_attr")
  attr.attr_set = bit.bor(MOUNT_ATTR_NOSUID, MOUNT_ATTR_NODEV)
  if enabled then
    attr.attr_set = bit.bor(attr.attr_set, MOUNT_ATTR_RDONLY)
  else
    attr.attr_clr = MOUNT_ATTR_RDONLY
  end
  if C.syscall(abi.mount_setattr,
      ffi.cast("int", AT_FDCWD),
      ffi.cast("const char *", path),
      ffi.cast("unsigned int", AT_RECURSIVE),
      attr,
      ffi.cast("size_t", ffi.sizeof(attr))) == 0 then
    return true
  end
  local failure = ffi.errno()
  if failure ~= 22 and failure ~= E.ENOSYS
      and failure ~= E.EOPNOTSUPP then
    return nil
  end

  local file = io.open("/proc/self/mountinfo", "r")
  if not file then return nil end
  local mounts = {}
  for line in file:lines() do
    local mountpoint, options =
      line:match("^%d+ %d+ %S+ %S+ (%S+) (%S+)")
    if mountpoint then
      mountpoint = mountpoint:gsub("\\(%d%d%d)", function(value)
        return string.char(tonumber(value, 8))
      end)
      if mountpoint == path
          or mountpoint:sub(1, #path + 1) == path .. "/" then
        mounts[#mounts + 1] = {
          path = mountpoint,
          options = "," .. options .. ",",
        }
      end
    end
  end
  file:close()
  table.sort(mounts, function(left, right)
    return #left.path < #right.path
  end)
  if #mounts == 0 or mounts[1].path ~= path then return nil end
  for _, mountpoint in ipairs(mounts) do
    local flags = bit.bor(MS.SILENT, MS.BIND, MS.NOSUID, MS.NODEV)
    for option, flag in pairs({
      noexec = MS.NOEXEC,
      noatime = MS.NOATIME,
      nodiratime = MS.NODIRATIME,
      relatime = MS.RELATIME,
    }) do
      if mountpoint.options:find("," .. option .. ",", 1, true) then
        flags = bit.bor(flags, flag)
      end
    end
    if enabled
        or mountpoint.options:find(",ro,", 1, true) then
      flags = bit.bor(flags, MS.RDONLY)
    end
    if C.mount("none", mountpoint.path, nil,
        bit.bor(flags, MS.REMOUNT), nil) ~= 0 then
      return nil
    end
  end
  return true
end

local root = spec.root
local newroot = root .. "/newroot"
local root_stat = vim.uv.fs_lstat(root)
if not root_stat or root_stat.type ~= "directory"
    or root_stat.dev ~= spec.root_identity.dev
    or root_stat.ino ~= spec.root_identity.ino then
  terminal_error("root-identity", 0)
end
if C.mount("tmpfs", root, "tmpfs", bit.bor(MS.NOSUID, MS.NODEV),
    "mode=0700") ~= 0 then
  terminal_error("mount-root")
end
if not mkdir(newroot, 493) then terminal_error("mkdir-newroot") end
local source_root = vim.uv.fs_stat("/")
if C.mount("/", newroot, nil, bit.bor(MS.BIND, MS.REC), nil) ~= 0 then
  terminal_error("bind-root")
end
if not same_inode(source_root, vim.uv.fs_stat(newroot)) then
  terminal_error("bind-root-identity")
end
if not readonly(newroot, true) then terminal_error("readonly-root") end

local blocked_file = root .. "/blocked"
if not create_file(blocked_file) then terminal_error("blocked-file") end

local function target(path)
  return path == "/" and newroot or newroot .. path
end

for _, path in ipairs({ "/run" }) do
  if C.mount("tmpfs", target(path), "tmpfs",
      bit.bor(MS.NOSUID, MS.NODEV),
      "mode=0755") ~= 0 then
    terminal_error("private-runtime")
  end
end

if C.mount("tmpfs", target("/dev"), "tmpfs", MS.NOSUID,
    "mode=0755") ~= 0 then
  terminal_error("private-dev")
end
for _, name in ipairs({
  "null", "zero", "full", "random", "urandom", "tty",
}) do
  local destination = target("/dev/" .. name)
  if not create_file(destination)
      or C.mount("/dev/" .. name, destination, nil, MS.BIND, nil) ~= 0 then
    terminal_error("device-" .. name)
  end
end
if not mkdir(target("/dev/pts"), 493)
    or C.mount("devpts", target("/dev/pts"), "devpts",
      bit.bor(MS.NOSUID, MS.NOEXEC),
      "newinstance,ptmxmode=0666,mode=0620") ~= 0
    or C.symlink("pts/ptmx", target("/dev/ptmx")) ~= 0 then
  terminal_error("device-pts")
end
if not mkdir(target("/dev/shm"), 1023)
    or C.mount("tmpfs", target("/dev/shm"), "tmpfs",
      bit.bor(MS.NOSUID, MS.NODEV),
      "mode=1777") ~= 0 then
  terminal_error("device-shm")
end
for name, destination in pairs({
  fd = "/proc/self/fd",
  stdin = "/proc/self/fd/0",
  stdout = "/proc/self/fd/1",
  stderr = "/proc/self/fd/2",
}) do
  if C.symlink(destination, target("/dev/" .. name)) ~= 0 then
    terminal_error("device-links")
  end
end

local function ensure_target(path, stat)
  local destination = target(path)
  if vim.uv.fs_stat(destination) then return true end
  local current = newroot
  local parts = {}
  for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
  for index, part in ipairs(parts) do
    current = current .. "/" .. part
    if index < #parts or stat and stat.type == "directory" then
      if not mkdir(current, 493) then return nil end
    elseif not create_file(current) then
      return nil
    end
  end
  return true
end

local function contains(root, path)
  return root == "/" or path == root
    or path:sub(1, #root + 1) == root .. "/"
end

local entries = {}
for _, entry in ipairs(spec.profile.filesystem.entries or {}) do
  entries[#entries + 1] = entry
end
for _, entry in ipairs(spec.protected_create) do
  if vim.uv.fs_lstat(entry.path) then
    terminal_error("protected-create-race", E.EEXIST)
  end
end
table.sort(entries, function(left, right)
  if #left.path ~= #right.path then return #left.path < #right.path end
  local rank = { write = 1, read = 2, deny = 3 }
  return rank[left.access] < rank[right.access]
end)

for _, entry in ipairs(entries) do
  if entry.path ~= "/" then
    local stat = vim.uv.fs_stat(entry.path)
    if entry.access == "write" and not stat then
      terminal_error("missing-write", 2)
    elseif entry.access == "read" and stat then
      if not ensure_target(entry.path, stat) then
        terminal_error("readonly-target")
      end
      if C.mount(entry.path, target(entry.path), nil,
          bit.bor(MS.BIND, MS.REC), nil) ~= 0
          or not same_inode(stat, vim.uv.fs_stat(target(entry.path)))
          or not readonly(target(entry.path), true) then
        terminal_error("readonly-path")
      end
    elseif entry.access == "write" then
      if not ensure_target(entry.path, stat) then
        terminal_error("writable-target")
      end
      if C.mount(entry.path, target(entry.path), nil,
          bit.bor(MS.BIND, MS.REC), nil) ~= 0
          or not same_inode(stat, vim.uv.fs_stat(target(entry.path)))
          or not readonly(target(entry.path), false) then
        terminal_error("writable-path")
      end
    elseif entry.access == "deny" and stat then
      if not ensure_target(entry.path, stat) then
        terminal_error("deny-target")
      elseif stat.type == "directory" then
        if C.mount("tmpfs", target(entry.path), "tmpfs",
            bit.bor(MS.NOSUID, MS.NODEV, MS.NOEXEC), "mode=0700") ~= 0 then
          terminal_error("deny-directory")
        end
        local has_grant = false
        for _, nested in ipairs(entries) do
          if nested.path ~= entry.path and contains(entry.path, nested.path) then
            local nested_stat = vim.uv.fs_stat(nested.path)
            if nested_stat
                and not ensure_target(nested.path, nested_stat) then
              terminal_error("deny-exception-target")
            end
            if nested.access ~= "deny" then has_grant = true end
          end
        end
        local mode = has_grant and 73 or 0
        if C.chmod(target(entry.path), mode) ~= 0
            or not readonly(target(entry.path), true) then
          terminal_error("deny-directory")
        end
      elseif C.mount(blocked_file, target(entry.path), nil, MS.BIND, nil) ~= 0
          or not readonly(target(entry.path), true) then
        terminal_error("deny-file")
      end
    end
  end
end

local oldroot = C.open("/", bit.bor(O.RDONLY, O.DIRECTORY, O.CLOEXEC))
if oldroot < 0 or C.chdir(newroot) ~= 0 then terminal_error("pivot-chdir") end
if C.syscall(abi.pivot_root,
    ffi.cast("const char *", "."),
    ffi.cast("const char *", ".")) ~= 0 then
  terminal_error("pivot-root")
end
if C.fchdir(oldroot) ~= 0 or C.umount2(".", MNT_DETACH) ~= 0 then
  terminal_error("detach-oldroot")
end
C.close(oldroot)
if C.chdir("/") ~= 0 then terminal_error("root-chdir") end

local function pipe()
  local value = ffi.new("int[2]")
  if C.pipe2(value, PIPE_CLOEXEC) ~= 0 then terminal_error("pipe") end
  return tonumber(value[0]), tonumber(value[1])
end

local function socket_pair()
  local value = ffi.new("int[2]")
  if C.socketpair(1, bit.bor(2, O.CLOEXEC), 0, value) ~= 0 then
    terminal_error("socketpair")
  end
  return tonumber(value[0]), tonumber(value[1])
end

local function send_fd(socket, fd)
  local byte = ffi.new("char[1]", 1)
  local iov = ffi.new("struct iovec[1]")
  iov[0].iov_base, iov[0].iov_len = byte, 1
  local control = ffi.new("unsigned char[24]")
  local header = ffi.cast("struct cmsghdr *", control)
  header.cmsg_len, header.cmsg_level, header.cmsg_type = 20, 1, 1
  ffi.cast("int *", control + 16)[0] = fd
  local message = ffi.new("struct msghdr")
  message.msg_iov, message.msg_iovlen = iov, 1
  message.msg_control, message.msg_controllen = control, 24
  return C.sendmsg(socket, message, 0) == 1
end

local function receive_fd(socket)
  local byte = ffi.new("char[1]")
  local iov = ffi.new("struct iovec[1]")
  iov[0].iov_base, iov[0].iov_len = byte, 1
  local control = ffi.new("unsigned char[24]")
  local message = ffi.new("struct msghdr")
  message.msg_iov, message.msg_iovlen = iov, 1
  message.msg_control, message.msg_controllen = control, 24
  if C.recvmsg(socket, message, 0) ~= 1 then return nil end
  local header = ffi.cast("struct cmsghdr *", control)
  if header.cmsg_len ~= 20 or header.cmsg_level ~= 1
      or header.cmsg_type ~= 1 then
    return nil
  end
  return tonumber(ffi.cast("int *", control + 16)[0])
end

local stdin_copy = C.dup(0)
if stdin_copy < 0 then terminal_error("stdin") end
local stdout_r, stdout_w = pipe()
local stderr_r, stderr_w = pipe()
local control_r, control_w = pipe()
local command_r, command_w = pipe()
local confirm_r, confirm_w = pipe()
local status_r, status_w = pipe()
local listener_parent, listener_child = socket_pair()

local function drop_capabilities(error_fd)
  for capability = 0, 63 do
    if C.prctl(PR_CAPBSET_DROP, capability, 0, 0, 0) ~= 0
        and ffi.errno() ~= 22 then
      child_error(error_fd, "cap-bounding")
    end
  end
  if C.prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) ~= 0 then
    child_error(error_fd, "cap-ambient")
  end
  local header = ffi.new("struct __user_cap_header_struct")
  local capabilities = ffi.new("struct __user_cap_data_struct[2]")
  header.version = 0x20080522
  header.pid = 0
  if C.capset(header, capabilities) ~= 0 then
    child_error(error_fd, "capset")
  end
end

local function install_seccomp(error_fd, notify)
  if C.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ~= 0 then
    child_error(error_fd, "no-new-privs")
  end

  local filter = ffi.new("struct sock_filter[?]", 256)
  local length = 0
  local function ins(code, k, jt, jf)
    filter[length].code = code
    filter[length].jt = jt or 0
    filter[length].jf = jf or 0
    filter[length].k = k
    length = length + 1
  end
  local LD_W_ABS, JEQ, JGE, JSET, RET =
    0x20, 0x15, 0x35, 0x45, 0x06
  ins(LD_W_ABS, 4)
  ins(JEQ, abi.audit_arch, 1, 0)
  ins(RET, SECCOMP_RET_KILL_PROCESS)
  ins(LD_W_ABS, 0)
  if abi.x32 then
    ins(JGE, 0x40000000, 0, 1)
    ins(RET, SECCOMP_RET_KILL_PROCESS)
  end
  local namespace_flags = bit.bor(
    CLONE.NEWNS, CLONE.NEWUTS, CLONE.NEWIPC, CLONE.NEWUSER,
    CLONE.NEWPID, CLONE.NEWNET, 0x02000000, 0x80)
  ins(JEQ, abi.clone, 0, 4)
  ins(LD_W_ABS, 16)
  ins(JSET, namespace_flags, 0, 1)
  ins(RET, bit.bor(SECCOMP_RET_ERRNO, EPERM))
  ins(LD_W_ABS, 0)
  ins(JEQ, abi.clone3, 0, 1)
  ins(RET, bit.bor(SECCOMP_RET_ERRNO, E.ENOSYS))
  for _, number in ipairs(abi.deny) do
    ins(JEQ, number, 0, 1)
    ins(RET, bit.bor(SECCOMP_RET_ERRNO, EPERM))
  end
  if spec.profile.network == "restricted" then
    for _, number in ipairs(abi.network_deny) do
      ins(JEQ, number, 0, 1)
      ins(RET, bit.bor(SECCOMP_RET_ERRNO, EPERM))
    end
    ins(JEQ, abi.socket, 0, 3)
    ins(LD_W_ABS, 16)
    ins(JEQ, 1, 1, 0)
    ins(RET, bit.bor(SECCOMP_RET_ERRNO, EPERM))
    ins(JEQ, abi.socketpair, 0, 3)
    ins(LD_W_ABS, 16)
    ins(JEQ, 1, 1, 0)
    ins(RET, bit.bor(SECCOMP_RET_ERRNO, EPERM))
  end
  if notify then
    local mediated = {
      abi.open,
      abi.creat,
      abi.rename,
      abi.mkdir,
      abi.rmdir,
      abi.link,
      abi.unlink,
      abi.symlink,
      abi.mknod,
      abi.openat,
      abi.mkdirat,
      abi.mknodat,
      abi.unlinkat,
      abi.renameat,
      abi.linkat,
      abi.symlinkat,
      abi.renameat2,
      abi.openat2,
    }
    if spec.profile.network == "enabled" then
      mediated[#mediated + 1] = abi.bind
    end
    for _, number in pairs(mediated) do
      if number then
        ins(JEQ, number, 0, 1)
        ins(RET, SECCOMP_RET_USER_NOTIF)
      end
    end
  end
  ins(RET, SECCOMP_RET_ALLOW)
  local program = ffi.new("struct sock_fprog")
  program.len = length
  program.filter = filter
  local pointer = ffi.cast("unsigned long",
    ffi.cast("uintptr_t", ffi.cast("void *", program)))
  if notify then
    local listener = C.syscall(abi.seccomp,
      ffi.cast("unsigned int", SECCOMP_SET_MODE_FILTER),
      ffi.cast("unsigned int", SECCOMP_FILTER_FLAG_NEW_LISTENER),
      ffi.cast("void *", program))
    if listener < 0 then child_error(error_fd, "seccomp-listener") end
    return tonumber(listener)
  end
  if C.prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, pointer, 0, 0) ~= 0 then
    child_error(error_fd, "seccomp")
  end
end

local function remote_data(pid, address, size)
  if size < 0 or size > 65536 then return nil end
  local buffer = ffi.new("unsigned char[?]", math.max(size, 1))
  local local_iov = ffi.new("struct iovec[1]")
  local remote_iov = ffi.new("struct iovec[1]")
  local_iov[0].iov_base = buffer
  local_iov[0].iov_len = size
  remote_iov[0].iov_base = ffi.cast(
    "void *", ffi.cast("uintptr_t", address))
  remote_iov[0].iov_len = size
  local count = C.process_vm_readv(
    pid, local_iov, 1, remote_iov, 1, 0)
  if count < 0 then return nil end
  return ffi.string(buffer, tonumber(count))
end

local function remote_string(pid, address)
  local value = remote_data(pid, address, 4096)
  if not value then return nil, E.EFAULT end
  local ending = value:find("\0", 1, true)
  if not ending then return nil, E.ENAMETOOLONG end
  return value:sub(1, ending - 1)
end

local function int_argument(notification, index)
  return tonumber(ffi.cast("int", notification.data.args[index]))
end

local function number_argument(notification, index)
  return tonumber(notification.data.args[index])
end

local reference_cache = {}
local namespace_id

local function namespace_ids(path)
  local file = io.open(path .. "/status", "r")
  if not file then return nil end
  for line in file:lines() do
    local encoded_ids = line:match("^NSpid:%s*(.*)")
    if encoded_ids then
      file:close()
      local ids = {}
      for value in encoded_ids:gmatch("%d+") do
        ids[#ids + 1] = tonumber(value)
      end
      return ids
    end
  end
  file:close()
end

local function process_namespace(path)
  return vim.uv.fs_readlink(path .. "/ns/pid")
end

local function matching_namespace(path, pid)
  local ids = namespace_ids(path)
  return ids and ids[#ids] == pid
    and process_namespace(path) == namespace_id
end

local function reference_pid(pid)
  if spec.procfs == "fresh" then return pid end
  if not namespace_id then
    local ids = namespace_ids("/proc/self")
    if not ids or #ids < 2 or ids[#ids] ~= tonumber(C.getpid()) then
      return nil
    end
    namespace_id = process_namespace("/proc/self")
    if not namespace_id then return nil end
  end
  local cached = reference_cache[pid]
  if cached
      and matching_namespace("/proc/" .. cached, pid) then
    return cached
  end

  local related = {}
  local scan = vim.uv.fs_scandir("/proc")
  if not scan then return nil end
  while true do
    local name, kind = vim.uv.fs_scandir_next(scan)
    if not name then break end
    if kind == "directory" and name:match("^%d+$") then
      local path = "/proc/" .. name
      if matching_namespace(path, pid) then
        reference_cache[pid] = tonumber(name)
        return reference_cache[pid]
      elseif process_namespace(path) == namespace_id then
        related[#related + 1] = name
      end
    end
  end
  for _, leader in ipairs(related) do
    local tasks = vim.uv.fs_scandir("/proc/" .. leader .. "/task")
    if tasks then
      while true do
        local name, kind = vim.uv.fs_scandir_next(tasks)
        if not name then break end
        if kind == "directory"
            and matching_namespace(
              "/proc/" .. leader .. "/task/" .. name, pid) then
          reference_cache[pid] = tonumber(name)
          return reference_cache[pid]
        end
      end
    end
  end
end

local function process_path(pid, dirfd)
  local reference = reference_pid(pid)
  if not reference then return nil end
  if dirfd == AT_FDCWD then
    return "/proc/" .. tostring(reference) .. "/cwd"
  end
  return "/proc/" .. tostring(reference) .. "/fd/" .. tostring(dirfd)
end

local function captured_base(pid, dirfd, path)
  local reference
  local relative = path
  if path:sub(1, 1) == "/" then
    local reference_id = reference_pid(pid)
    reference = reference_id
      and "/proc/" .. tostring(reference_id) .. "/root" or nil
    relative = path:gsub("^/+", "")
    if relative == "" then relative = "." end
  else
    reference = process_path(pid, dirfd)
  end
  if not reference then return nil, E.EACCES end
  local fd = C.open(reference, bit.bor(O.PATH, O.CLOEXEC))
  if fd < 0 then return nil, ffi.errno() end
  return tonumber(fd), relative
end

local function base_path(pid, dirfd, path)
  if path:sub(1, 1) == "/" then return path end
  local reference = process_path(pid, dirfd)
  local base = reference and vim.uv.fs_readlink(reference)
  if not base or base:sub(-10) == " (deleted)" then return nil end
  return base .. "/" .. path
end

local function resolved_destination(path, depth)
  if not path or depth and depth > 40 then return nil end
  depth = (depth or 0) + 1
  local stat = vim.uv.fs_lstat(path)
  if stat and stat.type == "link" then
    local link = vim.uv.fs_readlink(path)
    if not link then return nil end
    if link:sub(1, 1) ~= "/" then
      link = vim.fs.dirname(path) .. "/" .. link
    end
    return resolved_destination(link, depth)
  end
  local resolved = vim.uv.fs_realpath(path)
  if resolved then return vim.fs.normalize(resolved) end
  local suffix = {}
  local current = path
  while current ~= "/" and not vim.uv.fs_lstat(current) do
    table.insert(suffix, 1, vim.fs.basename(current))
    local parent = vim.fs.dirname(current)
    if parent == current then return nil end
    current = parent
  end
  resolved = vim.uv.fs_realpath(current)
  if not resolved then return nil end
  for _, part in ipairs(suffix) do
    resolved = resolved .. "/" .. part
  end
  return vim.fs.normalize(resolved)
end

local function restriction_for(path)
  local selected
  local specificity = -1
  for _, entry in ipairs(spec.protected_create) do
    if contains(entry.path, path) and #entry.path > specificity then
      selected = entry.access
      specificity = #entry.path
    end
  end
  return selected
end

local function path_restriction(pid, dirfd, path)
  local candidate = base_path(pid, dirfd, path)
  if not candidate then return nil, E.EACCES end
  local lexical = vim.fs.normalize(candidate)
  local selected = restriction_for(lexical)
  if selected then return selected, nil end
  local resolved = resolved_destination(candidate)
  if not resolved then return nil, E.EACCES end
  return restriction_for(resolved), nil
end

local function send_response(listener, notification, value, failure)
  local response = ffi.new("struct seccomp_notif_resp")
  response.id = notification.id
  response.val = value or 0
  response.error = failure and -failure or 0
  if C.ioctl(listener, SECCOMP_IOCTL_NOTIF_SEND, response) ~= 0
      and ffi.errno() ~= E.ENOENT then
    return nil
  end
  return true
end

local function notification_valid(listener, notification)
  local id = ffi.new("unsigned long long[1]", notification.id)
  return C.ioctl(listener, SECCOMP_IOCTL_NOTIF_ID_VALID, id) == 0
end

local function send_result(listener, notification, value, failure)
  if value < 0 then
    return send_response(listener, notification, 0, failure or E.EIO)
  end
  return send_response(listener, notification, tonumber(value), nil)
end

local function add_open_fd(listener, notification, fd, flags, failure)
  if fd < 0 then
    return send_response(listener, notification, 0, failure or E.EIO)
  end
  local request = ffi.new("struct seccomp_notif_addfd")
  request.id = notification.id
  request.flags = SECCOMP_ADDFD_FLAG_SEND
  request.srcfd = fd
  request.newfd_flags = bit.band(flags, O.CLOEXEC)
  local installed = C.ioctl(listener, SECCOMP_IOCTL_NOTIF_ADDFD, request)
  local failure = ffi.errno()
  C.close(fd)
  if installed < 0 then
    return send_response(listener, notification, 0, failure)
  end
  return true
end

local function open_is_mutating(flags)
  return bit.band(flags,
    bit.bor(O.WRONLY, 2, O.CREAT, O.TRUNC, O.APPEND, O.TMPFILE)) ~= 0
end

local function open_notification(listener, notification, dirfd, path_index,
    flags, mode, how_data)
  local pid = tonumber(notification.pid)
  local path, path_err = remote_string(
    pid, notification.data.args[path_index])
  if not path then
    return send_response(listener, notification, 0, path_err)
  end
  local restriction, resolve_err = path_restriction(pid, dirfd, path)
  if resolve_err then
    return send_response(listener, notification, 0, resolve_err)
  end
  if restriction == "deny"
      or restriction == "read" and open_is_mutating(flags) then
    return send_response(listener, notification, 0, E.EPERM)
  end
  local base, relative_or_err = captured_base(pid, dirfd, path)
  if not base then
    return send_response(listener, notification, 0, relative_or_err)
  end
  if not notification_valid(listener, notification) then
    C.close(base)
    return true
  end
  local fd
  if how_data then
    fd = C.syscall(abi.openat2,
      ffi.cast("int", base),
      ffi.cast("const char *", relative_or_err),
      ffi.cast("void *", how_data.buffer),
      ffi.cast("size_t", how_data.size))
  else
    fd = C.openat(base, relative_or_err, flags,
      ffi.cast("unsigned int", mode))
  end
  local open_err = ffi.errno()
  C.close(base)
  return add_open_fd(
    listener, notification, tonumber(fd), flags, open_err)
end

local function captured_path(pid, notification, dir_index, path_index)
  local path, path_err = remote_string(
    pid, notification.data.args[path_index])
  if not path then return nil, path_err end
  local dirfd = dir_index and int_argument(notification, dir_index)
    or AT_FDCWD
  local restriction, resolve_err = path_restriction(pid, dirfd, path)
  if resolve_err then return nil, resolve_err end
  local base, relative_or_err = captured_base(pid, dirfd, path)
  if not base then return nil, relative_or_err end
  return {
    base = base,
    path = relative_or_err,
    restriction = restriction,
  }
end

local function close_paths(...)
  for _, value in ipairs({ ... }) do
    if value and value.base then C.close(value.base) end
  end
end

local function mutating_path(listener, notification, operation)
  local pid = tonumber(notification.pid)
  local first, first_err = captured_path(pid, notification,
    operation.first_dir, operation.first_path)
  if not first then
    return send_response(listener, notification, 0, first_err)
  end
  local second, second_err
  if operation.second_path then
    second, second_err = captured_path(pid, notification,
      operation.second_dir, operation.second_path)
    if not second then
      close_paths(first)
      return send_response(listener, notification, 0, second_err)
    end
  end
  if first.restriction or second and second.restriction then
    close_paths(first, second)
    return send_response(listener, notification, 0, E.EPERM)
  end
  if not notification_valid(listener, notification) then
    close_paths(first, second)
    return true
  end
  local result
  if operation.kind == "mkdir" then
    result = C.mkdirat(first.base, first.path,
      number_argument(notification, operation.mode))
  elseif operation.kind == "mknod" then
    result = C.mknodat(first.base, first.path,
      number_argument(notification, operation.mode),
      number_argument(notification, operation.device))
  elseif operation.kind == "symlink" then
    local source, source_err = remote_string(
      pid, notification.data.args[operation.source])
    if not source then
      close_paths(first)
      return send_response(listener, notification, 0, source_err)
    end
    result = C.symlinkat(source, first.base, first.path)
  elseif operation.kind == "link" then
    result = C.linkat(first.base, first.path, second.base, second.path,
      operation.flags and number_argument(notification, operation.flags) or 0)
  elseif operation.kind == "rename" then
    if operation.flags then
      result = C.renameat2(first.base, first.path, second.base, second.path,
        number_argument(notification, operation.flags))
    else
      result = C.renameat(first.base, first.path, second.base, second.path)
    end
  elseif operation.kind == "unlink" then
    result = C.unlinkat(first.base, first.path, operation.flags or 0)
  end
  local operation_err = ffi.errno()
  close_paths(first, second)
  return send_result(
    listener, notification, result, operation_err)
end

local function bind_notification(listener, notification)
  local pid = tonumber(notification.pid)
  local length = number_argument(notification, 2)
  if length < 2 or length > 4096 then
    return send_response(listener, notification, 0, E.EFAULT)
  end
  local address = remote_data(pid, notification.data.args[1], length)
  if not address or #address ~= length then
    return send_response(listener, notification, 0, E.EFAULT)
  end
  local family = address:byte(1) + address:byte(2) * 256
  local bind_cwd
  if family == 1 and length > 2 and address:byte(3) ~= 0 then
    local ending = address:find("\0", 3, true) or length + 1
    local path = address:sub(3, ending - 1)
    local restriction, resolve_err =
      path_restriction(pid, AT_FDCWD, path)
    if resolve_err or restriction then
      return send_response(listener, notification, 0,
        resolve_err or E.EPERM)
    end
    if path:sub(1, 1) ~= "/" then
      bind_cwd = captured_base(pid, AT_FDCWD, ".")
      if not bind_cwd then
        return send_response(listener, notification, 0, E.EACCES)
      end
    end
  end
  if not notification_valid(listener, notification) then
    if bind_cwd then C.close(bind_cwd) end
    return true
  end
  local pidfd = C.syscall(abi.pidfd_open,
    ffi.cast("pid_t", pid),
    ffi.cast("unsigned int", 0))
  if pidfd < 0 then
    local pidfd_err = ffi.errno()
    if bind_cwd then C.close(bind_cwd) end
    return send_response(listener, notification, 0, pidfd_err)
  end
  local socket_fd = C.syscall(
    abi.pidfd_getfd,
    ffi.cast("int", pidfd),
    ffi.cast("int", int_argument(notification, 0)),
    ffi.cast("unsigned int", 0))
  local duplicate_err = ffi.errno()
  C.close(pidfd)
  if socket_fd < 0 then
    if bind_cwd then C.close(bind_cwd) end
    return send_response(listener, notification, 0, duplicate_err)
  end
  local buffer = ffi.new("unsigned char[?]", length)
  ffi.copy(buffer, address, length)
  local original_cwd
  if bind_cwd then
    original_cwd = C.open(".",
      bit.bor(O.RDONLY, O.DIRECTORY, O.CLOEXEC))
    if original_cwd < 0 or C.fchdir(bind_cwd) ~= 0 then
      local cwd_err = ffi.errno()
      if original_cwd >= 0 then C.close(original_cwd) end
      C.close(bind_cwd)
      C.close(socket_fd)
      return send_response(listener, notification, 0, cwd_err)
    end
  end
  local result = C.bind(socket_fd, buffer, length)
  local bind_err = ffi.errno()
  if original_cwd then
    if C.fchdir(original_cwd) ~= 0 then
      C.close(original_cwd)
      C.close(bind_cwd)
      C.close(socket_fd)
      return nil
    end
    C.close(original_cwd)
    C.close(bind_cwd)
  end
  C.close(socket_fd)
  return send_result(listener, notification, result, bind_err)
end

local function handle_notification(listener)
  local notification = ffi.new("struct seccomp_notif")
  if C.ioctl(listener, SECCOMP_IOCTL_NOTIF_RECV, notification) ~= 0 then
    local failure = ffi.errno()
    if failure == E.EINTR or failure == E.EAGAIN then return true end
    return nil
  end
  local nr = tonumber(notification.data.nr)
  if nr == abi.open then
    return open_notification(listener, notification, AT_FDCWD, 0,
      number_argument(notification, 1), number_argument(notification, 2))
  elseif nr == abi.creat then
    return open_notification(listener, notification, AT_FDCWD, 0,
      bit.bor(O.WRONLY, O.CREAT, O.TRUNC), number_argument(notification, 1))
  elseif nr == abi.openat then
    return open_notification(listener, notification,
      int_argument(notification, 0), 1,
      number_argument(notification, 2), number_argument(notification, 3))
  elseif nr == abi.openat2 then
    local size = number_argument(notification, 3)
    if size < 24 or size > 256 then
      return send_response(listener, notification, 0, E.EFAULT)
    end
    local data = remote_data(
      tonumber(notification.pid), notification.data.args[2], size)
    if not data or #data ~= size then
      return send_response(listener, notification, 0, E.EFAULT)
    end
    local buffer = ffi.new("unsigned char[?]", size)
    ffi.copy(buffer, data, size)
    local flags = tonumber(ffi.cast(
      "struct open_how *", buffer).flags)
    return open_notification(listener, notification,
      int_argument(notification, 0), 1, flags, 0,
      { buffer = buffer, size = size })
  elseif nr == abi.mkdir then
    return mutating_path(listener, notification, {
      kind = "mkdir", first_path = 0, mode = 1,
    })
  elseif nr == abi.mkdirat then
    return mutating_path(listener, notification, {
      kind = "mkdir", first_dir = 0, first_path = 1, mode = 2,
    })
  elseif nr == abi.mknod then
    return mutating_path(listener, notification, {
      kind = "mknod", first_path = 0, mode = 1, device = 2,
    })
  elseif nr == abi.mknodat then
    return mutating_path(listener, notification, {
      kind = "mknod", first_dir = 0, first_path = 1,
      mode = 2, device = 3,
    })
  elseif nr == abi.unlink then
    return mutating_path(listener, notification, {
      kind = "unlink", first_path = 0,
    })
  elseif nr == abi.rmdir then
    return mutating_path(listener, notification, {
      kind = "unlink", first_path = 0, flags = AT_REMOVEDIR,
    })
  elseif nr == abi.unlinkat then
    return mutating_path(listener, notification, {
      kind = "unlink", first_dir = 0, first_path = 1,
      flags = int_argument(notification, 2),
    })
  elseif nr == abi.symlink then
    return mutating_path(listener, notification, {
      kind = "symlink", source = 0, first_path = 1,
    })
  elseif nr == abi.symlinkat then
    return mutating_path(listener, notification, {
      kind = "symlink", source = 0, first_dir = 1, first_path = 2,
    })
  elseif nr == abi.link then
    return mutating_path(listener, notification, {
      kind = "link", first_path = 0, second_path = 1,
    })
  elseif nr == abi.linkat then
    return mutating_path(listener, notification, {
      kind = "link", first_dir = 0, first_path = 1,
      second_dir = 2, second_path = 3, flags = 4,
    })
  elseif nr == abi.rename then
    return mutating_path(listener, notification, {
      kind = "rename", first_path = 0, second_path = 1,
    })
  elseif nr == abi.renameat then
    return mutating_path(listener, notification, {
      kind = "rename", first_dir = 0, first_path = 1,
      second_dir = 2, second_path = 3,
    })
  elseif nr == abi.renameat2 then
    return mutating_path(listener, notification, {
      kind = "rename", first_dir = 0, first_path = 1,
      second_dir = 2, second_path = 3, flags = 4,
    })
  elseif spec.profile.network == "enabled" and nr == abi.bind then
    return bind_notification(listener, notification)
  end
  return send_response(listener, notification, 0, E.ENOSYS)
end

local init = C.fork()
if init < 0 then terminal_error("fork-init") end
if init == 0 then
  C.close(stdout_r)
  C.close(stderr_r)
  C.close(control_r)
  C.close(command_w)
  C.close(confirm_r)
  C.close(status_r)
  C.close(signal_fd)
  local parent = C.getppid()
  if C.prctl(PR_SET_PDEATHSIG, SIG.KILL, 0, 0, 0) ~= 0
      or C.getppid() ~= parent then
    child_error(control_w, "parent-death")
  end
  if spec.procfs == "fresh" then
    if C.umount2("/proc", MNT_DETACH) ~= 0 and ffi.errno() ~= 22 then
      child_error(control_w, "unmount-proc")
    end
    if C.mount("proc", "/proc", "proc",
        bit.bor(MS.NOSUID, MS.NODEV, MS.NOEXEC), nil) ~= 0
        or not readonly("/proc", true) then
      child_error(control_w, "mount-proc")
    end
    for _, path in ipairs({
      "/proc/kcore",
      "/proc/keys",
      "/proc/latency_stats",
      "/proc/sysrq-trigger",
      "/proc/timer_list",
    }) do
      if vim.uv.fs_stat(path)
          and (C.mount("/dev/null", path, nil, MS.BIND, nil) ~= 0
            or not readonly(path, true)) then
        child_error(control_w, "mask-proc")
      end
    end
    for _, path in ipairs({ "/proc/acpi", "/proc/scsi" }) do
      if vim.uv.fs_stat(path)
          and C.mount("tmpfs", path, "tmpfs",
            bit.bor(MS.RDONLY, MS.NOSUID, MS.NODEV, MS.NOEXEC),
            "mode=0000") ~= 0 then
        child_error(control_w, "mask-proc")
      end
    end
  end
  drop_capabilities(control_w)

  local target_pid = C.fork()
  if target_pid < 0 then child_error(confirm_w, "fork-target") end
  if target_pid == 0 then
    C.close(listener_parent)
    C.close(status_w)
    if C.dup2(stdout_w, 1) < 0 or C.dup2(stderr_w, 2) < 0 then
      child_error(confirm_w, "stdio")
    end
    if C.dup2(stdin_copy, 0) < 0 then child_error(confirm_w, "stdin") end
    C.close(stdin_copy)
    C.close(stdout_w)
    C.close(stderr_w)
    if C.setsid() < 0 then child_error(confirm_w, "session") end
    if C.chdir(spec.cwd or "/") ~= 0 then child_error(confirm_w, "cwd") end
    if C.sigprocmask(SIG_UNBLOCK, blocked_signals, nil) ~= 0 then
      child_error(confirm_w, "signal-unblock")
    end

    local listener = install_seccomp(
      confirm_w, #spec.protected_create > 0)
    if listener then
      if not send_fd(listener_child, listener) then
        child_error(confirm_w, "seccomp-listener-transfer")
      end
      C.close(listener)
    end
    C.close(listener_child)

    if spec.mode == "probe" then
      local probe_fd = C.open("/dev/null", bit.bor(O.RDONLY, O.CLOEXEC))
      if probe_fd < 0 then
        child_error(confirm_w, "protected-create-probe")
      end
      C.close(probe_fd)
      C.close(confirm_w)
      finish(0)
    elseif spec.mode == "fs" then
      C.close(confirm_w)
      local request = spec.fs or {}
      if request.operation == "read" then
        local fd = C.open(request.path,
          bit.bor(O.RDONLY, O.CLOEXEC, O.NONBLOCK))
        if fd < 0 then
          write_all(2, string.format("open failed (errno=%d)\n", ffi.errno()))
          finish(66)
        end
        local stat = vim.uv.fs_fstat(fd)
        if not stat or stat.type ~= "file" then
          C.close(fd)
          write_all(2, "not a regular file\n")
          finish(66)
        end
        local buffer = ffi.new("char[65536]")
        while true do
          local count = C.read(fd, buffer, 65536)
          if count == 0 then break end
          if count < 0 then
            if ffi.errno() ~= E.EINTR then
              write_all(2,
                string.format("read failed (errno=%d)\n", ffi.errno()))
              finish(74)
            end
          elseif not write_all(1, ffi.string(buffer, count)) then
            write_all(2, "stdout write failed\n")
            finish(74)
          end
        end
        C.close(fd)
        finish(0)
      elseif request.operation == "mkdirp" then
        local current = ""
        for part in request.path:gmatch("[^/]+") do
          current = current .. "/" .. part
          if not mkdir(current, request.mode or 493) then finish(73) end
        end
        finish(0)
      elseif request.operation == "write_all" then
        local flags = bit.bor(O.WRONLY, O.CREAT, O.CLOEXEC,
          request.flags == "a" and O.APPEND or O.TRUNC)
        local fd = C.open(request.path, flags,
          ffi.cast("unsigned int", request.mode or 420))
        if fd < 0 then finish(73) end
        local buffer = ffi.new("char[65536]")
        while true do
          local count = C.read(0, buffer, 65536)
          if count == 0 then break end
          if count < 0 then
            if ffi.errno() ~= E.EINTR then finish(74) end
          elseif not write_all(fd, ffi.string(buffer, count)) then
            finish(74)
          end
        end
        C.close(fd)
        finish(0)
      end
      finish(64)
    end

    local argv = ffi.new("char *[?]", #command + 1)
    local argv_storage = {}
    for index, value in ipairs(command) do
      local storage = ffi.new("char[?]", #value + 1)
      ffi.copy(storage, value)
      argv_storage[index] = storage
      argv[index - 1] = storage
    end
    local names = {}
    for name in pairs(spec.env or {}) do names[#names + 1] = name end
    table.sort(names)
    local envp = ffi.new("char *[?]", #names + 1)
    local env_storage = {}
    for index, name in ipairs(names) do
      local value = name .. "=" .. tostring(spec.env[name])
      local storage = ffi.new("char[?]", #value + 1)
      ffi.copy(storage, value)
      env_storage[index] = storage
      envp[index - 1] = storage
    end
    close_descriptors(confirm_w, confirm_w)
    C.execve(argv[0], argv, envp)
    child_error(confirm_w, "exec")
  end

  C.close(listener_child)
  local listener = -1
  if #spec.protected_create > 0 then
    listener = receive_fd(listener_parent) or -1
    if listener < 0 then
      C.kill(target_pid, SIG.KILL)
      child_error(control_w, "seccomp-listener-transfer", 0)
    end
  end
  C.close(listener_parent)
  write_all(control_w, "ready\n")
  C.close(control_w)

  C.close(confirm_w)
  C.close(stdin_copy)
  C.close(stdout_w)
  C.close(stderr_w)
  local target_status = ffi.new("int[1]")
  local command_poll = ffi.new("struct pollfd[2]")
  local command_buffer = ffi.new("char[256]")
  command_poll[0].fd = command_r
  command_poll[0].events = bit.bor(POLLIN, POLLHUP)
  command_poll[1].fd = listener
  command_poll[1].events = listener >= 0 and bit.bor(POLLIN, POLLHUP) or 0
  while true do
    local waited = C.waitpid(target_pid, target_status, WNOHANG)
    if waited == target_pid then break end
    if waited < 0 and ffi.errno() ~= E.EINTR then finish(125) end
    local polled = C.poll(command_poll, listener >= 0 and 2 or 1, 50)
    if polled < 0 and ffi.errno() ~= E.EINTR then finish(125) end
    if polled > 0
        and bit.band(command_poll[0].revents, POLLIN) ~= 0 then
      local count = C.read(command_r, command_buffer, 255)
      if count > 0 then
        for value in ffi.string(command_buffer, count):gmatch("%d+") do
          C.kill(-target_pid, tonumber(value))
        end
      end
    end
    if listener >= 0 and polled > 0
        and bit.band(command_poll[1].revents, POLLIN) ~= 0
        and not handle_notification(listener) then
      C.kill(-target_pid, SIG.KILL)
      finish(125)
    end
  end
  C.close(command_r)
  if listener >= 0 then C.close(listener) end
  C.kill(-target_pid, SIG.TERM)
  C.kill(-1, SIG.KILL)
  local ignored = ffi.new("int[1]")
  while C.waitpid(-1, ignored, 0) >= 0 or ffi.errno() == E.EINTR do end
  local raw = tonumber(target_status[0])
  local signal = bit.band(raw, 0x7f)
  local code = signal == 0 and bit.band(bit.rshift(raw, 8), 0xff)
    or 128 + signal
  write_all(status_w, string.format("%d %d\n", code, signal))
  C.close(status_w)
  finish(0)
end

C.close(stdout_w)
C.close(stderr_w)
C.close(control_w)
C.close(command_r)
C.close(confirm_w)
C.close(status_w)
C.close(stdin_copy)
C.close(listener_parent)
C.close(listener_child)

local small = ffi.new("char[256]")
local control_count = C.read(control_r, small, 255)
if control_count <= 0 then terminal_error("namespace-init", 0) end
local control = ffi.string(small, control_count)
if not control:match("^ready") then
  local stage, errno = control:match("^error ([^ ]+) (%d+)")
  terminal_error(stage or "namespace-init", tonumber(errno) or 0)
end
C.close(control_r)
local confirm_count
repeat
  confirm_count = C.read(confirm_r, small, 255)
until confirm_count >= 0 or ffi.errno() ~= E.EINTR
if confirm_count > 0 then
  local confirmation = ffi.string(small, confirm_count)
  local stage, errno = confirmation:match("^error ([^ ]+) (%d+)")
  terminal_error(stage or "target-setup", tonumber(errno) or 0)
end
C.close(confirm_r)
frame({ v = 1, type = "ready" })

local descriptors = ffi.new("struct pollfd[4]")
descriptors[0].fd, descriptors[0].events = stdout_r, bit.bor(POLLIN, POLLHUP)
descriptors[1].fd, descriptors[1].events = stderr_r, bit.bor(POLLIN, POLLHUP)
descriptors[2].fd, descriptors[2].events =
  signal_fd, bit.bor(POLLIN, POLLHUP)
descriptors[3].fd, descriptors[3].events =
  status_r, bit.bor(POLLIN, POLLHUP)
local open_streams, sequence, target_result = 2, 0, nil
local buffer = ffi.new("char[65536]")
while open_streams > 0 or not target_result do
  local polled = C.poll(descriptors, 4, -1)
  if polled < 0 and ffi.errno() ~= E.EINTR then terminal_error("poll") end
  for index = 0, 1 do
    if descriptors[index].fd >= 0
        and bit.band(descriptors[index].revents, bit.bor(POLLIN, POLLHUP)) ~= 0 then
      local count = C.read(descriptors[index].fd, buffer, 65536)
      if count > 0 then
        sequence = sequence + 1
        frame({
          v = 1,
          type = "output",
          stream = index == 0 and "stdout" or "stderr",
          seq = sequence,
          data = ffi.string(buffer, count),
        })
      elseif count == 0 then
        C.close(descriptors[index].fd)
        descriptors[index].fd = -1
        open_streams = open_streams - 1
      elseif ffi.errno() ~= E.EINTR then
        terminal_error("read-output")
      end
    end
  end
  if bit.band(descriptors[2].revents, POLLIN) ~= 0 then
    local count = C.read(signal_fd, buffer, 128)
    if count >= 4 then
      local signal = tonumber(ffi.cast("unsigned int *", buffer)[0])
      write_all(command_w, tostring(signal) .. "\n")
    elseif count < 0 and ffi.errno() ~= E.EINTR then
      terminal_error("read-signal")
    end
  end
  if descriptors[3].fd >= 0
      and bit.band(descriptors[3].revents, bit.bor(POLLIN, POLLHUP)) ~= 0 then
    local count = C.read(status_r, buffer, 255)
    if count > 0 then
      target_result = ffi.string(buffer, count)
      C.close(status_r)
      descriptors[3].fd = -1
    elseif count == 0 then
      terminal_error("target-status", 0)
    elseif ffi.errno() ~= E.EINTR then
      terminal_error("target-status")
    end
  end
end
C.close(command_w)
C.close(signal_fd)

local init_status = ffi.new("int[1]")
while C.waitpid(init, init_status, 0) < 0 do
  if ffi.errno() ~= E.EINTR then terminal_error("wait-init") end
end
local code, signal = target_result:match("^(%d+) (%d+)")
if not code then terminal_error("target-status", 0) end
frame({ v = 1, type = "exit", code = tonumber(code), signal = tonumber(signal) })
finish(0)
