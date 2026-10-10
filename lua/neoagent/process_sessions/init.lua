local async = require("neoagent.async")
local util = require("neoagent.util")
local validate = require("neoagent.subprocess.validate")
local controls = require("neoagent.process_sessions.control")
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
---@field start async fun(wait_ms: integer): Neoagent.ProcessSessionResult Start once; return only copied process observations.
---@field commit fun(): integer? Call only after accepting publication of this result.
---@field abort fun(reason: string)

---@class Neoagent.ProcessReservation
---@field session_id integer Identifies ownership even before handoff or after forgetting.
---@field committed boolean
---@field discarded boolean
---@field done boolean Target cleanup observation has finished.
---@field release "pending"|"quarantined"|"released"
---@field release_error? Neoagent.Error Why release cannot be confirmed.
---@field cleanup_error? Neoagent.Error Independent cleanup observation failure.

---@class Neoagent.ProcessSessionsStatus
---@field closed boolean
---@field reserved integer
---@field completed integer
---@field provisional integer
---@field quarantined integer
---@field released boolean
---@field reservations Neoagent.ProcessReservation[] Copied reservations, ordered by ID.
---@field cleanup_error? Neoagent.Error

---@class Neoagent.ProcessSessions
---@field reserve fun(self: Neoagent.ProcessSessions, spec: Neoagent.SubprocessSpec): Neoagent.ProcessAdmission Own publication synchronously before starting async work.
---@field interact async fun(self: Neoagent.ProcessSessions, id: integer, wait_ms: integer, control?: Neoagent.ProcessControl): Neoagent.ProcessSessionResult
---@field history fun(self: Neoagent.ProcessSessions, id: integer): Neoagent.SubprocessOutputEvent[]
---@field forget fun(self: Neoagent.ProcessSessions, id: integer)
---@field close fun(self: Neoagent.ProcessSessions, reason: string)
---@field status fun(self: Neoagent.ProcessSessions): Neoagent.ProcessSessionsStatus
---@field wait_cleanup async fun(self: Neoagent.ProcessSessions, timeout_ms: integer): true
---@field wait_release async fun(self: Neoagent.ProcessSessions, timeout_ms: integer): true

---@class Neoagent.ProcessSessionEntry
---@field id integer
---@field controller? Neoagent.ProcessController
---@field constructing boolean
---@field started boolean
---@field text fun(events: Neoagent.SubprocessOutputEvent[], dropped: integer, done: boolean): string
---@field history Neoagent.ProcessOutputBuffer
---@field committed boolean
---@field discarded boolean
---@field busy boolean
---@field complete_order? integer
---@field remove_cancel? fun()
---@field cleanup_reported? Neoagent.Error

local function integer(value, minimum, maximum, label)
  if not validate.integer(value, minimum, maximum) then
    error(validate.error("process_validation", label .. " is outside its integer bounds"), 0)
  end
  return value
end

