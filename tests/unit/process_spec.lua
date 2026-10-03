local assert = require("luassert")

describe("native process helpers", function()

  it("owns Windows process descendants through a kill-on-close job", function()
    ---@type string[]
    local calls = {}
    ---@type Neoagent.WindowsProcessBackend
    local backend = {
      create = function() calls[#calls + 1] = "create" return "job" end,
      open = function(pid) calls[#calls + 1] = "open:" .. pid return "process" end,
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
      close = function(handle) calls[#calls + 1] = "close:" .. tostring(handle) end,
    }
    local tree = assert(require("neoagent.process.windows").new({ backend = backend }))
    assert.is_false(tree:running())
    assert.is_false(tree:terminate(15))
    assert(tree:attach(0))
    assert(tree:attach(42))
    assert.is_true(tree:running())
    local replaced, replace_err = tree:attach(43)
    assert.is_nil(replaced)
    assert.are.equal("process tree already has a root", replace_err)
    assert.is_true(tree:terminate(15))
    tree:close(true)
    assert.is_false(tree:running())
    local attached, attach_err = tree:attach(42)
    assert.is_nil(attached)
    assert.are.equal("process tree is closed", attach_err)
    tree:close(true)
    assert.are.same({
      "create", "open:42", "assign:job:process",
      "terminate:job:15", "terminate:job:125", "close:process", "close:job",
    }, calls)
  end)

  it("configures the native Windows process Job boundary", function()
    ---@type string[]
    local calls = {}
    local ffi = {
      cdef = function() end,
      ---@param name string
      new = function(name)
        assert.are.equal("NEOAGENT_JOB_EXTENDED_LIMIT_INFORMATION", name)
        return { BasicLimitInformation = {} }
      end,
      sizeof = function() return 144 end,
    }
    ---@type Neoagent.WindowsProcessKernel
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
      CloseHandle = function(handle) calls[#calls + 1] = "close:" .. tostring(handle) return 1 end,
    }
    local tree = assert(require("neoagent.process.windows").new({
      native = { ffi = ffi --[[@as Neoagent.WindowsProcessFfi]], kernel = kernel },
    }))
    assert(tree:attach(43))
    assert.is_true(tree:running())
    tree:close(true)
    assert.are.same({
      "create", "configure", "open", "assign", "query",
      "terminate", "close:process", "close:job",
    }, calls)
  end)

  it("reports native Windows Job API failures and closes handles", function()
    local windows = require("neoagent.process.windows")
    local ffi = {
      cdef = function() end,
      new = function() return { BasicLimitInformation = {} } end,
      sizeof = function() return 144 end,
    }
    ---@type Neoagent.WindowsProcessHandle[]
    local closed = {}
    local mode = "create"
    ---@type Neoagent.WindowsProcessKernel
    local kernel = {
      GetLastError = function() return 5 end,
      CreateJobObjectW = function()
        if mode == "create" then return nil end
        return "job"
      end,
      SetInformationJobObject = function()
        return mode == "configure" and 0 or 1
      end,
      OpenProcess = function()
        if mode == "open" then return nil end
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
      CloseHandle = function(handle) closed[#closed + 1] = handle return 1 end,
    }
    ---@return Neoagent.WindowsProcessTree?, string?
    local function create()
      return windows.new({ native = { ffi = ffi --[[@as Neoagent.WindowsProcessFfi]], kernel = kernel } })
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
    tree:close()
  end)
end)
