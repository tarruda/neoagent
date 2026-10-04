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
  before_each(function()
    owner = sessions.new({ capacity = 2, completed = 2, output_bytes = 64 })
  end)
  after_each(function()
    owner:close("test finished")
    helper.complete(function()
      return owner:wait_cleanup(4000)
    end)
    assert.is_true(helper.complete(function()
      return owner:wait_release(4000)
    end))
  end)
  ---@async
  local function prepare(command, milliseconds, stdio)
    return owner:prepare(helper.spec(command, { stdio = stdio }), milliseconds)
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
      { kind = "resize", columns = 0, rows = 24 },
      { kind = "terminate", reason = "" },
    }) do
      local result = helper.complete(function() return owner:interact(id, 0, command) end)
      assert.is_false(result.ok)
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

  it("reports disposal exceptions while continuing to release other retained processes", function()
    ---@type Neoagent.Error[]
    local failures = {}
    owner = sessions.new({ capacity = 2 }, function(err) failures[#failures + 1] = err end)
    local admission = helper.success(function()
      return owner:prepare(helper.spec("exec sleep 30"), 0, function(spec, maximum, on_cleanup)
        local controller = require("neoagent.process_sessions.local").new(spec, maximum, on_cleanup)
        local dispose = controller.dispose
        function controller:dispose(reason)
          dispose(self, reason)
          error(require("neoagent.util").error("process_cleanup", "disposal observer failed"), 0)
        end
        return controller
      end)
    end)
    assert(admission.commit())
    background("exec sleep 30")
    owner:close("release every target")
    assert.is_true(helper.complete(function() return owner:wait_release(3000) end))
    assert.are.equal(0, owner:status().reserved)
    assert.are.equal(1, #failures)
    assert.matches("disposal observer failed", assert(failures[1]).message, 1, true)
    assert.are.equal("process_cleanup", assert(helper.complete(function() return owner:wait_cleanup(3000) end).error).kind)
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
      return owner:prepare(helper.spec("", { argv = { "/neoagent-missing-retained-executable" } }), 0)
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
      return owner:prepare(helper.spec("exec sleep 30", { timeout_ms = 30, kill_grace_ms = 0 }), 0)
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
