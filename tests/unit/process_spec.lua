local async = require("neoagent.async")
local process = require("neoagent.process")

local function complete(fn, timeout)
  local run = async.run(fn)
  assert(vim.wait(timeout or 3000, function() return run:is_done() end, 5))
  return run:result()
end

local function descendant_command(marker)
  return "(trap '' TERM; sleep 0.2; printf survived > "
    .. vim.fn.shellescape(marker)
    .. ") </dev/null >/dev/null 2>&1 & wait"
end

local function descendant_survived(marker)
  vim.wait(500, function() return vim.uv.fs_stat(marker) ~= nil end, 5)
  local survived = vim.uv.fs_stat(marker) ~= nil
  vim.fn.delete(marker)
  return survived
end

describe("neoagent process runner", function()
  it("clears the ambient environment when requested", function()
    local saved = vim.env.NEOAGENT_PROCESS_SECRET
    vim.env.NEOAGENT_PROCESS_SECRET = "hidden"
    local completed = complete(function()
      return process.run({
        "sh", "-c", "printf '%s:%s' \"${SAFE-unset}\" \"${NEOAGENT_PROCESS_SECRET-unset}\"",
      }, {
        clear_env = true,
        env = { SAFE = "visible" },
      })
    end)
    vim.env.NEOAGENT_PROCESS_SECRET = saved
    assert.are.equal(0, completed.code)
    assert.are.equal("visible:unset", completed.stdout)
  end)

  it("streams output without retaining it when capture is disabled", function()
    local chunks = {}
    local completed = complete(function()
      return process.run({
        "sh", "-c", "printf out; printf err >&2",
      }, {
        capture = false,
        on_output = function(data, is_stderr)
          chunks[#chunks + 1] = { data = data, is_stderr = is_stderr }
        end,
      })
    end)
    assert.are.equal(0, completed.code)
    assert.are.equal("", completed.stdout)
    assert.are.equal("", completed.stderr)
    assert.are.equal("", completed.output)
    local streams = { stdout = "", stderr = "" }
    for _, chunk in ipairs(chunks) do
      local stream = chunk.is_stderr and "stderr" or "stdout"
      streams[stream] = streams[stream] .. chunk.data
    end
    assert.are.equal("out", streams.stdout)
    assert.are.equal("err", streams.stderr)
  end)

  it("bounds retained process output", function()
    local completed = complete(function()
      return process.run({
        "sh", "-c", "printf 12; printf 345 >&2",
      }, {
        max_capture_bytes = 4,
      })
    end)
    assert.is_false(completed.ok)
    assert.matches("exceeded 4 bytes", completed.error.message)
  end)

  it("escalates timed-out TERM-resistant processes to KILL", function()
    local completed = complete(function()
      return process.run({
        "sh", "-c", "trap '' TERM; while :; do sleep 1; done",
      }, {
        -- The timeout leaves the spawned shell time to install its TERM trap.
        timeout_ms = 500,
        kill_grace_ms = 20,
      })
    end)
    assert.is_true(completed.timed_out)
    assert.are.equal(137, completed.code)

    completed = complete(function()
      return process.run({
        "sh", "-c", "trap '' TERM; while :; do sleep 1; done",
      }, {
        timeout_ms = 500,
        kill_grace_ms = 0,
      })
    end)
    assert.is_true(completed.timed_out)
    assert.are.equal(137, completed.code)
  end)

  it("terminates descendants after a timeout", function()
    local marker = vim.fn.tempname()
    local completed = complete(function()
      return process.run({ "sh", "-c", descendant_command(marker) }, {
        timeout_ms = 50,
        kill_grace_ms = 20,
      })
    end)
    assert.is_true(completed.timed_out)
    assert.is_false(descendant_survived(marker))
  end)

  it("terminates descendants after explicit cancellation", function()
    local marker = vim.fn.tempname()
    local run = async.run(function()
      return process.run({ "sh", "-c", descendant_command(marker) }, {
        kill_grace_ms = 20,
      })
    end)
    vim.defer_fn(function() run:cancel() end, 50)
    assert(vim.wait(3000, function() return run:is_done() end, 5))
    assert.are.equal("cancelled", run:result().error.kind)
    assert.is_false(descendant_survived(marker))
  end)

  it("owns Windows process descendants through a kill-on-close job", function()
    local calls = {}
    local backend = {
      create = function() calls[#calls + 1] = "create" return "job" end,
      open = function(pid) calls[#calls + 1] = "open:" .. pid return "process" end,
      assign = function(job, child)
        calls[#calls + 1] = "assign:" .. job .. ":" .. child
        return true
      end,
      terminate = function(job, code)
        calls[#calls + 1] = "terminate:" .. job .. ":" .. code
        return true
      end,
      close = function(handle) calls[#calls + 1] = "close:" .. handle end,
    }
    local tree = assert(require("neoagent.process.windows").new({ backend = backend }))
    assert(tree:attach(42))
    assert.is_true(tree:terminate(15))
    tree:close(true)
    assert.are.same({
      "create", "open:42", "assign:job:process", "close:process",
      "terminate:job:15", "terminate:job:125", "close:job",
    }, calls)
  end)

  it("configures the native Windows process Job boundary", function()
    local calls = {}
    local ffi = {
      cdef = function() end,
      new = function(name)
        assert.are.equal("NEOAGENT_JOB_EXTENDED_LIMIT_INFORMATION", name)
        return { BasicLimitInformation = {} }
      end,
      sizeof = function() return 144 end,
    }
    local kernel = {
      GetLastError = function() return 5 end,
      CreateJobObjectW = function() calls[#calls + 1] = "create" return "job" end,
      SetInformationJobObject = function(job, class, limits, size)
        assert.are.equal("job", job)
        assert.are.equal(9, class)
        assert.are.equal(0x2000, limits.BasicLimitInformation.LimitFlags)
        assert.are.equal(144, size)
        calls[#calls + 1] = "configure"
        return 1
      end,
      OpenProcess = function(access, inherit, pid)
        assert.are.equal(0x0101, access)
        assert.are.equal(0, inherit)
        assert.are.equal(43, pid)
        calls[#calls + 1] = "open"
        return "process"
      end,
      AssignProcessToJobObject = function(job, child)
        assert.are.same({ "job", "process" }, { job, child })
        calls[#calls + 1] = "assign"
        return 1
      end,
      TerminateJobObject = function(job, code)
        assert.are.same({ "job", 125 }, { job, code })
        calls[#calls + 1] = "terminate"
        return 1
      end,
      CloseHandle = function(handle) calls[#calls + 1] = "close:" .. handle return 1 end,
    }
    local tree = assert(require("neoagent.process.windows").new({
      native = { ffi = ffi, kernel = kernel },
    }))
    assert(tree:attach(43))
    tree:close(true)
    assert.are.same({
      "create", "configure", "open", "assign", "close:process",
      "terminate", "close:job",
    }, calls)
  end)

  it("reports process supervisor, spawn, and attachment setup failures", function()
    local tree_module = jit.os == "Windows"
      and "neoagent.process.windows" or "neoagent.process.posix"
    local original_tree = package.loaded[tree_module]
    local original_process = package.loaded["neoagent.process"]
    local original_system = vim.system
    local function runner(tree)
      package.loaded[tree_module] = tree
      package.loaded["neoagent.process"] = nil
      return require("neoagent.process")
    end
    local ok, err = pcall(function()
      local failed = complete(function()
        return runner({
          detach = false,
          new = function() return nil, "supervisor failed" end,
        }).run({ "true" })
      end)
      assert.is_false(failed.ok)
      assert.matches("Failed to create process supervisor", failed.error.message)

      local closed
      vim.system = function() error("spawn failed") end
      failed = complete(function()
        return runner({
          detach = false,
          new = function()
            return {
              close = function(_, force) closed = force end,
            }
          end,
        }).run({ "true" })
      end)
      assert.is_false(failed.ok)
      assert.matches("Failed to start process", failed.error.message)
      assert.is_true(closed)

      local killed
      closed = nil
      vim.system = function()
        return {
          pid = 42,
          kill = function(_, signal) killed = signal end,
        }
      end
      failed = complete(function()
        return runner({
          detach = false,
          new = function()
            return {
              attach = function() return nil, "attach failed" end,
              close = function(_, force) closed = force end,
            }
          end,
        }).run({ "true" })
      end)
      assert.is_false(failed.ok)
      assert.matches("Failed to supervise process tree", failed.error.message)
      assert.are.equal(9, killed)
      assert.is_true(closed)
    end)
    vim.system = original_system
    package.loaded[tree_module] = original_tree
    package.loaded["neoagent.process"] = original_process
    assert(ok, err)
  end)

  it("reports stdout and stderr stream read failures", function()
    local original_system = vim.system
    for _, stream in ipairs({ "stdout", "stderr" }) do
      vim.system = function(_, options)
        options[stream]("stream failed")
        return { kill = function() end }
      end
      local completed = complete(function()
        return process.run({ "true" })
      end)
      assert.is_false(completed.ok)
      assert.are.equal("tool", completed.error.kind)
      assert.matches("Failed reading process " .. stream, completed.error.message)
    end
    vim.system = original_system
  end)
end)
