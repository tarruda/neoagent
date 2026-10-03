local assert = require("luassert")
local async = require("neoagent.async")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")

describe("local subprocess pipes", function()
  if jit.os == "Windows" then
    pending("POSIX commands; native Windows commands run in tests/windows")
    return
  end
  local scopes = {}
  local function scope()
    local owner = subprocess.scope()
    scopes[#scopes + 1] = owner
    return owner
  end
  after_each(function()
    for _, owner in ipairs(scopes) do
      owner:close("test finished")
      assert.is_true(helper.complete(function()
        return owner:wait(4000)
      end))
    end
    scopes = {}
  end)

  it("defaults to closed stdin and preserves separate binary output", function()
    local events = {}
    local result = helper.complete(function()
      return subprocess.run(helper.spec("cat; printf '\\000\\377out'; printf 'err\\000' >&2"), {
        capture = { max_bytes = 100 },
        on_output = function(event)
          events[#events + 1] = event
        end,
      })
    end)
    assert.are.equal(0, result.code)
    assert.are.equal("\0\255out", result.stdout)
    assert.are.equal("err\0", result.stderr)
    local combined = {}
    for _, event in ipairs(events) do
      combined[#combined + 1] = event.data
    end
    assert.are.equal(table.concat(combined), result.output)
    assert.is_true(result.duration_ms >= 0)
    assert.is_true(result.finished_at_ns >= result.started_at_ns)
  end)

  it("sends large initial chunks without adding newlines and drains trailing output", function()
    local bytes = ("a\0\255\nb"):rep(300000)
    local result = helper.complete(function()
      return subprocess.run(helper.spec("cat", { stdio = { kind = "pipes", stdin = "open" } }), {
        capture = { max_bytes = #bytes },
        input = { chunks = { "", bytes:sub(1, 17777), bytes:sub(17778) }, close = true },
      })
    end)
    assert.are.equal(bytes, result.stdout)
    assert.are.equal(0, result.code)
  end)

  it("reports lifetime timeout while initial input is waiting for a reader", function()
    local result = helper.complete(function()
      return subprocess.run(
        helper.spec("sleep 10", {
          stdio = { kind = "pipes", stdin = "open" },
          timeout_ms = 50,
          kill_grace_ms = 0,
        }),
        {
          capture = false,
          input = { chunks = { ("x"):rep(2 * 1024 * 1024) }, close = true },
        }
      )
    end)
    assert.is_true(result.timed_out, vim.inspect(result))
    assert.are.equal("timeout", result.termination_reason)
  end)

  it("keeps a handle alive after one waiter is cancelled", function()
    local output = ""
    local handle = scope():spawn(helper.spec("cat", { stdio = { kind = "pipes", stdin = "open" } }), {
      on_output = function(event)
        output = output .. event.data
      end,
    })
    local cancelled = async.run(function()
      return handle:wait()
    end)
    local completed = async.run(function()
      return handle:wait()
    end)
    cancelled:cancel()
    assert.are.equal("cancelled", helper.wait(cancelled).error.kind)
    assert.are.equal("running", handle:state().phase)
    assert.is_true(handle:write("one\0"))
    assert.is_true(handle:write("two\n"))
    assert.is_true(handle:close_stdin())
    assert.is_true(handle:close_stdin())
    assert.is_true(helper.complete(function()
      return handle:flush()
    end))
    assert.are.equal(0, helper.wait(completed).code)
    assert.are.same({ true, true }, { pcall(handle.close_stdin, handle) })
    assert.are.equal("one\0two\n", output)
    local snapshot = handle:state()
    assert.are.equal("exited", snapshot.phase)
    assert(snapshot.terminal).code = 999
    assert.are.equal(
      0,
      helper.complete(function()
        return handle:wait()
      end).code
    )
    handle:dispose("completed owner")
    assert.are.equal("exited", handle:state().phase)
  end)

  it("overlays or replaces the process environment", function()
    local before = vim.env.NEOAGENT_PROCESS_SECRET
    vim.env.NEOAGENT_PROCESS_SECRET = "ambient"
    local results = {}
    for _, inherit in ipairs({ true, false }) do
      results[#results + 1] = helper.complete(function()
        return subprocess.run(
          helper.spec('printf \'%s:%s\' "$SAFE" "${NEOAGENT_PROCESS_SECRET-unset}"', {
            environment = { inherit = inherit, set = { SAFE = "value" } },
          }),
          { capture = { max_bytes = 100 } }
        )
      end)
    end
    vim.env.NEOAGENT_PROCESS_SECRET = before
    assert.are.equal("value:ambient", results[1].stdout)
    assert.are.equal("value:unset", results[2].stdout)
    local empty = helper.complete(function()
      return subprocess.run(
        helper.spec("", {
          argv = { vim.fn.exepath("env"), "-0" },
          environment = { inherit = false, set = {} },
        }),
        { capture = { max_bytes = 1024 } }
      )
    end)
    assert.are.equal(0, empty.code)
    assert.is_true(empty.stdout == "", "an exact empty environment inherited ambient values")
  end)

  it("does not retain output for an explicitly non-capturing run", function()
    local count = 0
    local result = helper.complete(function()
      return subprocess.run(helper.spec("head -c 1048576 /dev/zero"), {
        capture = false,
        on_output = function(event)
          assert.is_true(#event.data <= 65536)
          count = count + #event.data
        end,
      })
    end)
    assert.are.equal(1048576, count)
    assert.are.equal("", result.stdout)
    assert.are.equal("", result.stderr)
    assert.are.equal("", result.output)
  end)

  it("reports capture overflow as its own failure", function()
    local result = helper.complete(function()
      return subprocess.run(helper.spec("printf 12345; sleep 10"), { capture = { max_bytes = 4 } })
    end)
    assert.are.equal("output_limit", assert(result.error).code)
  end)

  it("terminates a failed or yielding observer and keeps errors bounded", function()
    for _, observer in ipairs({
      function()
        error("private output\0" .. ("x"):rep(10000))
      end,
      coroutine.yield,
    }) do
      local handle = scope():spawn(helper.spec("printf ready; sleep 10"), { on_output = observer })
      local result = helper.complete(function()
        return handle:wait()
      end)
      assert.are.equal("process_observer", assert(result.error).kind)
      assert.is_nil(assert(result.error).detail)
      assert.are.equal("failed", handle:state().phase)
      assert.is_true(helper.complete(function()
        return handle:wait_cleanup()
      end))
    end
  end)

  it("preserves a lifetime deadline after the initial waiter leaves", function()
    local handle = scope():spawn(helper.spec("trap '' TERM; printf ready; while :; do sleep 1; done", {
      timeout_ms = 200,
      kill_grace_ms = 10,
    }))
    local first = async.run(function()
      return handle:wait()
    end)
    first:cancel()
    assert.are.equal("cancelled", helper.wait(first).error.kind)
    local outcome = helper.complete(function()
      return handle:wait()
    end)
    assert.is_true(outcome.timed_out)
    assert.are.equal(137, outcome.code)
    assert.are.equal("timeout", outcome.termination_reason)
  end)

  it("disposes a cancelled run before cancellation escapes", function()
    local owner = scope()
    local ready = false
    local run = async.run(function()
      return owner:run(helper.spec("printf ready; sleep 10"), {
        capture = false,
        on_output = function()
          ready = true
        end,
      })
    end)
    assert(vim.wait(3000, function()
      return ready
    end, 5))
    run:cancel()
    assert.are.equal("cancelled", helper.wait(run).error.kind)
    assert.is_true(helper.complete(function()
      return owner:wait(3000)
    end))
  end)

  it("preserves cancellation while initial input is waiting for a reader", function()
    local owner = scope()
    local ready = false
    local run = async.run(function()
      return owner:run(helper.spec("printf ready; exec sleep 10", { stdio = { kind = "pipes", stdin = "open" } }), {
        capture = false,
        input = { chunks = { ("x"):rep(2 * 1024 * 1024) }, close = true },
        on_output = function()
          ready = true
        end,
      })
    end)
    assert(vim.wait(3000, function()
      return ready
    end, 5))
    run:cancel()
    local result = helper.wait(run)
    assert.is_true(helper.complete(function()
      return owner:wait(3000)
    end))
    assert.are.equal("cancelled", assert(result.error).kind)
  end)

  it("preserves owner disposal while initial input is waiting for a reader", function()
    local owner = scope()
    local ready = false
    local run = async.run(function()
      return owner:run(helper.spec("printf ready; exec sleep 10", { stdio = { kind = "pipes", stdin = "open" } }), {
        capture = false,
        input = { chunks = { ("x"):rep(2 * 1024 * 1024) }, close = true },
        on_output = function()
          ready = true
        end,
      })
    end)
    assert(vim.wait(3000, function()
      return ready
    end, 5))
    owner:close("owner ended during input")
    assert.are.equal("process_disposed", assert(helper.wait(run).error).code)
    assert.is_true(helper.complete(function()
      return owner:wait(3000)
    end))
  end)

  it("preserves capture failure while initial input is waiting for a reader", function()
    local result = helper.complete(function()
      return scope():run(helper.spec("printf ready; exec sleep 10", { stdio = { kind = "pipes", stdin = "open" } }), {
        capture = { max_bytes = 4 },
        input = { chunks = { ("x"):rep(2 * 1024 * 1024) }, close = true },
      })
    end)
    assert.are.equal("output_limit", assert(result.error).code)
  end)

  it("awaits the actual exit after explicitly allowing partial input consumption", function()
    for _, code in ipairs({ 0, 7 }) do
      local result = helper.complete(function()
        return scope():run(helper.spec("head -c 1; exit " .. code, { stdio = { kind = "pipes", stdin = "open" } }), {
          capture = { max_bytes = 32 },
          input = { chunks = { ("x"):rep(2 * 1024 * 1024) }, close = true, allow_early_close = true },
        })
      end)
      assert.are.equal(code, result.code)
      assert.are.equal("x", result.stdout)
    end
  end)

  it("closes only its own targets and refuses work after closure", function()
    local first, second = scope(), scope()
    local a = first:spawn(helper.spec("sleep 10"))
    local b = second:spawn(helper.spec("sleep 10"))
    first:close("owner finished")
    first:close("again")
    assert.are.equal(
      "process_disposed",
      assert(helper.complete(function()
        return a:wait()
      end).error).code
    )
    assert.is_true(helper.complete(function()
      return a:wait_cleanup()
    end))
    assert.are.equal("running", b:state().phase)
    local err = helper.failure(function()
      first:spawn(helper.spec("true"))
    end)
    assert.are.equal("process_disposed", err.code)
    b:terminate("stop")
    b:terminate("ignored")
    assert.are.equal(
      "stop",
      helper.complete(function()
        return b:wait()
      end).termination_reason
    )
  end)

  it("bounds pending bytes and writes independently and lets callers cancel flush", function()
    for _, bytes in ipairs({ "x", ("x"):rep(65536) }) do
      local handle = scope():spawn(helper.spec("sleep 10", { stdio = { kind = "pipes", stdin = "open" } }))
      local count = #bytes == 1 and 64 or 16
      for _ = 1, count do
        handle:write(bytes)
      end
      local err = helper.failure(function()
        handle:write(bytes)
      end)
      assert.are.equal("input_limit", err.code)
      local flush = async.run(function()
        return handle:flush()
      end)
      flush:cancel()
      assert.are.equal("cancelled", assert(helper.wait(flush).error).kind)
      assert.are.equal("running", handle:state().phase)
      handle:dispose("input owner finished")
      assert.is_true(helper.complete(function()
        return handle:wait_cleanup()
      end))
    end
  end)

  it("preserves a cancelled flush when its owner disposes before it resumes", function()
    local handle = scope():spawn(helper.spec("exec sleep 10", { stdio = { kind = "pipes", stdin = "open" } }))
    for _ = 1, 16 do
      handle:write(("x"):rep(65536))
    end
    local flush = async.run(function()
      return handle:flush()
    end)
    flush:cancel()
    handle:dispose("input owner finished")
    local result = helper.wait(flush)
    assert.is_true(helper.complete(function()
      return handle:wait_cleanup()
    end))
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal("disposed", handle:state().phase)
  end)

  it("reports a broken input pipe without converting it into a target exit", function()
    local ready = false
    local handle = scope():spawn(
      helper.spec("exec 0<&-; printf ready; sleep 10", {
        stdio = { kind = "pipes", stdin = "open" },
      }),
      {
        on_output = function()
          ready = true
        end,
      }
    )
    assert(vim.wait(3000, function()
      return ready
    end, 5))
    local result = helper.complete(function()
      handle:write("data")
      return handle:flush()
    end)
    assert.are.equal("stdin_closed", assert(result.error).code)
    assert.are.equal("running", handle:state().phase)
    assert.is_false(handle:state().stdin_writable)
    assert.are.equal(
      "stdin_closed",
      helper.failure(function()
        handle:write("again")
      end).code
    )
    assert.are.equal(
      "stdin_closed",
      helper.failure(function()
        handle:close_stdin()
      end).code
    )
  end)

  it("rejects invalid and unavailable controls with stable codes", function()
    local handle = scope():spawn(helper.spec("sleep 10"))
    assert.are.equal(
      "stdin_closed",
      helper.failure(function()
        handle:write("input")
      end).code
    )
    assert.is_true(handle:close_stdin())
    assert.are.equal(
      "unsupported_control",
      helper.failure(function()
        handle:resize(80, 24)
      end).code
    )
    assert.are.equal(
      "invalid_terminal_size",
      helper.failure(function()
        handle:resize(0, 24)
      end).code
    )
    assert.are.equal(
      "process_validation",
      helper.failure(function()
        handle:write(("x"):rep(65537))
      end).code
    )
    assert.are.equal(
      "process_validation",
      helper.failure(function()
        handle:terminate("")
      end).code
    )
    handle:terminate("end")
    assert.are.equal(
      "process_terminal",
      helper.failure(function()
        handle:write("x")
      end).code
    )
    helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal(
      "process_terminal",
      helper.failure(function()
        handle:resize(80, 24)
      end).code
    )
  end)

  it("kills a process group's children even when its leader exits first", function()
    local marker = vim.fn.tempname()
    local result = helper.complete(function()
      return subprocess.run(helper.spec("(sleep 0.2; printf late > " .. vim.fn.shellescape(marker) .. ") & exit 0"), {
        capture = false,
      })
    end)
    local escaped = vim.wait(400, function()
      return vim.uv.fs_stat(marker) ~= nil
    end, 5)
    vim.fn.delete(marker)
    assert.are.equal(0, result.code)
    assert.is_false(escaped)
  end)

  it("reports non-zero exit and missing executable without inventing outcomes", function()
    local result = helper.complete(function()
      return subprocess.run(helper.spec("exit 17"), { capture = false })
    end)
    assert.are.equal(17, result.code)
    local owner = scope()
    local err = helper.failure(function()
      owner:spawn(helper.spec("", { argv = { "/neoagent-does-not-exist" } }))
    end)
    assert.are.equal("process_start", err.code)
    assert.is_true(helper.complete(function()
      return owner:wait(1000)
    end))
  end)
end)
