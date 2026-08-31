local async = require("neoagent.async")
local fs = require("neoagent.fs")
local sandbox = require("neoagent.sandbox")
local windows = require("neoagent.sandbox.windows")
local Workspace = require("neoagent.workspace")

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

  it("classifies command failures by sandbox-denial evidence", function()
    local active = profile()
    active.environment.set = environment
    local execute = sandbox.new({
      platform = windows,
      profile = active,
      capabilities = status.capabilities,
      nvim = vim.env.NEOAGENT_NVIM or vim.v.progpath,
    }):wrap()
    local context = {
      context = {
        workspace = Workspace.new({ root = root, cwd = root }),
        agent = "Windows sandbox",
      },
    }
    local function command(argv)
      return wait(async.run(function()
        return execute({
          execute = function(_, ctx)
            local process_result = ctx.process(argv, { cwd = root })
            local output = process_result.output
            if output == "" then output = "(no output)" end
            return {
              content = { { type = "text", text = output } },
              details = { exit_code = process_result.code },
              isError = process_result.code ~= 0,
            }
          end,
        }, {}, context)
      end), 60000)
    end
    local function assert_ordinary(value)
      assert.is_true(value.isError)
      assert.is_nil(value.details.sandbox)
      assert.is_nil(value.content[1].text:find(
        "blocked by the sandbox", 1, true))
    end
    local function assert_restricted(value)
      assert.is_true(value.isError)
      assert.is_true(value.details.sandbox.ran_restricted)
      assert.matches("blocked by the sandbox",
        value.content[1].text, 1, true)
    end

    local search_path = vim.fs.joinpath(root, "no-match.txt")
    assert(fs.write_all(search_path, "present\r\n"))
    local findstr = vim.fs.joinpath(
      vim.env.SystemRoot, "System32", "findstr.exe")
    local no_match = command({
      findstr, "/l", "/c:absent", search_path,
    })
    assert_ordinary(no_match)
    assert.are.equal(1, no_match.details.exit_code)

    local git = vim.fn.exepath("git")
    assert.is_not.equal("", git)
    local git_parent = vim.fs.dirname(vim.fs.dirname(git))
    local bash
    for _, candidate in ipairs({
      vim.fs.joinpath(git_parent, "bin", "bash.exe"),
      vim.fs.joinpath(vim.fs.dirname(git_parent), "bin", "bash.exe"),
    }) do
      if vim.uv.fs_stat(candidate) then bash = candidate break end
    end
    assert.is_string(bash)
    local function bash_command(script)
      return command({
        bash, "--noprofile", "--norc", "-c", script,
      })
    end

    local protected_write = bash_command(table.concat({
      "/usr/bin/cat > .git/created.txt <<'EOF'",
      "blocked",
      "EOF",
    }, "\n"))
    assert_restricted(protected_write)
    assert.is_nil(vim.uv.fs_stat(
      vim.fs.joinpath(readonly, "created.txt")))

    local missing_write = bash_command(table.concat({
      "/usr/bin/cat > missing/created.txt <<'EOF'",
      "blocked",
      "EOF",
    }, "\n"))
    assert_ordinary(missing_write)
    assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(root, "missing")))

    assert_restricted(bash_command("/usr/bin/cat < secret/value"))
    assert_ordinary(bash_command("/usr/bin/cat < absent.txt"))
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
    local value = run(argv, options({ timeout_ms = 180000 }))
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
