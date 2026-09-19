local async = require("neoagent.async")
local util = require("neoagent.util")
local process_tree = require(jit.os == "Windows" and "neoagent.process.windows" or "neoagent.process.posix")

local M = {}

---@class Neoagent.WorkerRequest
---@field argv string[]
---@field cwd string
---@field env table<string, string>
---@field clear_env? boolean
---@field kill_grace_ms? integer
---@field reap_grace_ms? integer
---@field on_stdout? fun(data: string)
---@field on_stderr? fun(data: string)
---@field on_exit? fun(result: Neoagent.WorkerResult)

---@class Neoagent.WorkerResult
---@field code integer
---@field signal integer
---@field stderr string
---@field error? Neoagent.Error

---@class Neoagent.WorkerLease
---@field wait_ready? async fun(self: Neoagent.WorkerLease): true
---@field write fun(self: Neoagent.WorkerLease, bytes: string): true?, Neoagent.Error?
---@field close_stdin fun(self: Neoagent.WorkerLease): true?, Neoagent.Error?
---@field terminate fun(self: Neoagent.WorkerLease, reason: string)
---@field wait async fun(self: Neoagent.WorkerLease): Neoagent.WorkerResult
---@field dispose fun(self: Neoagent.WorkerLease, reason: string)

---@class Neoagent.ProcessWorkerLease: Neoagent.WorkerLease
---@field _process vim.SystemObj
---@field _tree Neoagent.PosixProcessTree|Neoagent.WindowsProcessTree
---@field _result? Neoagent.WorkerResult
---@field _waiters Neoagent.AwaitCallbacks<Neoagent.WorkerResult>[]
---@field _stdin_closed boolean
---@field _terminating boolean
---@field _closed boolean
---@field _kill_timer? uv.uv_timer_t
---@field _dispose_timer? uv.uv_timer_t
---@field _kill_grace_ms integer
---@field _reap_grace_ms integer
---@field _kill_sent boolean
---@field _disposing boolean
---@field _stderr string
---@field _on_exit? fun(result: Neoagent.WorkerResult)
local Lease = {}
Lease.__index = Lease

local MAX_STDERR = 16 * 1024
local REAP_GRACE_MS = 2000
---@type table<Neoagent.ProcessWorkerLease, boolean>
local active_disposals = {}

local function close_kill_timer(self)
  local timer = self._kill_timer
  self._kill_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function close_dispose_timer(self)
  local timer = self._dispose_timer
  self._dispose_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@param self Neoagent.ProcessWorkerLease
local function kill(self)
  if self._kill_sent then
    return
  end
  self._kill_sent = true
  local killed = self._tree:terminate(9)
  if not killed then
    pcall(self._process.kill, self._process, 9)
  end
end

---@param self Neoagent.ProcessWorkerLease
---@param value Neoagent.WorkerResult
local function finish(self, value)
  assert(not self._result, "Worker lease completed more than once")
  close_kill_timer(self)
  close_dispose_timer(self)
  self._tree:close(not self._kill_sent)
  self._closed = true
  self._result = util.copy(value)
  active_disposals[self] = nil
  local waiters = self._waiters
  self._waiters = {}
  for _, done in ipairs(waiters) do
    done.resolve(util.copy(self._result))
  end
  if self._on_exit then
    pcall(self._on_exit, util.copy(self._result))
  end
end

-- Input operations enqueue bytes without yielding; success does not await
-- delivery to the child. Completion remains observable through the lease.
---@param bytes string
---@return true?, Neoagent.Error?
function Lease:write(bytes)
  assert(type(bytes) == "string" and bytes ~= "", "worker write requires bytes")
  if self._disposing or self._closed or self._result or self._stdin_closed then
    return nil, util.error("protocol", "Worker stdin is closed")
  end
  local ok, err = pcall(self._process.write, self._process, bytes)
  if not ok then
    return nil, util.error("protocol", "Could not write to worker", tostring(err))
  end
  return true
end

---@return true?, Neoagent.Error?
function Lease:close_stdin()
  if self._stdin_closed then
    return true
  end
  self._stdin_closed = true
  local ok, err = pcall(self._process.write, self._process, nil)
  if not ok then
    return nil, util.error("protocol", "Could not close worker stdin", tostring(err))
  end
  return true
end

---@param reason string
function Lease:terminate(reason)
  assert(type(reason) == "string", "worker termination reason is required")
  if self._closed or self._result or self._terminating then
    return
  end
  self._terminating = true
  self._stdin_closed = true
  pcall(self._process.write, self._process, nil)
  local signalled = self._tree:terminate(15)
  if not signalled then
    pcall(self._process.kill, self._process, 15)
  end
  self._kill_timer = assert(vim.uv.new_timer())
  self._kill_timer:start(self._kill_grace_ms, 0, function()
    close_kill_timer(self)
    kill(self)
  end)
end