---@param options? Neoagent.ProcessSessionsOptions
---@param on_cleanup? fun(error: Neoagent.Error)
---@param default_factory? Neoagent.ProcessControllerFactory Selected by the owning composition for each admission.
---@return Neoagent.ProcessSessions
function M.new(options, on_cleanup, default_factory)
  if options == nil then
    options = {}
  end
  validate.fields(options, { capacity = true, completed = true, output_bytes = true }, "Process session options")
  assert(on_cleanup == nil or type(on_cleanup) == "function", "Process cleanup observer must be a function")
  assert(default_factory == nil or type(default_factory) == "function", "Process controller factory must be a function")
  local capacity = integer(options.capacity == nil and 16 or options.capacity, 1, 64, "Process capacity")
  local completed = integer(options.completed == nil and 32 or options.completed, 1, 256, "Completed retention")
  local output_bytes =
    integer(options.output_bytes == nil and 65536 or options.output_bytes, 1, 262144, "Process output budget")
  local next_id, completion_order = 0, 0
  local closed = false
  local notification = async.notification()
  ---@type Neoagent.Error?
  local cleanup_error
  ---@type table<integer, Neoagent.ProcessSessionEntry>
  local entries = {}

  ---@param entry Neoagent.ProcessSessionEntry
  ---@return Neoagent.ProcessControllerState
  local function state(entry)
    if entry.controller then
      return entry.controller:state()
    end
    -- Reservation precedes placement callbacks. A constructor that raises
    -- without returning a controller has not acquired native resources.
    return {
      done = not entry.constructing and (entry.started or entry.discarded),
      released = not entry.constructing,
      stdin_writable = false,
      resize_supported = false,
    }
  end

  ---@param entry Neoagent.ProcessSessionEntry
  ---@param err Neoagent.Error
  local function record_cleanup(entry, err)
    cleanup_error = cleanup_error or util.copy(err)
    if on_cleanup and not vim.deep_equal(entry.cleanup_reported, err) then
      -- Target cleanup can finish before worker or staging cleanup. Report a
      -- later distinct failure while suppressing repeated copies of one fact.
      entry.cleanup_reported = util.copy(err)
      local report, diagnostic = on_cleanup, util.copy(err)
      -- Native watchdogs can report from fast callbacks. Preserve the fact
      -- now, but keep editor-facing delivery on the loop and independent of
      -- caller cancellation or disposal of the remaining controllers.
      util.schedule(function()
        pcall(report, diagnostic)
      end)
    end
  end

  ---@param published? Neoagent.ProcessSessionEntry
  local function prune(published)
    ---@type Neoagent.ProcessSessionEntry[]
    local retained = {}
    for id, entry in pairs(entries) do
      local state = state(entry)
      if state.done and not entry.complete_order then
        -- Native completion can precede the scheduled observer. Assign its
        -- retention order whenever it first becomes observable to pruning.
        completion_order = completion_order + 1
        entry.complete_order = completion_order
      end
      if state.done and state.released then
        if entry.discarded then
          entries[id] = nil
        elseif entry.committed and not entry.busy then
          retained[#retained + 1] = entry
        end
      end
    end
    if published and published.complete_order then
      -- Observe all completed entries before publishing this one as newest.
      -- IDs and completion counters never share an eviction ordering, and a
      -- newly handed-off ID cannot be removed by this same pruning pass.
      completion_order = completion_order + 1
      published.complete_order = completion_order
    end
    table.sort(retained, function(left, right)
      return assert(left.complete_order) < assert(right.complete_order)
    end)
    for index = 1, #retained - completed do
      entries[assert(retained[index]).id] = nil
    end
  end
  local function changed()
    prune()
    notification.notify()
  end
  local function status()
    prune()
    local reserved, retained, provisional, quarantined = 0, 0, 0, 0
    ---@type Neoagent.ProcessReservation[]
    local reservations = {}
    local released = true
    for _, entry in pairs(entries) do
      local state = state(entry)
      if not state.released or not entry.committed and not entry.discarded then
        reserved = reserved + 1
        local uncertain = not state.released and state.release_error ~= nil
        if uncertain then
          quarantined = quarantined + 1
        end
        reservations[#reservations + 1] = {
          session_id = entry.id,
          committed = entry.committed,
          discarded = entry.discarded,
          done = state.done,
          release = state.released and "released" or uncertain and "quarantined" or "pending",
          release_error = util.copy(state.release_error),
          cleanup_error = util.copy(state.cleanup_error),
        }
      end
      released = released and state.released
      if state.done and entry.committed then
        retained = retained + 1
      end
      if not entry.committed and not entry.discarded then
        provisional = provisional + 1
      end
    end
    table.sort(reservations, function(left, right)
      return left.session_id < right.session_id
    end)
    return {
      closed = closed,
      reserved = reserved,
      completed = retained,
      provisional = provisional,
      quarantined = quarantined,
      reservations = reservations,
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
    if entry.controller then
      local disposed, err = pcall(entry.controller.dispose, entry.controller, reason)
      if not disposed then
        record_cleanup(entry, util.normalize_error(err, "process_cleanup"))
      end
    end
    changed()
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
    local run = assert(async.current(), "Process interaction requires a managed Run")
    if run:is_cancelled() then
      error(async.cancelled_error, 0)
    end
    local controller = assert(entry.controller)
    if entry.busy then
      error(validate.error("process_session_busy", "Process session already has an interaction"), 0)
    end
    entry.busy = true
    local ok, result = pcall(function()
      if control then
        controller:control(controls.validate(control))
      end
      if run:is_cancelled() then
        error(async.cancelled_error, 0)
      end
      local result = controller:collect(wait_ms, until_exit)
      for _, event in ipairs(result.events) do
        entry.history.append(event)
      end
      result.text = entry.text(result.events, result.dropped_bytes, result.done)
      result.session_id = entry.id
      return result
    end)
    entry.busy = false
    changed()
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
        local state = state(entry)
        if release and not state.released or not release and not state.done then
          return false
        end
      end
      return true
    end
    local deadline = vim.uv.hrtime() + timeout_ms * 1000000
    while not ready() do
      local remaining = math.ceil((deadline - vim.uv.hrtime()) / 1000000)
      if remaining <= 0 then
        error(validate.error("process_cleanup", "Process session cleanup wait timed out"), 0)
      end
      notification.wait(remaining)
    end
    prune()
    if not release and cleanup_error then
      error(util.copy(cleanup_error), 0)
    end
    return true
  end
  return {
    reserve = function(_, spec)
      spec = validate.spec(spec)
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
      local entry = {
        id = next_id,
        constructing = false,
        started = false,
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
      ---@type Neoagent.ProcessSessionResult?
      local initial
      return {
        ---@async
        start = function(wait_ms)
          integer(wait_ms, 0, 30000, "Process wait budget")
          if entry.discarded or closed or run:is_cancelled() then
            error(validate.error("process_disposed", "Process admission is no longer available"), 0)
          end
          if entry.started then
            error(validate.error("process_validation", "Process admission already started"), 0)
          end
          local observer = assert(async.current(), "Process startup requires a managed Run")
          entry.started, entry.constructing = true, true
          local ok, result = pcall( ---@async
            function()
              if observer:is_cancelled() then
                error(async.cancelled_error, 0)
              end
              -- The publication owner already holds this admission before
              -- placement or startup can yield. Only observations cross the
              -- producing Run's result-delivery boundary.
              local controller = (default_factory or native.new)(spec, output_bytes, function(err)
                record_cleanup(entry, err)
              end, function()
                -- Native release can arrive from a fast callback and can
                -- make a previously completed record eligible for eviction.
                util.schedule(changed)
              end)
              entry.controller = controller
              entry.constructing = false
              if entry.discarded or closed or run:is_cancelled() or observer:is_cancelled() then
                error(validate.error("process_disposed", "Process admission was revoked during placement"), 0)
              end
              controller:start()
              return collect(entry, wait_ms, nil, true)
            end
          )
          entry.constructing = false
          -- Observe completion independently of the startup or polling Run.
          local controller = entry.controller
          if controller then
            async.run(function()
              controller:wait()
            end, {
              on_done = changed,
            })
          else
            notification.notify()
          end
          if not ok or run:is_cancelled() or observer:is_cancelled() then
            abort(entry, "Process admission failed")
            error((run:is_cancelled() or observer:is_cancelled()) and async.cancelled_error or result, 0)
          end
          if result.done then
            result.session_id = nil
          end
          initial = result
          return util.copy(result)
        end,
        commit = function()
          if entry.discarded or closed or run:is_cancelled() then
            abort(entry, "Process handoff was revoked")
            error(validate.error("process_disposed", "Process admission is no longer available"), 0)
          end
          if not initial then
            error(validate.error("process_validation", "Process admission has not completed startup"), 0)
          end
          if entry.remove_cancel then
            entry.remove_cancel()
            entry.remove_cancel = nil
          end
          if not initial.session_id then
            abort(entry, "Completed process result accepted")
            return nil
          end
          local published = not entry.committed
          entry.committed = true
          prune(published and entry or nil)
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
