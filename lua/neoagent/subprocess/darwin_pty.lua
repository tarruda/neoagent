local ffi = require("ffi")
local validate = require("neoagent.subprocess.validate")
local environment = require("neoagent.subprocess.environment")
local executable = require("neoagent.subprocess.posix_executable")
local streams = require("neoagent.subprocess.streams")
local children = require("neoagent.subprocess.posix_child")
local M = {}

-- Darwin's public libc ABI; no Neovim or LuaJIT private structure access.
ffi.cdef([[
typedef struct { unsigned short rows, columns, xpixel, ypixel; } NeoagentDarwinPtySize;
int openpty(int *, int *, char *, const void *, const NeoagentDarwinPtySize *);
int close(int);
int fcntl(int, int, ...);
int ioctl(int, unsigned long, ...);
]])

---@class Neoagent.DarwinPtyLibc
---@field openpty fun(master: ffi.cdata*, slave: ffi.cdata*, name: nil, termios: nil, size: ffi.cdata*): integer
---@field close fun(fd: integer): integer
---@field fcntl fun(fd: integer, command: integer, value: ffi.cdata*): integer
---@field ioctl fun(fd: integer, request: integer, value: ffi.cdata*): integer
local C = ffi.C --[[@as Neoagent.DarwinPtyLibc]]

---@class Neoagent.DarwinPtyInts: ffi.cdata*
---@field [integer] integer
---@class Neoagent.DarwinPtyPointers: ffi.cdata*
---@field [integer] string|nil

---@param values string[]
---@return ffi.cdata*
local function strings(values)
  local vector = ffi.new("const char *[?]", #values + 1) --[[@as Neoagent.DarwinPtyPointers]]
  for index, value in ipairs(values) do
    vector[index - 1] = value
  end
  return vector
end

---@param operation string
---@param code integer
local function check(operation, code)
  if code ~= 0 then
    error(validate.error("process_start", "Process " .. operation .. " failed (errno " .. code .. ")"), 0)
  end
end

---@param spec Neoagent.SubprocessSpec
---@param env table<string, string>
---@param callbacks Neoagent.SubprocessCallbacks
---@return Neoagent.SubprocessDriver
function M.new(spec, env, callbacks)
  local io = streams.new(callbacks)
  ---@type Neoagent.PosixChild?
  local child
  ---@type uv.uv_pipe_t?
  local output
  ---@type table<integer, boolean>
  local descriptors = {}
  local started, disposed = false, false
  ---@type {argv: ffi.cdata*, env: ffi.cdata*, strings: string[][]}?
  local arguments
  ---@type integer?
  local master
  local function release_descriptors()
    for fd in pairs(descriptors) do
      C.close(fd)
      descriptors[fd] = nil
    end
    arguments = nil
  end
  local function dispose()
    disposed = true
    release_descriptors()
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
    local size = ffi.new("NeoagentDarwinPtySize[1]", { { rows, columns, 0, 0 } })
    if not output or output:is_closing() or C.ioctl(assert(master), 0x80087467, size) ~= 0 then
      error(validate.error("process_terminal", "Could not resize process terminal"), 0)
    end
    return true
  end
  local function start()
    local paths = executable.candidates(assert(spec.argv[1]), env.PATH)
    local entries = environment.list(env)
    -- The child inherits this root with its address space. Parent cleanup
    -- cannot release the child's backing strings before it executes.
    arguments = { argv = strings(spec.argv), env = strings(entries), strings = { spec.argv, entries } }
    child = children.new({
      exited = function(code, signal)
        callbacks.exited(code, signal)
        io.exited()
      end,
      output = callbacks.output,
      closed = callbacks.closed,
      failed = callbacks.failed,
    })
    local master_fd = ffi.new("int[1]") --[[@as Neoagent.DarwinPtyInts]]
    local slave_fd = ffi.new("int[1]") --[[@as Neoagent.DarwinPtyInts]]
    local size = ffi.new("NeoagentDarwinPtySize[1]", { { spec.stdio.rows, spec.stdio.columns, 0, 0 } })
    check("terminal allocation", C.openpty(master_fd, slave_fd, nil, nil, size) == 0 and 0 or ffi.errno())
    local fd, slave = master_fd[0], slave_fd[0]
    descriptors[fd], descriptors[slave] = true, true
    local cloexec = ffi.new("int", 1)
    check("terminal descriptor", C.fcntl(fd, 2, cloexec) == 0 and 0 or ffi.errno())
    check("terminal descriptor", C.fcntl(slave, 2, cloexec) == 0 and 0 or ffi.errno())
    local duplicate = C.fcntl(fd, 67, ffi.new("int", 3)) -- F_DUPFD_CLOEXEC
    if duplicate < 0 then
      check("terminal descriptor", ffi.errno())
    end
    descriptors[duplicate] = true
    output = io.pipe()
    assert(output:open(fd))
    descriptors[fd] = nil
    master = fd
    local input = io.pipe()
    assert(input:open(duplicate))
    descriptors[duplicate] = nil
    io.input(input)

    -- The CLOEXEC writer disappears only after exec or child failure. A
    -- four-byte errno distinguishes native setup/exec failure from target
    -- exit 127. The parent reads asynchronously with a bounded startup wait.
    local channel = assert(vim.uv.pipe({ nonblock = true }, { nonblock = false }))
    descriptors[channel.read], descriptors[channel.write] = true, true
    local acknowledgement = io.pipe()
    assert(acknowledgement:open(channel.read))
    descriptors[channel.read] = nil
    local complete, bytes, read_error = false, "", false
    assert(acknowledgement:read_start(function(err, data)
      if err or data == nil then
        read_error = err ~= nil
        complete = true
        io.close(acknowledgement)
      else
        bytes = bytes .. data
        if #bytes >= 4 then
          complete = true
          io.close(acknowledgement)
        end
      end
    end))
    local restored = require("neoagent.subprocess.fork_exec").launch(
      slave,
      channel.write,
      paths,
      spec.cwd,
      arguments.argv,
      arguments.env,
      child.attach
    )
    started = true
    release_descriptors()
    check("signal mask restoration", restored)
    io.read(output, "pty")
    local ready = vim.wait(validate.START_MS, function()
      return complete or disposed
    end, 5)
    if not ready or disposed or read_error or #bytes ~= 0 and #bytes ~= 4 then
      error(validate.error("process_start", "Process execution acknowledgement failed or expired"), 0)
    end
    if #bytes == 4 then
      local code = ffi.new("int[1]") --[[@as Neoagent.DarwinPtyInts]]
      ffi.copy(code, bytes, 4)
      check("execution", code[0])
    end
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
