local async = require("neoagent.async")
local util = require("neoagent.util")
local validate = require("neoagent.subprocess.validate")
local native = require("neoagent.process_sessions.local")
local M = {}

---@class Neoagent.ProcessSessionsOptions
---@field capacity? integer Defaults to 16; live or unreleased controllers are never evicted.
---@field completed? integer Defaults to 32 retained completed records.
---@field output_bytes? integer Defaults to 65536 per pending buffer and retained tail.

---@class Neoagent.ProcessSessionResult: Neoagent.ProcessCollection
---@field session_id? integer Provisional until admission.commit() succeeds.
---@field text string Incremental UTF-8 text; binary/control bytes are escaped.

---@class Neoagent.ProcessAdmission
---@field result Neoagent.ProcessSessionResult
---@field commit fun(): integer? Call only after accepting publication of this result.
---@field abort fun(reason: string)

---@class Neoagent.ProcessSessions
---@field prepare async fun(self: Neoagent.ProcessSessions, spec: Neoagent.SubprocessSpec, wait_ms: integer, factory?: Neoagent.ProcessControllerFactory): Neoagent.ProcessAdmission
---@field interact async fun(self: Neoagent.ProcessSessions, id: integer, wait_ms: integer, control?: Neoagent.ProcessControl): Neoagent.ProcessSessionResult
---@field history fun(self: Neoagent.ProcessSessions, id: integer): Neoagent.SubprocessOutputEvent[]
---@field forget fun(self: Neoagent.ProcessSessions, id: integer)
---@field close fun(self: Neoagent.ProcessSessions, reason: string)
---@field status fun(self: Neoagent.ProcessSessions): {closed: boolean, reserved: integer, completed: integer, provisional: integer, released: boolean, cleanup_error?: Neoagent.Error}
---@field wait_cleanup async fun(self: Neoagent.ProcessSessions, timeout_ms: integer): true
---@field wait_release async fun(self: Neoagent.ProcessSessions, timeout_ms: integer): true

---@class Neoagent.ProcessSessionEntry
---@field id integer
---@field controller Neoagent.ProcessController
---@field text fun(events: Neoagent.SubprocessOutputEvent[], dropped: integer, done: boolean): string
---@field history Neoagent.ProcessOutputBuffer
---@field committed boolean
---@field discarded boolean
---@field busy boolean
---@field complete_order? integer
---@field remove_cancel? fun()
---@field cleanup_reported? boolean

local function integer(value, minimum, maximum, label)
  if not validate.integer(value, minimum, maximum) then
    error(validate.error("process_validation", label .. " is outside its integer bounds"), 0)
  end
  return value
end

