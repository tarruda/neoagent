local assert = require("luassert")
local fs = require("neoagent.fs")
local helper = require("tests.helpers.subprocess")
local sessions = require("neoagent.process_sessions")
local remote = require("neoagent.sandbox.process_session")

describe("native retained process authority", function()
  local platform, unavailable = require("neoagent.sandbox.platform").select()
  local status = platform and platform.check({ fs = fs, nvim = vim.env.NEOAGENT_NVIM }) or unavailable
  local active = platform and status and status.ok
  if vim.env.NEOAGENT_REQUIRE_SANDBOX == "1" or jit.os == "Windows" then
    it("has native sandbox support", function()
      assert.is_true(active, vim.inspect(status))
    end)
  end
  if not active then
    pending("native sandbox is unavailable")
    return
  end
  ---@type Neoagent.ProcessSessions
  local owner
  ---@type string
  local root
  ---@type Neoagent.SandboxProfile
  local profile
  ---@type Neoagent.Agent?
  local agent
  before_each(function()
    root = vim.fs.joinpath(vim.env.RUNNER_TEMP or vim.uv.os_tmpdir(), "neoagent-retained-" .. tostring(vim.uv.hrtime()))
    assert(fs.mkdirp(root))
    root = assert(vim.uv.fs_realpath(root))
    assert(fs.mkdirp(vim.fs.joinpath(root, "denied")))
    assert(fs.write_all(vim.fs.joinpath(root, "denied", "value"), "private"))
    owner = sessions.new({ capacity = 1, output_bytes = 1024 })
    profile = {
      id = "retained-authority",
      filesystem = { default = "read", entries = {
        { path = root, access = "write" },
        { path = vim.fs.joinpath(root, "denied"), access = "deny" },
      } },
      network = "restricted",
      environment = { clear = false, inherit = {}, set = { NEOAGENT_RETAINED_VALUE = "original" } },
    }
  end)
  after_each(function()
    require("tests.helpers.sandbox").cleanup()
    if agent then agent:destroy(); agent = nil end
    owner:close("native test complete")
    helper.complete(function() return owner:wait_cleanup(15000) end, 20000)
    assert.is_true(helper.complete(function() return owner:wait_release(15000) end, 20000))
    vim.fn.delete(root, "rf")
  end)

  it("applies the shared sandbox composition to an Agent's default admission", function()
    local _, _, _, runtime = require("neoagent.sandbox.composition").switchable({ tools = {} },
      { enabled = true, profile = function() return profile end },
      { platform = assert(platform), status = assert(status), nvim = vim.env.NEOAGENT_NVIM })
    agent = require("neoagent").new({
      default_registry = false, providers = {}, tools = {}, workspace_trust = false,
      persistence = { enabled = false }, recording = { enabled = false }, agent_instructions = false, skills = false,
    }, { workspace = root, process_placement = function(context, spec)
      return runtime:process_factory({ context = context, process = spec })
    end })
    owner = agent:get_process_sessions()
    local admission = helper.success(function()
      return helper.admit(owner, { argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c",
        "try:\n open('denied/value').read()\n print('LEAK')\nexcept PermissionError:\n print('DENIED')" },
        cwd = root, stdio = { kind = "pipes" }, timeout_ms = 15000 }, 30000)
    end, 35000)
    assert.is_true(admission.result.done, vim.inspect(admission.result))
    assert.are.equal(0, assert(admission.result.outcome).code, admission.result.text)
    assert.matches("DENIED", admission.result.text, 1, true)
    assert.is_nil((admission.result.text:find("LEAK", 1, true)))
    admission.commit()
  end)

  it("executes a restricted Tool while a retained target waits for input", function()
    local tool = require("neoagent.tools.write_file").new()
    local selected, _, _, runtime = require("neoagent.sandbox.composition").switchable({ tools = { tool } },
      { enabled = true, profile = function() return profile end },
      { platform = assert(platform), status = assert(status), nvim = vim.env.NEOAGENT_NVIM })
    local context = {
      workspace = require("neoagent.workspace").new({ root = root, cwd = root }),
      files = require("neoagent.files.memory").new(), agent = "concurrent native authority",
    }
    local factory = runtime:process_factory({ context = context, process = {
      argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c", "input(); print('FINISHED')" },
      cwd = root, stdio = { kind = "pipes", stdin = "open" }, timeout_ms = 60000,
    } })
    owner = sessions.new({ capacity = 1, output_bytes = 1024 }, nil, factory)
    local admission = helper.success(function()
      return helper.admit(owner, {
        argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c", "input(); print('FINISHED')" },
        cwd = root, stdio = { kind = "pipes", stdin = "open" }, timeout_ms = 60000,
      }, 0)
    end, 30000)
    local id = assert(admission.commit())
    local model = require("tests.helpers.fake_model")
    local completed = helper.wait(require("neoagent.agent_loop").run({
      model = model.new({
        { result = model.assistant({ { type = "toolCall", id = "write", name = "write_file",
          arguments = { path = "tool-result", content = "written while target is retained" } } }, "toolUse") },
        { result = model.assistant({}) },
      }),
      messages = {}, tools = selected.tools, execute_tool = selected.execute_tool,
      context = context, commit_message = function() return true end,
    }), 30000)
    assert.is_true(completed.ok, vim.inspect(completed))
    assert.are.equal("written while target is retained", fs.read(vim.fs.joinpath(root, "tool-result")))
    assert.is_false(helper.success(function() return owner:interact(id, 0) end).done)
    local response = helper.success(function()
      return owner:interact(id, 5000, { kind = "write", data = "go\n" })
    end, 10000)
    local output = response.text
    assert(vim.wait(15000, function()
      if response.done then return true end
      response = helper.success(function() return owner:interact(id, 100) end)
      output = output .. response.text
      return response.done
    end, 10))
    assert.is_nil(response.cleanup_error, vim.inspect(response))
    assert.are.equal(0, assert(response.outcome).code, output)
    assert.matches("FINISHED", output, 1, true)
  end)

  for _, terminal in ipairs({ false, true }) do
    it("retains original sandbox authority across " .. (terminal and "PTY" or "pipe") .. " handoff", function()
      local factory = remote.factory(require("neoagent.sandbox.placement").new({ profile = profile, platform = assert(platform),
        capabilities = assert(status).capabilities, nvim = vim.env.NEOAGENT_NVIM }), {})
      owner = sessions.new({ capacity = 1, output_bytes = 1024 }, nil, factory)
      -- Neither changed caller state nor a later interaction can widen the
      -- profile or environment selected at admission.
      profile.filesystem.entries = { { path = root, access = "write" } }
      profile.environment.set.NEOAGENT_RETAINED_VALUE = "changed"
      local script = table.concat({
        "import os, sys",
        "print('READY=' + os.environ['NEOAGENT_RETAINED_VALUE'], flush=True)",
        "input()",
        "try:",
        " open('denied/value').read()",
        " print('LEAK', flush=True)",
        "except PermissionError:",
        " print('DENIED', flush=True)",
        "with open('allowed', 'w') as f: f.write('owned')",
        "print('FINISHED', flush=True)",
      }, "\n")
      local admission = helper.success(function()
        return helper.admit(owner, { argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c", script },
          cwd = root, stdio = terminal and { kind = "pty", columns = 80, rows = 24 }
            or { kind = "pipes", stdin = "open" }, timeout_ms = 20000 }, 0)
      end, 30000)
      local id = assert(admission.commit())
      local output = admission.result.text
      local response = helper.success(function()
        return owner:interact(id, 1000, { kind = "write", data = terminal and jit.os == "Windows" and "go\r" or "go\n" })
      end)
      output = output .. response.text
      assert(vim.wait(15000, function()
        response = helper.success(function() return owner:interact(id, 100) end)
        output = output .. response.text
        return response.done
      end, 5))
      assert.is_nil(response.error, vim.inspect(response))
      assert.is_nil(response.cleanup_error, vim.inspect(response))
      assert.are.equal(0, assert(response.outcome).code, output)
      assert.matches("READY=original", output, 1, true)
      assert.matches("DENIED", output, 1, true)
      assert.matches("FINISHED", output, 1, true)
      assert.is_nil((output:find("LEAK", 1, true)))
      assert.are.equal("owned", (fs.read(vim.fs.joinpath(root, "allowed"))))
    end)
  end

  it("ends a retained worker and its target when the owner closes", function()
    local factory = remote.factory(require("neoagent.sandbox.placement").new({ profile = profile, platform = assert(platform),
      capabilities = assert(status).capabilities, nvim = vim.env.NEOAGENT_NVIM }), {})
    owner = sessions.new({ capacity = 1, output_bytes = 1024 }, nil, factory)
    local admission = helper.success(function()
      return helper.admit(owner, { argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c",
        "import time; print('ready', flush=True); time.sleep(120)" }, cwd = root,
        stdio = { kind = "pipes" } }, 0)
    end, 30000)
    assert(admission.commit())
    assert.are.equal(1, owner:status().reserved)
    owner:close("owner destroyed")
    assert.is_true(helper.complete(function() return owner:wait_release(15000) end, 20000))
    assert.are.equal(0, owner:status().reserved)
  end)

  it("finishes cancelled native admission before admitting another worker", function()
    local async = require("neoagent.async")
    local connections = require("neoagent.rpc.connection")
    local original = connections.new
    ---@type Neoagent.AwaitCallbacks<true>?
    local opening
    connections.new = function(options)
      local connection = original(options)
      local open = connection.open
      ---@async
      function connection:open(context)
        -- Native readiness has already launched the restricted RPC worker.
        -- Delay opening only; no additional native owner helps its cleanup.
        async.await(function(done) opening = done end)
        return open(self, context)
      end
      return connection
    end
    local factory = remote.factory(require("neoagent.sandbox.placement").new({ profile = profile,
      platform = assert(platform), capabilities = assert(status).capabilities, nvim = vim.env.NEOAGENT_NVIM }), {})
    owner = sessions.new({ capacity = 1 }, nil, factory)
    local marker = vim.fs.joinpath(root, "cancelled-command")
    local admitting = async.run(function()
      return helper.admit(owner, { argv = { jit.os == "Windows" and "python" or "python3", "-c",
        "open('cancelled-command', 'w').write('ran')" }, cwd = root, stdio = { kind = "pipes" } }, 0)
    end)
    local reached = vim.wait(30000, function() return opening ~= nil or admitting:is_done() end, 5)
    connections.new = original
    admitting:cancel()
    if opening then opening.resolve(true) end
    assert.is_true(reached)
    assert.is_not_nil(opening, vim.inspect(admitting:result()))
    assert.are.equal("cancelled", assert(helper.wait(admitting).error).kind)
    assert.is_true(helper.complete(function() return owner:wait_cleanup(15000) end, 20000))
    assert.is_true(helper.complete(function() return owner:wait_release(15000) end, 20000))
    assert.is_nil(vim.uv.fs_stat(marker), "cancelled admission executed its requested command")
    local next_admission = helper.success(function()
      return helper.admit(owner, { argv = { jit.os == "Windows" and "python" or "python3", "-c", "print('NEXT')" },
        cwd = root, stdio = { kind = "pipes" } }, 30000)
    end, 35000)
    assert.are.equal(0, assert(next_admission.result.outcome).code, vim.inspect(next_admission.result))
    assert.matches("NEXT", next_admission.result.text, 1, true)
    next_admission.commit()
  end)
end)
