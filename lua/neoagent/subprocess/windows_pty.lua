local ffi = require("ffi")
local validate = require("neoagent.subprocess.validate")
local streams = require("neoagent.subprocess.streams")
local trees = require("neoagent.process.windows")
local strings = require("neoagent.subprocess.windows_text")
local M = {}

ffi.cdef([[
typedef struct { short X, Y; } NeoagentConsoleSize;
typedef struct {
  unsigned long cb;
  unsigned short *reserved, *desktop, *title;
  unsigned long x, y, xsize, ysize, xchars, ychars, fill, flags;
  unsigned short show, reserved_bytes;
  unsigned char *reserved_data;
  void *input, *output, *error;
} NeoagentConsoleStartup;
typedef struct { NeoagentConsoleStartup startup; void *attributes; } NeoagentConsoleStartupEx;
typedef struct { void *process, *thread; unsigned long pid, tid; } NeoagentConsoleProcess;
long __stdcall CreatePseudoConsole(NeoagentConsoleSize, void *, void *, unsigned long, void **);
void __stdcall ClosePseudoConsole(void *);
int __stdcall InitializeProcThreadAttributeList(void *, unsigned long, unsigned long, size_t *);
int __stdcall UpdateProcThreadAttribute(void *, unsigned long, uintptr_t, void *, size_t, void *, size_t *);
void __stdcall DeleteProcThreadAttributeList(void *);
int __stdcall CreateProcessW(const unsigned short *, unsigned short *, void *, void *, int, unsigned long,
                            void *, const unsigned short *, NeoagentConsoleStartupEx *, NeoagentConsoleProcess *);
int __stdcall GetExitCodeProcess(void *, unsigned long *);
int __stdcall CloseHandle(void *);
unsigned long __stdcall GetLastError(void);
int __stdcall CompareStringOrdinal(const unsigned short *, int, const unsigned short *, int, int);
]])

---@class Neoagent.ConsoleKernel
---@field CreatePseudoConsole fun(size: ffi.cdata*, input: ffi.cdata*, output: ffi.cdata*, flags: integer, result: ffi.cdata*): integer
---@field InitializeProcThreadAttributeList fun(list: ffi.cdata*?, count: integer, flags: integer, size: ffi.cdata*): integer
---@field UpdateProcThreadAttribute fun(list: ffi.cdata*, flags: integer, key: integer, value: ffi.cdata*, size: integer, previous: nil, returned: nil): integer
---@field DeleteProcThreadAttributeList fun(list: ffi.cdata*)
---@field CreateProcessW fun(program: ffi.cdata*, command: ffi.cdata*, process_security: nil, thread_security: nil, inherit: integer, flags: integer, env: ffi.cdata*, cwd: ffi.cdata*, startup: Neoagent.ConsoleStartup, result: Neoagent.ConsoleProcess): integer
---@field GetExitCodeProcess fun(process: Neoagent.WindowsProcessHandle, result: ffi.cdata*): integer
---@field CloseHandle fun(handle: ffi.cdata*): integer
---@field GetLastError fun(): integer
---@field CompareStringOrdinal fun(left: ffi.cdata*, left_size: integer, right: ffi.cdata*, right_size: integer, ignore_case: integer): integer
local kernel = ffi.load("kernel32") --[[@as Neoagent.ConsoleKernel]]

---@class Neoagent.ConsolePointers: ffi.cdata*
---@field [integer] ffi.cdata*
---@class Neoagent.ConsoleNumbers: ffi.cdata*
---@field [integer] integer
---@class Neoagent.ConsoleStartup: ffi.cdata*
---@field startup { cb: integer, flags: integer }
---@field attributes ffi.cdata*
---@class Neoagent.ConsoleProcess: ffi.cdata*
---@field process ffi.cdata*
---@field thread ffi.cdata*

