local assert = require("luassert")
local config = require("neoagent.config")
local health = require("neoagent.health")
local profiles = require("neoagent.profiles")

describe("local subprocess health diagnostics", function()
  local cases = {
    { os = "BSD", arch = "x64", error = "Unsupported native process platform: BSD" },
    { os = "Linux", arch = "mips", error = "Unsupported native process ABI: Linux/mips" },
    { os = "OSX", arch = "x86", error = "Unsupported native process ABI: OSX/x86" },
    { os = "Linux", arch = "x64" },
    { os = "OSX", arch = "arm64" },
    { os = "Windows", arch = "x64" },
  }

  for _, platform in ipairs(cases) do
    it("reports " .. platform.os .. "/" .. platform.arch .. " without starting a process owner", function()
      local os, arch = jit.os, jit.arch
      local original_health, bundled = vim.health, profiles.bundled
      local new_signal, spawn = vim.uv.new_signal, vim.uv.spawn
      local pty = require("neoagent.subprocess.pty")
      local new_pty = pty.new
      local allocations = 0
      ---@type table<string, string[]>
      local messages = { ok = {}, error = {}, warn = {}, start = {} }
      config._reset()
      config.setup({ persistence = { enabled = false }, ui = { images = false } })
      -- Keep the independent configuration diagnostic observable without
      -- constructing platform-specific provider resources on a simulated host.
      profiles.bundled = function()
        error("independent configuration failure", 0)
      end
      vim.health = {}
      for kind in pairs(messages) do
        vim.health[kind] = function(message)
          messages[kind][#messages[kind] + 1] = message
        end
      end
      vim.uv.new_signal = function()
        allocations = allocations + 1
        error("health must not create process watchers")
      end
      vim.uv.spawn = function()
        allocations = allocations + 1
        error("platform inspection must not launch a target")
      end
      pty.new = function()
        allocations = allocations + 1
        error("ordinary process support does not require a PTY")
      end
      jit.os, jit.arch = platform.os, platform.arch
      local ok, err = pcall(health.check)
      jit.os, jit.arch = os, arch
      vim.health, profiles.bundled = original_health, bundled
      vim.uv.new_signal, vim.uv.spawn, pty.new = new_signal, spawn, new_pty
      config._reset()

      assert.is_true(ok, vim.inspect(err))
      assert.are.equal(0, allocations)
      local success = "local subprocess platform is supported: " .. platform.os .. "/" .. platform.arch
      if platform.error then
        local reported = false
        for _, message in ipairs(messages.error) do
          if message:find(platform.error, 1, true) then
            reported = true
          end
        end
        assert.is_true(reported, "health omitted the subprocess restriction: " .. platform.error)
        assert.is_false(vim.tbl_contains(messages.ok, success))
      else
        assert.is_true(vim.tbl_contains(messages.ok, success), "health omitted supported native command execution")
      end
      assert.is_true(vim.tbl_contains(messages.error, "configuration error: independent configuration failure"))
    end)
  end
end)
