local assert = require("luassert")
local async = require("neoagent.async")
local helper = require("tests.helpers.subprocess")
local sessions = require("neoagent.process_sessions")
local workers = require("neoagent.rpc.worker_lease")
local remote = require("neoagent.sandbox.process_session")

-- Exercise the real worker, framing, controller and native launch without
-- requiring native sandbox activation in the fast suite. Enforcement is
-- covered separately on each native sandbox host.
describe("retained process RPC", function()
  if jit.os == "Windows" then
    pending("POSIX commands; native Windows coverage uses portable commands")
    return
  end
  ---@type Neoagent.ProcessSessions
  local owner
  ---@type Neoagent.ProcessControllerFactory
  local factory
  ---@type Neoagent.WorkerLease[]
  local leases
  ---@type string?
  local reap_gate
  ---@type uv.uv_timer_t?
  local reap_delay
  local hold_completion = false
  local hold_release, fail_worker_cleanup = false, false
  local stall_worker, quarantined = false, false
  ---@type fun(message: table)?
  local inspect_request
  ---@type (fun(message: table, deliver: fun()): boolean?)?
  local intercept_reply
  ---@type Neoagent.AwaitCallbacks<true>?
  local finish_worker_wait
  local hold_worker_wait = false
  local hold_worker_release = false
  local fail_staging_cleanup = false
  ---@type Neoagent.AwaitCallbacks<true>?
  local finish_worker_release
  ---@type fun()?
  local worker_created
  ---@type string?
  local exit_gate
  ---@type Neoagent.Run<unknown, unknown>[]
  local pending = {}
  ---@type fun()?
  local deliver_completion
  ---@type fun()?
  local deliver_release
  before_each(function()
    leases = {}
    owner = sessions.new({ output_bytes = 64, capacity = 2 }, nil, function(spec, maximum, cleanup, released)
      return factory(spec, maximum, cleanup, released)
    end)
    local root = assert(vim.uv.cwd())
    factory = remote.factory(require("neoagent.sandbox.placement").new({
      profile = {
        id = "retained-test",
        filesystem = { default = "read", entries = {} },
        network = "restricted",
        environment = { clear = false, inherit = {}, set = {} },
      },
      platform = {
        name = "test",
        check = function()
          return { ok = true, platform = "test" }
        end,
        start_worker = function(request)
          if vim.env.NEOAGENT_COVERAGE == "1" then
            table.insert(request.argv, 2, "--cmd")
            table.insert(request.argv, 3, ("lua dofile(%q)"):format(root .. "/tests/fixtures/coverage_worker.lua"))
          end
          if reap_gate then
            request.env.NEOAGENT_TEST_REAP_GATE = reap_gate
            request.env.NEOAGENT_WORKER_FILE = root .. "/tests/fixtures/process_reap_worker.lua"
            for index, argument in ipairs(request.argv) do
              if argument == root .. "/scripts/tool_worker.lua" then
                request.argv[index] = request.env.NEOAGENT_WORKER_FILE
              end
            end
          end
          do
            local deliver = assert(request.on_stdout)
            local decoder = require("neoagent.ipc.framing").new({ max_frame = 1024 * 1024, on_value = function(message)
              local function defer_release(notification)
                local bytes = require("neoagent.rpc.protocol").encode(notification)
                deliver_release = function() deliver_release = nil; deliver(bytes) end
              end
              if hold_release and message.type == "event" then
                if message.name == "process_released" then
                  defer_release(message)
                  return
                elseif message.name == "process_complete" then
                  if message.value.released then
                    -- Separate an already-confirmed native release from its
                    -- completion snapshot, as asynchronous close callbacks do.
                    defer_release({ type = "event", call_id = message.call_id, sequence = message.sequence + 1,
                      name = "process_released", value = {} })
                  end
                  message.value.released = false
                end
              end
              local function forward() deliver(require("neoagent.rpc.protocol").encode(message)) end
              if intercept_reply and intercept_reply(message, forward) then return end
              if hold_completion and message.type == "event" and message.name == "process_complete" then
                deliver_completion = forward
              else
                forward()
              end
            end })
            request.on_stdout = function(bytes) decoder:feed(bytes) end
          end
          local lease = workers.start(request)
          if hold_worker_release then
            local is_released, wait_release = lease.is_released, lease.wait_release
            function lease:is_released()
              return not hold_worker_release and is_released(self)
            end
            function lease:wait_release()
              wait_release(self)
              if hold_worker_release then
                async.await(function(done) finish_worker_release = done end)
              end
              return true
            end
          end
          local write = lease.write
          local incoming = require("neoagent.rpc.protocol").decoder(function(message)
            if inspect_request then inspect_request(message) end
          end)
          function lease:write(bytes)
            incoming:feed(bytes)
            if stall_worker then return true end
            return write(self, bytes)
          end
          if fail_worker_cleanup or hold_worker_wait then
            local wait = lease.wait
            function lease:wait()
              local result = wait(self)
              if hold_worker_wait then
                async.await(function(done) finish_worker_wait = done end)
              end
              if fail_worker_cleanup then
                result.cleanup_error = require("neoagent.util").error("process_cleanup", "Worker staging cleanup failed")
              end
              return result
            end
          end
          leases[#leases + 1] = lease
          if worker_created then worker_created() end
          if fail_staging_cleanup then
            local relay = require("neoagent.sandbox.relay_lease").new({
              cleanup = function() return nil, "staging removal denied" end,
            })
            relay:attach(lease)
            local native_protocol = require("neoagent.sandbox.protocol")
            relay:feed(native_protocol.encode({ v = 1, type = "ready" }))
            async.run(function()
              local result = lease:wait()
              relay:feed(native_protocol.encode({ v = 1, type = "exit", code = result.code or 0, signal = result.signal or 0 }))
              relay:host_exited(result)
            end)
            -- Keep this test's real RPC transport; the relay owns staging
            -- completion and release exactly as on the native platform.
            return {
              write = function(_, bytes) return lease:write(bytes) end,
              close_stdin = function() return lease:close_stdin() end,
              terminate = function(_, reason) lease:terminate(reason) end,
              dispose = function(_, reason) relay:dispose(reason) end,
              ---@async
              wait = function() return relay:wait() end,
              is_released = function() return relay:is_released() end,
              ---@async
              wait_release = function() return relay:wait_release() end,
            }
          end
          return lease
        end,
      },
      nvim = vim.env.NEOAGENT_NVIM,
    }), { context = { workspace = { root = root, cwd = root } } })
  end)
  after_each(function()
    hold_completion, deliver_completion = false, nil
    hold_release, fail_worker_cleanup = false, false
    stall_worker = false
    inspect_request, intercept_reply = nil, nil
    hold_worker_wait = false
    hold_worker_release = false
    fail_staging_cleanup = false
    if finish_worker_release then finish_worker_release.resolve(true); finish_worker_release = nil end
    worker_created = nil
    if finish_worker_wait then finish_worker_wait.resolve(true); finish_worker_wait = nil end
    for _, run in ipairs(pending) do run:cancel(); helper.wait(run) end
    pending = {}
    if deliver_release then deliver_release() end
    if reap_delay and not reap_delay:is_closing() then reap_delay:stop(); reap_delay:close() end
    reap_delay = nil
    if reap_gate then vim.fn.delete(reap_gate); reap_gate = nil end
    owner:close("test complete")
    helper.complete(function()
      return owner:wait_cleanup(5000)
    end)
    if not quarantined then
      assert.is_true(helper.complete(function()
        return owner:wait_release(5000)
      end), vim.inspect(owner:status()))
    end
    quarantined = false
    for _, lease in ipairs(leases) do
      assert.is_true(helper.complete(function() return lease:wait_release() end))
      assert.is_true(lease:is_released())
    end
    if exit_gate then vim.fn.delete(exit_gate); exit_gate = nil end
  end)
  local function start(command, stdio, wait_ms)
    return helper.success(function()
      return helper.admit(owner, helper.spec(command, { stdio = stdio }), wait_ms or 0)
    end)
  end
  local function poll(id, command, wait_ms)
    return helper.success(function()
      return owner:interact(id, wait_ms or 1000, command)
    end)
  end

  it("retains one worker across handoff and later pipe interactions", function()
    local admission = start("cat", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    assert.are.equal(1, #leases)
    assert.is_false(assert(leases[1]):is_released())
    assert.are.equal("first\n", poll(id, { kind = "write", data = "first\n" }).text)
    assert.are.equal("second\n", poll(id, { kind = "write", data = "second\n" }).text)
    local final = poll(id, { kind = "close_stdin" })
    for _ = 1, 5 do
      if final.done then
        break
      end
      final = poll(id)
    end
    assert.is_true(final.done)
    assert.are.equal(0, assert(final.outcome).code)
    assert.is_nil(final.error, vim.inspect(final))
    assert.is_nil(final.cleanup_error, vim.inspect(final))
    assert.are.equal(1, #leases)
  end)

  it("releases a controller disposed before native startup without creating a worker", function()
    local controller = factory(helper.spec("exit 0"), 64, function() end)
    controller:dispose("admission revoked")
    local result = helper.complete(function() return controller:start() end)
    assert.are.equal("process_disposed", assert(result.error).code)
    assert.is_true(helper.complete(function() return controller:wait_cleanup() end))
    assert.is_true(controller:state().released)
    local controlled = helper.complete(function() return controller:control({ kind = "write", data = "late" }) end)
    assert.are.equal("process_terminal", assert(controlled.error).code)
    assert.are.equal(0, #leases)
  end)

  it("rejects concurrent controller requests without disturbing the active poll", function()
    ---@type Neoagent.ProcessController?
    local controller
    owner = sessions.new({ output_bytes = 64 }, nil, function(spec, maximum, on_cleanup, on_released)
      controller = factory(spec, maximum, on_cleanup, on_released)
      return controller
    end)
    local admission = helper.success(function()
      return helper.admit(owner, helper.spec("cat", { stdio = { kind = "pipes", stdin = "open" } }), 0)
    end)
    local id = assert(admission.commit())
    local collecting = false
    inspect_request = function(message)
      if message.type == "request" and message.method == "process_collect" then collecting = true end
    end
    local waiting = async.run(function() return assert(controller):collect(30000) end)
    pending[#pending + 1] = waiting
    assert(vim.wait(1000, function() return collecting end, 5))
    local rejected = helper.complete(function() return assert(controller):control({ kind = "write", data = "denied" }) end)
    assert.are.equal("process_session_busy", assert(rejected.error).code)
    waiting:cancel()
    assert.are.equal("cancelled", assert(helper.wait(waiting).error).kind)
    assert.are.equal("alive\n", poll(id, { kind = "write", data = "alive\n" }).text)
  end)

  it("preserves its target when an already cancelled Run requests a poll", function()
    local admission = start("cat", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    local result = helper.complete(function()
      assert(async.current()):cancel()
      return owner:interact(id, 30000)
    end)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal("alive\n", poll(id, { kind = "write", data = "alive\n" }).text)
  end)

  it("settles a detached control acknowledgement before the next interaction", function()
    local admission = start("cat", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    ---@type integer?
    local control_request
    local cancellations = 0
    inspect_request = function(message)
      if message.type == "request" and message.method == "process_control" and not control_request then
        control_request = message.request_id
      elseif message.type == "cancel" then
        cancellations = cancellations + 1
      end
    end
    ---@type fun()?
    local acknowledge
    intercept_reply = function(message, deliver)
      if message.type == "response" and message.request_id == control_request then
        acknowledge = deliver
        return true
      end
    end
    local first = async.run(function() return owner:interact(id, 1000, { kind = "write", data = "first\n" }) end)
    pending[#pending + 1] = first
    assert(vim.wait(2000, function() return acknowledge ~= nil end, 5))
    first:cancel()
    assert.are.equal("cancelled", assert(helper.wait(first).error).kind)
    local second = async.run(function() return owner:interact(id, 1000, { kind = "write", data = "second\n" }) end)
    pending[#pending + 1] = second
    local settled_early = second:is_done()
    intercept_reply = nil
    assert(acknowledge)()
    local result = helper.wait(second)
    assert.is_false(settled_early, vim.inspect(result))
    assert.is_nil(result.error, vim.inspect(result))
    assert.are.equal(0, cancellations, "an accepted control must retain its acknowledgement")
    local text = result.text
    assert(vim.wait(2000, function()
      if text == "first\nsecond\n" then return true end
      text = text .. poll(id, nil, 100).text
      return text == "first\nsecond\n"
    end, 5), text)
  end)

  it("interrupts a poll cancelled during dispatch without ending its target", function()
    local admission = start("cat", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    ---@type Neoagent.Run<Neoagent.ProcessSessionResult, unknown>?
    local observing
    inspect_request = function(message)
      if message.type == "request" and message.method == "process_collect" then
        inspect_request = nil
        assert(observing):cancel()
      end
    end
    local waiting = async.run(function(run)
      observing = run
      return owner:interact(id, 30000)
    end)
    pending[#pending + 1] = waiting
    assert.are.equal("cancelled", assert(helper.wait(waiting).error).kind)
    assert.are.equal("kept\n", poll(id, { kind = "write", data = "kept\n" }).text)
    assert.are.equal("alive\n", poll(id, { kind = "write", data = "alive\n" }).text)
  end)

  it("releases a worker created while its owner revokes admission", function()
    worker_created = function() owner:close("admission revoked") end
    local result = helper.complete(function() return helper.admit(owner, helper.spec("exit 0"), 0) end)
    assert.are.equal("process_disposed", assert(result.error).code)
    assert.is_true(helper.complete(function() return owner:wait_release(5000) end))
    assert.are.equal(1, #leases)
    assert.are.equal(0, owner:status().reserved)
  end)

  it("reports cwd resolution failure before creating a remote worker", function()
    local realpath = vim.uv.fs_realpath
    vim.uv.fs_realpath = function(path)
      if path == ".." then return nil, "access denied", "EACCES" end
      return realpath(path)
    end
    local result = helper.complete(function()
      return helper.admit(owner, helper.spec("exit 0", { cwd = ".." }), 0)
    end)
    vim.uv.fs_realpath = realpath
    assert.are.equal("process_start", assert(result.error).code)
    assert.matches("EACCES", assert(result.error).message, 1, true)
    assert.are.equal(0, #leases)
    assert.are.equal(0, owner:status().reserved)
  end)

  it("completes without a background ID when the initial wait observes exit", function()
    local admission = start("printf complete", nil, 2000)
    assert.is_true(admission.result.done, vim.inspect(admission.result))
    assert.are.equal("complete", admission.result.text)
    assert.are.equal(0, assert(admission.result.outcome).code)
    assert.is_nil(admission.commit())
  end)

  it("preserves idempotent close and termination after the remote target completes", function()
    local admission = start("cat", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    poll(id, { kind = "close_stdin" })
    assert.is_true(helper.complete(function() return owner:wait_release(5000) end))
    assert.is_true(poll(id, { kind = "close_stdin" }, 0).done)
    assert.is_true(poll(id, { kind = "terminate", reason = "already finished" }, 0).done)
    local rejected = helper.complete(function()
      return owner:interact(id, 0, { kind = "write", data = "late" })
    end)
    assert.are.equal("process_terminal", assert(rejected.error).code)
  end)

  it("applies explicit target environment overrides to the captured worker environment", function()
    local admission = helper.success(function()
      return helper.admit(owner, helper.spec("printf '%s' \"$NEOAGENT_RETAINED_OVERRIDE\"", {
        environment = { inherit = true, set = { NEOAGENT_RETAINED_OVERRIDE = "selected" } },
      }), 1000)
    end)
    assert.is_true(admission.result.done)
    assert.are.equal("selected", admission.result.text)
    assert.is_nil(admission.commit())
  end)

  it("closes an owner while a long poll is awaiting the worker", function()
    local admission = start("cat", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    local collecting = false
    inspect_request = function(message)
      if message.type == "request" and message.method == "process_collect" then collecting = true end
    end
    local waiting = async.run(function() return owner:interact(id, 30000) end)
    pending[#pending + 1] = waiting
    assert(vim.wait(1000, function() return collecting end, 5))
    owner:close("Agent destroyed during poll")
    assert.is_true(helper.complete(function() return owner:wait_release(5000) end))
    assert.is_true(waiting:is_done())
    assert.are.equal(0, owner:status().reserved)
  end)

  it("quarantines target capacity when its worker exits during a pending poll", function()
    local admission = start("read line", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    local collecting = false
    inspect_request = function(message)
      if message.type == "request" and message.method == "process_collect" then collecting = true end
    end
    local waiting = async.run(function() return owner:interact(id, 30000) end)
    pending[#pending + 1] = waiting
    assert(vim.wait(1000, function() return collecting end, 5))
    quarantined = true
    assert(leases[1]):dispose("worker exited unexpectedly")
    assert.is_false(helper.wait(waiting).ok)
    local cleanup = helper.complete(function() return owner:wait_cleanup(5000) end)
    assert.are.equal("process_cleanup", assert(cleanup.error).code)
    assert.are.equal(1, owner:status().reserved)
    local status = owner:status()
    assert.are.equal(1, status.quarantined)
    local reservation = assert(status.reservations[1])
    assert.are.equal(id, reservation.session_id)
    assert.is_true(reservation.done)
    assert.is_true(reservation.committed)
    assert.is_false(reservation.discarded)
    assert.are.equal("quarantined", reservation.release)
    assert.matches("Target release could not be confirmed", assert(reservation.release_error).message, 1, true)
    assert(reservation.release_error).message = "caller mutation"
    owner:forget(id)
    status = owner:status()
    assert.are.equal(1, status.reserved)
    assert.is_true(assert(status.reservations[1]).discarded)
    assert.matches("Target release could not be confirmed", assert(assert(status.reservations[1]).release_error).message, 1, true)
  end)

  it("contains a stop whose independent supervision timer cannot be armed", function()
    local admission = helper.success(function()
      return helper.admit(owner, helper.spec("read line", {
        stdio = { kind = "pipes", stdin = "open" }, kill_grace_ms = 1001,
      }), 0)
    end)
    assert(admission.commit())
    local probe = assert(vim.uv.new_timer())
    local methods = getmetatable(probe).__index
    probe:close()
    local start_timer = methods.start
    local refused = false
    methods.start = function(timer, timeout, interval, callback)
      if timeout == 8001 then
        refused = true
        return nil, "stop supervision unavailable"
      end
      return start_timer(timer, timeout, interval, callback)
    end
    quarantined = true
    local ok, err = pcall(function()
      owner:close("owner destroyed")
      assert(vim.wait(5000, function() return assert(leases[1]):is_released() end, 5))
      assert.is_true(refused)
      assert.are.equal(1, owner:status().reserved)
      assert.are.equal("process_cleanup", assert(owner:status().cleanup_error).code)
    end)
    methods.start = start_timer
    assert.is_true(ok, vim.inspect(err))
  end)

  it("reports invalid disposal acknowledgement while retaining uncertain target capacity", function()
    local admission = start("read line", { kind = "pipes", stdin = "open" })
    assert(admission.commit())
    local disposal_id
    inspect_request = function(message)
      if message.type == "request" and message.method == "process_dispose" then disposal_id = message.request_id end
    end
    intercept_reply = function(message)
      if message.type == "event" then return true end
      if message.type == "response" and message.request_id == disposal_id then message.value = { invalid = true } end
    end
    quarantined = true
    owner:close("owner destroyed")
    assert(vim.wait(5000, function() return assert(leases[1]):is_released() end, 5))
    assert.are.equal(1, owner:status().reserved)
    assert.are.equal("process_cleanup", assert(owner:status().cleanup_error).code)
  end)

  it("resolves a relative working directory once before remote placement", function()
    local admission = helper.success(function()
      return helper.admit(owner, helper.spec("pwd", { cwd = ".." }), 1000)
    end)
    assert.is_true(admission.result.done)
    assert.are.equal(assert(vim.uv.fs_realpath("..")) .. "\n", admission.result.text)
    admission.commit()
  end)

  it("keeps unobserved output bounded and releases a completed worker without polling", function()
    local admission = start("read line; head -c 200000 /dev/zero; printf END", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    local early = poll(id, { kind = "write", data = "go\n" }, 0)
    assert(vim.wait(5000, function()
      return assert(leases[1]):is_released()
    end, 5))
    local final = poll(id, nil, 0)
    assert.is_true(final.done)
    assert.is_nil(final.error, vim.inspect(final))
    assert.is_nil(final.cleanup_error, vim.inspect(final))
    local kept = 0
    for _, event in ipairs(early.events) do
      kept = kept + #event.data
    end
    for _, event in ipairs(final.events) do
      kept = kept + #event.data
    end
    assert.are.equal(200003, kept + early.dropped_bytes + final.dropped_bytes)
    assert.matches("END$", early.text .. final.text)
  end)

  it("preserves output and ownership when a committed RPC poll is cancelled", function()
    local admission = start("read line; printf ready; read line; printf kept", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    assert.are.equal("ready", poll(id, { kind = "write", data = "go\n" }).text)
    local waiting = async.run(function()
      return owner:interact(id, 30000)
    end)
    waiting:cancel()
    assert.are.equal("cancelled", assert(helper.wait(waiting).error).kind)
    local final = poll(id, { kind = "write", data = "finish\n" })
    local output = final.text
    if not final.done then
      output = output .. poll(id).text
    end
    assert.are.equal("kept", output)
  end)

  it("terminates a provisional worker when its initial wait is cancelled", function()
    local waiting = async.run(function()
      return helper.admit(owner, helper.spec("exec sleep 30"), 30000)
    end)
    assert(vim.wait(2000, function()
      return #leases == 1
    end, 5))
    waiting:cancel()
    assert.are.equal("cancelled", assert(helper.wait(waiting).error).kind)
    assert.is_true(helper.complete(function()
      return owner:wait_release(5000)
    end))
  end)

  it("owns failed target startup until its worker and native resources release", function()
    local result = helper.complete(function()
      return helper.admit(owner, helper.spec("", { argv = { "/neoagent-missing-executable" } }), 1000)
    end)
    assert.is_not_nil(result.error)
    assert.is_true(helper.complete(function()
      return owner:wait_release(5000)
    end))
    assert.are.equal(0, owner:status().reserved)
  end)

  it("releases locally rejected requests without quarantining unused target capacity", function()
    owner = sessions.new({ capacity = 1 }, nil, factory)
    local sent = false
    inspect_request = function(message)
      if message.type == "request" or message.type == "request_begin" then sent = true end
    end
    local result = helper.complete(function()
      return helper.admit(owner, helper.spec("exit 0", {
        environment = { inherit = false, set = {
          LARGE = string.rep("x", require("neoagent.rpc.protocol").MAX_REQUEST),
        } },
      }), 0)
    end)
    assert.matches("aggregate protocol limit", assert(result.error).message, 1, true)
    assert.is_false(sent)
    local released = helper.complete(function() return owner:wait_release(2000) end)
    quarantined = released ~= true
    assert.is_true(released, "an unsent process request cannot reserve target capacity")
    assert.are.equal(0, owner:status().reserved)
    local admission = helper.success(function() return helper.admit(owner, helper.spec("printf recovered"), 2000) end)
    assert.are.equal("recovered", admission.result.text)
    assert.is_nil(admission.commit())
  end)

  it("allows the native startup budget plus time to deliver its acknowledgement", function()
    ---@type integer?
    local startup_request
    inspect_request = function(message)
      if message.type == "request" and message.method == "process_start" then startup_request = message.request_id end
    end
    local delay = assert(vim.uv.new_timer())
    intercept_reply = function(message, deliver)
      if message.type == "response" and message.request_id == startup_request then
        assert(delay:start(require("neoagent.subprocess.validate").START_MS + 100, 0, deliver))
        return true
      end
    end
    local admitting = async.run(function()
      return helper.admit(owner, helper.spec("cat", { stdio = { kind = "pipes", stdin = "open" } }), 0)
    end)
    pending[#pending + 1] = admitting
    local waited, result = pcall(helper.wait, admitting, 12000)
    delay:stop()
    delay:close()
    intercept_reply = nil
    if not waited or result.ok == false then quarantined = true end
    assert.is_true(waited, vim.inspect(result))
    assert.is_nil(result.error, vim.inspect(result))
    local id = assert(result.commit())
    assert.are.equal("alive\n", poll(id, { kind = "write", data = "alive\n" }).text)
  end)

  it("reports permanent staging release failure as quarantined capacity", function()
    fail_staging_cleanup, quarantined = true, true
    local admission = start("cat", { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    poll(id, { kind = "close_stdin" })
    assert(vim.wait(3000, function() return owner:status().quarantined == 1 end, 5))
    local result = helper.complete(function() return owner:wait_cleanup(5000) end)
    assert.matches("Could not clean native sandbox resources", assert(result.error).message, 1, true)
    owner:forget(id)
    local status = owner:status()
    assert.are.equal(1, status.reserved)
    assert.are.equal(1, status.quarantined)
    local reservation = assert(status.reservations[1])
    assert.is_true(reservation.discarded)
    assert.are.equal("staging removal denied", assert(reservation.release_error).detail)
    assert.are.equal("staging removal denied", assert(reservation.cleanup_error).detail)
  end)

  it("rejects cancelled controls and preserves completed output already buffered remotely", function()
    ---@type Neoagent.ProcessController?
    local controller
    owner = sessions.new(nil, nil, function(spec, maximum, cleanup, released)
      controller = factory(spec, maximum, cleanup, released)
      return controller
    end)
    local admission = helper.success(function()
      return helper.admit(owner, helper.spec("cat", { stdio = { kind = "pipes", stdin = "open" } }), 0)
    end)
    local id = assert(admission.commit())
    local controls_sent = 0
    inspect_request = function(message)
      if message.type == "request" and message.method == "process_control" then controls_sent = controls_sent + 1 end
    end
    local result = helper.complete(function()
      assert(async.current()):cancel()
      return owner:interact(id, 0, { kind = "close_stdin" })
    end)
    assert.are.equal(0, controls_sent)
    assert.are.equal("cancelled", assert(result.error).kind)
    helper.success(function()
      assert(controller):control({ kind = "write", data = "preserved\n" })
      assert(controller):control({ kind = "close_stdin" })
      return assert(controller):wait_cleanup()
    end)
    result = helper.complete(function()
      assert(async.current()):cancel()
      return owner:interact(id, 0)
    end)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal("preserved\n", poll(id, nil, 0).text)
  end)

  it("releases admission rejected before the worker creates a target", function()
    local cwd = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(cwd, "p"))
    inspect_request = function(message)
      if message.type == "request" and message.method == "process_start" then
        assert.are.equal(0, vim.fn.delete(cwd, "d"))
      end
    end
    local result = helper.complete(function()
      return helper.admit(owner, helper.spec("exit 0", { cwd = cwd }), 0)
    end)
    vim.fn.delete(cwd, "d")
    assert.matches("cwd must identify a directory", assert(result.error).message, 1, true)
    local released = helper.complete(function() return owner:wait_release(2000) end)
    if released ~= true then
      quarantined = true
      assert(leases[1]):dispose("regression cleanup")
    end
    assert.is_true(released, "rejected admission permanently consumed capacity")
    assert.are.equal(0, owner:status().reserved)
  end)

  for _, exits in ipairs({ false, true }) do
    it("rechecks " .. (exits and "completion" or "output") .. " after the preceding cancelled poll settles", function()
      local ending = "read line"
      if exits then
        exit_gate = vim.fn.tempname()
        ending = "while [ ! -e " .. vim.fn.shellescape(exit_gate) .. " ]; do sleep 0.01; done"
      end
      local admission = start("read line; printf kept; " .. ending,
        { kind = "pipes", stdin = "open" })
      local id = assert(admission.commit())
      ---@type fun()?
      local deliver_collection
      local completed = false
      intercept_reply = function(message, deliver)
        if message.type == "event" and message.name == "process_complete" then completed = true end
        if message.type == "response" and message.value.events and #message.value.events > 0 then
          deliver_collection = deliver
          return true
        end
      end
      local previous = async.run(function()
        return owner:interact(id, 30000, { kind = "write", data = "go\n" })
      end)
      pending[#pending + 1] = previous
      assert(vim.wait(2000, function() return deliver_collection ~= nil end, 5))
      if exits then
        assert(require("neoagent.fs").write_all((assert(exit_gate)), "go"))
        assert(vim.wait(2000, function() return completed end, 5))
      end
      previous:cancel()
      assert.are.equal("cancelled", assert(helper.wait(previous).error).kind)
      local next_poll = async.run(function() return owner:interact(id, 30000) end)
      pending[#pending + 1] = next_poll
      intercept_reply = nil
      local delay = assert(vim.uv.new_timer())
      delay:start(require("neoagent.rpc.protocol").CANCEL_GRACE_MS + 300, 0, function()
        assert(deliver_collection)()
      end)
      local observed, result = pcall(helper.wait, next_poll, 3000)
      delay:stop()
      delay:close()
      if owner:status().cleanup_error then quarantined = true end
      assert.is_true(observed, vim.inspect(result))
      assert.is_nil(result.error, vim.inspect(result))
      assert.are.equal("kept", result.text)
      if exits then assert.is_true(result.done) end
    end)
  end

  it("publishes target completion before worker shutdown settles", function()
    hold_worker_wait = true
    local admission = start("printf complete", nil, 300)
    assert(vim.wait(2000, function() return finish_worker_wait ~= nil end, 5))
    assert.is_true(admission.result.done, "completed target waited for worker shutdown")
    assert.are.equal("complete", admission.result.text)
    assert.is_false(admission.result.released)
    assert.is_nil(admission.commit())
    assert.are.equal(1, owner:status().reserved)
  end)

  it("closes after target release while the preceding poll response is still being observed", function()
    exit_gate = vim.fn.tempname()
    hold_completion, hold_release = true, true
    local admission = start("while [ ! -e " .. vim.fn.shellescape(exit_gate) .. " ]; do sleep 0.01; done")
    local id = assert(admission.commit())
    assert(require("neoagent.fs").write_all(exit_gate, "exit"))
    assert(vim.wait(3000, function() return deliver_completion ~= nil and deliver_release ~= nil end, 5))
    ---@type fun()?
    local deliver_poll
    intercept_reply = function(message, deliver)
      if message.type == "response" then
        deliver_poll = deliver
        return true
      end
    end
    local waiting = async.run(function() return owner:interact(id, 30000) end)
    pending[#pending + 1] = waiting
    assert(vim.wait(3000, function() return deliver_poll ~= nil end, 5))
    -- Preserve wire order: completion preceded this new request's reply.
    -- Its delivery can coincide with disposal of that request's observer.
    assert(deliver_completion)()
    assert(deliver_release)()
    owner:close("close during completion delivery")
    intercept_reply = nil
    local delay = assert(vim.uv.new_timer())
    delay:start(50, 0, function() assert(deliver_poll)() end)
    helper.wait(waiting)
    local result = helper.complete(function() return owner:wait_release(5000) end)
    delay:stop()
    delay:close()
    assert.is_true(result)
    assert.is_true(helper.complete(function() return owner:wait_cleanup(1000) end))
    assert.is_nil(owner:status().cleanup_error)
  end)

  for _, stdio in ipairs({ { kind = "pipes", stdin = "closed" }, { kind = "pty", columns = 80, rows = 24 } }) do
    it("preserves local error kinds across " .. stdio.kind .. " RPC controls", function()
      local spec = helper.spec("exec sleep 30", { stdio = stdio })
      local local_owner = sessions.new()
      local command = stdio.kind == "pipes" and { kind = "write", data = "closed" } or { kind = "close_stdin" }
      local local_admission = helper.success(function() return helper.admit(local_owner, spec, 0) end)
      local local_result = helper.complete(function()
        return local_owner:interact(assert(local_admission.commit()), 0, command)
      end)
      local_owner:close("local comparison finished")
      assert.is_true(helper.complete(function() return local_owner:wait_release(5000) end))
      local admission = helper.success(function() return helper.admit(owner, spec, 0) end)
      local id = assert(admission.commit())
      local remote_result = helper.complete(function() return owner:interact(id, 0, command) end)
      assert.are.equal(assert(local_result.error).kind, assert(remote_result.error).kind)
      assert.are.equal(assert(local_result.error).code, assert(remote_result.error).code)
      assert.are.equal(1, owner:status().reserved)
      assert.is_false(poll(id, nil, 0).done)
    end)
  end

  it("notifies release observers when worker resources outlive successful cleanup", function()
    hold_worker_release = true
    local admission = start("printf complete", nil, 1000)
    admission.commit()
    assert.is_true(helper.complete(function() return owner:wait_cleanup(5000) end))
    assert(vim.wait(3000, function() return finish_worker_release ~= nil end, 5))
    local status = owner:status()
    assert.are.equal(1, status.reserved)
    assert.are.equal(0, status.quarantined)
    assert.are.equal("pending", assert(status.reservations[1]).release)
    local observing = async.run(function() return owner:wait_release(10000) end)
    pending[#pending + 1] = observing
    hold_worker_release = false
    assert(finish_worker_release).resolve(true)
    finish_worker_release = nil
    assert.is_true(helper.wait(observing, 2000), "worker release did not notify the manager")
    assert.are.equal(0, owner:status().reserved)
    assert.are.same({}, owner:status().reservations)
  end)

  it("supervises acknowledged termination independently of lifetime and subsequent polling", function()
    local admission = start("trap '' TERM; printf ready; while :; do read line; done",
      { kind = "pipes", stdin = "open" })
    local id = assert(admission.commit())
    local output = admission.result.text
    if not output:find("ready", 1, true) then output = output .. poll(id).text end
    assert.are.equal("ready", output)
    local terminating = false
    ---@type integer?
    local collection_id
    inspect_request = function(message)
      if message.type ~= "request" then return end
      if message.method == "process_control" and message.payload.kind == "terminate" then terminating = true end
      if terminating and message.method == "process_collect" then collection_id = message.request_id end
    end
    intercept_reply = function(message, deliver)
      if stall_worker then return true end
      if message.type == "response" and message.request_id == collection_id then
        deliver()
        stall_worker = true
        return true
      end
    end
    poll(id, { kind = "terminate", reason = "explicit stop" }, 0)
    quarantined = true
    local lease = assert(leases[1])
    local settled = vim.wait(11000, function() return lease:is_released() end, 5)
    stall_worker, intercept_reply = false, nil
    if not settled then lease:dispose("regression cleanup") end
    assert.is_true(settled, "acknowledged termination lost its parent deadline")
    assert.are.equal(1, owner:status().reserved)
    assert.are.equal("process_cleanup", assert(owner:status().cleanup_error).code)
  end)

  it("reserves capacity and retains the worker until a failed target reap eventually releases", function()
    reap_gate = vim.fn.tempname()
    assert(require("neoagent.fs").write_all(reap_gate, "hold"))
    owner = sessions.new({ capacity = 1 }, nil, factory)
    local admission = start("exit 0", nil, 2000)
    assert.is_true(admission.result.done)
    assert.are.equal("process_cleanup", assert(admission.result.cleanup_error).code)
    assert.is_false(admission.result.released)
    assert.is_nil(admission.commit())
    assert.are.equal(1, owner:status().reserved)
    assert.is_false(assert(leases[1]):is_released())
    assert.are.equal("process_capacity", assert(helper.complete(function()
      return helper.admit(owner, helper.spec("exit 0"), 0)
    end).error).code)
    vim.fn.delete((assert(reap_gate)))
    reap_gate = nil
    assert.is_true(helper.complete(function() return owner:wait_release(5000) end))
    assert.are.equal(0, owner:status().reserved)
    assert.is_true(assert(leases[1]):is_released())
  end)

  it("retires the completion watchdog while retaining a target awaiting native release", function()
    reap_gate = vim.fn.tempname()
    assert(require("neoagent.fs").write_all(reap_gate, "hold"))
    hold_completion = true
    local admission = start("exit 0", nil, 100)
    local id = assert(admission.commit())
    assert(vim.wait(2000, function() return deliver_completion ~= nil end, 5))
    -- A collect response can report done before its independent completion
    -- notification arrives. Native release remains blocked beyond the RPC
    -- completion watchdog, then succeeds without another process request.
    assert(deliver_completion)()
    assert.is_true(poll(id, nil, 0).done)
    reap_delay = assert(vim.uv.new_timer())
    reap_delay:start(6100, 0, function()
      assert(reap_delay):stop()
      assert(reap_delay):close()
      vim.uv.fs_unlink((assert(reap_gate)))
    end)
    assert.is_true(helper.complete(function() return owner:wait_release(9000) end, 10000), vim.inspect(owner:status()))
    assert.are.equal(0, owner:status().reserved)
  end)

  it("bounds a missing completion notification after an exited collection", function()
    hold_completion, hold_release, quarantined = true, true, true
    local admission = start("exit 0", nil, 100)
    local id = assert(admission.commit())
    assert(vim.wait(2000, function() return deliver_completion ~= nil end, 5))
    assert(vim.wait(8000, function() return assert(leases[1]):is_released() end, 5))
    local result = poll(id, nil, 0)
    assert.is_true(result.done)
    assert.are.equal("protocol", assert(result.error).kind)
    assert.matches("completion was not acknowledged", assert(result.error).message, 1, true)
    assert.are.equal(1, owner:status().reserved)
  end)

  it("retains a collected cleanup failure when the completion notification is lost", function()
    local failures = {}
    owner = sessions.new({ capacity = 1 }, function(err) failures[#failures + 1] = err end, factory)
    reap_gate = vim.fn.tempname()
    assert(require("neoagent.fs").write_all(reap_gate, "hold"))
    hold_completion, hold_release, quarantined = true, true, true
    local admission = start("exit 0", nil, 2000)
    local cleanup = assert(admission.result.cleanup_error)
    assert.are.equal("process_cleanup", cleanup.code)
    assert.is_false(admission.result.done)
    local id = assert(admission.commit())
    -- The target really releases before losing its worker. Only the release
    -- acknowledgement is withheld, so teardown does not orphan a native child.
    assert.are.equal(0, vim.fn.delete((assert(reap_gate))))
    reap_gate = nil
    assert(vim.wait(3000, function() return deliver_release ~= nil end, 5))
    assert(leases[1]):dispose("lose channel before target completion acknowledgement")
    helper.complete(function() return owner:wait_cleanup(5000) end)
    assert(vim.wait(1000, function() return #failures > 0 end, 5))
    assert.are.same(cleanup, owner:status().cleanup_error,
      "the acknowledged target cleanup error was replaced by release uncertainty")
    assert.are.same(cleanup, failures[1])
    assert.are.equal(2, #failures, "target cleanup and release uncertainty each report once")
    assert.are.equal(1, owner:status().reserved)
    assert.is_true(poll(id, nil, 0).done)
    assert.are.equal(2, #failures, "reading a cleanup snapshot repeated the diagnostic")
  end)

  it("enforces the parent lifetime deadline without another poll from its owner", function()
    ---@type Neoagent.Error[]
    local diagnostics = {}
    owner = sessions.new({ capacity = 1 }, function(err)
      -- The Agent's default notification recipient also needs editor APIs.
      -- Calling one here catches diagnostics swallowed in fast callbacks.
      assert.are.equal(1, vim.api.nvim_eval("1"))
      diagnostics[#diagnostics + 1] = err
    end, factory)
    local admission = helper.success(function()
      return helper.admit(owner, helper.spec("exec sleep 30", { timeout_ms = 500, kill_grace_ms = 0 }), 0)
    end)
    local id = assert(admission.commit())
    quarantined = true
    intercept_reply = function() return true end
    assert(vim.wait(10000, function() return assert(leases[1]):is_released() end, 5))
    intercept_reply = nil
    local result = poll(id, nil, 0)
    assert.is_true(result.done)
    assert.are.equal("process_supervision", assert(result.error).code)
    assert.matches("exceeded its process deadline", assert(result.error).message, 1, true)
    assert.are.equal(1, owner:status().reserved)
    assert(vim.wait(1000, function() return #diagnostics == 1 end, 5), "watchdog cleanup diagnostic was lost")
    assert.matches("Target release could not be confirmed", assert(diagnostics[1]).message, 1, true)
  end)

  it("reports later worker cleanup failure without requiring another session read", function()
    local failures = {}
    owner = sessions.new({ capacity = 1 }, function(err) failures[#failures + 1] = err end, factory)
    hold_release, fail_worker_cleanup = true, true
    local admission = start("exit 0", nil, 1000)
    assert.is_true(admission.result.done)
    assert.is_nil(admission.result.cleanup_error)
    assert.is_nil(admission.commit())
    assert(vim.wait(2000, function() return deliver_release ~= nil end, 5))
    assert.are.equal(0, #failures)
    assert(deliver_release)()
    assert(vim.wait(3000, function() return #failures == 1 end, 5), "late worker cleanup had no diagnostic recipient")
    assert.matches("Worker staging cleanup failed", failures[1].message, 1, true)
  end)

  for _, fails in ipairs({ false, true }) do
    it("waits for worker cleanup observation with failure=" .. tostring(fails), function()
      hold_worker_wait, fail_worker_cleanup = true, fails
      local admission = start("exit 0", nil, 1000)
      assert.is_true(admission.result.done)
      assert.is_false(admission.result.cleanup_done)
      admission.commit()
      owner:close("target finished")
      assert(vim.wait(2000, function() return finish_worker_wait ~= nil end, 5))
      assert.is_false(owner:status().cleanup_done)
      local observer = async.run(function() return owner:wait_cleanup(3000) end)
      pending[#pending + 1] = observer
      assert.is_false(observer:is_done(), "cleanup succeeded before its worker outcome was known")
      hold_worker_wait = false
      assert(finish_worker_wait).resolve(true)
      finish_worker_wait = nil
      local result = helper.wait(observer)
      assert.is_true(owner:status().cleanup_done)
      if fails then
        assert.matches("Worker staging cleanup failed", assert(result.error).message, 1, true)
      else
        assert.is_true(result)
      end
    end)
  end

  for _, target_failed in ipairs({ false, true }) do
    it("preserves relay cleanup causes " .. (target_failed and "alongside target cleanup" or "without target cleanup"), function()
      local util = require("neoagent.util")
      local failures = {}
      local publications = {}
      owner = sessions.new({ capacity = 1 }, function(err) failures[#failures + 1] = err end,
        function(spec, maximum, on_cleanup, on_released)
          return factory(spec, maximum, function(err)
            publications[#publications + 1] = err
            on_cleanup(err)
          end, on_released)
        end)
      fail_worker_cleanup, fail_staging_cleanup, quarantined = true, true, true
      if target_failed then
        intercept_reply = function(message)
          if message.type == "event" and message.name == "process_complete" then
            message.value.cleanup_error = util.error("process_cleanup", "Target cleanup failed")
          end
        end
      end
      local admission = start("exit 0", nil, 1000)
      admission.commit()
      assert(vim.wait(3000, function()
        local reservation = owner:status().reservations[1]
        return reservation and reservation.cleanup_error
          and reservation.cleanup_error.message == "Could not clean native sandbox resources"
      end, 5), "worker cleanup was not reported")
      local cleanup = assert(assert(owner:status().reservations[1]).cleanup_error)
      assert.are.equal("staging removal denied", cleanup.detail)
      local host = assert(rawget(cleanup, "cause"), "relay's native cleanup cause was lost")
      assert.are.equal("Worker staging cleanup failed", host.message)
      assert.are.same(target_failed and util.error("process_cleanup", "Target cleanup failed") or nil, rawget(cleanup, "target_cleanup_error"))
      assert(vim.wait(1000, function() return #failures >= (target_failed and 2 or 1) end, 5), "later cleanup diagnostic was lost")
      assert.are.same(cleanup, failures[#failures])
      local observed = helper.complete(function() return owner:wait_cleanup(1000) end)
      assert.is_not_nil(observed.error)
      assert.is_true(owner:status().cleanup_done)
      assert.is_false(owner:status().released)
      assert.are.equal(target_failed and 2 or 1, #publications)
      assert.are.equal(#publications, #failures)
    end)
  end

  it("observes native cleanup when allocating worker shutdown supervision fails", function()
    local invocations = require("neoagent.sandbox.invocation")
    local new = invocations.new
    invocations.new = function(connection, lease, on_cleanup, timeout_ms)
      local invocation = new(connection, lease, on_cleanup, timeout_ms)
      local begin_shutdown = invocation.begin_shutdown
      function invocation:begin_shutdown()
        local allocate = vim.uv.new_timer
        vim.uv.new_timer = function() return nil end
        local ok, err = pcall(begin_shutdown, self)
        vim.uv.new_timer = allocate
        if not ok then error(err, 0) end
      end
      return invocation
    end
    local checked, failure = pcall(function()
      local admission = start("exit 0", nil, 1000)
      admission.commit()
      owner:close("finished")
      assert(vim.wait(3000, function() return assert(leases[1]):is_released() end, 5))
      local result = helper.complete(function() return owner:wait_cleanup(1000) end)
      quarantined = not owner:status().cleanup_done
      assert.is_true(owner:status().cleanup_done, "shutdown timer failure abandoned native cleanup observation")
      assert.is_not_nil(result.error)
      assert.is_true(helper.complete(function() return owner:wait_release(1000) end))
    end)
    invocations.new = new
    if not checked then error(failure, 0) end
  end)

  it("normalizes termination reasons before sending a retained control", function()
    local reason = "cancel\27[31m " .. string.rep("x", require("neoagent.rpc.protocol").MAX_REQUEST)
    local expected = require("neoagent.subprocess.validate").reason(reason)
    local admission = start("exec sleep 30")
    local id = assert(admission.commit())
    ---@type string?
    local sent
    inspect_request = function(message)
      if message.method == "process_control" then sent = message.payload.reason end
    end
    local result = helper.complete(function()
      return owner:interact(id, 1000, { kind = "terminate", reason = reason })
    end)
    -- The broken path loses the target's release acknowledgement. Retain its
    -- reservation while cleaning the real worker during test teardown.
    if result.error then quarantined = true end
    assert.is_nil(result.error, vim.inspect(result))
    assert.are.equal(expected, sent)
    assert.is_true(helper.complete(function() return owner:wait_release(5000) end))
    assert.are.equal(0, owner:status().reserved)
    assert.are.equal(expected, assert(poll(id).outcome).termination_reason)
  end)

  it("contains an unresponsive worker after target completion without claiming target release", function()
    hold_release, quarantined = true, true
    local admission = start("exit 0", nil, 1000)
    assert.is_true(admission.result.done)
    admission.commit()
    assert(vim.wait(2000, function() return deliver_release ~= nil end, 5))
    stall_worker = true
    owner:close("Agent destroyed")
    local lease = assert(leases[1])
    local settled = vim.wait(12000, function() return lease:is_released() end, 5)
    stall_worker = false
    -- The real target already exited before its release frame was held.
    -- Always dispose the real worker, including against the broken version.
    if not settled then lease:dispose("regression cleanup") end
    assert.is_true(settled, "completed target left an unresponsive worker unsupervised")
    assert.are.equal(1, owner:status().reserved)
    assert.are.equal("process_cleanup", assert(owner:status().cleanup_error).code)
  end)

  for _, terminal in ipairs({ false, true }) do
    it("releases the owned " .. (terminal and "PTY" or "pipe") .. " target before its worker on disposal", function()
      local admission = start("printf '%s\\n' $$; exec sleep 30", terminal
        and { kind = "pty", columns = 80, rows = 24 } or { kind = "pipes" })
      local id = assert(admission.commit())
      local output = admission.result.text
      if not output:find("%d+") then output = output .. poll(id).text end
      local pid = math.floor(assert(tonumber(output:match("%d+"))))
      local ok, err = pcall(function()
        owner:close("retained owner destroyed")
        assert.is_true(helper.complete(function() return owner:wait_release(5000) end))
        assert.is_nil(vim.uv.kill(pid, 0), "worker release left its target alive")
      end)
      if vim.uv.kill(pid, 0) then vim.uv.kill(pid, "sigkill") end
      assert.is_true(ok, vim.inspect(err))
    end)
  end

  it("runs PTY resize and interruption through the worker-local native handle", function()
    local admission =
      start("trap 'printf interrupted; exit 42' INT; printf ready; while :; do read line; stty size; done", {
        kind = "pty",
        columns = 80,
        rows = 24,
      })
    local id = assert(admission.commit())
    local output = admission.result.text
    if not output:find("ready", 1, true) then
      output = output .. poll(id).text
    end
    assert.matches("ready", output, 1, true)
    poll(id, { kind = "resize", columns = 99, rows = 31 }, 0)
    local resized = poll(id, { kind = "write", data = "size\n" })
    output = resized.text
    if not output:find("31 99", 1, true) then
      output = output .. poll(id).text
    end
    assert.matches("31 99", output, 1, true)
    local final = poll(id, { kind = "interrupt" })
    output = final.text
    if not final.done then
      final = poll(id)
      output = output .. final.text
    end
    assert.are.equal(42, assert(final.outcome).code)
    assert.matches("interrupted", output, 1, true)
  end)
end)
