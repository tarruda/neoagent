local util = require("neoagent.util")

---@class Neoagent.AsyncFailure
---@field ok false
---@field error Neoagent.Error

---@class Neoagent.AsyncSuccess
---@field ok true

-- A coroutine with no return value settles with the default success record.
---@alias Neoagent.NoReturn nil
---@alias Neoagent.RunValue<T> T extends Neoagent.NoReturn and Neoagent.AsyncSuccess or T
---@alias Neoagent.RunResult<T> Neoagent.RunValue<T>|Neoagent.AsyncFailure
---@alias Neoagent.CancelSubscription fun(): boolean
---@alias Neoagent.DiagnosticPhase 'event'|'done'|'listener'|'cancel'|'dispose'

---@class Neoagent.AsyncDiagnostic
---@field kind 'callback'
---@field phase Neoagent.DiagnosticPhase
---@field message string

---@class Neoagent.RunOptions<T, E>
---@field on_event? fun(event: E)
---@field on_done? fun(result: Neoagent.RunResult<T>)
---@field error_kind? string
---@field report? fun(diagnostic: Neoagent.AsyncDiagnostic)

---@class Neoagent.AwaitCallbacks<T>
---@field resolve fun(value: T, disposer?: fun(value: T)): boolean
---@field reject fun(error: unknown): boolean

---@class Neoagent.CancelHandler
---@field fn fun()
---@field active boolean

---@class Neoagent.QueuedCallback
---@field invoke fun()
---@field phase Neoagent.DiagnosticPhase

---@class Neoagent.AwaitState
---@field state 'pending'|'settled'|'cancelled'|'delivered'
---@field yielded boolean
---@field delivery_scheduled? boolean
---@field cancel_invoked? boolean
---@field cancel_pending? boolean
---@field cancel_producer? fun()
---@field cancel_wait? Neoagent.CancelSubscription
---@field remove_cancel? Neoagent.CancelSubscription
---@field ok? boolean
---@field value? unknown
---@field disposer? fun(value: unknown)
---@field resolve? fun(value: unknown, disposer?: fun(value: unknown)): boolean
---@field reject? fun(error: unknown): boolean

local M = {}
---@type table<thread, Neoagent.Run<unknown, unknown>>
local managed = setmetatable({}, { __mode = "k" })

---@class Neoagent.Run<T, E>
---@field _co? thread
---@field _on_event? fun(event: E)
---@field _on_done? fun(result: Neoagent.RunResult<T>)
---@field _error_kind string
---@field _report? fun(diagnostic: Neoagent.AsyncDiagnostic)
---@field _callback_queue (Neoagent.QueuedCallback|false)[]
---@field _callback_head integer
---@field _drain_scheduled? boolean
---@field _diagnostics Neoagent.AsyncDiagnostic[]
---@field _diagnostic_listeners table<fun(diagnostic: Neoagent.AsyncDiagnostic), boolean>
---@field _listeners fun(result: Neoagent.RunResult<T>)[]
---@field _cancel_handlers Neoagent.CancelHandler[]
---@field _inactive_cancel_handlers integer
---@field _children table<Neoagent.Run<unknown, unknown>, boolean>
---@field _parents table<Neoagent.Run<unknown, unknown>, boolean>
---@field _completed boolean
---@field _cancelled boolean
---@field _cancelling? boolean
---@field _result? Neoagent.RunResult<T>
---@field _waiting? Neoagent.AwaitState
local Run = {}
Run.__index = Run

local cancelled_error = { kind = "cancelled", message = "Operation cancelled" }
local MAX_DIAGNOSTICS = 32
local MAX_DIAGNOSTIC_CHARACTERS = 1024
local CALLBACK_COMPACT_THRESHOLD = 256
local CANCEL_COMPACT_THRESHOLD = 64

---@param value unknown
---@return string
local function diagnostic_message(value)
  return util.safe_message(value, {
    fallback = "Callback failure could not be rendered",
    max_characters = MAX_DIAGNOSTIC_CHARACTERS,
    max_source_bytes = MAX_DIAGNOSTIC_CHARACTERS * 4,
  })
end

