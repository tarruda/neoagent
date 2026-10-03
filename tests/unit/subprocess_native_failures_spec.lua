local assert = require("luassert")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")
local limits = require("neoagent.subprocess.validate")

describe("subprocess native failures", function()
  if jit.os == "Windows" then
    pending("POSIX native children; Windows has its native suite")
    return
  end
  local new_pipe, read_start, write = vim.uv.new_pipe, vim.uv.read_start, vim.uv.write
  local kill = vim.uv.kill
  local reap_ms = limits.REAP_MS
  local pipe = require("neoagent.subprocess.pipe")
  local new_driver = pipe.new
  local cleanup_failure = false
  ---@type Neoagent.SubprocessScope
  local owner
  ---@type Neoagent.WorkerLease?
  local worker

  before_each(function()
    owner = subprocess.scope()
    worker = nil
    cleanup_failure = false
  end)
  after_each(function()
    vim.uv.new_pipe, vim.uv.read_start, vim.uv.write = new_pipe, read_start, write
    vim.uv.kill = kill
    limits.REAP_MS = reap_ms
    pipe.new = new_driver
    if worker then
      worker:dispose("test finished")
      helper.complete(function()
        return assert(worker):wait()
      end)
    end
    owner:close("test finished")
    local cleaned = helper.complete(function()
      return owner:wait(4000)
    end)
    if cleanup_failure then
      assert.are.equal("process_cleanup", assert(cleaned.error).code)
    else
      assert.is_true(cleaned)
    end
  end)

  it("drains buffered output after the editor was blocked beyond the cleanup interval", function()
    limits.REAP_MS = 20
    local interval_passed = false
    pipe.new = function(spec, env, callbacks)
      local exited = callbacks.exited
      callbacks.exited = function(code, signal)
        exited(code, signal)
        local timer = assert(vim.uv.new_timer())
        timer:start(40, 0, function()
          timer:close()
          interval_passed = true
        end)
      end
      return new_driver(spec, env, callbacks)
    end
    local bytes = 0
    local handle = owner:spawn(helper.spec("head -c 100000 /dev/zero"), {
      on_output = function(event)
        bytes = bytes + #event.data
      end,
    })
    assert(vim.wait(2000, function()
      return interval_passed
    end, 5, true))
    local result = helper.complete(function()
      return handle:wait()
    end)
    cleanup_failure = handle:state().phase == "failed"
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal(100000, bytes)
  end)

  for _, kind in ipairs({ "handle", "worker" }) do
    it("drains " .. kind .. " output when editor delivery stalls after cleanup timing starts", function()
      limits.REAP_MS = 20
      ---@type {stream: uv.uv_stream_t, callback: uv.read_start.callback}[]
      local readers = {}
      local released = false
      vim.uv.read_start = function(stream, callback)
        if released then
          return read_start(stream, callback)
        end
        readers[#readers + 1] = { stream = stream, callback = callback }
        return 0
      end
      local blocked = false
      pipe.new = function(spec, env, callbacks, input_limits)
        local exited = callbacks.exited
        callbacks.exited = function(code, signal)
          exited(code, signal)
          -- The owner's earlier scheduled callback arms its drain timer.
          vim.schedule(function()
            released = true
            for _, reader in ipairs(readers) do
              assert(read_start(reader.stream, reader.callback))
            end
            local elapsed = false
            local timer = assert(vim.uv.new_timer())
            timer:start(60, 0, function()
              timer:close()
              elapsed = true
            end)
            blocked = vim.wait(1000, function()
              return elapsed
            end, 5, true)
          end)
        end
        return new_driver(spec, env, callbacks, input_limits)
      end
      local output = ""
      local result
      if kind == "handle" then
        local handle = owner:spawn(helper.spec("printf buffered"), {
          on_output = function(event)
            output = output .. event.data
          end,
        })
        result = helper.complete(function()
          return handle:wait()
        end)
        cleanup_failure = handle:state().phase == "failed"
      else
        worker = require("neoagent.rpc.worker_lease").start({
          argv = { "sh", "-c", "printf buffered" },
          cwd = assert(vim.uv.cwd()),
          env = { PATH = assert(vim.env.PATH) },
          reap_grace_ms = 20,
          on_stdout = function(bytes)
            output = output .. bytes
          end,
        })
        result = helper.complete(function()
          return assert(worker):wait()
        end)
      end
      assert.is_true(blocked)
      assert.is_nil(result.error, vim.inspect(result))
      assert.are.equal(0, result.code)
      assert.are.equal("buffered", output)
    end)
  end

  it("drops queued output after a forced cleanup deadline closes the streams", function()
    limits.REAP_MS = 20
    cleanup_failure = true
    ---@type uv.read_start.callback?
    local receive
    vim.uv.read_start = function(_, callback)
      receive = callback
      return 0
    end
    local observed = 0
    local handle = owner:spawn(helper.spec("sleep 10"), {
      on_output = function()
        observed = observed + 1
      end,
    })
    handle:dispose("owner ended")
    local ready = false
    vim.schedule(function()
      ready = true
    end)
    assert(vim.wait(1000, function()
      return ready
    end, 5))
    local injected = false
    local timer = assert(vim.uv.new_timer())
    timer:start(40, 0, function()
      timer:close()
      assert(receive)(nil, "queued output")
      injected = true
    end)
    -- Queue native completion and late output without running editor callbacks.
    assert(vim.wait(1000, function()
      return injected
    end, 5, true))
    assert.are.equal(
      "process_cleanup",
      assert(helper.complete(function()
        return handle:wait_cleanup()
      end).error).code
    )
    assert.are.equal(0, observed)
  end)

  for _, kind in ipairs({ "pipes", "pty" }) do
    it("terminates the " .. kind .. " leader when its process group cannot be signalled", function()
      vim.uv.kill = function(pid, signal)
        if pid < 0 then
          return nil, "ESRCH", "ESRCH"
        end
        return kill(pid, signal)
      end
      local handle = owner:spawn(helper.spec("exec sleep 10", {
        stdio = kind == "pipes" and { kind = "pipes" } or { kind = "pty", columns = 80, rows = 24 },
      }))
      handle:terminate("group signal failed")
      assert.are.equal(
        "group signal failed",
        helper.complete(function()
          return handle:wait()
        end).termination_reason
      )
    end)
  end

  it("owns allocated pipes through failure to allocate the remaining streams", function()
    local created = 0
    vim.uv.new_pipe = function(ipc)
      created = created + 1
      if created == 2 then
        error("native allocation failed")
      end
      return new_pipe(ipc)
    end
    assert.are.equal(
      "process_start",
      helper.failure(function()
        owner:spawn(helper.spec("sleep 10"))
      end).code
    )
    assert.is_false(owner:is_settled(), "allocated pipes still have pending close callbacks")
    assert.is_true(helper.complete(function()
      return owner:wait(1000)
    end))
  end)

  for refused = 1, 3 do
    it("allocates lifecycle timer " .. refused .. " before starting a target", function()
      local new_timer, spawn = vim.uv.new_timer, vim.uv.spawn
      local allocated, launched = 0, 0
      vim.uv.new_timer = function()
        allocated = allocated + 1
        if allocated == refused then
          error("native timer allocation failed")
        end
        return new_timer()
      end
      vim.uv.spawn = function(...)
        launched = launched + 1
        return spawn(...)
      end
      local ok, err = pcall(owner.spawn, owner, helper.spec("exec sleep 10", { timeout_ms = 5000 }))
      vim.uv.new_timer, vim.uv.spawn = new_timer, spawn
      assert.is_false(ok)
      assert.are.equal(0, launched, "a target started without its required lifecycle timers")
      assert(type(err) == "table")
      assert.are.equal("process_start", require("neoagent.util").normalize_error(err).code)
      assert.is_true(owner:is_settled())
    end)
  end

  it("can terminate a published target without allocating another timer", function()
    local handle = owner:spawn(helper.spec("exec sleep 10", { timeout_ms = 5000 }))
    local new_timer = vim.uv.new_timer
    vim.uv.new_timer = function()
      error("native timer allocation failed")
    end
    local ok, err = pcall(handle.terminate, handle, "finished")
    vim.uv.new_timer = new_timer
    assert.is_true(ok, vim.inspect(err))
    assert.are.equal(
      "finished",
      helper.complete(function()
        return handle:wait()
      end).termination_reason
    )
  end)

  it("reports asynchronous worker input failure through its retained lease", function()
    vim.uv.write = function(stream, bytes, completed)
      return write(stream, bytes, function()
        assert(completed)("EPIPE")
      end)
    end
    worker = require("neoagent.rpc.worker_lease").start({
      argv = { "sh", "-c", "exec sleep 10" },
      cwd = assert(vim.uv.cwd()),
      env = { PATH = assert(vim.env.PATH) },
    })
    assert.is_true((worker:write("accepted input")))
    local result = helper.complete(function()
      return assert(worker):wait()
    end)
    assert.are.equal("worker_exit", assert(result.error).kind)
    assert.matches("Worker input failed", assert(result.error).message, 1, true)
    assert.is_nil(result.cleanup_error)
  end)

  it("rejects spawn and cleans the target when starting an output reader fails", function()
    vim.uv.read_start = function()
      return nil, "EIO"
    end
    local failure = helper.failure(function()
      owner:spawn(helper.spec("sleep 10"))
    end)
    vim.uv.read_start = read_start
    assert.are.equal("process_stream", failure.code)
    assert.is_true(helper.complete(function()
      return owner:wait(3000)
    end))
  end)

  it("reports a native read error without publishing a successful exit", function()
    vim.uv.read_start = function(stream, receive)
      return read_start(stream, function()
        receive("EIO")
      end)
    end
    local handle = owner:spawn(helper.spec("printf ready; sleep 10"))
    assert.are.equal(
      "process_stream",
      assert(helper.complete(function()
        return handle:wait()
      end).error).code
    )
    vim.uv.read_start = read_start
    assert.is_true(helper.complete(function()
      return handle:wait_cleanup()
    end))
  end)

  it("rejects a native write enqueue failure and keeps the target controllable", function()
    local handle = owner:spawn(helper.spec("sleep 10", { stdio = { kind = "pipes", stdin = "open" } }))
    vim.uv.write = function()
      return nil, "EPIPE"
    end
    assert.are.equal(
      "stdin_closed",
      helper.failure(function()
        handle:write("bytes")
      end).code
    )
    assert.is_false(handle:state().stdin_writable)
    assert.are.equal(
      "stdin_closed",
      assert(helper.complete(function()
        return handle:flush()
      end).error).code
    )
    assert.are.equal("running", handle:state().phase)
    local rejected = helper.complete(function()
      return owner:run(helper.spec("sleep 10", { stdio = { kind = "pipes", stdin = "open" } }), {
        capture = false,
        input = { chunks = { "bytes" }, close = true },
      })
    end)
    assert.are.equal("stdin_closed", assert(rejected.error).code)
    handle:terminate("input failed")
    assert.are.equal(
      "input failed",
      helper.complete(function()
        return handle:wait()
      end).termination_reason
    )
  end)

  it("rejects native PTY allocation failures without publishing a handle", function()
    local selected = helper.spec("unused", { stdio = { kind = "pty", columns = 80, rows = 24 } })
    vim.uv.new_pipe = function()
      error("native allocation failed")
    end
    assert.are.equal(
      "process_start",
      helper.failure(function()
        owner:spawn(selected)
      end).code
    )
    vim.uv.new_pipe = new_pipe
    assert.is_true(helper.complete(function()
      return owner:wait(1000)
    end))
    selected.argv = { "/neoagent-missing-pty-command" }
    assert.are.equal(
      "process_start",
      helper.failure(function()
        owner:spawn(selected)
      end).code
    )
  end)

  for _, throws in ipairs({ false, true }) do
    it("reports native PTY write rejection with throwing=" .. tostring(throws), function()
      local handle = owner:spawn(helper.spec("exec sleep 10", {
        stdio = { kind = "pty", columns = 80, rows = 24 },
      }))
      vim.uv.write = function()
        if throws then
          error("closed native stream")
        end
        return nil, "EPIPE"
      end
      assert.are.equal(
        "stdin_closed",
        helper.failure(function()
          handle:write("bytes")
        end).code
      )
      assert.is_false(handle:state().stdin_writable)
      assert.are.equal("running", handle:state().phase)
      handle:terminate("native input failed")
      assert.are.equal(
        "native input failed",
        helper.complete(function()
          return handle:wait()
        end).termination_reason
      )
    end)
  end

  it("rejects an invalid scope wait without dropping active targets", function()
    local handle = owner:spawn(helper.spec("sleep 10"))
    local result = helper.complete(function()
      return owner:wait(0)
    end)
    assert.are.equal("process_validation", assert(result.error).code)
    assert.are.equal("running", handle:state().phase)
  end)
end)
