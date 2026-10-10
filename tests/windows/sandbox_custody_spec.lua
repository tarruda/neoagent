local assert = require("luassert")
local async = require("neoagent.async")
local helper = require("tests.helpers.subprocess")

describe("Windows editor custody", function()
  if jit.os ~= "Windows" then
    pending("requires Windows")
    return
  end
  local ffi = require("ffi")
  ffi.cdef([[
void * __stdcall OpenProcess(unsigned long, int, unsigned long);
int __stdcall AssignProcessToJobObject(void *, void *);
]])
  local load = ffi.load
  local kernel = load("kernel32")
  local fail_configure, fail_query, pending_queries, terminations = false, false, 0, 0
  ffi.load = function(name, global)
    local library = load(name, global)
    if name ~= "kernel32" then return library end
    return setmetatable({
      SetInformationJobObject = function(...)
        if fail_configure then library.SetLastError(5); return 0 end
        return library.SetInformationJobObject(...)
      end,
      TerminateJobObject = function(...)
        terminations = terminations + 1
        return library.TerminateJobObject(...)
      end,
      QueryInformationJobObject = function(handle, kind, value, size, returned)
        if fail_query then library.SetLastError(5); return 0 end
        local result = library.QueryInformationJobObject(handle, kind, value, size, returned)
        if result ~= 0 and kind == 1 and pending_queries > 0 then
          pending_queries = pending_queries - 1
          value.ActiveProcesses = 1
        end
        return result
      end,
    }, { __index = library })
  end
  require("scripts.sandbox_windows_job")
  ffi.load = load
  -- Custody loads this same native owner; only native return values above are
  -- injected. Every test allocates and closes a real authenticated Windows Job.
  local custody = require("neoagent.sandbox.windows.custody")
  local validate = require("neoagent.subprocess.validate")
  local reap_ms = validate.REAP_MS
  ---@type Neoagent.WindowsSandboxCustody[]
  local owners
  ---@type Neoagent.Run<unknown, unknown>[]
  local observers
  ---@type Neoagent.AwaitCallbacks<true>?
  local host_released
  ---@type fun()?
  local finish_host
  ---@type Neoagent.WindowsSandboxCustody?
  local unconfirmed
  ---@type Neoagent.Run<unknown, unknown>?
  local supervisor
  ---@type uv.uv_process_t[]
  local children

  before_each(function()
    owners, observers = {}, {}
    children = {}
    supervisor = nil
    finish_host = nil
    unconfirmed = nil
    validate.REAP_MS = 20
    fail_configure, fail_query, pending_queries, terminations = false, false, 0, 0
  end)
  after_each(function()
    fail_configure, fail_query, pending_queries = false, false, 0
    validate.REAP_MS = reap_ms
    if finish_host then finish_host() end
    if supervisor then supervisor:cancel(); helper.wait(supervisor) end
    if host_released then host_released.resolve(true); host_released = nil end
    for _, observer in ipairs(observers) do
      observer:cancel("custody test finished")
      helper.wait(observer)
    end
    for _, owner in ipairs(owners) do
      if owner == unconfirmed then
        -- Unknown execution deliberately cannot release custody. These tests
        -- never launched a host, so teardown can close their empty native Job.
        assert(owner._job):stop()
        assert(owner._job):close()
      elseif not owner._finishing then
        assert.is_true(helper.complete(function()
          local cleaned, err = owner:finish({ execution = "not_started", stderr = "" })
          assert(cleaned, err)
          return true
        end))
      else
        assert.is_true(helper.complete(function() return owner:wait_release() end, 5000))
      end
    end
    for _, child in ipairs(children) do
      if not child:is_closing() then child:kill(9); child:close() end
    end
  end)

  local function new(recover)
    local owner = custody.new(assert(vim.uv.fs_realpath("scripts")), recover or function() return true end)
    owners[#owners + 1] = owner
    return owner
  end

  local function assign(owner)
    local exited = false
    local child, pid = assert(vim.uv.spawn("python", {
      args = { "-c", "import time; time.sleep(60)" },
      cwd = assert(vim.uv.cwd()), stdio = { nil, nil, nil }, detached = false, hide = true, verbatim = false,
    }, function() exited = true end))
    children[#children + 1] = child
    local process = kernel.OpenProcess(0x101, 0, pid)
    assert.is_not_nil(process)
    local assigned = kernel.AssignProcessToJobObject(assert(assert(owner._job).handle), process)
    kernel.CloseHandle(process)
    assert.is_not.equal(0, assigned)
    return function() return exited end
  end

  it("releases a Job allocated before custody setup fails", function()
    local owner = new()
    fail_configure = true
    local started, err = pcall(owner.start, owner)
    fail_configure = false
    assert.is_false(started)
    assert.matches("target-job", err.message, 1, true)
    assert.are.equal("errno=5", err.detail)
    assert.is_not_nil(assert(owner._job).handle)
    assert.is_true(helper.complete(function() return owner:finish({ execution = "not_started", stderr = "" }) end))
    assert.is_true(owner:is_released())
    assert.is_nil(assert(owner._job).handle)
  end)

  it("retries native observation and recovery after bounded cleanup fails", function()
    local attempts = 0
    local owner = new(function()
      attempts = attempts + 1
      if attempts == 1 then error("recovery temporarily unavailable") end
      return true
    end)
    owner:start()
    fail_query = true
    local observed = helper.complete(function()
      local cleaned, err = owner:finish({ execution = "started", code = 137, stderr = "" })
      return { cleaned = cleaned, failure = err }
    end)
    assert.is_nil(observed.cleaned)
    assert.matches("lease-job-query", observed.failure, 1, true)
    assert.is_false(owner:is_released())
    local cancelled = async.run(function() return owner:wait_release() end)
    observers[#observers + 1] = cancelled
    cancelled:cancel()
    assert.are.equal("cancelled", assert(helper.wait(cancelled).error).kind)
    fail_query, pending_queries = false, 1
    assert.is_true(helper.complete(function() return owner:wait_release() end, 5000))
    assert.are.equal(2, attempts)
    assert.is_nil(assert(owner._job).handle)
  end)

  it("stops late targets while retaining authority for unconfirmed native execution", function()
    local recoveries = 0
    local owner = new(function() recoveries = recoveries + 1; return true end)
    unconfirmed = owner
    owner:start()
    local run = async.run
    async.run = function(body, options)
      local value = run(body, options)
      if options and options.error_kind == "sandbox_unavailable" then supervisor = value end
      return value
    end
    local ok, observed = pcall(helper.complete, function()
        local cleaned, err = owner:finish({ execution = "unknown", stderr = "" })
        return { cleaned = cleaned, failure = err }
      end)
    async.run = run
    assert.is_true(ok, vim.inspect(observed))
    assert.is_nil(observed.cleaned)
    assert.matches("could not be established", observed.failure, 1, true)
    assert.are.equal(0, recoveries)
    assert.is_true(vim.wait(2000, function() return terminations >= 2 end, 5),
      "unknown host execution abandoned the Job termination obligation")
    local exited = assign(owner)
    assert.is_true(vim.wait(5000, exited, 5), "a late target survived retained custody")
    assert.is_false(assert(owner._job):is_empty(), "uncertain admission cannot establish permanent Job emptiness")
    assert.is_false(owner:is_released())
    assert.is_not_nil(assert(owner._job).handle)
    local release = async.run(function() return owner:wait_release() end)
    observers[#observers + 1] = release
    local settled = vim.wait(1000, function() return release:is_done() end, 5)
    if not settled then release:cancel() end
    local result = helper.wait(release)
    assert.is_true(settled, "permanently failed release was reported as still pending")
    assert.matches("could not be established", assert(result.error).message, 1, true)
  end)

  it("stops targets before host release while keeping empty Job evidence provisional", function()
    local owner = new()
    owner:start()
    local exited = assign(owner)
    local host_complete = false
    finish_host = function()
      host_complete = true
      if host_released then host_released.resolve(true); host_released = nil end
    end
    local host = {
      is_released = function() return host_complete end,
      ---@async
      wait_release = function()
        return async.await(function(done) host_released = done end)
      end,
    }
    local observed = helper.complete(function()
      local cleaned, err = owner:finish({ execution = "started", stderr = "" }, nil,
        host --[[@as Neoagent.WorkerLease]])
      return { cleaned = cleaned, failure = err }
    end)
    assert.is_nil(observed.cleaned)
    assert.is_true(vim.wait(5000, exited, 5), "termination waited for native host release")
    assert.is_true(terminations > 0)
    assert.is_false(assert(owner._job):is_empty())
    assert.is_false(owner:is_released())
    finish_host()
    assert.is_true(helper.complete(function() return owner:wait_release() end, 5000))
    assert.is_true(terminations > 0)
  end)
end)
