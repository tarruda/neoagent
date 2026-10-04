local environment = require("neoagent.subprocess.environment")
local validate = require("neoagent.subprocess.validate")
local streams = require("neoagent.subprocess.streams")

local M = {}

---@class Neoagent.SubprocessCallbacks
---@field output fun(stream: "stdout"|"stderr"|"pty", bytes: string)
---@field exited fun(code: integer, signal: integer)
---@field closed fun() Output and tracked handles drained; dispose finalizes retained native ownership.
---@field released fun() All native components have released their ownership after disposal.
---@field failed fun(code: string, message: string)
---@field input_failed? fun() Accepted input failed asynchronously.

---@class Neoagent.SubprocessDriver
-- The owner retains the driver before start() allocates native resources.
-- Termination must also settle partial startup, including an allocated pipe
-- or PTY whose process creation or PID lookup failed.
---@field start fun(): true
---@field observe fun(done: fun(running: boolean)) Non-waiting observation in the driver's native context.
---@field cleanup_ms integer Native cleanup observation interval.
---@field delivery_delay_ns? fun(now_ns: number): number Cumulative time native reads waited for editor delivery.
---@field write fun(bytes: string): true
---@field close_stdin fun(): true
---@field flush async fun(): true
---@field writable fun(): boolean
---@field resize fun(columns: integer, rows: integer): true
---@field interrupt fun(): boolean Interrupt input or request a native process interrupt.
---@field stop fun(): boolean Request the backend's graceful stop sequence.
---@field kill fun(): boolean Request forced termination of owned native resources.
---@field dispose fun()

---@class Neoagent.ProcessInputLimits
---@field bytes integer
---@field writes integer

-- Own the libuv streams directly. vim.system's write() does not expose write
-- completion, and supported Neovim versions close output on process exit.
-- Both callbacks are needed here: input is bounded and exit must drain output.
---@param spec Neoagent.SubprocessSpec
---@param env table<string, string>
---@param callbacks Neoagent.SubprocessCallbacks
---@param input_limits? Neoagent.ProcessInputLimits Private transport budget; RPC and local handles have different input windows.
---@return Neoagent.SubprocessDriver
function M.new(spec, env, callbacks, input_limits)
  local uv = vim.uv
  local posix_child = jit.os ~= "Windows" and require("neoagent.subprocess.posix_child") or nil
  local release = require("neoagent.subprocess.release").new(callbacks.released)
  local io = streams.new({
    output = callbacks.output,
    exited = callbacks.exited,
    closed = callbacks.closed,
    failed = callbacks.failed,
    input_failed = callbacks.input_failed,
    released = release.retain(),
  }, input_limits)
  local exited, disposed = false, false
  local release_process
  ---@type uv.uv_pipe_t?
  local stdin

  ---@type uv.uv_pipe_t
  local stdout, stderr
  ---@type uv.uv_process_t?
  local process
  ---@type Neoagent.PosixChild?
  local child
  ---@type Neoagent.WindowsProcessTree?
  local tree
  local function finalize_windows()
    if tree and disposed and (exited or not process) then
      tree:close(true)
      tree = nil
    end
    if disposed and not tree then
      release.close()
    end
  end
  local function dispose()
    disposed = true
    local cleaned, err = pcall(function()
      if tree then
        tree:terminate(9)
        finalize_windows()
      end
      if child then
        child.terminate(true)
        child.close()
      end
    end)
    io.dispose()
    if not tree then
      release.close()
    end
    if not cleaned then
      error(err, 0)
    end
  end

  local function launch()
    local env_list = environment.for_pipes(env)
    local function complete(code, signal)
      exited = true
      if release_process then
        assert(process):close(release_process)
        finalize_windows()
      else
        io.close(process)
      end
      callbacks.exited(code, signal)
      io.exited()
    end
    if jit.os == "Windows" then
      tree = require("neoagent.process.windows").new()
      if not tree then
        error(validate.error("process_supervision", "Failed to create process supervisor"), 0)
      end
    elseif posix_child then
      child = posix_child.new({
        exited = complete,
        output = callbacks.output,
        closed = callbacks.closed,
        released = release.retain(),
        failed = callbacks.failed,
      })
    end
    stdout, stderr = io.pipe(), io.pipe()
    if spec.stdio.stdin == "open" then
      stdin = io.pipe()
      io.input(stdin)
    end
    local argv = spec.argv
    local verbatim = false
    if jit.os == "Windows" then
      local prepared = require("neoagent.process.windows_command").prepare_cmd(argv)
      if prepared then
        argv = prepared
        verbatim = true
      end
    end
    local _, spawn_code
    process, _, spawn_code = uv.spawn(assert(argv[1]), {
      args = vim.list_slice(argv, 2),
      cwd = spec.cwd,
      env = env_list,
      stdio = { stdin, stdout, stderr },
      detached = jit.os ~= "Windows",
      hide = true,
      verbatim = verbatim,
    }, complete)
    if not process then
      local code = type(spawn_code) == "string" and spawn_code:match("^E[A-Z0-9]+$") or "UNKNOWN"
      error(validate.error("process_start", "Failed to start process (" .. code .. ")"), 0)
    end
    if jit.os == "Windows" then
      -- Keep uv's process handle and the Job until native exit, even when
      -- the owner's bounded cleanup observation has already failed.
      release_process = release.retain()
    else
      io.own(process)
    end
    local pid = process:get_pid()
    if child then
      child.attach(pid)
      -- This documented libuv ownership transfer must happen before yielding:
      -- libuv must never reap a PID that our group owner can still signal.
      io.close(process)
    elseif tree and not tree:attach(pid) then
      error(validate.error("process_supervision", "Failed to supervise process tree"), 0)
    end
    io.read(stdout, "stdout")
    io.read(stderr, "stderr")
    if child then
      child.poll()
    end
    return true
  end

  local function running()
    if child then
      return child.poll()
    end
    if exited then
      return false
    end
    -- Windows signal zero queries the retained native handle with
    -- WaitForSingleObject, independently of delayed exit notification.
    local alive, _, code = assert(process):kill(0)
    if alive ~= nil then
      return true
    elseif code == "ESRCH" then
      return false
    end
    error(validate.error("process_supervision", "Could not observe native process state"), 0)
  end

  local function terminate(force)
    if not process then
      -- Failed allocation or spawn still owns any pipes already created.
      exited = true
      dispose()
      io.exited()
      return true
    end
    local signal = force and 9 or 15
    if child then
      return child.terminate(force)
    end
    if tree and tree:terminate(signal) then
      return true
    end
    if not exited and not process:is_closing() then
      local sent, result = pcall(process.kill, process, signal)
      return sent and result ~= nil
    end
    return false
  end

  return {
    start = function()
      local ok, failure = pcall(launch)
      if not ok then
        -- Failed admission may precede read_start. Those pipes cannot report
        -- EOF, but the retained process must still deliver its native exit.
        io.close(stdout)
        io.close(stderr)
        error(failure, 0)
      end
      return true
    end,
    observe = function(done)
      done(running())
    end,
    cleanup_ms = validate.REAP_MS,
    delivery_delay_ns = io.delivery_delay_ns,
    write = io.write,
    close_stdin = io.close_stdin,
    flush = io.flush,
    writable = io.writable,
    resize = function()
      error(validate.error("unsupported_control", "Pipe processes cannot be resized"), 0)
    end,
    interrupt = function()
      if child then
        return child.interrupt()
      end
      -- Windows redirected processes have no portable console interrupt.
      -- Match the explicit stop behavior of their native Job owner.
      return terminate(true)
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
