local assert = require("luassert")

describe("native process helpers", function()
  ---@type {tree: Neoagent.WindowsProcessTree, released: boolean}[]
  local owners = {}
  before_each(function()
    owners = {}
  end)
  after_each(function()
    for _, entry in ipairs(owners) do
      entry.tree:close()
    end
    assert(vim.wait(2000, function()
      for _, entry in ipairs(owners) do
        if not entry.released then
          return false
        end
      end
      return true
    end, 5))
  end)

  ---@param options {backend?: Neoagent.WindowsProcessBackend, native?: Neoagent.WindowsProcessNativeOptions}
  ---@return Neoagent.WindowsProcessTree?, string?
  local function start(options)
    local entry = { released = false }
    local tree = require("neoagent.process.windows").new({
      backend = options.backend,
      native = options.native,
      callbacks = {
        empty = function() end,
        released = function()
          entry.released = true
        end,
        failed = function() end,
      },
    })
    entry.tree = tree
    owners[#owners + 1] = entry
    local ok, err = tree:start()
    if not ok then
      tree:close()
      return nil, err
    end
    return tree
  end

  it("owns Windows process descendants through a kill-on-close job", function()
    ---@type string[]
    local calls = {}
    ---@type Neoagent.WindowsProcessBackend
    local backend = {
      create = function()
        calls[#calls + 1] = "create"
        return "job"
      end,
      open = function(pid)
        calls[#calls + 1] = "open:" .. pid
        return "process"
      end,
      assign = function(job, child)
        calls[#calls + 1] = "assign:" .. tostring(job) .. ":" .. tostring(child)
        return true
      end,
      running = function(process)
        assert.are.equal("process", process)
        return true
      end,
      terminate = function(job, code)
        calls[#calls + 1] = "terminate:" .. tostring(job) .. ":" .. code
        return true
      end,
      empty = function()
        return true
      end,
      close = function(handle)
        calls[#calls + 1] = "close:" .. tostring(handle)
      end,
    }
    local tree = assert(start({ backend = backend }))
    tree:poll()
    assert.is_nil(tree.empty, "an empty Job during creation cannot establish target completion")
    assert.is_false(tree:running())
    assert.is_false(tree:terminate(15))
    assert(tree:attach(0))
    assert(tree:attach(42))
    assert.is_true(tree:running())
    local replaced, replace_err = tree:attach(43)
    assert.is_nil(replaced)
    assert.are.equal("process tree already has a root", replace_err)
    assert.is_true(tree:terminate(15))
    tree:close()
    assert.is_false(tree:running())
    local attached, attach_err = tree:attach(42)
    assert.is_nil(attached)
    assert.are.equal("process tree is closed", attach_err)
    tree:close()
    assert.are.same({
      "create",
      "open:42",
      "assign:job:process",
      "terminate:job:15",
      "terminate:job:125",
      "close:process",
      "close:job",
    }, calls)
  end)

  it("configures the native Windows process Job boundary", function()
    ---@type string[]
    local calls = {}
    local ffi = {
      cdef = function() end,
      ---@param name string
      new = function(name)
        if name == "NEOAGENT_JOB_ACCOUNTING_INFORMATION" then
          return { ActiveProcesses = 0 }
        end
        assert.are.equal("NEOAGENT_JOB_EXTENDED_LIMIT_INFORMATION", name)
        return { BasicLimitInformation = {} }
      end,
      sizeof = function()
        return 144
      end,
    }
    ---@type Neoagent.WindowsProcessKernel
    local kernel = {
      GetLastError = function()
        return 5
      end,
      CreateJobObjectW = function()
        calls[#calls + 1] = "create"
        return "job"
      end,
      SetInformationJobObject = function(job, class, limits, size)
        assert.are.equal("job", job)
        assert.are.equal(9, class)
        assert.are.equal(0x2000, limits.BasicLimitInformation.LimitFlags)
        assert.are.equal(144, size)
        calls[#calls + 1] = "configure"
        return 1
      end,
      QueryInformationJobObject = function(job, class, information)
        assert.are.same({ "job", 1 }, { job, class })
        information.ActiveProcesses = 0
        return 1
      end,
      OpenProcess = function(access, inherit, pid)
        assert.are.equal(0x100101, access)
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
      WaitForSingleObject = function(process, timeout)
        assert.are.same({ "process", 0 }, { process, timeout })
        calls[#calls + 1] = "query"
        return 0x102
      end,
      TerminateJobObject = function(job, code)
        assert.are.same({ "job", 125 }, { job, code })
        calls[#calls + 1] = "terminate"
        return 1
      end,
      CloseHandle = function(handle)
        calls[#calls + 1] = "close:" .. tostring(handle)
        return 1
      end,
    }
    local tree = assert(start({
      native = {
        ffi = ffi --[[@as Neoagent.WindowsProcessFfi]],
        kernel = kernel,
      },
    }))
    assert(tree:attach(43))
    assert.is_true(tree:running())
    tree:close()
    assert.are.same({
      "create",
      "configure",
      "open",
      "assign",
      "query",
      "terminate",
      "close:process",
      "close:job",
    }, calls)
  end)

  it("retains an atomically assigned Job when disposal interrupts native creation", function()
    local empty, stopped = false, 0
    local closed = {}
    local tree = assert(start({
      backend = {
        create = function()
          return "job"
        end,
        open = function()
          error("native creation transfers its existing handle")
        end,
        assign = function()
          error("native creation already assigned the Job")
        end,
        running = function()
          return false
        end,
        empty = function()
          return empty
        end,
        terminate = function()
          stopped = stopped + 1
          return true
        end,
        close = function(handle)
          closed[#closed + 1] = handle
        end,
      },
    }))
    tree:close()
    assert.is_nil(tree.closed)
    assert.are.equal(1, stopped)
    assert.are.same({}, closed)
    tree:adopt("process")
    assert.are.equal(2, stopped)
    assert.are.same({}, closed)
    empty = true
    tree:poll()
    assert.are.same({ "process", "job" }, closed)
    tree:poll()
  end)

  it("closes a late native process handle after its Job already emptied", function()
    local closed = {}
    local tree = assert(start({
      backend = {
        create = function()
          return "job"
        end,
        open = function()
          error("native creation supplies its handle")
        end,
        assign = function()
          error("native creation assigns its Job")
        end,
        running = function()
          return false
        end,
        empty = function()
          return true
        end,
        terminate = function()
          return true
        end,
        close = function(handle)
          closed[#closed + 1] = handle
        end,
      },
    }))
    tree:close()
    assert.has_error(function()
      tree:adopt("process")
    end, "process tree is closed")
    assert.are.same({ "job", "process" }, closed)
  end)

  it("retries failed termination after disposal until the retained Job releases", function()
    local denied, empty, attempts = true, false, 0
    local tree = assert(start({ backend = {
      create = function() return "job" end,
      open = function() return "process" end,
      assign = function() return true end,
      running = function() return not empty end,
      empty = function() return empty end,
      terminate = function()
        attempts = attempts + 1
        if denied then return nil, "Win32 error 5" end
        empty = true
        return true
      end,
      close = function() end,
    } }))
    assert(tree:attach(42))
    tree:close()
    assert.is_nil(tree.closed)
    assert.are.equal(1, attempts)
    denied = false
    local released = vim.wait(2000, function() return tree.closed == true end, 5)
    -- Teardown must also terminate the failing baseline's retained Job.
    if not released then tree:terminate(); tree:poll() end
    assert.is_true(released, "disposed Job never retried its failed termination")
    assert.is_true(attempts > 1)
  end)

  for _, refused in ipairs({ "allocation", "scheduling" }) do
    it("releases partial native ownership when Job observation " .. refused .. " fails", function()
      local new_timer = vim.uv.new_timer
      local restore
      local created, closed = 0, 0
      vim.uv.new_timer = function()
        if refused == "allocation" then
          return nil
        end
        local timer = assert(new_timer())
        local methods = getmetatable(timer).__index
        local schedule = methods.start
        restore = function()
          methods.start = schedule
        end
        methods.start = function()
          return nil, "Job observation could not start"
        end
        return timer
      end
      local ok, err = pcall(function()
        local tree, failure = start({
          backend = {
            create = function()
              created = created + 1
              return "job"
            end,
            open = function()
              error("a target must not start without observation")
            end,
            assign = function()
              error("a target must not start without observation")
            end,
            running = function()
              return false
            end,
            empty = function()
              return true
            end,
            terminate = function()
              return true
            end,
            close = function()
              closed = closed + 1
            end,
          },
        })
        assert.is_nil(tree)
        assert.is_string(failure)
        assert.are.equal(refused == "allocation" and 0 or 1, created)
        assert.are.equal(created, closed)
      end)
      vim.uv.new_timer = new_timer
      if restore then
        restore()
      end
      assert.is_true(ok, vim.inspect(err))
    end)
  end

  it("reports native Windows Job API failures and closes handles", function()
    local ffi = {
      cdef = function() end,
      new = function()
        return { BasicLimitInformation = {} }
      end,
      sizeof = function()
        return 144
      end,
    }
    ---@type Neoagent.WindowsProcessHandle[]
    local closed = {}
    local mode = "create"
    ---@type Neoagent.WindowsProcessKernel
    local kernel = {
      GetLastError = function()
        return 5
      end,
      CreateJobObjectW = function()
        if mode == "create" then
          return nil
        end
        return "job"
      end,
      SetInformationJobObject = function()
        return mode == "configure" and 0 or 1
      end,
      QueryInformationJobObject = function(_, _, information)
        information.ActiveProcesses = 0
        return mode == "accounting" and 0 or 1
      end,
      OpenProcess = function()
        if mode == "open" then
          return nil
        end
        return "process"
      end,
      AssignProcessToJobObject = function()
        return mode == "assign" and 0 or 1
      end,
      WaitForSingleObject = function()
        return mode == "query" and 0xffffffff or mode == "exited" and 0 or 0x102
      end,
      TerminateJobObject = function()
        return mode == "terminate" and 0 or 1
      end,
      CloseHandle = function(handle)
        closed[#closed + 1] = handle
        return 1
      end,
    }
    ---@return Neoagent.WindowsProcessTree?, string?
    local function create()
      return start({
        native = {
          ffi = ffi --[[@as Neoagent.WindowsProcessFfi]],
          kernel = kernel,
        },
      })
    end

    local tree, err = create()
    assert.is_nil(tree)
    assert.are.equal("Win32 error 5", err)
    mode = "configure"
    tree, err = create()
    assert.is_nil(tree)
    assert.are.equal("Win32 error 5", err)
    assert.are.same({ "job" }, closed)

    mode = "open"
    tree = assert(create())
    local attached, attach_err = tree:attach(42)
    assert.is_nil(attached)
    assert.are.equal("Win32 error 5", attach_err)
    tree:close()

    mode = "assign"
    tree = assert(create())
    attached, attach_err = tree:attach(42)
    assert.is_nil(attached)
    assert.are.equal("Win32 error 5", attach_err)
    tree:close()

    mode = "terminate"
    tree = assert(create())
    assert(tree:attach(42))
    assert.is_true(tree:running())
    mode = "exited"
    assert.is_false(tree:running())
    mode = "query"
    local running, query_err = tree:running()
    assert.is_nil(running)
    assert.are.equal("Win32 error 5", query_err)
    mode = "terminate"
    assert.is_false(tree:terminate())
    local reported = {}
    tree.callbacks.failed = function(message)
      reported[#reported + 1] = message
    end
    mode = "accounting"
    tree:poll()
    tree:poll()
    assert.are.same({ "Could not observe process Job completion (Win32 error 5)" }, reported)
    assert.is_nil(tree.empty)
    mode = "exited"
    tree:close()
  end)
end)
