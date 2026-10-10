local assert = require("luassert")

describe("Windows sandbox native Job ownership", function()
  if jit.os ~= "Windows" then
    pending("requires Windows")
    return
  end
  local ffi = require("ffi")
  ffi.cdef("void __stdcall SetLastError(unsigned long);")
  local load = ffi.load
  local fail_query, fail_configure = false, false
  ffi.load = function(name, global)
    local library = load(name, global)
    if name ~= "kernel32" then
      return library
    end
    return setmetatable({
      QueryInformationJobObject = function(...)
        if fail_query then
          library.SetLastError(5)
          return 0
        end
        return library.QueryInformationJobObject(...)
      end,
      SetInformationJobObject = function(...)
        if fail_configure then
          library.SetLastError(5)
          return 0
        end
        return library.SetInformationJobObject(...)
      end,
    }, { __index = library })
  end
  local loaded, jobs = pcall(dofile, "scripts/sandbox_windows_job.lua")
  local objects = require("scripts.sandbox_windows_objects")
  ffi.load = load
  assert.is_true(loaded, tostring(jobs))
  ---@type Neoagent.WindowsSandboxJob[]
  local owners
  ---@type ffi.cdata*[]
  local observations
  ---@type string
  local name

  ---@param identity? string
  local function new_owner(identity)
    local state = vim.json.decode((assert(require("neoagent.fs").read(vim.fs.joinpath(
      assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")))))
    local deps = {
      identity = identity or state.owner_sid,
      wide = function(text)
        return (assert(require("neoagent.subprocess.windows_text").wide(text)))
      end,
      failure = function(stage, code)
        error({ stage = stage, errno = code }, 0)
      end,
    }
    local owner = jobs.new(objects.new(name, deps), deps)
    owners[#owners + 1] = owner
    return owner
  end

  ---@param owner Neoagent.WindowsSandboxJob
  local function observe(owner)
    -- Observe the Job through its owner's existing process-local namespace
    -- alias. Cross-host namespace reopening is covered by crash recovery.
    local kernel = load("kernel32")
    local handle = kernel.OpenJobObjectW(4, 0, owner._wide(owner._namespace:path("target")))
    assert(handle ~= nil, "owned native Job is no longer observable")
    observations[#observations + 1] = handle
  end

  before_each(function()
    owners, observations = {}, {}
    name = "NeoagentJobOwnershipTest-" .. vim.fn.getpid() .. "-" .. tostring(vim.uv.hrtime())
  end)

  after_each(function()
    fail_query, fail_configure = false, false
    for _, owner in ipairs(owners) do
      owner:stop()
      owner:close()
    end
    for _, handle in ipairs(observations) do load("kernel32").CloseHandle(handle) end
  end)

  it("retains its native identity when termination observation fails", function()
    local owner = new_owner()
    owner:create()
    fail_query = true
    local stopped, err = pcall(owner.stop, owner)
    assert.is_false(stopped)
    assert.are.equal("lease-job-query", err.stage)
    assert.is_false(owner:is_empty())
    assert.is_false((pcall(owner.close, owner)))
    observe(owner)
    fail_query = false
    owner:stop()
    assert.is_true(owner:is_empty())
    owner:close()
  end)

  it("owns a Job allocated before native configuration fails", function()
    local owner = new_owner()
    fail_configure = true
    local created, err = pcall(owner.create, owner)
    assert.is_false(created)
    assert.are.equal("target-job", err.stage)
    observe(owner)
    owner:stop()
    owner:close()
  end)

  it("does not report missing native identity as confirmed emptiness", function()
    local owner = new_owner()
    assert.is_false(owner:open())
    assert.is_false(owner:is_empty())
  end)

  it("rejects an existing native identity before configuring or adopting it", function()
    local original = new_owner()
    original:create()
    local attempted = new_owner()
    local created = pcall(attempted.create, attempted)
    assert.is_false(created, "creation adopted an existing native Job")
    assert.is_nil(attempted.handle, "rejected ownership retained a foreign Job")
    observe(original)
  end)

  it("rejects a same-name Job belonging to a different authority", function()
    -- Everyone is a valid boundary for this host too, but cannot authenticate
    -- an object as belonging to the coordinator's private host identity.
    local foreign = new_owner("S-1-1-0")
    foreign:create()
    local observer = new_owner()
    assert.is_false(observer:open(), "a foreign namespace supplied termination evidence")
    assert.is_false(observer:is_empty())
  end)
end)
