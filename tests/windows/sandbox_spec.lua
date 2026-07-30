local async = require("neoagent.async")
local fs = require("neoagent.fs")
local sandbox = require("neoagent.sandbox")
local windows = require("neoagent.sandbox.windows")

local function wait(run, timeout)
  assert(vim.wait(timeout or 30000, function() return run:is_done() end, 10))
  local result = run:result()
  if type(result) == "table" and result.ok == false then
    assert.is_true(result.ok,
      result.error and result.error.message or "sandbox operation failed")
  end
  return result
end

local function run(argv, opts)
  return wait(async.run(function()
    return sandbox.sandbox_exec(argv, opts)
  end), (opts.timeout_ms or 30000) + 30000)
end

describe("neoagent Windows sandbox", function()
  if jit.os ~= "Windows" then
    pending("requires Windows")
    return
  end

  local root
  local status
  local environment
  local readonly
  local secret

  local function profile(network)
    return {
      id = "windows-live",
      filesystem = {
        default = "read",
        entries = {
          { path = root, access = "write" },
          { path = readonly, access = "read" },
          { path = secret, access = "deny" },
          { path = windows.temporary_root(), access = "write" },
        },
      },
      network = network or "restricted",
      environment = {
        clear = true,
        inherit = {},
        set = {},
      },
    }
  end

  local function options(extra)
    return vim.tbl_extend("force", {
      os = "Windows",
      profile = profile(),
      cwd = root,
      env = environment,
      capabilities = status.capabilities,
      nvim = vim.env.NEOAGENT_NVIM or vim.v.progpath,
    }, extra or {})
  end

  before_each(function()
    root = vim.fs.joinpath(vim.env.RUNNER_TEMP or vim.uv.os_tmpdir(),
      "neoagent-live-" .. tostring(vim.uv.hrtime()))
    assert(fs.mkdirp(root))
    readonly = vim.fs.joinpath(root, ".git")
    secret = vim.fs.joinpath(root, "secret")
    assert(fs.mkdirp(readonly))
    assert(fs.mkdirp(secret))
    assert(fs.write_all(vim.fs.joinpath(readonly, "config"), "original\r\n"))
    assert(fs.write_all(vim.fs.joinpath(secret, "value"), "classified\r\n"))
    environment = {
      PATH = assert(vim.env.PATH),
      PATHEXT = vim.env.PATHEXT or ".COM;.EXE;.BAT;.CMD",
      SystemRoot = assert(vim.env.SystemRoot),
      WINDIR = vim.env.WINDIR or vim.env.SystemRoot,
      COMSPEC = assert(vim.env.COMSPEC),
      TEMP = windows.temporary_root(),
      TMP = windows.temporary_root(),
      TMPDIR = windows.temporary_root(),
    }
    status = windows.check({
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM or vim.v.progpath,
    })
    assert.is_true(status.ok,
      tostring(status.stage) .. ": " .. tostring(status.message))
  end)

  after_each(function()
    if root then vim.fn.delete(root, "rf") end
  end)

  it("streams binary-safe output and preserves process exit status", function()
    local value = run({
      "cmd.exe", "/d", "/s", "/c",
      "echo stdout & echo stderr 1>&2 & exit /b 7",
    }, options())
    assert.are.equal(7, value.code, value.stderr)
    assert.matches("stdout", value.stdout)
    assert.matches("stderr", value.stderr)
    assert.is_false(value.timed_out)
  end)

  it("preserves Windows argv quoting at process creation", function()
    local script = vim.fs.joinpath(root, "arguments.ps1")
    assert(fs.write_all(script,
      "[Console]::Out.Write(($args | ConvertTo-Json -Compress))\r\n"))
    local expected = {
      "",
      "space value",
      'embedded"quote',
      "trailing\\",
      "two\\\\slashes",
    }
    local argv = {
      "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
      "-ExecutionPolicy", "Bypass", "-File", script,
    }
    vim.list_extend(argv, expected)
    local value = run(argv, options())
    assert.are.equal(0, value.code, value.stderr)
    assert.are.same(expected, vim.json.decode(value.stdout))
  end)

  it("enforces writable, read-only, denied, and offline boundaries", function()
    local writable = vim.fs.joinpath(root, "writable.txt")
    local value = run({
      "cmd.exe", "/d", "/s", "/c",
      'echo allowed>"' .. writable .. '"',
    }, options())
    assert.are.equal(0, value.code, value.stderr)
    assert.matches("allowed", assert(fs.read(writable)))

    value = run({
      "cmd.exe", "/d", "/s", "/c",
      'echo changed>"' .. vim.fs.joinpath(readonly, "config") .. '"',
    }, options())
    assert.are_not.equal(0, value.code)
    assert.are.equal("original\r\n",
      assert(fs.read(vim.fs.joinpath(readonly, "config"))))

    value = run({
      "cmd.exe", "/d", "/s", "/c",
      'rmdir /s /q "' .. readonly .. '"',
    }, options())
    assert.are_not.equal(0, value.code)
    assert.is_table(vim.uv.fs_stat(readonly))

    value = run({
      "cmd.exe", "/d", "/s", "/c",
      'type "' .. vim.fs.joinpath(secret, "value") .. '"',
    }, options())
    assert.are_not.equal(0, value.code)
    assert.is_nil(value.output:find("classified", 1, true))
    assert.is_true(status.capabilities.windows_filtering_platform)
    assert.is_true(status.capabilities.restricted_token)
  end)

  it("protects future carveouts and removes its owned placeholder", function()
    local protected = vim.fs.joinpath(root, "future-metadata")
    local active = profile()
    active.filesystem.entries[#active.filesystem.entries + 1] = {
      path = protected,
      access = "read",
    }
    local value = run({
      "cmd.exe", "/d", "/s", "/c",
      'mkdir "' .. protected .. '"',
    }, options({ profile = active }))
    assert.are_not.equal(0, value.code)
    assert.is_nil(vim.uv.fs_lstat(protected))
  end)

  it("selects the online identity when network is enabled", function()
    local listener = assert(vim.uv.new_tcp())
    assert(listener:bind("127.0.0.1", 0))
    local address = assert(listener:getsockname())
    local accepted
    local listener_error
    assert(listener:listen(8, function(err)
      if err then listener_error = err return end
      local client = vim.uv.new_tcp()
      local ok, accept_err = listener:accept(client)
      if not ok then
        listener_error = accept_err
        client:close()
        return
      end
      accepted = true
      client:close()
    end))
    local completed, value = pcall(run, {
        "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
        "-Command",
        "$client=[Net.Sockets.TcpClient]::new();"
          .. "$client.Connect('127.0.0.1'," .. address.port .. ");"
          .. "[Console]::Out.Write('online');$client.Dispose()",
      }, options({ profile = profile("enabled") }))
    if completed then
      vim.wait(1000, function()
        return accepted or listener_error ~= nil
      end, 10)
    end
    listener:close()
    assert.is_true(completed, tostring(value))
    assert.are.equal(0, value.code, value.stderr)
    assert.are.equal("online", value.stdout)
    assert.is_nil(listener_error)
    assert.is_true(accepted)
  end)

  it("kills descendants on timeout and reconciles interrupted ACL leases", function()
    local escaped = vim.fs.joinpath(root, "escaped.txt")
    local child = vim.fs.joinpath(root, "child.cmd")
    local parent = vim.fs.joinpath(root, "parent.ps1")
    assert(fs.write_all(child, table.concat({
      "@echo off",
      "ping.exe -n 4 127.0.0.1 >nul",
      'echo escaped>"' .. escaped .. '"',
      "",
    }, "\r\n")))
    local child_literal = "'" .. child:gsub("'", "''") .. "'"
    assert(fs.write_all(parent, table.concat({
      "$child = " .. child_literal,
      "$arguments = '/d /c \"' + $child + '\"'",
      "Start-Process -FilePath $env:COMSPEC "
        .. "-ArgumentList $arguments -WindowStyle Hidden",
      "Start-Sleep -Seconds 30",
      "",
    }, "\r\n")))
    local value = run({
      "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
      "-ExecutionPolicy", "Bypass", "-File", parent,
    }, options({ timeout_ms = 500, kill_grace_ms = 0 }))
    assert.is_true(value.timed_out)
    assert.is_false(vim.wait(5000, function()
      return vim.uv.fs_stat(escaped) ~= nil
    end, 20))
    assert.is_nil(vim.uv.fs_stat(escaped))

    value = run({
      "cmd.exe", "/d", "/s", "/c",
      'echo changed>"' .. vim.fs.joinpath(readonly, "config") .. '"',
    }, options())
    assert.are_not.equal(0, value.code)
    assert.are.equal("original\r\n",
      assert(fs.read(vim.fs.joinpath(readonly, "config"))))
  end)
end)
