local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local async = require("neoagent.async")
local subprocess = require("neoagent.subprocess_common")
local workers = require("neoagent.rpc.worker_lease")

describe("native child reaping failures", function()
  if jit.os ~= "Linux" and jit.os ~= "OSX" then
    pending("POSIX waitable children")
    return
  end
  local module = "neoagent.subprocess.posix_child"
  local original = require("neoagent.subprocess.posix_child")
  local ffi = require("ffi")
  local C = ffi.C --[[@as Neoagent.ChildWaitApi]]
  ---@type Neoagent.SubprocessScope
  local owner
  ---@type Neoagent.WorkerLease?
  local worker
  ---@type Neoagent.PosixChild?
  local child
  ---@type integer?
  local pid
  local blocked, attempts, reaped = false, 0, false
  local failure_errno = 1
  ---@type integer?
  local observation_errno

  before_each(function()
    owner = subprocess.scope()
    worker, child, pid = nil, nil, nil
    blocked, attempts, reaped = true, 0, false
    failure_errno = 1
    observation_errno = nil
    -- Preserve real creation, exit observation, signalling, and reaping.
    -- Only the native reap call fails until this test permits it to finish.
    package.loaded.ffi = setmetatable({
      cdef = function() end,
      C = {
        waitid = function(kind, value, info, flags)
          local result = C.waitid(kind, value, info, flags)
          if observation_errno and (observation_errno ~= 10 or info.child.pid ~= 0) then
            local errno = observation_errno
            observation_errno = nil
            if errno == 10 then
              pid = value
              reaped = C.waitpid(value, nil, 1) == value
            end
            local _ = ffi.errno(errno)
            return -1
          end
          return result
        end,
        waitpid = function(value, status, flags)
          pid = value
          attempts = attempts + 1
          if blocked then
            if failure_errno == 4 then
              blocked = false
            elseif failure_errno == 10 then
              -- Another reaper consumed this child before our final wait.
              reaped = C.waitpid(value, status, flags) == value
            end
            local _ = ffi.errno(failure_errno)
            return -1
          end
          local result = C.waitpid(value, status, flags)
          reaped = reaped or result == value
          return result
        end,
      },
    }, { __index = ffi })
    package.loaded[module] = nil
    local ok, injected = pcall(require, module)
    package.loaded.ffi = ffi
    assert.is_true(ok, vim.inspect(injected))
    local new = injected.new
    injected.new = function(callbacks)
      child = new(callbacks)
      return child
    end
  end)

  after_each(function()
    blocked = false
    package.loaded.ffi = ffi
    package.loaded[module] = original
    if worker then
      worker:dispose("test complete")
      helper.complete(function()
        return assert(worker):wait()
      end)
    end
    owner:close("test complete")
    helper.complete(function()
      return owner:wait(3000)
    end)
    if child then
      pcall(child.close)
    end
    if pid then
      assert(
        vim.wait(2000, function()
          local result = C.waitpid(assert(pid), nil, 1)
          return result > 0 or (result == -1 and ffi.errno() == 10)
        end, 5),
        "test child was not reaped"
      )
    end
  end)

  for _, kind in ipairs({ "handle", "worker" }) do
    it("reports " .. kind .. " cleanup failure and retains a child until reaping succeeds", function()
      -- EPERM models a policy denying the final wait operation.
      local result
      local release_waiter
      if kind == "handle" then
        local handle = owner:spawn(helper.spec("exit 0"))
        result = helper.complete(function()
          return handle:wait()
        end)
        assert.are.equal(
          "process_cleanup",
          result.error and result.error.code,
          "native reap failure was reported as success"
        )
        assert.are.equal(
          "process_cleanup",
          assert(helper.complete(function()
            return handle:wait_cleanup()
          end).error).code
        )
        assert.is_true(owner:is_settled())
        assert.is_false(owner:is_released())
        assert.is_false(handle:state().released)
        release_waiter = async.run(function()
          return handle:wait_release()
        end)
        release_waiter:cancel()
        assert.are.equal("cancelled", assert(helper.wait(release_waiter).error).kind)
        release_waiter = async.run(function()
          return handle:wait_release()
        end)
      else
        worker = workers.start({
          argv = { "sh", "-c", "exit 0" },
          cwd = assert(vim.uv.cwd()),
          env = { PATH = assert(vim.env.PATH) },
        })
        result = helper.complete(function()
          return assert(worker):wait()
        end)
        assert.are.equal(0, result.code)
        assert.are.equal(
          "process_cleanup",
          result.cleanup_error and result.cleanup_error.code,
          "native reap failure was reported as success"
        )
        assert.matches("errno 1", assert(result.cleanup_error).message, 1, true)
        assert.is_false(assert(worker):is_released())
        release_waiter = async.run(function()
          return assert(worker):wait_release()
        end)
        release_waiter:cancel()
        assert.are.equal("cancelled", assert(helper.wait(release_waiter).error).kind)
        release_waiter = async.run(function()
          return assert(worker):wait_release()
        end)
      end
      assert(
        vim.wait(2000, function()
          return attempts > 1
        end, 5),
        "the native owner abandoned the failed reap"
      )
      assert.is_false(reaped)
      assert.is_false(assert(release_waiter):is_done())
      blocked = false
      assert(
        vim.wait(2000, function()
          return reaped
        end, 5),
        "the native owner did not finish reaping"
      )
      assert.is_true(helper.wait(assert(release_waiter)))
      assert.is_true(helper.complete(function()
        return owner:wait_release(2000)
      end))
      assert.is_true(owner:is_released())
    end)
  end

  it("keeps failed-start release observable after its bounded cleanup reports failure", function()
    local pipes = require("neoagent.subprocess.pipe")
    local new = pipes.new
    pipes.new = function(...)
      local driver = new(...)
      local start = driver.start
      driver.start = function()
        start()
        error({ kind = "process_start", code = "process_start", message = "failure before publication" }, 0)
      end
      return driver
    end
    local ok, failure = pcall(helper.failure, function()
      owner:spawn(helper.spec("exec sleep 30"))
    end)
    pipes.new = new
    assert.is_true(ok, vim.inspect(failure))
    assert.are.equal("process_start", failure.code)
    assert.are.equal(
      "process_cleanup",
      assert(helper.complete(function()
        return owner:wait(3000)
      end).error).code
    )
    assert.is_true(owner:is_settled())
    assert.is_false(owner:is_released())
    local observing = async.run(function()
      return owner:wait_release(2000)
    end)
    observing:cancel()
    assert.are.equal("cancelled", assert(helper.wait(observing).error).kind)
    assert.is_false(owner:is_released())
    blocked = false
    assert.is_true(helper.complete(function()
      return owner:wait_release(2000)
    end))
    assert.is_true(reaped)
    assert.is_true(owner:is_released())
  end)

  it("reserves session capacity until a failed native reap eventually releases it", function()
    local sessions = require("neoagent.process_sessions").new({ capacity = 1 })
    local admission = helper.success(function()
      return sessions:prepare(helper.spec("exit 0"), 1000)
    end)
    assert.is_true(admission.result.done)
    assert.are.equal("process_cleanup", assert(admission.result.cleanup_error).code)
    admission.commit()
    assert.are.equal(1, sessions:status().reserved)
    local rejected = helper.complete(function()
      return sessions:prepare(helper.spec("exit 0"), 0)
    end)
    assert.are.equal("process_capacity", assert(rejected.error).code)
    blocked = false
    assert.is_true(helper.complete(function()
      return sessions:wait_release(2000)
    end))
    assert.are.equal(0, sessions:status().reserved)
    local admitted = helper.success(function()
      return sessions:prepare(helper.spec("exit 0"), 1000)
    end)
    assert.are.equal(0, assert(admitted.result.outcome).code)
    admitted.commit()
    sessions:close("test complete")
    assert.is_true(helper.complete(function()
      return sessions:wait_release(2000)
    end))
  end)

  it("retries an interrupted reap without reporting a cleanup failure", function()
    failure_errno = 4
    local handle = owner:spawn(helper.spec("exit 0"))
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.is_nil(result.error, vim.inspect(result))
    assert.are.equal(0, result.code)
    assert.are.equal(2, attempts)
    assert.is_true(reaped)
    assert.is_false(assert(child).poll())
    assert.is_false(assert(child).terminate(true))
  end)

  it("reports lost wait ownership and prevents subsequent native signals", function()
    failure_errno = 10
    local handle = owner:spawn(helper.spec("exit 0"))
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal("process_cleanup", assert(result.error).code)
    assert.is_true(reaped)
    assert.is_false(assert(child).terminate(true))
  end)

  for _, errno in ipairs({ 1, 10 }) do
    it("retains observation failure without signalling a reaped identity (errno " .. errno .. ")", function()
      local limits = require("neoagent.subprocess.validate")
      local reap_ms = limits.REAP_MS
      limits.REAP_MS = 50
      blocked, observation_errno = false, errno
      local ok, failure = pcall(function()
        local result = helper.complete(function()
          return owner:run(helper.spec("exit 0"), { capture = false })
        end)
        assert.are.equal("process_supervision", assert(result.error).code)
        assert.matches("errno " .. errno, assert(result.error).message, 1, true)
        helper.complete(function()
          return owner:wait(4000)
        end)
        assert.is_true(reaped)
        assert.is_false(assert(child).terminate(true))
      end)
      limits.REAP_MS = reap_ms
      assert.is_true(ok, vim.inspect(failure))
    end)
  end

  for _, thrown in ipairs({ false, true }) do
    it("releases its watcher if reap timer allocation " .. (thrown and "throws" or "fails"), function()
      local new_signal, new_timer, spawn = vim.uv.new_signal, vim.uv.new_timer, vim.uv.spawn
      ---@type uv.uv_signal_t?
      local watcher
      local launched = false
      vim.uv.new_signal = function()
        watcher = new_signal()
        vim.uv.new_timer = function()
          if thrown then
            error("native timer allocation failed")
          end
          return nil
        end
        return watcher
      end
      vim.uv.spawn = function(...)
        launched = true
        return spawn(...)
      end
      local ok, failure = pcall(function()
        return helper.failure(function()
          owner:spawn(helper.spec("exit 0"))
        end)
      end)
      vim.uv.new_signal, vim.uv.new_timer, vim.uv.spawn = new_signal, new_timer, spawn
      assert.is_true(ok, vim.inspect(failure))
      assert.are.equal("process_supervision", failure.code)
      assert.is_false(launched)
      assert.is_true(assert(watcher):is_closing())
    end)
  end

  it("releases reserved resources when native child observation cannot start", function()
    local new_signal = vim.uv.new_signal
    local watcher = assert(new_signal())
    local methods = getmetatable(watcher).__index
    local start = methods.start
    methods.start = function()
      return nil, "native signal watch failed"
    end
    vim.uv.new_signal = function()
      return watcher
    end
    local ok, failure = pcall(helper.failure, function()
      owner:spawn(helper.spec("exit 0"))
    end)
    methods.start, vim.uv.new_signal = start, new_signal
    assert.is_true(ok, vim.inspect(failure))
    assert.are.equal("process_supervision", failure.code)
    assert.is_true(watcher:is_closing())
    assert.is_true(helper.complete(function()
      return owner:wait(1000)
    end))
  end)

  if jit.os == "Linux" then
    for _, architecture in ipairs({ "mips", "mipsel", "mips64", "mips64el" }) do
      it("rejects unsupported " .. architecture .. " child ownership before native spawn", function()
        local arch, spawn = jit.arch, vim.uv.spawn
        local launched = false
        jit.arch = architecture
        vim.uv.spawn = function()
          launched = true
          return nil, "unsupported ABI reached native launch", "ENOSYS"
        end
        local ok, failure = pcall(function()
          local pipe_failure = helper.failure(function()
            owner:spawn(helper.spec("exit 23"))
          end)
          local terminal_failure = helper.failure(function()
            owner:spawn(helper.spec("exit 23", { stdio = { kind = "pty", columns = 80, rows = 24 } }))
          end)
          assert.are.equal("pty_unavailable", terminal_failure.code)
          return pipe_failure
        end)
        jit.arch, vim.uv.spawn = arch, spawn
        assert.is_true(ok, vim.inspect(failure))
        assert.is_false(launched, "an unsupported wait ABI reached process creation")
        assert.are.equal("process_supervision", failure.code)
        assert.matches(architecture, assert(failure.message), 1, true)
      end)
    end
  end
end)
