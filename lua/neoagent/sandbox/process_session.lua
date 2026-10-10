local async = require("neoagent.async")
local codec = require("neoagent.rpc.process_codec")
local util = require("neoagent.util")
local validate = require("neoagent.subprocess.validate")
local worker = require("neoagent.sandbox.worker")
local M = {}

local REQUEST_GRACE_MS = 5000

---@class Neoagent.SandboxProcessTransaction
---@field run? Neoagent.Run<table, unknown>
---@field call? Neoagent.RpcCall
---@field detached boolean The observer ended; the transaction still owns its acknowledgement.
---@field peer_interrupted boolean Only collection can be stopped without abandoning a control's result.

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@param spec Neoagent.ValidatedSubprocessSpec
---@param maximum integer
---@param launch Neoagent.SandboxWorkerLaunch
---@param on_cleanup fun(error: Neoagent.Error)
---@param on_released? fun()
---@return Neoagent.ProcessController
local function controller(spec, maximum, launch, on_cleanup, on_released)
  local buffer = require("neoagent.process_sessions.buffer").new(maximum)
  local dropped = 0
  ---@type Neoagent.SandboxInvocation?
  local invocation
  ---@type uv.uv_timer_t?
  local request_timer
  ---@type uv.uv_timer_t?
  local lifetime_timer
  ---@type uv.uv_timer_t?
  local disposal_timer
  ---@type uv.uv_timer_t?
  local release_timer
  ---@type Neoagent.ProcessTargetState
  local target = {
    done = false,
    stdin_writable = spec.stdio.kind == "pty" or spec.stdio.stdin == "open",
    resize_supported = spec.stdio.kind == "pty",
  }
  ---@type Neoagent.Error?
  local failure, cleanup_error
  ---@type Neoagent.Error?
  local release_error
  local release_published = false
  -- Collection snapshots describe the target. Connection notifications
  -- acknowledge completion/release independently of request delivery.
  ---@type {received: boolean, released: boolean, pending?: Neoagent.ProcessTargetCollection}
  local completion = { received = false, released = false }
  ---@type {requested: boolean, phase: "open"|"closing"|"settled", forced: boolean}
  local shutdown = { requested = false, phase = "open", forced = false }
  -- Closing the logical invocation can detach native cleanup. Join both
  -- outcomes before publishing the worker's one cleanup transition.
  ---@type {error?: Neoagent.Error}?
  local worker_observation, close_observation
  ---@type "new"|"starting"|"finished"
  local startup = "new"
  local stdin_closed, target_requested = false, false
  ---@type Neoagent.SandboxProcessTransaction?
  local transaction
  ---@type async fun(method: string, payload: table, timeout_ms: integer): true
  local request
  local function report_cleanup(err)
    if err then
      pcall(on_cleanup, util.copy(err))
    end
  end
  local notification = async.notification()
  local changed = notification.wait
  local function released()
    return shutdown.phase == "settled"
      and (not target_requested or completion.released)
      and (not invocation or invocation:is_released())
  end
  local function notify()
    notification.notify()
    if not release_published and released() then
      release_published = true
      if on_released then
        on_released()
      end
    end
  end
  ---@async
  local function settle_detached()
    while transaction and transaction.detached do
      changed()
    end
  end
  local function completed()
    -- Collection snapshots can precede the final output notification. Only
    -- its ordered application ends target observation; worker shutdown and
    -- native release proceed independently afterward.
    return completion.received and completion.pending == nil or shutdown.phase == "settled"
  end
  local function state()
    return {
      done = completed(),
      cleanup_done = shutdown.phase == "settled",
      released = released(),
      release_error = not released() and util.copy(release_error) or nil,
      stdin_writable = not shutdown.requested and not completion.received and not target.done and target.stdin_writable,
      resize_supported = not shutdown.requested
        and not completion.received
        and not target.done
        and target.resize_supported,
      outcome = util.copy(target.outcome),
      error = util.copy(failure or target.error),
      cleanup_error = util.copy(cleanup_error or target.cleanup_error),
    }
  end
  local function remember(collection)
    -- A terminal cleanup failure is independently valid even if the later
    -- completion notification is lost. Retain its first observation so copied
    -- snapshots cannot publish the same target transition more than once.
    local first_cleanup_error = not target.cleanup_error and collection.cleanup_error or nil
    for _, event in ipairs(collection.events) do
      buffer.append(event)
    end
    dropped = dropped + collection.dropped_bytes
    target = {
      done = collection.done,
      stdin_writable = collection.stdin_writable,
      resize_supported = collection.resize_supported,
      outcome = collection.outcome,
      error = collection.error,
      cleanup_error = target.cleanup_error or collection.cleanup_error,
    }
    report_cleanup(first_cleanup_error)
  end
  local function finish_worker()
    if shutdown.phase == "settled" or not worker_observation or not close_observation then
      return
    end
    local err = worker_observation.error or close_observation.error
    if err then
      -- Native and staging failures already share the worker's cause chain.
      -- Add the independent target failure without replacing that structure.
      cleanup_error = util.copy(err)
      cleanup_error.target_cleanup_error = util.copy(target.cleanup_error)
    end
    shutdown.phase = "settled"
    if err then
      report_cleanup(cleanup_error)
    end
    notify()
    local owner = assert(invocation)
    if not owner:is_released() then
      -- The lease retains native ownership beyond bounded cleanup. Its
      -- release observation belongs here even after the target is complete.
      async.run(function()
        return owner:wait_release()
      end, {
        on_done = function(observation)
          if type(observation) == "table" and observation.ok == false then
            release_error = release_error or observation.error
          end
          notify()
        end,
      })
    end
  end
  local function observe_worker_cleanup(err)
    if not worker_observation then
      worker_observation = { error = util.copy(err) }
      finish_worker()
    end
  end
  local function close_worker_when_ready()
    if shutdown.phase ~= "open" or startup == "starting" or transaction then
      return
    end
    if not shutdown.forced and target_requested and not completion.released then
      return
    end
    shutdown.phase = "closing"
    close_timer(lifetime_timer)
    close_timer(request_timer)
    close_timer(disposal_timer)
    close_timer(release_timer)
    if not invocation then
      shutdown.phase = "settled"
      return
    end
    local owner = invocation
    async.run(function()
      return { error = owner:close(shutdown.forced) }
    end, {
      error_kind = "protocol",
      on_done = function(result)
        close_observation = { error = result.error }
        finish_worker()
      end,
    })
  end
  -- Request settlement is the boundary for applying final target output.
  -- Only then can the independently acknowledged release permit shutdown.
  local function advance()
    if not transaction and completion.pending then
      local terminal = completion.pending
      completion.pending = nil
      remember(terminal)
    end
    close_worker_when_ready()
    notify()
  end
  local function stop_accepting()
    shutdown.requested = true
    if not target.done then
      failure = failure or validate.error("process_disposed", "Process controller was disposed")
    end
  end
  local function force(reason)
    if shutdown.forced or shutdown.phase == "settled" then
      return
    end
    shutdown.forced = true
    if target_requested and not completion.released then
      release_error = util.with_cause(
        validate.error("process_cleanup", "Target release could not be confirmed; capacity remains reserved"),
        failure
      )
      cleanup_error = cleanup_error or release_error
      report_cleanup(cleanup_error)
    end
    stop_accepting()
    if invocation then
      invocation:dispose(reason)
      invocation.connection:abort()
    end
    advance()
  end
  local function supervise_stop(reason)
    if not disposal_timer or completion.received or shutdown.forced or shutdown.phase ~= "open" then
      return
    end
    -- Repeated stop requests share the first deadline. Match the target's
    -- configured TERM grace, then allow native cleanup and RPC delivery.
    if not disposal_timer:is_active() then
      vim.uv.update_time()
      local armed = disposal_timer:start(spec.kill_grace_ms + validate.REAP_MS + REQUEST_GRACE_MS, 0, function()
        force(reason)
      end)
      if not armed then
        force("Could not supervise retained process termination")
      end
    end
  end
  local function dispose(reason)
    if shutdown.requested or shutdown.phase ~= "open" then
      return
    end
    stop_accepting()
    if completion.received and target.done then
      advance()
      return
    end
    supervise_stop("Retained process disposal was not acknowledged")
    if transaction and transaction.run then
      transaction.run:cancel()
    end
    -- Stop the target while its worker can still own signalling and reaping.
    -- Losing the worker first cannot establish release of another POSIX group.
    async.run(function()
      while startup == "starting" or transaction do
        changed()
      end
      if shutdown.phase ~= "open" or shutdown.forced then
        return
      end
      if target_requested and not completion.released then
        assert(invocation).connection:wait_cancelled()
        request("process_dispose", {}, REQUEST_GRACE_MS)
      end
      advance()
    end, {
      on_done = function(result)
        if result.ok == false then
          force("Could not dispose retained target through its worker")
        end
      end,
    })
    notify()
  end
  launch.on_failure = function(err)
    failure = failure or err
    force("retained process channel failed")
  end
  launch.on_event = function(message)
    if message.name == codec.RELEASED then
      assert(completion.received and not completion.released, "invalid process release event")
      assert(
        require("neoagent.validation").object(message.value) and next(message.value) == nil,
        "invalid process release acknowledgement"
      )
      completion.released = true
      advance()
      return
    end
    assert(message.name == codec.COMPLETE and not completion.received, "invalid process completion event")
    local collection = codec.collection(message.value, maximum)
    assert(collection.done, "process completion did not settle")
    completion.received = true
    -- Retire each satisfied target deadline at its acknowledgement boundary,
    -- including when native release must continue after cleanup failure.
    close_timer(lifetime_timer)
    close_timer(disposal_timer)
    if not transaction and request_timer and not request_timer:is_closing() then
      request_timer:stop()
    end
    -- Only connection notifications settle ownership. A collect response can
    -- observe release before an earlier completion notification is delivered.
    completion.released = collection.released
    if not completion.released then
      -- Release retries can legitimately outlive cleanup observation. Probe
      -- worker responsiveness independently instead of timing out that retry.
      vim.uv.update_time()
      assert(assert(release_timer):start(0, REQUEST_GRACE_MS, function()
        if transaction or shutdown.forced or shutdown.phase ~= "open" then
          return
        end
        async.run(function()
          request("process_ping", {}, REQUEST_GRACE_MS)
        end, {
          on_done = function(result)
            if result.ok == false then
              force("Retained worker stopped responding during native release")
            end
          end,
        })
      end))
    end
    -- Receipt can precede response validation. advance() applies these bytes
    -- only after the transaction's bytes, including for a detached observer.
    completion.pending = collection
    advance()
  end
  ---@param pending Neoagent.SandboxProcessTransaction
  ---@param result Neoagent.RunResult<table>
  local function settle_request(pending, result)
    if request_timer and not request_timer:is_closing() then
      request_timer:stop()
    end
    transaction = nil
    if
      result.ok == false
      and result.error.kind ~= "process"
      and not ((shutdown.requested or pending.peer_interrupted) and result.error.kind == "cancelled")
    then
      failure = failure or result.error
      force("retained process request failed")
    end
    if target.done and not completion.received and not shutdown.requested then
      assert(request_timer):start(REQUEST_GRACE_MS, 0, function()
        failure = failure or validate.error("protocol", "Retained process completion was not acknowledged")
        force("retained process completion deadline expired")
      end)
    end
    advance()
  end
  ---@async
  request = function(method, payload, timeout_ms)
    if transaction then
      error(validate.error("process_session_busy", "A retained process request is still completing"), 0)
    end
    if
      shutdown.forced
      or shutdown.phase ~= "open"
      or shutdown.requested and method ~= "process_dispose" and method ~= "process_ping"
    then
      error(validate.error("process_terminal", "Retained process no longer accepts requests"), 0)
    end
    vim.uv.update_time()
    assert(assert(request_timer):start(timeout_ms, 0, function()
      failure = failure or validate.error("process_supervision", "Retained process worker stopped responding")
      force("retained process request deadline expired")
    end))
    ---@type Neoagent.SandboxProcessTransaction
    local pending = { detached = false, peer_interrupted = false }
    transaction = pending
    local observer = assert(async.current())
    local remove_cancel = observer:on_cancel(function()
      -- Every detached observer leaves settlement with this transaction.
      -- Controls retain execution acknowledgements; collection alone asks
      -- the peer to stop waiting and return any output already consumed.
      pending.detached = true
      if method == "process_collect" then
        pending.peer_interrupted = true
        if pending.call then
          pending.call:interrupt()
        end
      end
    end)
    -- This transaction owns response validation and received output even if
    -- its caller stops observing. Cancellation never consumes unread output.
    local active = async.run(function()
      pending.call = assert(invocation).connection:start_request(method, payload, {
        on_dispatch = method == "process_start" and function()
          -- Encoding and aggregate limits can reject the request locally.
          -- Once transport dispatch begins, failed writes may be partial.
          target_requested = true
        end or nil,
      })
      if pending.peer_interrupted then
        pending.call:interrupt()
      end
      local value = pending.call:result()
      if method == "process_collect" then
        remember(codec.collection(value, maximum))
      else
        assert(require("neoagent.validation").object(value) and next(value) == nil, "invalid process acknowledgement")
        if method == "process_control" and payload.kind == "close_stdin" then
          stdin_closed = true
          target.stdin_writable = false
        elseif method == "process_control" and payload.kind == "terminate" then
          supervise_stop("Retained process termination was not completed")
        end
      end
    end, {
      error_kind = "protocol",
      on_done = function(result)
        settle_request(pending, result)
      end,
    })
    pending.run = active
    local ok, value = pcall(async.await, function(waiter)
      active:_listen(function(result)
        if result.ok == false then
          waiter.reject(result.error)
        else
          waiter.resolve(true)
        end
      end)
    end)
    remove_cancel()
    if not ok then
      -- The transport domain classifies request failures for supervision.
      -- Expose the native semantic error after that arbitration so placement
      -- does not change the caller's process-control error contract.
      local err = util.normalize_error(value, "protocol")
      if err.kind == "process" and err.code then
        err.kind = err.code
      end
      error(err, 0)
    end
    return true
  end
  return {
    ---@async
    start = function()
      assert(startup == "new", "process controller already started")
      startup = "starting"
      local ok, err = pcall(function()
        if shutdown.requested then
          error(validate.error("process_disposed", "Process controller is disposed"), 0)
        end
        request_timer = assert(vim.uv.new_timer())
        disposal_timer = assert(vim.uv.new_timer())
        release_timer = assert(vim.uv.new_timer())
        if spec.timeout_ms then
          lifetime_timer = assert(vim.uv.new_timer())
        end
        invocation = worker.start(launch, observe_worker_cleanup)
        if shutdown.requested then
          error(async.cancelled_error, 0)
        end
        invocation:open({})
        request("process_start", { spec = spec, output_bytes = maximum }, validate.START_MS + REQUEST_GRACE_MS)
        if lifetime_timer and not completion.received and not shutdown.requested then
          -- The worker owns the actual target deadline. This independent
          -- watchdog contains a stalled worker without inventing target exit.
          vim.uv.update_time()
          lifetime_timer:start(
            assert(spec.timeout_ms) + spec.kill_grace_ms + validate.REAP_MS + REQUEST_GRACE_MS,
            0,
            function()
              failure = failure
                or validate.error("process_supervision", "Retained worker exceeded its process deadline")
              force("retained process lifetime watchdog expired")
            end
          )
        end
      end)
      startup = "finished"
      notify()
      if not ok then
        failure = failure or util.normalize_error(err, "process_start")
        dispose("retained process admission failed")
        advance()
        error(failure, 0)
      end
      advance()
      return true
    end,
    state = state,
    ---@async
    collect = function(_, wait_ms, until_exit)
      local deadline = vim.uv.hrtime() + wait_ms * 1000000
      settle_detached()
      if buffer.empty() and not shutdown.requested and not target.done and not completed() then
        local remaining = math.max(0, math.ceil((deadline - vim.uv.hrtime()) / 1000000))
        request(
          "process_collect",
          { wait_ms = remaining, until_exit = until_exit == true },
          remaining + REQUEST_GRACE_MS
        )
      end
      while not completed() and not shutdown.requested and (until_exit or buffer.empty()) do
        local remaining = math.ceil((deadline - vim.uv.hrtime()) / 1000000)
        if remaining <= 0 then
          break
        end
        changed(remaining)
      end
      local result = state()
      local events, lost = buffer.take()
      result.events = events
      result.dropped_bytes = dropped + lost
      dropped = 0
      return result
    end,
    ---@async
    control = function(_, command)
      settle_detached()
      if
        not shutdown.requested
        and (command.kind == "terminate" and target.done or command.kind == "close_stdin" and stdin_closed)
      then
        return true
      end
      if target.done then
        error(validate.error("process_terminal", "Process no longer accepts controls"), 0)
      end
      request("process_control", command, REQUEST_GRACE_MS)
      return true
    end,
    ---@async
    wait_cleanup = function()
      while shutdown.phase ~= "settled" do
        changed()
      end
      return true
    end,
    dispose = function(_, reason)
      dispose(reason)
    end,
  }
