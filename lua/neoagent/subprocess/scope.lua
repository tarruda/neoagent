local async = require("neoagent.async")
local util = require("neoagent.util")
local validate = require("neoagent.subprocess.validate")
local handles = require("neoagent.subprocess.handle")
local captures = require("neoagent.subprocess.capture")

local M = {}

---@class Neoagent.SubprocessResult: Neoagent.SubprocessOutcome
---@field stdout string
---@field stderr string
---@field output string

---@class Neoagent.SubprocessScope
---@field spawn fun(self: Neoagent.SubprocessScope, spec: Neoagent.SubprocessSpec, observer?: Neoagent.SubprocessObserver): Neoagent.SubprocessHandle
---@field run async fun(self: Neoagent.SubprocessScope, spec: Neoagent.SubprocessSpec, options: Neoagent.SubprocessRunOptions): Neoagent.SubprocessResult
---@field close fun(self: Neoagent.SubprocessScope, reason: string)
---@field is_settled fun(self: Neoagent.SubprocessScope): boolean
---@field is_released fun(self: Neoagent.SubprocessScope): boolean
---@field wait async fun(self: Neoagent.SubprocessScope, timeout_ms: integer): true
---@field wait_release async fun(self: Neoagent.SubprocessScope, timeout_ms: integer): true

---@param on_settled? fun(err?: Neoagent.Error)
---@param on_released? fun()
---@return Neoagent.SubprocessScope
---@return async fun(): true
local function scope(on_settled, on_released)
  local closed = false
  ---@type table<Neoagent.OwnedSubprocess, boolean>
  local pending = {}
  ---@type table<Neoagent.OwnedSubprocess, boolean>
  local unreleased = {}
  ---@type table<Neoagent.AwaitCallbacks<true>, fun()>
  local waiters = {}
  ---@type table<Neoagent.AwaitCallbacks<true>, fun()>
  local release_waiters = {}
  ---@type Neoagent.Error?
  local failure

  local function notify(releasing)
    if next(releasing and unreleased or pending) then
      return
    end
    if not releasing and closed and on_settled then
      local complete = on_settled
      on_settled = nil
      complete(failure)
    end
    if releasing and on_released then
      on_released()
    end
    local current = releasing and release_waiters or waiters
    for waiter, cleanup in pairs(current) do
      cleanup()
      if failure and not releasing then
        waiter.reject(util.copy(failure))
      else
        waiter.resolve(true)
      end
    end
  end

  ---@async
  ---@param timeout_ms? integer
  ---@param releasing? boolean
  ---@return true
  local function wait(timeout_ms, releasing)
    local waiting = releasing and release_waiters or waiters
    return async.await(function(done)
      if next(releasing and unreleased or pending) == nil then
        if failure and not releasing then
          done.reject(util.copy(failure))
        else
          done.resolve(true)
        end
        return
      end
      ---@type uv.uv_timer_t?
      local timer
      local function cleanup()
        waiting[done] = nil
        if timer and not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      end
      if timeout_ms then
        timer = assert(vim.uv.new_timer())
        vim.uv.update_time()
        timer:start(timeout_ms, 0, function()
          cleanup()
          done.reject(validate.error("process_cleanup", "Process scope cleanup timed out"))
        end)
      end
      waiting[done] = cleanup
      notify(releasing)
      return cleanup
    end)
  end

  local function on_release(owned)
    unreleased[owned] = nil
    notify(true)
  end

  ---@param owned Neoagent.OwnedSubprocess
  ---@param err? Neoagent.Error
  local function on_cleanup(owned, err)
    pending[owned] = nil
    if err and not failure then
      failure = util.copy(err)
    end
    notify()
  end

  ---@param spec Neoagent.ValidatedSubprocessSpec
  ---@param observer Neoagent.SubprocessObserver
  ---@param capture? Neoagent.SubprocessCapture
  ---@return Neoagent.OwnedSubprocess
  local function own(spec, observer, capture)
    if closed then
      error(validate.error("process_disposed", "Process scope is closed"), 0)
    end
    local owned = handles.new(spec, observer, on_cleanup, on_release, capture)
    pending[owned] = true
    unreleased[owned] = true
    return owned
  end

  return {
    spawn = function(_, spec, observer)
      return own(validate.spec(spec), validate.observer(observer)):start()
    end,
    ---@async
    run = function(_, spec, options)
      spec = validate.spec(spec)
      options = validate.run(spec, options)
      local run = assert(async.current(), "Process run requires a managed coroutine")
      if run:is_cancelled() then
        error(async.cancelled_error, 0)
      end
      local capture = captures.new(options.capture)
      local owned = own(spec, { on_output = options.on_output }, capture)
      local remove_cancel = run:on_cancel(function()
        owned:dispose("Process run cancelled")
      end)
      local ok, outcome = pcall( ---@async
        function()
          local handle = owned:start()
          if options.input then
            owned:send(options.input)
          end
          return handle:wait()
        end
      )
      remove_cancel()
      if run:is_cancelled() then
        error(async.cancelled_error, 0)
      end
      if not ok then
        owned:dispose("Process run failed")
        error(outcome, 0)
      end
      return vim.tbl_extend("force", outcome, capture.result())
    end,
    close = function(_, reason)
      reason = validate.reason(reason)
      if closed then
        return
      end
      closed = true
      for owned in pairs(pending) do
        owned:dispose(reason)
      end
      notify()
    end,
    is_settled = function()
      return next(pending) == nil
    end,
    is_released = function()
      return next(unreleased) == nil
    end,
    ---@async
    wait_release = function(_, timeout_ms)
      if not validate.integer(timeout_ms, 1, 2147483647) then
        error(validate.error("process_validation", "Process scope wait requires a positive bounded timeout"), 0)
      end
      return wait(timeout_ms, true)
    end,
    ---@async
    wait = function(_, timeout_ms)
      if not validate.integer(timeout_ms, 1, 2147483647) then
        error(validate.error("process_validation", "Process scope wait requires a positive bounded timeout"), 0)
      end
      return wait(timeout_ms)
    end,
  },
    ---@async
    function()
      return wait()
    end
end

-- Internal constructor also returns an observer of the handles' bounded
-- cleanup, without imposing another deadline. The public entrypoint exposes
-- only the scope.
---@param on_released? fun()
---@return Neoagent.SubprocessScope
---@return async fun(): true
function M.new(on_released)
  return scope(nil, on_released)
end

---@async
---@param spec Neoagent.SubprocessSpec
---@param options Neoagent.SubprocessRunOptions
---@return Neoagent.SubprocessResult
function M.run(spec, options)
  local run = assert(async.current(), "Process run requires a managed coroutine")
  -- Keep this observer independent of the cancelling coroutine, including
  -- cancellation after a cleanup failure was queued for delivery.
  local release_diagnostics = run:_retain_diagnostics()
  local owner, wait_cleanup = scope(function(err)
    if err then
      run:_diagnose("dispose", err.message)
    end
    release_diagnostics()
  end)
  local ok, result = pcall(owner.run, owner, spec, options)
  owner:close("Process run finished")
  if not ok then
    -- Handles own bounded cleanup. Join their settlement without imposing a
    -- competing timeout; Run cancellation still detaches this waiter.
    pcall(wait_cleanup)
    error(result, 0)
  end
  -- Successful handle completion already includes resource settlement.
  return result
end

return M
