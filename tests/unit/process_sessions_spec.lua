local assert = require("luassert")
local async = require("neoagent.async")
local helper = require("tests.helpers.subprocess")
local sessions = require("neoagent.process_sessions")

-- Native process behavior is shared with the Windows suite's commands.
describe("retained process sessions", function()
  if jit.os == "Windows" then
    pending("POSIX commands; native Windows commands run in tests/windows")
    return
  end
  ---@type Neoagent.ProcessSessions
  local owner
  ---@type Neoagent.ProcessController[]
  local constructed
  before_each(function()
    constructed = {}
    owner = sessions.new({ capacity = 2, completed = 2, output_bytes = 64 })
  end)
  after_each(function()
    owner:close("test finished")
    -- Retain every constructor result so an admission regression cannot
    -- leak a child outside the manager during the failing-test run.
    for _, controller in ipairs(constructed) do controller:dispose("test finished") end
    for _, controller in ipairs(constructed) do
      assert.is_true(helper.complete(function() return controller:wait() end))
      assert(vim.wait(4000, function() return controller:state().released end, 5))
    end
    helper.complete(function()
      return owner:wait_cleanup(4000)
    end)
    assert.is_true(helper.complete(function()
      return owner:wait_release(4000)
    end))
  end)
  ---@async
  local function prepare(command, milliseconds, stdio)
    return helper.admit(owner, helper.spec(command, { stdio = stdio }), milliseconds)
  end
  local function background(command, stdio)
    local admission = helper.success(function()
      return prepare(command, 0, stdio)
    end)
    local id = assert(admission.commit())
    assert.is_number(id)
    return id
  end
  local function poll(id, control, wait_ms)
    return helper.success(function()
      return owner:interact(id, wait_ms or 1000, control)
    end)
  end

  local function poll_failure(id)
    local result = helper.complete(function()
      return owner:interact(id, 0)
    end)
    return assert(result.error)
  end

  it("returns a completed initial result without publishing a session", function()
    local admission = helper.success(function()
      return prepare("printf done", 1000)
    end)
    assert.is_true(admission.result.done)
    assert.are.equal(0, assert(admission.result.outcome).code)
    assert.are.equal("done", admission.result.text)
    assert.is_nil(admission.result.session_id)
    assert.is_nil(admission.commit())
    assert.are.equal(0, owner:status().provisional)
  end)

  it("revokes an admission when cancellation wins after startup before result delivery", function()
    ---@type Neoagent.Run<nil, unknown>?
    local publisher
    local delivered = false
    publisher = async.run(function()
      local admission = owner:reserve(helper.spec("exec sleep 30"))
      async.run(function()
        return admission.start(0)
      end, { on_done = function() assert(publisher):cancel() end }):await()
      delivered = true
      admission.commit()
    end)
    local result = helper.wait(assert(publisher))
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.is_false(delivered)
    assert.are.equal(0, owner:status().provisional)
    assert.is_true(helper.complete(function() return owner:wait_release(3000) end))
    assert.are.equal(0, owner:status().reserved)
  end)

  it("owns an unstarted reservation and wakes cleanup when its publisher cancels", function()
    local starts = 0
    owner = sessions.new({ capacity = 1 }, nil, function(spec, maximum, cleanup, released)
      starts = starts + 1
      return require("neoagent.process_sessions.local").new(spec, maximum, cleanup, released)
    end)
    ---@type Neoagent.ProcessAdmission?
    local admission
    local publisher = async.run(function()
      admission = owner:reserve(helper.spec("exit 0"))
      assert.are.equal("process_validation", helper.failure(assert(admission).commit).code)
      assert.are.equal("process_capacity", helper.failure(function() owner:reserve(helper.spec("exit 0")) end).code)
      async.await(function() end)
    end)
    local cleanup = async.run(function() return owner:wait_cleanup(3000) end)
    assert.is_false(cleanup:is_done())
    publisher:cancel()
    assert.are.equal("cancelled", assert(helper.wait(publisher).error).kind)
    assert.is_true(helper.wait(cleanup))
    assert.are.equal(0, owner:status().reserved)
    local rejected = helper.complete(function() return assert(admission).start(0) end)
    assert.are.equal("process_disposed", assert(rejected.error).code)
    assert.are.equal(0, starts)
  end)

  it("revokes a reservation when its startup observer was already cancelled", function()
    helper.success(function()
      local admission = owner:reserve(helper.spec("exit 0"))
      local result = async.run(function(observer)
        observer:cancel()
        return admission.start(0)
      end):await()
      assert.are.equal("cancelled", assert(result.error).kind)
      assert.are.equal(0, owner:status().provisional)
      return true
    end)
  end)

  it("starts an admission once while preserving its publication handle", function()
    helper.success(function()
      local admission = owner:reserve(helper.spec("cat", { stdio = { kind = "pipes", stdin = "open" } }))
      local result = admission.start(0)
      local started, failure = pcall(admission.start, 0)
      assert.is_false(started)
      assert.are.equal("process_validation", require("neoagent.util").normalize_error(failure).code)
      assert.are.equal(result.session_id, admission.commit())
      return true
    end)
  end)

  it("rejects invalid bounds before admission and preserves a session after invalid controls", function()
    for _, options in ipairs({ { capacity = 0 }, { completed = 257 }, { output_bytes = 262145 } }) do
      assert.are.equal("process_validation", helper.failure(function() sessions.new(options) end).code)
    end
    for _, milliseconds in ipairs({ -1, 0.5, 30001, math.huge }) do
      local result = helper.complete(function() return prepare("exit 0", milliseconds) end)
      assert.are.equal("process_validation", assert(result.error).code)
      assert.are.equal(0, owner:status().reserved)
    end
    local id = background("cat", { kind = "pipes", stdin = "open" })
    for _, command in ipairs({
      { kind = "write", data = string.rep("x", 65537) },
      { kind = "write" },
      { kind = "unknown" },
      { kind = "resize", columns = 0, rows = 24 },
      { kind = "terminate", reason = "" },
    }) do
      local result = helper.complete(function() return owner:interact(id, 0, command) end)
      assert.is_false(result.ok)
      local expected = command.kind == "resize" and "invalid_terminal_size" or "process_validation"
      assert.are.equal(expected, assert(result.error).kind)
      assert.are.equal(expected, assert(result.error).code)
    end
    assert.are.equal("alive\n", poll(id, { kind = "write", data = "alive\n" }).text)
    assert.are.equal(1, owner:status().reserved)
  end)

  it("returns an empty poll at its budget without stopping a silent process", function()
    local id = background("cat", { kind = "pipes", stdin = "open" })
    local result = poll(id, nil, 20)
    assert.is_false(result.done)
    assert.is_true(result.stdin_writable)
    assert.are.equal("", result.text)
    assert.are.equal("later\n", poll(id, { kind = "write", data = "later\n" }).text)
  end)

  it("refuses admission from an already cancelled Run", function()
    local result = helper.complete(function()
      assert(async.current()):cancel()
      return prepare("exit 0", 0)
    end)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal(0, owner:status().reserved)
  end)

  for _, capacity in ipairs({ 1, 2 }) do
    it("reserves admission before reentrant placement with capacity " .. capacity, function()
      local nesting = false
      ---@type Neoagent.RunResult<Neoagent.TestProcessAdmission>?
      local nested
      owner = sessions.new({ capacity = capacity }, nil, function(spec, maximum, cleanup, released)
        if not nesting then
          nesting = true
          nested = helper.complete(function() return prepare("exec sleep 30", 0) end)
        end
        local controller = require("neoagent.process_sessions.local").new(spec, maximum, cleanup, released)
        constructed[#constructed + 1] = controller
        return controller
      end)
      local outer = helper.success(function() return prepare("exec sleep 30", 0) end)
      local outer_id = assert(outer.commit())
      local inner = assert(nested)
      if capacity == 1 then
        assert.are.equal("process_capacity", assert(inner.error).code)
      else
        assert.is_not.equal(outer_id, assert(inner.result).session_id)
        assert.is_number(assert(inner.commit)())
      end
      assert.are.equal(capacity, owner:status().reserved)
    end)
  end

  it("releases a reservation when placement fails and wakes its cleanup observers", function()
    ---@type Neoagent.Run<true, unknown>?
    local observing
    owner = sessions.new(nil, nil, function()
      assert.are.equal(1, owner:status().reserved)
      observing = async.run(function() return owner:wait_release(1000) end)
      error(require("neoagent.util").error("sandbox_unavailable", "placement rejected"), 0)
    end)
    local result = helper.complete(function() return prepare("exit 0", 0) end)
    assert.are.equal("placement rejected", assert(result.error).message)
    assert.is_true(helper.wait(assert(observing)))
    assert.are.equal(0, owner:status().reserved)
  end)

  for _, revoke in ipairs({ "close", "cancel" }) do
    it("revokes admission during placement through " .. revoke, function()
      local starts = 0
      owner = sessions.new(nil, nil, function(spec, maximum, cleanup, released)
        if revoke == "close" then owner:close("placement revoked") else assert(async.current()):cancel() end
        local controller = require("neoagent.process_sessions.local").new(spec, maximum, cleanup, released)
        constructed[#constructed + 1] = controller
        local start = controller.start
        function controller:start() starts = starts + 1; return start(self) end
        return controller
      end)
      local result = helper.complete(function() return prepare("exec sleep 30", 0) end)
      assert.are.equal(0, starts)
      if revoke == "close" then
        assert.are.equal("process_disposed", assert(result.error).code)
      else
        assert.are.equal("cancelled", assert(result.error).kind)
      end
      assert.is_true(helper.complete(function() return owner:wait_release(1000) end))
      assert.are.equal(0, owner:status().reserved)
    end)
  end

  it("rejects cancelled controls and leaves already buffered output unread", function()
    ---@type Neoagent.ProcessController?
    local controller
    owner = sessions.new(nil, nil, function(spec, maximum, cleanup, released)
      controller = require("neoagent.process_sessions.local").new(spec, maximum, cleanup, released)
      return controller
    end)
    local id = background("cat", { kind = "pipes", stdin = "open" })
    local result = helper.complete(function()
      assert(async.current()):cancel()
      return owner:interact(id, 0, { kind = "close_stdin" })
    end)
    assert.are.equal("cancelled", assert(result.error).kind)
    helper.success(function()
      assert(controller):control({ kind = "write", data = "preserved\n" })
      assert(controller):control({ kind = "close_stdin" })
      return assert(controller):wait()
    end)
    result = helper.complete(function()
      assert(async.current()):cancel()
      return owner:interact(id, 0)
    end)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal("preserved\n", poll(id, nil, 0).text)
  end)

  it("reports disposal exceptions while continuing to release other retained processes", function()
    ---@type Neoagent.Error[]
    local failures = {}
    local wrapped = false
    owner = sessions.new({ capacity = 2 }, function(err) failures[#failures + 1] = err end,
      function(spec, maximum, on_cleanup, on_released)
        local controller = require("neoagent.process_sessions.local").new(spec, maximum, on_cleanup, on_released)
        if wrapped then return controller end
        wrapped = true
        local dispose = controller.dispose
        function controller:dispose(reason)
          dispose(self, reason)
          error(require("neoagent.util").error("process_cleanup", "disposal observer failed"), 0)
        end
        return controller
      end)
    local admission = helper.success(function() return prepare("exec sleep 30", 0) end)
    assert(admission.commit())
    background("exec sleep 30")
    owner:close("release every target")
    assert.is_true(helper.complete(function() return owner:wait_release(3000) end))
    assert.are.equal(0, owner:status().reserved)
    assert.are.equal(1, #failures)
    assert.matches("disposal observer failed", assert(failures[1]).message, 1, true)
    assert.are.equal("process_cleanup", assert(helper.complete(function() return owner:wait_cleanup(3000) end).error).kind)
  end)

  it("leaves output unread when cancellation wins after a control has already taken effect", function()
    local cancel = true
    owner = sessions.new(nil, nil, function(spec, maximum, cleanup, released)
      local controller = require("neoagent.process_sessions.local").new(spec, maximum, cleanup, released)
      local control = controller.control
      function controller:control(command)
        local result = control(self, command)
        if cancel then cancel = false; assert(async.current()):cancel() end
        return result
      end
      return controller
    end)
    local id = background("cat", { kind = "pipes", stdin = "open" })
    local result = helper.complete(function() return owner:interact(id, 0, { kind = "write", data = "received\n" }) end)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal("received\n", poll(id).text)
  end)

  it("bounds cleanup observers independently of the retained process lifetime", function()
    local id = background("cat", { kind = "pipes", stdin = "open" })
    local cleanup = helper.complete(function() return owner:wait_cleanup(10) end)
    local release = helper.complete(function() return owner:wait_release(10) end)
    assert.are.equal("process_cleanup", assert(cleanup.error).code)
    assert.are.equal("process_cleanup", assert(release.error).code)
    assert.are.equal(1, owner:status().reserved)
    assert.is_nil(owner:status().cleanup_error)
    assert.are.equal("owned\n", poll(id, { kind = "write", data = "owned\n" }).text)
  end)

  it("releases failed native admission and permits a later process", function()
    local result = helper.complete(function()
      return helper.admit(owner, helper.spec("", { argv = { "/neoagent-missing-retained-executable" } }), 0)
    end)
    assert.are.equal("process_start", assert(result.error).code)
    assert.is_true(helper.complete(function() return owner:wait_cleanup(3000) end))
    assert.is_true(helper.complete(function() return owner:wait_release(3000) end))
    assert.are.equal(0, owner:status().reserved)
    local next_admission = helper.success(function() return prepare("printf recovered", 1000) end)
    assert.are.equal("recovered", next_admission.result.text)
    assert.is_nil(next_admission.commit())
  end)

  it("retains stable IDs and consumes only new output through serialized controls", function()
    local id = background("cat", { kind = "pipes", stdin = "open" })
    local one = poll(id, { kind = "write", data = "one\n" })
    assert.are.equal(id, one.session_id)
    assert.are.equal("one\n", one.text)
    assert.are.equal("", poll(id, nil, 0).text)
    assert.are.equal("two\n", poll(id, { kind = "write", data = "two\n" }).text)
    local final = poll(id, { kind = "close_stdin" })
    if not final.done then
      final = poll(id)
    end
    assert.is_true(final.done)
    assert.are.equal(0, assert(final.outcome).code)
    local history = owner:history(id)
    local text = {}
    for _, event in ipairs(history) do
      text[#text + 1] = event.data
    end
    assert.are.equal("one\ntwo\n", table.concat(text))
  end)

  it("terminates an uncommitted admission when its initial observer cancels", function()
    local waiting = async.run(function()
      return prepare("exec sleep 30", 30000)
    end)
    assert.are.equal(1, owner:status().provisional)
    waiting:cancel()
    assert.are.equal("cancelled", assert(helper.wait(waiting).error).kind)
    assert.is_true(helper.complete(function()
      return owner:wait_release(3000)
    end))
    assert.are.equal(0, owner:status().reserved)
  end)

  it("rejects provisional IDs and revokes unpublished handoffs", function()
    local admission = helper.success(function()
      return prepare("exec sleep 30", 0)
    end)
    local id = assert(admission.result.session_id)
    assert.are.equal("process_session_missing", poll_failure(id).code)
    admission.abort("result was not committed")
    assert.are.equal("process_disposed", helper.failure(admission.commit).code)
    assert.is_true(helper.complete(function()
      return owner:wait_release(3000)
    end))
  end)

  it("preserves committed work when a poll is cancelled and rejects competing interactions", function()
    local id = background("cat", { kind = "pipes", stdin = "open" })
    local waiting = async.run(function()
      return owner:interact(id, 30000)
    end)
    assert.are.equal("process_session_busy", poll_failure(id).code)
    waiting:cancel()
    assert.are.equal("cancelled", assert(helper.wait(waiting).error).kind)
    assert.are.equal("alive\n", poll(id, { kind = "write", data = "alive\n" }).text)
  end)

  it("bounds pending output and history while continuing to drain the target", function()
    local id = background("head -c 200000 /dev/zero; printf END")
    assert(vim.wait(3000, function()
      return owner:status().completed == 1
    end, 5))
    local final = poll(id)
    assert.is_true(final.done)
    assert.are.equal(0, assert(final.outcome).code)
    local bytes = 0
    for _, event in ipairs(final.events) do
      bytes = bytes + #event.data
    end
    assert.are.equal(64, bytes)
    assert.are.equal(200003 - 64, final.dropped_bytes)
    assert.matches("END$", final.text)
    assert.are.equal(0, poll(id, nil, 0).dropped_bytes)
  end)

  it("preserves incomplete UTF-8 independently for stdout and stderr across polls", function()
    local id = background("read x; printf '\\342\\202'; read x; printf E >&2; printf '\\254'; read x; printf '\\360'", {
      kind = "pipes",
      stdin = "open",
    })
    assert.are.equal("", poll(id, { kind = "write", data = "a\n" }).text)
    local second = poll(id, { kind = "write", data = "b\n" })
    local text = second.text
    if not text:find("€", 1, true) or not text:find("E", 1, true) then
      text = text .. poll(id).text
    end
    assert.is_truthy((text:find("€", 1, true)))
    assert.is_truthy((text:find("E", 1, true)))
    local final = poll(id, { kind = "write", data = "c\n" })
    text = final.text
    if not final.done then
      text = text .. poll(id).text
    end
    assert.are.equal("\\xF0", text)
  end)

  it("rejects capacity pressure without evicting live or provisional processes", function()
    local first = background("cat", { kind = "pipes", stdin = "open" })
    local provisional = helper.success(function()
      return prepare("exec sleep 30", 0)
    end)
    assert.are.equal(
      "process_capacity",
      assert(helper.complete(function()
        return prepare("exit 0", 0)
      end).error).code
    )
    assert.are.equal("still here\n", poll(first, { kind = "write", data = "still here\n" }).text)
    provisional.abort("release provisional slot")
    poll(first, { kind = "close_stdin" })
    assert.is_true(helper.complete(function()
      return owner:wait_release(3000)
    end))
    assert.are.equal(0, owner:status().reserved)
  end)

  it("keeps the lifetime deadline active after handoff", function()
    local admission = helper.success(function()
      return helper.admit(owner, helper.spec("exec sleep 30", { timeout_ms = 30, kill_grace_ms = 0 }), 0)
    end)
    local id = assert(admission.commit())
    local final = poll(id)
    assert.is_true(final.done)
    assert.is_true(assert(final.outcome).timed_out)
    assert.are.equal("timeout", assert(final.outcome).termination_reason)
  end)

  it("retains only the configured number of completed records", function()
    local ids = {}
    for index = 1, 3 do
      ids[index] = background("read value; printf $value", { kind = "pipes", stdin = "open" })
      poll(ids[index], { kind = "write", data = tostring(index) .. "\n" })
      assert.is_true(helper.complete(function()
        return owner:wait_release(3000)
      end))
    end
    assert.are.equal(2, owner:status().completed)
    assert.are.equal("process_session_missing", poll_failure(ids[1]).code)
    assert.is_true(poll(ids[3], nil, 0).done)
    owner:forget(ids[2])
    assert.are.equal("process_session_missing", poll_failure(ids[2]).code)
  end)

  for _, stage in ipairs({ "release", "interaction" }) do
    it("enforces retention when the last eligibility transition is " .. stage, function()
      ---@type {native: boolean, observed: boolean, published: boolean, publish: fun(), pending?: Neoagent.AwaitCallbacks<true>}[]
      local records = {}
      owner = sessions.new({ capacity = 2, completed = 1 }, nil, function(spec, maximum, cleanup, released)
        local notify_release = (assert(released))
        local record = { native = false, observed = false, published = stage ~= "release" }
        record.publish = function()
          record.published = true
          if record.native then notify_release() end
        end
        records[#records + 1] = record
        local first = #records == 1
        local controller = require("neoagent.process_sessions.local").new(spec, maximum, cleanup, function()
          record.native = true
          if record.published then notify_release() end
        end)
        local state, collect, wait = controller.state, controller.collect, controller.wait
        function controller:state()
          local value = state(self)
          value.released = value.released and record.published
          return value
        end
        function controller:collect(wait_ms, until_exit)
          local value = collect(self, wait_ms, until_exit)
          value.released = value.released and record.published
          if first and stage == "interaction" and value.done then
            async.await(function(done) record.pending = done end)
          end
          return value
        end
        function controller:wait()
          wait(self)
          -- Observe after the manager's completion callback has reconsidered
          -- retention, while release or interaction is still outstanding.
          assert(async.current()):_listen(function() record.observed = true end)
          return true
        end
        return controller
      end)
      ---@type integer?
      local first, second
      ---@type Neoagent.Run<Neoagent.ProcessSessionResult, unknown>?
      local collecting
      local checked, failure = pcall(function()
        first = background("cat", { kind = "pipes", stdin = "open" })
        second = background("cat", { kind = "pipes", stdin = "open" })
        collecting = async.run(function() return owner:interact(first, 1000, { kind = "close_stdin" }) end)
        assert(vim.wait(3000, function()
          return assert(collecting):is_done() or assert(records[1]).pending ~= nil
        end, 5))
        poll(second, { kind = "close_stdin" })
        assert(vim.wait(3000, function()
          for _, record in ipairs(records) do
            if not record.native or not record.observed then return false end
          end
          return true
        end, 5))
      end)
      for _, record in ipairs(records) do
        record.publish()
        if record.pending then record.pending.resolve(true) end
      end
      if collecting then helper.wait(collecting) end
      assert.is_true(checked, vim.inspect(failure))
      assert(vim.wait(1000, function() return not pcall(owner.history, owner, assert(first)) end, 5),
        "the oldest completed record survived its retention eligibility transition")
      assert.is_table(owner:history(assert(second)))
    end)
  end

  it("keeps a newly committed handoff available when it completed before newer retained records", function()
    owner = sessions.new({ capacity = 2, completed = 1 })
    local admission = helper.success(function() return prepare("exit 0", 0) end)
    assert(admission.result.session_id)
    assert.is_true(helper.complete(function() return owner:wait_release(3000) end))
    local newer = background("exit 0")
    assert.is_true(helper.complete(function() return owner:wait_release(3000) end))
    local id = assert(admission.commit())
    assert.is_true(poll(id, nil, 0).done)
    assert.are.equal("process_session_missing", poll_failure(newer).code)
  end)

  it("publishes completed handoff before completion observers have resumed", function()
    local hold = true
    ---@type Neoagent.AwaitCallbacks<true>[]
    local observations = {}
    ---@type Neoagent.ProcessController?
    local first
    local checked, failure = pcall(function()
      owner = sessions.new({ capacity = 3, completed = 1 }, nil, function(spec, maximum, cleanup, released)
        local controller = require("neoagent.process_sessions.local").new(spec, maximum, cleanup, released)
        first = first or controller
        local wait = controller.wait
        function controller:wait()
          wait(self)
          if hold then async.await(function(done) observations[#observations + 1] = done end) end
          return true
        end
        return controller
      end)
      local admission = helper.success(function() return prepare("cat", 0, { kind = "pipes", stdin = "open" }) end)
      local newer
      for _ = 1, 2 do
        newer = background("exit 0")
        assert.is_true(poll(newer).done)
      end
      assert(first):control({ kind = "close_stdin" })
      assert(vim.wait(2000, function() return #observations == 3 and assert(first):state().released end, 5))
      local id = assert(admission.commit())
      assert.is_true(poll(id, nil, 0).done)
      assert.are.equal("process_session_missing", poll_failure(newer).code)
    end)
    hold = false
    for _, observation in ipairs(observations) do observation.resolve(true) end
    assert.is_true(checked, vim.inspect(failure))
  end)

  it("closes every retained process and rejects later admission", function()
    local first = background("exec sleep 30")
    background("exec sleep 30", { kind = "pty", columns = 80, rows = 24 })
    owner:close("Agent destroyed")
    assert.are.equal("process_disposed", poll_failure(first).code)
    assert.are.equal(
      "process_disposed",
      assert(helper.complete(function()
        return prepare("exit 0", 0)
      end).error).code
    )
    assert.is_true(helper.complete(function()
      return owner:wait_release(3000)
    end))
  end)
end)
