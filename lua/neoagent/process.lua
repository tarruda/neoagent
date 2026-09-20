local async = require("neoagent.async")
local util = require("neoagent.util")
local launch = require("neoagent.process.launch")
local process_tree = require(jit.os == "Windows" and "neoagent.process.windows" or "neoagent.process.posix")

---@class Neoagent.ProcessOptions
---@field cwd? string
---@field env? table<string, string|number>|string[]
---@field clear_env? boolean
---@field stdin? string|string[]|true
---@field capture? boolean
---@field max_capture_bytes? integer
---@field timeout_ms? integer
---@field kill_grace_ms? integer
---@field on_output? fun(data: string, is_stderr: boolean, stdout: string, stderr: string, output: string)

---@class Neoagent.ProcessResult
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string
---@field output string
---@field timed_out boolean

local M = {}

---@class Neoagent.ProcessScope
---@field _pending table<fun(), boolean>
---@field _waiters table<Neoagent.AwaitCallbacks<true>, fun()>
---@field _closed boolean
local Scope = {}
Scope.__index = Scope

---@async
---@param command string[]
---@param opts? Neoagent.ProcessOptions
---@return Neoagent.ProcessResult
---@param scope? Neoagent.ProcessScope
local function run(command, opts, scope)
  opts = opts or {}
  if opts.max_capture_bytes ~= nil then
    assert(
      type(opts.max_capture_bytes) == "number" and opts.max_capture_bytes > 0 and opts.max_capture_bytes % 1 == 0,
      "max_capture_bytes must be a positive integer"
    )
  end
  local stdout, stderr, output = "", "", ""
  local capture = opts.capture ~= false
  local captured_bytes = 0
  local timed_out = false
  local result = async.await( ---@param done Neoagent.AwaitCallbacks<Neoagent.ProcessResult>
    function(done)
      ---@type vim.SystemObj|Neoagent.ProcessChild|nil
      local process
      ---@type Neoagent.PosixProcessTree|Neoagent.WindowsProcessTree|nil
      local tree
      ---@type uv.uv_timer_t?
      local timer
      ---@type uv.uv_timer_t?
      local kill_timer
      local timer_closed = false
      local kill_timer_closed = false
      local accepting_output = true
      local termination_requested = false
      local function close_timer()
        if timer and not timer_closed then
          timer_closed = true
          timer:stop()
          timer:close()
        end
      end
      local function close_kill_timer()
        if kill_timer and not kill_timer_closed then
          kill_timer_closed = true
          kill_timer:stop()
          kill_timer:close()
        end
      end
      ---@param value integer
      local function signal(value)
        local signalled = tree and tree:terminate(value)
        if not signalled and process then
          local child = process
          pcall(function()
            child:kill(value)
          end)
        end
      end
      local function terminate()
        termination_requested = true
        if not process then
          return
        end
        signal(15)
        if opts.kill_grace_ms == 0 then
          signal(9)
          return
        end
        if not kill_timer then
          kill_timer = assert(vim.uv.new_timer())
          kill_timer:start(opts.kill_grace_ms or 1000, 0, function()
            close_kill_timer()
            signal(9)
          end)
        end
      end
      local function dispose()
        accepting_output = false
        close_timer()
        close_kill_timer()
        -- A spawn callback can close the scope before its child is returned.
        -- Keep the unattached supervisor so that child still joins its tree.
        if process then
          signal(9)
          if tree then
            tree:close(false)
          end
        end
      end
      local function release()
        if scope then
          scope._pending[dispose] = nil
          if next(scope._pending) == nil then
            local waiters = scope._waiters
            scope._waiters = {}
            for done, cleanup in pairs(waiters) do
              cleanup()
              done.resolve(true)
            end
          end
        end
      end
      if scope then
        scope._pending[dispose] = true
      end
      ---@param data string
      ---@param is_stderr boolean
      ---@return true?
      local function retain(data, is_stderr)
        if not capture then
          return true
        end
        local next_bytes = captured_bytes + #data
        if opts.max_capture_bytes and next_bytes > opts.max_capture_bytes then
          accepting_output = false
          local err = util.error("tool", "Process output exceeded " .. opts.max_capture_bytes .. " bytes")
          rawset(err, "code", "output_limit")
          done.reject(err)
          terminate()
          return nil
        end
        captured_bytes = next_bytes
        if is_stderr then
          stderr = stderr .. data
        else
          stdout = stdout .. data
        end
        output = output .. data
        return true
      end
      local tree_err
      tree, tree_err = process_tree.new()
      if not tree then
        release()
        done.reject(util.error("tool", "Failed to create process supervisor", tree_err))
        return
      end
      local started, started_process = pcall(launch.start, command, {
        cwd = opts.cwd,
        env = opts.env,
        clear_env = opts.clear_env,
        stdin = opts.stdin,
        stdout = function(err, data)
          if err then
            accepting_output = false
            done.reject(util.error("tool", "Failed reading process stdout", err))
            terminate()
          elseif data and accepting_output then
            if not retain(data, false) then
              return
            end
            if opts.on_output then
              opts.on_output(data, false, stdout, stderr, output)
            end
          end
        end,
        stderr = function(err, data)
          if err then
            accepting_output = false
            done.reject(util.error("tool", "Failed reading process stderr", err))
            terminate()
          elseif data and accepting_output then
            if not retain(data, true) then
              return
            end
            if opts.on_output then
              opts.on_output(data, true, stdout, stderr, output)
            end
          end
        end,
      }, function(completed)
        release()
        close_timer()
        close_kill_timer()
        if tree then
          tree:close(true)
        end
        done.resolve({
          code = completed.signal ~= 0 and 128 + completed.signal or completed.code,
          signal = completed.signal,
          stdout = stdout,
          stderr = stderr,
          output = output,
          timed_out = timed_out,
        })
      end)
      if not started then
        tree:close(true)
        release()
        done.reject(util.error("tool", "Failed to start process", started_process))
        return
      end
      local child = assert(started_process)
      ---@cast child vim.SystemObj|Neoagent.ProcessChild
      process = child
      local attached, attach_err = tree:attach(child.pid)
      if not attached then
        pcall(function()
          child:kill(9)
        end)
        tree:close(true)
        done.reject(util.error("tool", "Failed to supervise process tree", attach_err))
        return
      end
      if scope and scope._closed then
        dispose()
      elseif termination_requested then
        terminate()
      end
      if opts.timeout_ms then
        timer = assert(vim.uv.new_timer())
        timer:start(opts.timeout_ms, 0, function()
          timed_out = true
          terminate()
        end)
      end
      return function()
        accepting_output = false
        close_timer()
        terminate()
      end
    end
  )
  return result