---@async
---@return Neoagent.WorkerResult
function Lease:wait()
  if self._result then
    return util.copy(self._result)
  end
  return async.await(function(done)
    self._waiters[#self._waiters + 1] = done
    return function()
      for index, waiter in ipairs(self._waiters) do
        if waiter == done then
          table.remove(self._waiters, index)
          break
        end
      end
    end
  end)
end

---@param reason string
function Lease:dispose(reason)
  assert(type(reason) == "string" and reason ~= "", "worker disposal reason is required")
  if self._disposing or self._closed then
    return
  end
  self._disposing = true
  active_disposals[self] = true
  self:terminate(reason)
  self._dispose_timer = assert(vim.uv.new_timer())
  self._dispose_timer:start(self._kill_grace_ms + self._reap_grace_ms, 0, function()
    close_dispose_timer(self)
    kill(self)
    finish(self, {
      code = 137,
      signal = 9,
      stderr = self._stderr,
      error = util.error("worker_exit", "Worker could not be reaped after termination"),
    })
  end)
end

---@param env table<string, string>
---@return table<string, string>|string[]
local function spawn_environment(env)
  if vim.fn.has("nvim-0.12") == 0 then
    local names = vim.tbl_keys(env)
    table.sort(names)
    return vim.tbl_map(function(name)
      return name .. "=" .. env[name]
    end, names)
  end
  return env
end

---@param request Neoagent.WorkerRequest
---@return Neoagent.WorkerLease
function M.start(request)
  assert(type(request) == "table", "worker request must be an object")
  assert(type(request.argv) == "table" and util.is_list(request.argv) and #request.argv > 0, "worker argv is required")
  assert(type(request.cwd) == "string" and request.cwd ~= "", "worker cwd is required")
  assert(type(request.env) == "table" and not util.is_list(request.env), "worker environment must be an object")
  assert(
    request.kill_grace_ms == nil
      or type(request.kill_grace_ms) == "number" and request.kill_grace_ms >= 0 and request.kill_grace_ms % 1 == 0,
    "worker kill grace must be a non-negative integer"
  )
  assert(
    request.reap_grace_ms == nil
      or type(request.reap_grace_ms) == "number" and request.reap_grace_ms >= 0 and request.reap_grace_ms % 1 == 0,
    "worker reap grace must be a non-negative integer"
  )
  local tree, tree_err = process_tree.new()
  if not tree then
    error(util.error("worker_start", "Could not create worker process supervisor", tree_err), 0)
  end
  local stderr = ""
  ---@type Neoagent.ProcessWorkerLease?
  local lease
  ---@type vim.SystemCompleted?
  local early_completion
  local stream_failure
  ---@param completed vim.SystemCompleted
  local function complete(completed)
    if not lease then
      early_completion = completed
      return
    end
    if lease._result then
      return
    end
    finish(lease, {
      code = completed.signal ~= 0 and 128 + completed.signal or completed.code,
      signal = completed.signal,
      stderr = stderr,
    })
  end
  ---@param label string
  ---@param callback? fun(data: string)
  ---@param data string
  local function publish(label, callback, data)
    if not callback then
      return
    end
    local published, publish_err = pcall(callback, data)
    if not published then
      stream_failure = label .. " callback failed: " .. tostring(publish_err)
      if lease then
        lease:terminate("worker " .. label .. " callback failed")
      end
    end
  end
  local ok, process = pcall(vim.system, request.argv, {
    cwd = request.cwd,
    env = spawn_environment(request.env),
    clear_env = request.clear_env ~= false,
    stdin = true,
    text = false,
    detach = process_tree.detach,
    stdout = function(err, data)
      if err and lease then
        lease:terminate("worker stdout failed")
      elseif data then
        publish("stdout", request.on_stdout, data)
      end
    end,
    stderr = function(err, data)
      if err and lease then
        lease:terminate("worker stderr failed")
      elseif data then
        if #stderr < MAX_STDERR then
          stderr = (stderr .. data):sub(1, MAX_STDERR)
          if lease then
            lease._stderr = stderr
          end
        end
        publish("stderr", request.on_stderr, data)
      end
    end,
  }, complete)
  if not ok then
    tree:close(true)
    error(util.error("worker_start", "Could not start worker", tostring(process)), 0)
  end
  lease = setmetatable({
    _process = process,
    _tree = tree,
    _waiters = {},
    _stdin_closed = false,
    _terminating = false,
    _closed = false,
    _disposing = false,
    _kill_grace_ms = request.kill_grace_ms or 500,
    _reap_grace_ms = request.reap_grace_ms or REAP_GRACE_MS,
    _kill_sent = false,
    _stderr = stderr,
    _on_exit = request.on_exit,
  }, Lease)
  local attached, attach_err = tree:attach(process.pid)
  if not attached then
    pcall(process.kill, process, 9)
    tree:close(true)
    error(util.error("worker_start", "Could not supervise worker", attach_err), 0)
  end
  if stream_failure then
    lease:terminate(stream_failure)
  end
  if early_completion then
    complete(early_completion)
  end
  return lease
end

return M
