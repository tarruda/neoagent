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
    owner:close("native test complete")
    helper.complete(function() return owner:wait_cleanup(15000) end, 20000)
    assert.is_true(helper.complete(function() return owner:wait_release(15000) end, 20000))
    vim.fn.delete(root, "rf")
  end)

  for _, terminal in ipairs({ false, true }) do
    it("retains original sandbox authority across " .. (terminal and "PTY" or "pipe") .. " handoff", function()
      local factory = remote.factory({ profile = profile, platform = assert(platform),
        capabilities = assert(status).capabilities, nvim = vim.env.NEOAGENT_NVIM }, {})
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
        return owner:prepare({ argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c", script },
          cwd = root, stdio = terminal and { kind = "pty", columns = 80, rows = 24 }
            or { kind = "pipes", stdin = "open" }, timeout_ms = 20000 }, 0, factory)
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
    local factory = remote.factory({ profile = profile, platform = assert(platform),
      capabilities = assert(status).capabilities, nvim = vim.env.NEOAGENT_NVIM }, {})
    local admission = helper.success(function()
      return owner:prepare({ argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c",
        "import time; print('ready', flush=True); time.sleep(120)" }, cwd = root,
        stdio = { kind = "pipes" } }, 0, factory)
    end, 30000)
    assert(admission.commit())
    assert.are.equal(1, owner:status().reserved)
    owner:close("owner destroyed")
    assert.is_true(helper.complete(function() return owner:wait_release(15000) end, 20000))
    assert.are.equal(0, owner:status().reserved)
  end)
end)
