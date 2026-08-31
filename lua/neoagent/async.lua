local util = require("neoagent.util")

local M = {}
local managed = setmetatable({}, { __mode = "k" })

local Run = {}
Run.__index = Run

local cancelled_error = { kind = "cancelled", message = "Operation cancelled" }
local MAX_DIAGNOSTICS = 32
local MAX_DIAGNOSTIC_CHARACTERS = 1024
local MAX_DIAGNOSTIC_SOURCE_BYTES = MAX_DIAGNOSTIC_CHARACTERS * 4

local function diagnostic_message(value)
  local rendered, message
  local ok, result = pcall(tostring, value)
  if ok then rendered = result
  else rendered = "Callback failure could not be rendered" end
  local source = rendered:sub(1, MAX_DIAGNOSTIC_SOURCE_BYTES)
  message = util.text_from_bytes(source)
  local truncated = #rendered > #source
    or vim.fn.strchars(message) > MAX_DIAGNOSTIC_CHARACTERS
  if truncated then
    message = vim.fn.strcharpart(
      message, 0, MAX_DIAGNOSTIC_CHARACTERS - 1) .. "…"
  end
  return message
end

function Run:_record_diagnostic(diagnostic)
  diagnostic = util.copy(diagnostic)
  if #self._diagnostics == MAX_DIAGNOSTICS then
    table.remove(self._diagnostics, 1)
  end
  self._diagnostics[#self._diagnostics + 1] = diagnostic
  if self._report then pcall(self._report, util.copy(diagnostic)) end
  for listener in pairs(self._diagnostic_listeners) do
    pcall(listener, util.copy(diagnostic))
  end
end

function Run:_diagnose(phase, value)
  self:_record_diagnostic({
    kind = "callback",
    phase = phase,
    message = diagnostic_message(value),
  })
end

function Run:_subscribe_diagnostics(listener)
  self._diagnostic_listeners[listener] = true
  for _, diagnostic in ipairs(self._diagnostics) do
    pcall(listener, util.copy(diagnostic))
  end
  local active = true
  return function()
    if not active then return false end
    active = false
    self._diagnostic_listeners[listener] = nil
    return true
  end
end

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
      if not ok then run:_diagnose(item.phase, err) end
    end
  end)
end

function Run:_enqueue(fn, value, phase)
  if not fn then
    return
  end
  self._callback_queue[#self._callback_queue + 1] = {
    fn = fn,
    value = value,
    phase = phase,
  }
  schedule_drain(self)
end

function Run:emit(event)
  if self._completed then
    return false
  end
  self:_enqueue(self._on_event, event, "event")
  return true
end

function Run:_listen(fn)
  if self._completed then
    self:_enqueue(fn, self._result, "listener")
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
  self:_enqueue(self._on_done, result, "done")
  for _, listener in ipairs(self._listeners) do
    self:_enqueue(listener, result, "listener")
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
      local ok, err = pcall(entry.fn)
      if not ok then self:_diagnose("cancel", err) end
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

function Run:diagnostics()
  return util.copy(self._diagnostics)
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
  local remove_diagnostic_listener
  if parent ~= self and self._report == nil then
    remove_diagnostic_listener = self:_subscribe_diagnostics(
      function(diagnostic) parent:_record_diagnostic(diagnostic) end)
  end
  return M.await(function(done)
    local current = M.current()
    if current and current._waiting then current._waiting.defer_cancel = true end
    self:_listen(function(result)
      if remove_diagnostic_listener then remove_diagnostic_listener() end
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
  assert(opts.report == nil or type(opts.report) == "function",
    "async.run report must be a function")
  local run = setmetatable({
    _on_event = opts.on_event,
    _on_done = opts.on_done,
    _error_kind = opts.error_kind or "tool",
    _report = opts.report,
    _callback_queue = {},
    _diagnostics = {},
    _diagnostic_listeners = {},
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