end

-- Resolve authority once, outside the session manager and local process API.
-- The returned factory cannot observe later sandbox or environment changes.
---@generic C
---@param placement Neoagent.SandboxPlacement<C>
---@param context C
---@return Neoagent.ProcessControllerFactory
function M.factory(placement, context)
  local paths = placement.paths
  local profile = placement.resolve(context)
  local environment = placement.environment(profile)
  local normalize = require("neoagent.subprocess.environment").normalize
  return function(spec, maximum, on_cleanup, on_released)
    spec = validate.spec(spec)
    if not paths.is_absolute(spec.cwd) then
      -- Resolve relative cwd in the admitting process. Applying it again in
      -- a worker already launched there would change the target directory.
      local cwd, _, code = vim.uv.fs_realpath(spec.cwd)
      if not cwd then
        error(
          validate.error("process_start", "Could not resolve process working directory (" .. (code or "unknown") .. ")"),
          0
        )
      end
      spec.cwd = cwd
    end
    local selected = spec.environment
    local values = normalize({ inherit = false, set = (not selected or selected.inherit) and environment or {} })
    for name, value in pairs(normalize({ inherit = false, set = selected and selected.set or {} })) do
      values[name] = value
    end
    spec.environment = { inherit = false, set = values }
    return controller(spec, maximum, {
      platform = placement.platform,
      profile = util.copy(profile),
      paths = paths,
      services = placement.services,
      nvim = placement.nvim,
      cwd = spec.cwd,
      environment = util.copy(environment),
      mode = "process",
      on_failure = function() end,
    }, on_cleanup, on_released)
  end
end

return M