---@param diagnostic Neoagent.AsyncDiagnostic
---@param self Neoagent.Run<unknown, unknown>
function Run._record_diagnostic(self, diagnostic)
  diagnostic = util.copy(diagnostic)
  if #self._diagnostics == MAX_DIAGNOSTICS then
    table.remove(self._diagnostics, 1)
  end
  self._diagnostics[#self._diagnostics + 1] = diagnostic
  if self._report then
    pcall(self._report, util.copy(diagnostic))
  end
  for listener in pairs(self._diagnostic_listeners) do
    pcall(listener, util.copy(diagnostic))
  end
end

---@param phase Neoagent.DiagnosticPhase
---@param value unknown
---@param self Neoagent.Run<unknown, unknown>
function Run._diagnose(self, phase, value)
  self:_record_diagnostic({
    kind = "callback",
    phase = phase,
    message = diagnostic_message(value),
  })
end

---@param listener fun(diagnostic: Neoagent.AsyncDiagnostic)
---@return Neoagent.CancelSubscription
---@param self Neoagent.Run<unknown, unknown>
function Run._subscribe_diagnostics(self, listener)
  self._diagnostic_listeners[listener] = true
  for _, diagnostic in ipairs(self._diagnostics) do
    pcall(listener, util.copy(diagnostic))
  end
  local active = true
  return function()
    if not active then
      return false
    end
    active = false
    self._diagnostic_listeners[listener] = nil
    return true
  end
end

---@param run Neoagent.Run<unknown, unknown>
local function schedule_drain(run)
  if run._drain_scheduled then
    return
  end
  run._drain_scheduled = true
  util.schedule(function()
    while run._callback_head <= #run._callback_queue do
      local item = run._callback_queue[run._callback_head]
      run._callback_queue[run._callback_head] = false
      run._callback_head = run._callback_head + 1
      local ok, err = pcall(item.invoke)
      if not ok then
        run:_diagnose(item.phase, err)
      end
      local length = #run._callback_queue
      if run._callback_head > CALLBACK_COMPACT_THRESHOLD and run._callback_head > length / 2 then
        local compacted = {}
        for index = run._callback_head, length do
          compacted[#compacted + 1] = run._callback_queue[index]
        end
        run._callback_queue = compacted
        run._callback_head = 1
      end
    end
    run._callback_queue = {}
    run._callback_head = 1
    run._drain_scheduled = false
  end)
end

---@generic V
---@param fn? fun(value: V)
---@param value V
---@param phase Neoagent.DiagnosticPhase
---@param self Neoagent.Run<unknown, unknown>
function Run._enqueue(self, fn, value, phase)
  if not fn then
    return
  end
  self._callback_queue[#self._callback_queue + 1] = {
    invoke = function()
      fn(value)
    end,
    phase = phase,
  }
  schedule_drain(self)
end

---@generic T, E
---@param self Neoagent.Run<T, E>
---@param event E
---@return boolean
function Run.emit(self, event)
  if self._completed then
    return false
  end
  self:_enqueue(self._on_event, event, "event")
  return true
end

---@generic T, E
---@param self Neoagent.Run<T, E>
---@param fn fun(result: Neoagent.RunResult<T>)
function Run._listen(self, fn)
  if self._completed then
    self:_enqueue(fn, self._result, "listener")
  else
    self._listeners[#self._listeners + 1] = fn
  end
end

---@generic T, E
---@param self Neoagent.Run<T, E>
---@param result Neoagent.RunResult<T>
---@return boolean
function Run._finish(self, result)
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
  for _, entry in ipairs(self._cancel_handlers) do
    entry.active = false
  end
  self._cancel_handlers = {}
  self._inactive_cancel_handlers = 0
  return true
end

---@return boolean
---@param self Neoagent.Run<unknown, unknown>
function Run._compact_cancel_handlers(self)
  local inactive = self._inactive_cancel_handlers
  local handlers = self._cancel_handlers
  if self._cancelling or inactive < CANCEL_COMPACT_THRESHOLD or inactive * 2 < #handlers then
    return false
  end
  local compacted = {}
  for _, entry in ipairs(handlers) do
    if entry.active then
      compacted[#compacted + 1] = entry
    end
  end
  self._cancel_handlers = compacted
  self._inactive_cancel_handlers = 0
  return true
end

---@param fn fun()
---@return Neoagent.CancelSubscription
---@param self Neoagent.Run<unknown, unknown>
function Run.on_cancel(self, fn)
  assert(type(fn) == "function", "cancel handler must be a function")
  if self._completed then
    return function()
      return false
    end
  end
  if self._cancelled then
    local ok, err = pcall(fn)
    if not ok then
      self:_diagnose("cancel", err)
    end
    return function()
      return false
    end
  end
  local entry = { fn = fn, active = true }
  self._cancel_handlers[#self._cancel_handlers + 1] = entry
  return function()
    if not entry.active then
      return false
    end
    entry.active = false
    self._inactive_cancel_handlers = self._inactive_cancel_handlers + 1
    self:_compact_cancel_handlers()
    return true
  end
end

---@param self Neoagent.Run<unknown, unknown>
function Run.cancel(self)
  if self._completed or self._cancelled then
    return
  end
  self._cancelled = true
  for child in pairs(self._children) do
    child:cancel()
  end
  self._cancelling = true
  for _, entry in ipairs(self._cancel_handlers) do
    if entry.active then
      local ok, err = pcall(entry.fn)
      if not ok then
        self:_diagnose("cancel", err)
      end
      entry.active = false
    end
  end
  self._cancelling = false
  self._cancel_handlers = {}
  self._inactive_cancel_handlers = 0
  local waiting = self._waiting
  if waiting and waiting.cancel_wait then
    waiting.cancel_wait()
  end
end

---@return boolean
---@param self Neoagent.Run<unknown, unknown>
function Run.is_done(self)
  return self._completed
end

---@return boolean
---@param self Neoagent.Run<unknown, unknown>
function Run.is_cancelled(self)
  return self._cancelled
end

---@generic T, E
---@param self Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>?
function Run.result(self)
  return self._result
end

---@return Neoagent.AsyncDiagnostic[]
---@param self Neoagent.Run<unknown, unknown>
function Run.diagnostics(self)
  return util.copy(self._diagnostics)
end

---@async
---@generic T, E
---@param self Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
function Run.await(self)
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
    remove_diagnostic_listener = self:_subscribe_diagnostics(function(diagnostic)
      parent:_record_diagnostic(diagnostic)
    end)
  end
  if parent._cancelled then
    self:cancel()
    if remove_diagnostic_listener then
      self:_listen(remove_diagnostic_listener)
    end
    error(cancelled_error, 0)
  end
  return M.await(function(done)
    self:_listen(function(result)
      if remove_diagnostic_listener then
        remove_diagnostic_listener()
      end
      done.resolve(result)
    end)
    return function()
      self:cancel()
    end
  end)
end

---@param run Neoagent.Run<unknown, unknown>
---@param ... unknown
local function resume_run(run, ...)
  local result = { coroutine.resume(run._co, ...) }
  local ok = table.remove(result, 1)
  if not ok then
    local err = result[1]
    run:_finish({ ok = false, error = util.normalize_error(err, run._error_kind) })
    return
  end
  if coroutine.status(run._co) == "dead" then
    ---@type unknown
    local value = result[1]
    if value == nil then
      value = { ok = true }
    end
    run:_finish(value)
  end
end

---@return Neoagent.Run<unknown, unknown>?
function M.current()
  local co = coroutine.running()
  return co and managed[co] or nil
end

---@async
---@generic T
---@param start fun(done: Neoagent.AwaitCallbacks<T>): (fun())?
---@return T
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

  ---@type Neoagent.AwaitState
  local waiting = { state = "pending", yielded = false }
  ---@type fun()
  local schedule_delivery

  ---@param phase Neoagent.DiagnosticPhase
  ---@param fn fun(value: unknown)
  ---@param value? unknown
  local function diagnose(phase, fn, value)
    local ok, err = pcall(fn, value)
    if not ok then
      run:_diagnose(phase, err)
    end
  end

  ---@param value unknown
  ---@param disposer? fun(value: unknown)
  local function dispose(value, disposer)
    if disposer then
      diagnose("dispose", disposer, value)
    end
  end

  local function cancel_producer()
    if waiting.cancel_invoked or not waiting.cancel_producer then
      return
    end
    waiting.cancel_invoked = true
    diagnose("cancel", waiting.cancel_producer)
  end

  ---@return boolean
  local function cancel_wait()
    if waiting.state == "cancelled" or waiting.state == "delivered" then
      return false
    end
    local previous = waiting.state
    waiting.state = "cancelled"
    if previous == "pending" then
      waiting.cancel_pending = true
      cancel_producer()
    else
      local value, disposer = waiting.value, waiting.disposer
      waiting.value, waiting.disposer = nil, nil
      dispose(value, disposer)
    end
    if waiting.yielded then
      schedule_delivery()
    end
    return true
  end

  ---@param ok boolean
  ---@param value unknown
  ---@param disposer? fun(value: unknown)
  ---@return boolean
  local function settle(ok, value, disposer)
    if disposer ~= nil and type(disposer) ~= "function" then
      ok = false
      value = util.error("async", "await disposer must be a function")
      disposer = nil
    end
    if waiting.state == "cancelled" then
      if ok then
        dispose(value, disposer)
      end
      return false
    end
    if waiting.state ~= "pending" or run._completed then
      return false
    end
    waiting.state = "settled"
    waiting.ok = ok
    waiting.value = value
    waiting.disposer = ok and disposer or nil
    if waiting.yielded then
      schedule_delivery()
    end
    return true
  end
  waiting.resolve = function(value, disposer)
    return settle(true, value, disposer)
  end
  waiting.reject = function(err)
    return settle(false, err)
  end
  waiting.cancel_wait = cancel_wait
  run._waiting = waiting
  waiting.remove_cancel = run:on_cancel(cancel_wait)

  schedule_delivery = function()
    if waiting.delivery_scheduled or not waiting.yielded or waiting.state == "pending" then
      return
    end
    waiting.delivery_scheduled = true
    util.schedule(function()
      if run._completed then
        return
      end
      if run._cancelled then
        cancel_wait()
      end
      resume_run(run)
      waiting.delivery_scheduled = false
    end)
  end

  local ok, cancel_or_error = pcall(start, {
    resolve = waiting.resolve,
    reject = waiting.reject,
  })
  if not ok then
    waiting.reject(cancel_or_error)
  elseif type(cancel_or_error) == "function" then
    waiting.cancel_producer = cancel_or_error
    if waiting.cancel_pending then
      cancel_producer()
    end
  end

  if waiting.state == "pending" then
    waiting.yielded = true
    coroutine.yield()
  end
  if run._cancelled then
    cancel_wait()
  end
  local state = waiting.state
  local resolved, value = waiting.ok, waiting.value
  if state == "settled" then
    waiting.state = "delivered"
    state = "delivered"
    waiting.disposer = nil
  end
  if waiting.remove_cancel then
    waiting.remove_cancel()
  end
  if run._waiting == waiting then
    run._waiting = nil
  end
  waiting.value = nil
  if state == "cancelled" then
    error(cancelled_error, 0)
  end
  assert(state == "delivered", "async await resumed before settlement")
  if not resolved then
    error(util.normalize_error(value, "cancelled"), 0)
  end
  return value
end

---@generic T, E
---@param fn async fun(run: Neoagent.Run<T, E>): T
---@param opts? Neoagent.RunOptions<T, E>
---@return Neoagent.Run<T, E>
function M.run(fn, opts)
  assert(type(fn) == "function", "async.run fn must be a function")
  opts = opts or {}
  assert(opts.report == nil or type(opts.report) == "function", "async.run report must be a function")
  ---@type Neoagent.Run<T, E>
  local run = setmetatable({
    _on_event = opts.on_event,
    _on_done = opts.on_done,
    _error_kind = opts.error_kind or "tool",
    _report = opts.report,
    _callback_queue = {},
    _callback_head = 1,
    _diagnostics = {},
    _diagnostic_listeners = {},
    _listeners = {},
    _cancel_handlers = {},
    _inactive_cancel_handlers = 0,
    _children = setmetatable({}, { __mode = "k" }),
    _parents = setmetatable({}, { __mode = "k" }),
    _completed = false,
    _cancelled = false,
  }, Run)
  ---@async
  local function execute()
    managed[coroutine.running()] = run
    return fn(run)
  end
  run._co = coroutine.create(execute)
  resume_run(run)
  return run
end

M.Run = Run
M.cancelled_error = cancelled_error

-- Give the editor an event-loop turn, rather than adding more work to the
-- current scheduled-callback drain. Cancellation owns the pending timer.
---@async
function M.yield()
  M.await(function(done)
    local timer = assert(vim.uv.new_timer())
    local function close()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    timer:start(
      0,
      0,
      vim.schedule_wrap(function()
        close()
        done.resolve(true)
      end)
    )
    return close
  end)
end

return M
