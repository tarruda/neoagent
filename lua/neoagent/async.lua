local util = require("neoagent.util")

local M = {}
local managed = setmetatable({}, { __mode = "k" })

local Run = {}
Run.__index = Run

local cancelled_error = { kind = "cancelled", message = "Operation cancelled" }

local function schedule_drain(run)
  if run._drain_scheduled then
    return
  end
  run._drain_scheduled = true
  util.schedule(function()
    run._drain_scheduled = false
    while #run._callback_queue > 0 do
      local item = table.remove(run._callback_queue, 1)
      local ok, err = pcall(item.fn, item.value)
      if not ok then
        vim.notify("neoagent callback failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end)
end

function Run:_enqueue(fn, value)
  if not fn then
    return
  end
  self._callback_queue[#self._callback_queue + 1] = { fn = fn, value = value }
  schedule_drain(self)
end

function Run:emit(event)
  if self._completed then
    return false
  end
  self:_enqueue(self._on_event, event)
  return true
end

function Run:_listen(fn)
  if self._completed then
    self:_enqueue(fn, self._result)
  else
    self._listeners[#self._listeners + 1] = fn
  end
end

function Run:_finish(result)
  if self._completed then
    return false
  end
  self._completed = true
  self._result = result
  self._waiting = nil
  for parent in pairs(self._parents) do
    parent._children[self] = nil
  end
  self._parents = {}
  for child in pairs(self._children) do
    child._parents[self] = nil
  end
  self._children = {}
  self:_enqueue(self._on_done, result)
  for _, listener in ipairs(self._listeners) do
    self:_enqueue(listener, result)
  end
  self._listeners = {}
  return true
end

function Run:on_cancel(fn)
  if self._completed then
    return function() end
  end
  local entry = { fn = fn, active = true }
  self._cancel_handlers[#self._cancel_handlers + 1] = entry
  return function()
    entry.active = false
  end
end

function Run:cancel()
  if self._completed or self._cancelled then
    return
  end
  self._cancelled = true
  for child in pairs(self._children) do
    child:cancel()
  end
  for _, entry in ipairs(self._cancel_handlers) do
    if entry.active then
      pcall(entry.fn)
      entry.active = false
    end
  end
  local waiting = self._waiting
  if waiting and not waiting.settled and not waiting.defer_cancel then
    waiting.reject(cancelled_error)
  elseif not self._co or coroutine.status(self._co) == "dead" then
    self:_finish({ ok = false, error = cancelled_error })
  end
end

function Run:is_done()
  return self._completed
end

function Run:is_cancelled()
  return self._cancelled
end

function Run:result()
  return self._result
end

function Run:await()
  local parent = M.current()
  if not parent then
    error("Run:await() must be called inside a coroutine managed by neoagent.async", 2)
  end
  if parent ~= self and not self._completed then
    parent._children[self] = true
    self._parents[parent] = true
  end
  return M.await(function(done)
    local current = M.current()
    if current and current._waiting then current._waiting.defer_cancel = true end
    self:_listen(function(result)
      done.resolve(result)
    end)
    return function()
      self:cancel()
    end
  end)
end

local function resume_run(run, ...)
  if run._completed then
    return
  end
  local result = { coroutine.resume(run._co, ...) }
  local ok = table.remove(result, 1)
  if not ok then
    local err = result[1]
    run:_finish({ ok = false, error = util.normalize_error(err, run._error_kind) })
    return
  end
  if coroutine.status(run._co) == "dead" then
    local value = result[1]
    if value == nil then
      value = { ok = true }
    end
    run:_finish(value)
  end
end

function M.current()
  local co = coroutine.running()
  return co and managed[co] or nil
end

function M.await(start)
  assert(type(start) == "function", "async.await start must be a function")
  local co = coroutine.running()
  local run = co and managed[co]
  if not run then
    error("async.await() must be called inside a coroutine managed by neoagent.async", 2)
  end
  if run._cancelled then
    error(cancelled_error, 0)
  end

  local waiting = { settled = false, yielded = false }
  local function settle(ok, value)
    if waiting.settled or run._completed then
      return
    end
    waiting.settled = true
    waiting.ok = ok
    waiting.value = value
    if waiting.remove_cancel then
      waiting.remove_cancel()
    end
    if waiting.yielded then
      util.schedule(function()
        resume_run(run, ok, value)
      end)
    end
  end
  waiting.resolve = function(value)
    settle(true, value)
  end
  waiting.reject = function(err)
    settle(false, err)
  end
  run._waiting = waiting

  local ok, cancel_or_error = pcall(start, {
    resolve = waiting.resolve,
    reject = waiting.reject,
  })
  if not ok then
    waiting.reject(cancel_or_error)
  elseif type(cancel_or_error) == "function" and not waiting.settled then
    waiting.remove_cancel = run:on_cancel(cancel_or_error)
  end

  local resolved, value
  if waiting.settled then
    resolved, value = waiting.ok, waiting.value
  else
    waiting.yielded = true
    resolved, value = coroutine.yield()
  end
  if run._waiting == waiting then
    run._waiting = nil
  end
  if not resolved then
    error(util.normalize_error(value, "cancelled"), 0)
  end
  return value
end

function M.run(fn, opts)
  assert(type(fn) == "function", "async.run fn must be a function")
  opts = opts or {}
  local run = setmetatable({
    _on_event = opts.on_event,
    _on_done = opts.on_done,
    _error_kind = opts.error_kind or "tool",
    _callback_queue = {},
    _listeners = {},
    _cancel_handlers = {},
    _children = setmetatable({}, { __mode = "k" }),
    _parents = setmetatable({}, { __mode = "k" }),
    _completed = false,
    _cancelled = false,
  }, Run)
  run._co = coroutine.create(function()
    managed[coroutine.running()] = run
    return fn(run)
  end)
  resume_run(run)
  return run
end

M.Run = Run
M.cancelled_error = cancelled_error

return M
