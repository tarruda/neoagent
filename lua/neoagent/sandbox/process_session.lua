local async = require("neoagent.async")
local codec = require("neoagent.rpc.process_codec")
local util = require("neoagent.util")
local validate = require("neoagent.subprocess.validate")
local worker = require("neoagent.sandbox.worker")
local M = {}

local REQUEST_GRACE_MS = 5000

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
---@return Neoagent.ProcessController
local function controller(spec, maximum, launch, on_cleanup)
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
  ---@type Neoagent.ProcessControllerState
  local target = {
    done = false,
    released = false,
    stdin_writable = spec.stdio.kind == "pty" or spec.stdio.stdin == "open",
    resize_supported = spec.stdio.kind == "pty",
  }
  ---@type Neoagent.Error?
  local failure, cleanup_error
  -- Collection snapshots describe the target. Connection notifications
  -- acknowledge completion/release independently of request delivery.
  ---@type {received: boolean, released: boolean, pending?: Neoagent.ProcessCollection}
  local completion = { received = false, released = false }
  ---@type {requested: boolean, started: boolean, settled: boolean, forced: boolean}
  local shutdown = { requested = false, started = false, settled = false, forced = false }
  local started, starting = false, false
  local stdin_closed, target_requested = false, false
  ---@type {run?: Neoagent.Run<table, unknown>, call?: Neoagent.RpcCall, interrupted: boolean}?
  local transaction
  ---@type async fun(method: string, payload: table, timeout_ms: integer): true
  local request
  local function report_cleanup(err)
    if err then
      pcall(on_cleanup, util.copy(err))
    end
  end
  local function worker_cleanup(err)
    if err then
      cleanup_error = util.with_cause(err, target.cleanup_error)
      report_cleanup(cleanup_error)
    end
  end
  ---@type table<Neoagent.AwaitCallbacks<true>, fun()>
  local waiters = {}
  local function notify()
    local current = waiters
    waiters = {}
    for waiter, cleanup in pairs(current) do
      cleanup()
      waiter.resolve(true)
    end
  end
  ---@async
  local function changed(milliseconds)
    return async.await(function(waiter)
      local timer
      local function cleanup()
        waiters[waiter] = nil
        close_timer(timer)
      end
      if milliseconds then
        timer = assert(vim.uv.new_timer())
        vim.uv.update_time()
        timer:start(milliseconds, 0, function()
          cleanup()
          waiter.resolve(true)
        end)
      end
      waiters[waiter] = cleanup
      return cleanup
    end)
  end
  ---@async
  local function settle_poll()
    while transaction and transaction.interrupted do
      changed()
    end
  end
  local function completed()
    -- Collection snapshots can precede the final output notification. Only
    -- its ordered application ends target observation; worker shutdown and
    -- native release proceed independently afterward.
    return completion.received and completion.pending == nil or shutdown.settled
  end
  local function state()
    return {
      done = completed(),
      released = shutdown.settled
        and (not target_requested or completion.released)
        and (not invocation or invocation.lease:is_released()),
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
    for _, event in ipairs(collection.events) do
      buffer.append(event)
    end
    dropped = dropped + collection.dropped_bytes
    target = {
      done = collection.done,
      released = collection.released,
      stdin_writable = collection.stdin_writable,
      resize_supported = collection.resize_supported,
      outcome = collection.outcome,
      error = collection.error,
      cleanup_error = collection.cleanup_error,
    }
    report_cleanup(target.cleanup_error)
    notify()
  end
  local function finish()
    if shutdown.started or shutdown.settled or starting or transaction then
      return
    end
    if not shutdown.forced and target_requested and not completion.released then
      return
    end
    shutdown.started = true
    close_timer(lifetime_timer)
    close_timer(request_timer)
    close_timer(disposal_timer)
    close_timer(release_timer)
    if not invocation then
      shutdown.settled = true
      notify()
      return
    end
    local owner = invocation
    async.run(function()
      return { error = owner:close(shutdown.forced) }
    end, {
      error_kind = "protocol",
      on_done = function(result)
        worker_cleanup(result.error)
        shutdown.settled = true
        notify()
      end,
    })
  end
  local function force(reason)
    if shutdown.forced or shutdown.settled then
      return
    end
    shutdown.forced, shutdown.requested = true, true
    if target_requested and not completion.released then
      cleanup_error = cleanup_error
        or util.with_cause(
          validate.error("process_cleanup", "Target release could not be confirmed; capacity remains reserved"),
          failure
        )
      report_cleanup(cleanup_error)
    end
    if not target.done then
      failure = failure or validate.error("process_disposed", "Process controller was disposed")
    end
    if invocation then
      invocation:dispose(reason)
      invocation.connection:abort()
    end
    finish()
    notify()
  end
  local function supervise_stop(reason)
    if not disposal_timer or completion.received or shutdown.forced or shutdown.started or shutdown.settled then
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
    if shutdown.requested or shutdown.settled or shutdown.started then
      return
    end
    shutdown.requested = true
    if not target.done then
      failure = failure or validate.error("process_disposed", "Process controller was disposed")
    end
    if completion.received and target.done then
      finish()
      return
    end
    supervise_stop("Retained process disposal was not acknowledged")
    if transaction and transaction.run then
      transaction.run:cancel()
    end
    -- Stop the target while its worker can still own signalling and reaping.
    -- Losing the worker first cannot establish release of another POSIX group.
    async.run(function()
      while starting or transaction do
        changed()
      end
      if shutdown.started or shutdown.settled or shutdown.forced then
        return
      end
      if target_requested and not completion.released then
        assert(invocation).connection:wait_cancelled()
        request("process_dispose", {}, REQUEST_GRACE_MS)
      end
      finish()
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
      finish()
      notify()
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
        if transaction or shutdown.forced or shutdown.started or shutdown.settled then
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
    if transaction then
      -- Receipt precedes the request coroutine's response validation. Keep
      -- final bytes after that response's bytes, including cancelled polls.
      completion.pending = collection
    else
      remember(collection)
      finish()
    end
  end
  ---@async
  request = function(method, payload, timeout_ms)
    if transaction then
      error(validate.error("process_session_busy", "A retained process request is still completing"), 0)
    end
    if
      shutdown.forced
      or shutdown.started
      or shutdown.settled
      or shutdown.requested and method ~= "process_dispose" and method ~= "process_ping"
    then
      error(validate.error("process_terminal", "Retained process no longer accepts requests"), 0)
    end
    vim.uv.update_time()
    assert(assert(request_timer):start(timeout_ms, 0, function()
      failure = failure or validate.error("process_supervision", "Retained process worker stopped responding")
      force("retained process request deadline expired")
    end))
    ---@type {run?: Neoagent.Run<table, unknown>, call?: Neoagent.RpcCall, interrupted: boolean}
    local pending = { interrupted = false }
    transaction = pending
    local observer = assert(async.current())
    local remove_cancel = observer:on_cancel(function()
      if method == "process_collect" then
        pending.interrupted = true
        if pending.call then
          pending.call:interrupt()
        end
      end
    end)
    -- This transaction owns response validation and received output even if
    -- its caller stops observing. Cancellation never consumes unread output.
    local active = async.run(function()
      if method == "process_start" then
        target_requested = true
      end
      pending.call = assert(invocation).connection:start_request(method, payload)
      if pending.interrupted then
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
        if request_timer and not request_timer:is_closing() then
          request_timer:stop()
        end
        transaction = nil
        if
          result.ok == false
          and result.error.kind ~= "process"
          and not ((shutdown.requested or pending.interrupted) and result.error.kind == "cancelled")
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
        if completion.pending then
          local terminal = completion.pending
          completion.pending = nil
          remember(terminal)
        end
        finish()
        notify()
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
      error(value, 0)
    end
    return true
  end
  return {
    ---@async
    start = function()
      assert(not started, "process controller already started")
      started, starting = true, true
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
        local connection, lease = worker.start(launch)
        invocation = require("neoagent.sandbox.invocation").new(connection, lease, worker_cleanup)
        if shutdown.requested then
          error(async.cancelled_error, 0)
        end
        invocation:open({})
        request("process_start", { spec = spec, output_bytes = maximum }, REQUEST_GRACE_MS)
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
      starting = false
      notify()
      if not ok then
        failure = failure or util.normalize_error(err, "process_start")
        dispose("retained process admission failed")
        finish()
        error(failure, 0)
      end
      finish()
      return true
    end,
    state = state,
    ---@async
    collect = function(_, wait_ms, until_exit)
      local deadline = vim.uv.hrtime() + wait_ms * 1000000
      settle_poll()
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
      require("neoagent.process_sessions.local").validate_control(command)
      settle_poll()
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
    wait = function()
      while not completed() do
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
---@class Neoagent.SandboxProcessOptions<C>: Neoagent.SandboxCheckServices
---@field profile Neoagent.SandboxProfileSource<C>
---@field platform Neoagent.SandboxPlatform<C>
---@field paths? Neoagent.SandboxPaths
---@field environ? fun(): table<string, string>

---@generic C
---@param options Neoagent.SandboxProcessOptions<C>
---@param context C
---@return Neoagent.ProcessControllerFactory
function M.factory(options, context)
  local paths = options.paths or options.platform.paths or require("neoagent.sandbox.path").posix
  local services = {
    fs = options.fs or require("neoagent.fs"),
    nvim = options.nvim,
    capabilities = util.copy(options.capabilities or {}),
    start_worker = options.start_worker,
  }
  local profile = require("neoagent.sandbox.profile").resolve(options.profile, context, { paths = paths })
  if options.platform.compile then
    profile = options.platform.compile(profile, context, services)
  end
  local environ = options.environ or function()
    return assert(vim.uv.os_environ())
  end
  local environment = worker.environment(profile, environ(), paths)
  local normalize = require("neoagent.subprocess.environment").normalize
  local platform, nvim = options.platform, options.nvim
  return function(spec, maximum, on_cleanup)
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
      platform = platform,
      profile = util.copy(profile),
      paths = paths,
      services = services,
      nvim = nvim,
      cwd = spec.cwd,
      environment = util.copy(environment),
      mode = "process",
      on_failure = function() end,
    }, on_cleanup)
  end
end

return M