---@param operation string
---@param ok boolean
---@param code? integer
local function check(operation, ok, code)
  if not ok then
    error(
      validate.error(
        "process_start",
        "Process " .. operation .. " failed (Win32 " .. (code or kernel.GetLastError()) .. ")"
      ),
      0
    )
  end
end

---@param text string
---@return ffi.cdata*
local function wide(text)
  local value = strings.wide(text)
  if not value then
    error(validate.error("process_start", "Process text conversion failed (invalid WTF-8)"), 0)
  end
  return value
end

---@param spec Neoagent.SubprocessSpec
---@param env table<string, string>
---@param callbacks Neoagent.SubprocessCallbacks
---@return Neoagent.SubprocessDriver
function M.new(spec, env, callbacks)
  if not pcall(function()
    return kernel.CreatePseudoConsole
  end) then
    error(validate.error("pty_unavailable", "Native PTYs require Windows ConPTY support"), 0)
  end
  local console_pointer = ffi.new("void *[1]") --[[@as Neoagent.ConsolePointers]]
  ---@type ffi.cdata*?
  local console
  ---@type Neoagent.WindowsProcessTree?
  local tree
  ---@type uv.uv_timer_t?
  local monitor
  ---@type uv.luv_work_ctx_t?
  local console_work
  ---@type string?
  local console_bytes
  local exited, disposed, drained, notified = false, false, false, false
  ---@type "resize"|"close"|nil
  local operation
  ---@type {columns: integer, rows: integer}?
  local pending_size
  local close_requested = false
  local release = require("neoagent.subprocess.release").new(callbacks.released)
  ---@type fun()?
  local release_console, release_monitor
  ---@type {storage: ffi.cdata*, job?: Neoagent.ConsolePointers}?
  local attributes
  ---@type table<integer, boolean>
  local descriptors = {}
  ---@type fun()
  local settled
  local io = streams.new({
    output = callbacks.output,
    exited = callbacks.exited,
    failed = callbacks.failed,
    input_failed = callbacks.input_failed,
    released = release.retain(),
    closed = function()
      drained = true
      settled()
    end,
  })
  settled = function()
    if disposed and tree and (exited or not tree.attached) then
      tree:close(true)
      tree = nil
    end
    if console == nil and exited then
      -- luv roots the completion callback until the work context is collected.
      -- Break its reference back to this owner once no console needs it.
      console_work = nil
      if drained and not notified then
        notified = true
        if monitor and not monitor:is_closing() then
          monitor:stop()
          monitor:close(release_monitor)
        end
        vim.schedule(callbacks.closed)
      end
    end
    if disposed and not tree and console == nil then
      release.close()
    end
  end
  local function service_console()
    if console == nil or operation then
      return true
    end
    local next_operation = close_requested and "close" or pending_size and "resize"
    if not next_operation then
      return true
    end
    local size = pending_size
    pending_size = nil
    local ok, queued = pcall(function()
      console_bytes = console_bytes or ffi.string(console_pointer, ffi.sizeof(console_pointer))
      return assert(console_work):queue(
        assert(console_bytes),
        next_operation,
        size and size.columns or 0,
        size and size.rows or 0
      )
    end)
    if ok and queued then
      operation = next_operation
      return true
    end
    callbacks.failed(
      next_operation == "close" and "process_cleanup" or "process_terminal",
      "Could not schedule terminal " .. next_operation
    )
    return false
  end
  local function close_console()
    close_requested = true
    pending_size = nil
    service_console()
    settled()
  end
  local function release_setup()
    if attributes then
      kernel.DeleteProcThreadAttributeList(attributes.storage)
      attributes = nil
    end
    for fd in pairs(descriptors) do
      vim.uv.fs_close(fd)
      descriptors[fd] = nil
    end
  end
  local function dispose()
    disposed = true
    release_setup()
    if tree and tree.attached then
      tree:terminate(9)
    else
      exited = true
    end
    io.exited()
    io.dispose()
    close_console()
  end
  local function running()
    if exited then
      return false
    end
    local active = assert(tree):running()
    if active == nil then
      error(validate.error("process_supervision", "Could not observe native PTY process state"), 0)
    end
    if not active then
      local code = ffi.new("unsigned long[1]") --[[@as Neoagent.ConsoleNumbers]]
      if kernel.GetExitCodeProcess(assert(tree).process, code) == 0 then
        error(validate.error("process_supervision", "Could not read native PTY exit status"), 0)
      end
      exited = true
      callbacks.exited(code[0], 0)
      io.exited()
      close_console()
    end
    return active
  end
  local function start()
    monitor = assert(vim.uv.new_timer())
    release_monitor = release.retain()
    ---@param bytes string
    ---@param action "resize"|"close"
    ---@param columns integer
    ---@param rows integer
    ---@return boolean
    local function control_console(bytes, action, columns, rows)
      assert(type(bytes) == "string")
      local native = require("ffi")
      -- A worker Lua state can serve many console operations and owners.
      if not pcall(native.typeof, "NeoagentConsoleWorkSize") then
        native.cdef("typedef struct { short X, Y; } NeoagentConsoleWorkSize;")
      end
      native.cdef([[
void __stdcall ClosePseudoConsole(void *);
long __stdcall ResizePseudoConsole(void *, NeoagentConsoleWorkSize);
]])
      local pointer = native.new("void *[1]") --[[@as Neoagent.ConsolePointers]]
      native.copy(pointer, bytes, #bytes)
      local api = native.load("kernel32") --[[@as { ClosePseudoConsole: fun(handle: ffi.cdata*), ResizePseudoConsole: fun(handle: ffi.cdata*, size: ffi.cdata*): integer }]]
      if action == "resize" then
        return api.ResizePseudoConsole(pointer[0], native.new("NeoagentConsoleWorkSize", { columns, rows })) >= 0
      end
      api.ClosePseudoConsole(pointer[0])
      return true
    end
    console_work = vim.uv.new_work(control_console, function(success)
      local finished = operation
      operation = nil
      if finished == "close" then
        if success then
          console = nil
          console_bytes = nil
          assert(release_console)()
        else
          callbacks.failed("process_cleanup", "Could not release native terminal")
        end
      elseif not success then
        pending_size = nil
        if not close_requested then
          callbacks.failed("process_terminal", "Could not resize process terminal")
        end
      end
      -- Close has priority over the latest queued size and can never race a
      -- resize using the same HPCON. Failed close retries on the monitor.
      if success or finished == "resize" then
        service_console()
      end
      settled()
    end)
    -- This timer also retains failed/unfinished console cleanup after the
    -- caller's bounded observation ends. No blocking native wait runs here.
    assert(monitor:start(20, 20, function()
      if tree and tree.attached then
        local ok = pcall(running)
        if not ok then
          callbacks.failed("process_supervision", "Could not observe native PTY process state")
        end
      end
      if close_requested then
        close_console()
      end
      settled()
    end))
    tree = assert(trees.new())
    local application = require("neoagent.subprocess.windows_executable").resolve(spec, env)
    local function pair(readable)
      -- ConPTY requires synchronous borrowed ends; libuv drives OVERLAPPED
      -- host ends. uv.pipe/open/fileno keep CRT descriptor ownership in luv.
      local fds = assert(vim.uv.pipe({ nonblock = readable }, { nonblock = not readable }))
      descriptors[fds.read], descriptors[fds.write] = true, true
      local reader, writer = io.pipe(), io.pipe()
      assert(reader:open(fds.read))
      descriptors[fds.read] = nil
      assert(writer:open(fds.write))
      descriptors[fds.write] = nil
      return reader, writer
    end
    local input_read, input_write = pair(false)
    local output_read, output_write = pair(true)
    io.input(input_write)
    local size = ffi.new("NeoagentConsoleSize", { spec.stdio.columns, spec.stdio.rows })
    local status = kernel.CreatePseudoConsole(
      size,
      ffi.cast("void *", assert(input_read:fileno())),
      ffi.cast("void *", assert(output_write:fileno())),
      0,
      console_pointer
    )
    check("terminal allocation", status >= 0, status)
    console = console_pointer[0]
    release_console = release.retain()
    local length = ffi.new("size_t[1]") --[[@as Neoagent.ConsoleNumbers]]
    kernel.InitializeProcThreadAttributeList(nil, 2, 0, length)
    check("startup attributes", length[0] > 0)
    local storage = ffi.new("uint8_t[?]", length[0])
    check("startup attributes", kernel.InitializeProcThreadAttributeList(storage, 2, 0, length) ~= 0)
    attributes = { storage = storage }
    local pointer_size = assert(ffi.sizeof("void *"))
    check(
      "terminal binding",
      kernel.UpdateProcThreadAttribute(storage, 0, 0x20016, console, pointer_size, nil, nil) ~= 0
    )
    local job = ffi.new("void *[1]") --[[@as Neoagent.ConsolePointers]]
    -- UpdateProcThreadAttribute borrows this array until list destruction.
    attributes.job = job
    job[0] = ffi.cast("void *", tree.job)
    check("job binding", kernel.UpdateProcThreadAttribute(storage, 0, 0x2000d, job, pointer_size, nil, nil) ~= 0)
    local startup = ffi.new("NeoagentConsoleStartupEx") --[[@as Neoagent.ConsoleStartup]]
    startup.startup.cb = ffi.sizeof(startup)
    -- Clear inherited redirected stdio so Windows binds all three handles to
    -- this pseudoconsole. ConPTY alone only replaces inherited console handles.
    startup.startup.flags = 0x100 -- STARTF_USESTDHANDLES, with null handles.
    startup.attributes = storage
    local info = ffi.new("NeoagentConsoleProcess") --[[@as Neoagent.ConsoleProcess]]
    local names = vim.tbl_keys(env)
    table.sort(names, function(left, right)
      return kernel.CompareStringOrdinal(wide(left), -1, wide(right), -1, 1) == 1
    end)
    local entries = {}
    for index, name in ipairs(names) do
      entries[index] = name .. "=" .. env[name]
    end
    local created = kernel.CreateProcessW(
      wide(application),
      wide(require("neoagent.process.windows_command").line(spec.argv)),
      nil,
      nil,
      0,
      0x80000 + 0x400,
      wide(table.concat(entries, "\0") .. "\0\0"),
      wide(spec.cwd),
      startup,
      info
    )
    local failure = kernel.GetLastError()
    if created ~= 0 then
      tree:adopt(info.process)
      kernel.CloseHandle(info.thread)
    end
    release_setup()
    check("execution", created ~= 0, failure)
    io.close(input_read)
    io.close(output_write)
    io.read(output_read, "pty")
    running()
    return true
  end
  local function terminate(force)
    if not tree or not tree.attached then
      dispose()
      return true
    end
    return tree:terminate(force and 9 or 15)
  end
  return {
    start = start,
    observe = function(done)
      done(running())
    end,
    cleanup_ms = validate.REAP_MS,
    delivery_delay_ns = io.delivery_delay_ns,
    write = io.write,
    flush = io.flush,
    writable = io.writable,
    close_stdin = function()
      error(validate.error("unsupported_control", "PTY stdin cannot be closed portably"), 0)
    end,
    resize = function(columns, rows)
      if console == nil or close_requested then
        error(validate.error("process_terminal", "Could not resize process terminal"), 0)
      end
      -- ResizePseudoConsole synchronously writes a control pipe. Keep it off
      -- the editor thread and retain at most one newer requested size.
      pending_size = { columns = columns, rows = rows }
      if not service_console() then
        error(validate.error("process_terminal", "Could not resize process terminal"), 0)
      end
      return true
    end,
    interrupt = function()
      return io.write("\3")
    end,
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