---@param options? Neoagent.ProcessSessionsOptions
---@param on_cleanup? fun(error: Neoagent.Error)
---@return Neoagent.ProcessSessions
function M.new(options, on_cleanup)
  if options == nil then
    options = {}
  end
  validate.fields(options, { capacity = true, completed = true, output_bytes = true }, "Process session options")
  assert(on_cleanup == nil or type(on_cleanup) == "function", "Process cleanup observer must be a function")
  local capacity = integer(options.capacity == nil and 16 or options.capacity, 1, 64, "Process capacity")
  local completed = integer(options.completed == nil and 32 or options.completed, 1, 256, "Completed retention")
  local output_bytes =
    integer(options.output_bytes == nil and 65536 or options.output_bytes, 1, 262144, "Process output budget")
  local next_id, completion_order = 0, 0
  local closed = false
  ---@type Neoagent.Error?
  local cleanup_error
  ---@type table<integer, Neoagent.ProcessSessionEntry>
  local entries = {}

  ---@param entry Neoagent.ProcessSessionEntry
  ---@param err Neoagent.Error
  local function record_cleanup(entry, err)
    cleanup_error = cleanup_error or util.copy(err)
    if on_cleanup and not entry.cleanup_reported then
      entry.cleanup_reported = true
      -- Diagnostics cannot interrupt disposal of the remaining controllers.
      pcall(on_cleanup, util.copy(err))
    end
  end

  local function prune()
    ---@type Neoagent.ProcessSessionEntry[]
    local retained = {}
    for id, entry in pairs(entries) do
      local state = entry.controller:state()
      if state.done and state.released then
        if entry.discarded then
          entries[id] = nil
        elseif entry.committed and not entry.busy then
          retained[#retained + 1] = entry
        end
      end
    end
    table.sort(retained, function(left, right)
      return (left.complete_order or left.id) < (right.complete_order or right.id)
    end)
    for index = 1, #retained - completed do
      entries[assert(retained[index]).id] = nil
    end
  end
  local function status()
    prune()
    local reserved, retained, provisional = 0, 0, 0
    local released = true
    for _, entry in pairs(entries) do
      local state = entry.controller:state()
      if not state.released or not entry.committed and not entry.discarded then
        reserved = reserved + 1
      end
      released = released and state.released
      if state.done and entry.committed then
        retained = retained + 1
      end
      if not entry.committed and not entry.discarded then
        provisional = provisional + 1
      end
    end
    return {
      closed = closed,
      reserved = reserved,
      completed = retained,
      provisional = provisional,
      released = released,
      cleanup_error = util.copy(cleanup_error),
    }
  end
  local function abort(entry, reason)
    entry.discarded = true
    if entry.remove_cancel then
      entry.remove_cancel()
      entry.remove_cancel = nil
    end
    local disposed, err = pcall(entry.controller.dispose, entry.controller, reason)
    if not disposed then
      record_cleanup(entry, util.normalize_error(err, "process_cleanup"))
    end
    prune()
  end
  local function lookup(id)
    integer(id, 1, 9007199254740991, "Process session ID")
    local entry = entries[id]
    if not entry or not entry.committed or entry.discarded then
      error(validate.error("process_session_missing", "Process session is unavailable"), 0)
    end
    return entry
  end
  ---@async
  local function collect(entry, wait_ms, control, until_exit)
    integer(wait_ms, 0, 30000, "Process wait budget")
    if entry.busy then
      error(validate.error("process_session_busy", "Process session already has an interaction"), 0)
    end
    entry.busy = true
    local ok, result = pcall(function()
      if control then
        native.validate_control(control)
        entry.controller:control(control)
      end
      local result = entry.controller:collect(wait_ms, until_exit)
      for _, event in ipairs(result.events) do
        entry.history.append(event)
      end
      result.text = entry.text(result.events, result.dropped_bytes, result.done)
      result.session_id = entry.id
      return result
    end)
    entry.busy = false
    if not ok then
      error(result, 0)
    end
    return result
  end
  ---@async
  local function wait(timeout_ms, release)
    integer(timeout_ms, 1, validate.MAX_TIMEOUT_MS, "Process session cleanup wait")
    local function ready()
      for _, entry in pairs(entries) do
        local state = entry.controller:state()
        if release and not state.released or not release and not state.done then
          return false
        end
      end
      return true
    end
    if not ready() then
      async.await(function(done)
        local timer = assert(vim.uv.new_timer())
        local deadline = vim.uv.hrtime() + timeout_ms * 1000000
        local function stop()
          if not timer:is_closing() then
            timer:stop()
            timer:close()
          end
        end
        vim.uv.update_time()
        timer:start(0, 10, function()
          if ready() then
            stop()
            done.resolve(true)
          elseif vim.uv.hrtime() >= deadline then
            stop()
            done.reject(validate.error("process_cleanup", "Process session cleanup wait timed out"))
          end
        end)
        return stop
      end)
    end
    prune()
    if not release and cleanup_error then
      error(util.copy(cleanup_error), 0)
    end
    return true
  end
  return {
    ---@async
    prepare = function(_, spec, wait_ms, factory)
      spec = validate.spec(spec)
      integer(wait_ms, 0, 30000, "Process wait budget")
      if closed then
        error(validate.error("process_disposed", "Process sessions are closed"), 0)
      end
      local run = assert(async.current(), "Process admission requires a managed Run")
      if run:is_cancelled() then
        error(async.cancelled_error, 0)
      end
      if status().reserved >= capacity then
        error(validate.error("process_capacity", "Process session capacity is reserved"), 0)
      end
      next_id = next_id + 1
      ---@type Neoagent.ProcessSessionEntry
      local entry
      -- The allocation-free constructor receives its diagnostic recipient
      -- before start. Reporting remains live beyond the first completion wait.
      local controller = (factory or native.new)(spec, output_bytes, function(err)
        record_cleanup(entry, err)
      end)
      entry = {
        id = next_id,
        controller = controller,
        committed = false,
        discarded = false,
        busy = false,
        text = require("neoagent.process_sessions.text").new(),
        history = require("neoagent.process_sessions.buffer").new(output_bytes),
      }
      entries[entry.id] = entry
      entry.remove_cancel = run:on_cancel(function()
        abort(entry, "Process admission cancelled before handoff")
      end)
      local ok, result = pcall( ---@async
        function()
          controller:start()
          return collect(entry, wait_ms, nil, true)
        end
      )
      -- Observe completion independently of the admitting or polling Run.
      async.run(function()
        controller:wait()
      end, {
        on_done = function()
          completion_order = completion_order + 1
          entry.complete_order = completion_order
          prune()
        end,
      })
      if not ok or run:is_cancelled() then
        abort(entry, "Process admission failed")
        error(run:is_cancelled() and async.cancelled_error or result, 0)
      end
      if result.done then
        result.session_id = nil
      end
      return {
        result = util.copy(result),
        commit = function()
          if entry.discarded or closed or run:is_cancelled() then
            abort(entry, "Process handoff was revoked")
            error(validate.error("process_disposed", "Process admission is no longer available"), 0)
          end
          if entry.remove_cancel then
            entry.remove_cancel()
            entry.remove_cancel = nil
          end
          if not result.session_id then
            abort(entry, "Completed process result accepted")
            return nil
          end
          if not entry.committed and entry.complete_order then
            -- A result accepted after native completion is newly published
            -- history. Do not evict the ID in the act of handing it off.
            completion_order = completion_order + 1
            entry.complete_order = completion_order
          end
          entry.committed = true
          prune()
          return entry.id
        end,
        abort = function(reason)
          if not entry.committed then
            abort(entry, validate.reason(reason))
          end
        end,
      }
    end,
    ---@async
    interact = function(_, id, wait_ms, control)
      if closed then
        error(validate.error("process_disposed", "Process sessions are closed"), 0)
      end
      return collect(lookup(id), wait_ms, control)
    end,
    history = function(_, id)
      return lookup(id).history.snapshot()
    end,
    forget = function(_, id)
      abort(lookup(id), "Process session forgotten")
    end,
    close = function(_, reason)
      reason = validate.reason(reason)
      if closed then
        return
      end
      closed = true
      for _, entry in pairs(entries) do
        abort(entry, reason)
      end
    end,
    status = status,
    ---@async
    wait_cleanup = function(_, timeout_ms)
      return wait(timeout_ms, false)
    end,
    ---@async
    wait_release = function(_, timeout_ms)
      return wait(timeout_ms, true)
    end,
  }
end

return M