end

---@async
---@param command string[]
---@param opts? Neoagent.ProcessOptions
---@return Neoagent.ProcessResult
function M.run(command, opts)
  return run(command, opts)
end

---@async
---@param command string[]
---@param opts? Neoagent.ProcessOptions
---@return Neoagent.ProcessResult
function Scope:run(command, opts)
  assert(not self._closed, "Process scope is closed")
  return run(command, opts, self)
end

-- Closing signals pending commands; wait observes their exits. POSIX signals
-- reach only their process groups. Descendants that leave those groups require
-- containment by an external guardian owned by the execution environment.
function Scope:close()
  if self._closed then
    return
  end
  self._closed = true
  for dispose in pairs(self._pending) do
    dispose()
  end
end

---@return boolean
function Scope:is_settled()
  return next(self._pending) == nil
end

---@async
---@param timeout_ms integer
---@return true
function Scope:wait(timeout_ms)
  assert(
    type(timeout_ms) == "number" and timeout_ms > 0 and timeout_ms % 1 == 0,
    "Process scope wait requires a positive timeout"
  )
  if self:is_settled() then
    return true
  end
  return async.await(function(done)
    local timer = assert(vim.uv.new_timer())
    local function cleanup()
      self._waiters[done] = nil
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    self._waiters[done] = cleanup
    timer:start(timeout_ms, 0, function()
      cleanup()
      done.reject(util.error("process_cleanup", "Process scope cleanup timed out"))
    end)
    return cleanup
  end)
end

---@return Neoagent.ProcessScope
function M.scope()
  return setmetatable({ _pending = {}, _waiters = {}, _closed = false }, Scope)
end

return M
