local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local fs = require("neoagent.fs")

describe("Agent retained process placement", function()
  local dispatch = require("neoagent.sandbox.platform")
  local select_platform = dispatch.select
  ---@type Neoagent.Agent?
  local agent
  ---@type Neoagent.AgentApplet?
  local applet
  ---@type Neoagent.ProfileResources?
  local resources
  ---@type Neoagent.ProcessSessions?
  local owner
  ---@type Neoagent.SandboxRuntime<Neoagent.AgentToolEnvironment>
  local runtime
  ---@type string
  local root
  local checks, starts, compilations = 0, 0, 0
  local available = true
  ---@type Neoagent.SandboxContext<Neoagent.AgentToolEnvironment>[]
  local seen = {}

  before_each(function()
    root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    root = assert(vim.uv.fs_realpath(root))
    checks, starts, compilations = 0, 0, 0
    seen = {}
    available = true
    dispatch.select = function()
      return {
        name = "test",
        paths = require("neoagent.sandbox.path")[jit.os == "Windows" and "windows" or "posix"],
        check = function()
          checks = checks + 1
          return { ok = available, platform = "test", message = available and nil or "activation rejected" }
        end,
        compile = function(profile)
          compilations = compilations + 1
          profile.environment.set.NEOAGENT_PLACEMENT_COMPILED = "yes"
          return profile
        end,
        start_worker = function(request)
          starts = starts + 1
          if vim.env.NEOAGENT_COVERAGE == "1" then
            table.insert(request.argv, 2, "--cmd")
            table.insert(request.argv, 3, ("lua dofile(%q)"):format(
              assert(vim.uv.cwd()) .. "/tests/fixtures/coverage_worker.lua"))
          end
          return require("neoagent.rpc.worker_lease").start(request)
        end,
      }
    end
  end)

  after_each(function()
    dispatch.select = select_platform
    if agent then agent:destroy(); agent = nil end
    if owner then
      helper.complete(function() return assert(owner):wait_cleanup(10000) end, 12000)
      assert.is_true(helper.complete(function() return assert(owner):wait_release(10000) end, 12000))
      owner = nil
    end
    if applet then applet:destroy(); applet = nil end
    if resources then resources:destroy(); resources = nil end
    vim.fn.delete(root, "rf")
  end)

  local function create(enabled)
    local config = require("neoagent.config").resolve({
      default_registry = false, providers = {}, tools = {}, workspace_trust = false,
      persistence = { enabled = false }, recording = { enabled = false }, agent_instructions = false, skills = false,
      sandbox = { enabled = enabled, profile = function(default, ctx)
        seen[#seen + 1] = ctx
        default.environment.set.NEOAGENT_PLACEMENT = "restricted"
        return default
      end },
    })
    local profiles
    profiles, _, resources = require("neoagent.profiles").bundled(config, { startup = false })
    local profile = assert(profiles[1])
    applet = profile.create_applet({ profile = profile, label = "placement", workspace = root })
    local session = assert(require("neoagent.profile_sessions").new({
      profile_id = "neo", workspace = root, persistence = { enabled = false },
    }))
    local owned
    agent, owned = profile.create_agent({ id = "placement", label = "placement", profile = profile,
      applet = applet, session = session, workspace = root })
    runtime = assert(assert(owned).sandbox).runtime
    owner = agent:get_process_sessions()
  end

  ---@param retained boolean
  ---@return Neoagent.SubprocessSpec
  local function spec(retained)
    local script = "import os; print(os.getenv('NEOAGENT_PLACEMENT', 'host') + '/' + "
      .. "os.getenv('NEOAGENT_PLACEMENT_COMPILED', 'no'), flush=True)"
    if retained then script = script .. "; input(); print(os.getenv('NEOAGENT_PLACEMENT'), flush=True)" end
    return { argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c", script }, cwd = root,
      stdio = { kind = "pipes", stdin = retained and "open" or "closed" }, timeout_ms = 10000 }
  end

  it("uses checked sandbox authority for Agent admissions and preserves it across toggles", function()
    create(true)
    local admission = helper.success(function() return helper.admit(assert(owner), spec(true), 0) end)
    local id = assert(admission.commit())
    assert.are.equal(1, starts, "Agent admission bypassed sandbox composition")
    assert.are.equal(1, checks)
    assert.are.equal(1, compilations)
    local context = assert(seen[1])
    assert.are.equal(root, assert(assert(context.context).workspace).root)
    assert.are.equal(root, assert(context.process).cwd)
    assert.is_nil(context.call)
    assert(runtime:set_enabled(false))
    local result = helper.success(function() return assert(owner):interact(id, 3000, { kind = "write", data = "go\n" }) end)
    local output = admission.result.text .. result.text
    assert(vim.wait(5000, function()
      if result.done then return true end
      result = helper.success(function() return assert(owner):interact(id, 100) end)
      output = output .. result.text
      return result.done
    end, 5))
    assert.matches("restricted/yes\nrestricted\n", (output:gsub("\r\n", "\n")), 1, true)
    admission = helper.success(function() return helper.admit(assert(owner), spec(false), 3000) end)
    assert.are.equal("host/no\n", (admission.result.text:gsub("\r\n", "\n")))
    admission.commit()
    assert.are.equal(1, starts)
    assert(runtime:set_enabled(true))
    admission = helper.success(function() return helper.admit(assert(owner), spec(false), 3000) end)
    assert.are.equal("restricted/yes\n", (admission.result.text:gsub("\r\n", "\n")))
    admission.commit()
    assert.are.equal(2, starts)
    assert.are.equal(1, checks)
  end)

  it("blocks admissions when activation fails and permits host placement only after disabling", function()
    available = false
    create(true)
    local result = helper.complete(function() return helper.admit(assert(owner), spec(false), 3000) end)
    assert.are.equal("sandbox_unavailable", assert(result.error, "unavailable sandbox allowed host execution").kind)
    assert.are.equal(0, starts)
    assert.are.equal(0, assert(owner):status().reserved)
    assert(runtime:set_enabled(false))
    local admission = helper.success(function() return helper.admit(assert(owner), spec(false), 3000) end)
    assert.are.equal("host/no\n", (admission.result.text:gsub("\r\n", "\n")))
    admission.commit()
  end)
end)
