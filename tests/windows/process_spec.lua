local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local process = require("neoagent.process")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@param timeout? integer
---@return Neoagent.RunResult<T>
local function wait(run, timeout)
  assert(vim.wait(timeout or 10000, function() return run:is_done() end, 10))
  return (assert(run:result()))
end

---@param command string[]
---@param opts? Neoagent.ProcessOptions
---@return Neoagent.RunResult<Neoagent.ProcessResult>
local function run(command, opts)
  return wait(async.run(function() return process.run(command, opts) end))
end

describe("neoagent Windows process runner", function()
  if jit.os ~= "Windows" then
    pending("requires Windows")
    return
  end

  ---@type string?
  local root

  after_each(function()
    if root then vim.fn.delete(root, "rf") end
    root = nil
  end)

  it("preserves direct cmd tails and echo state", function()
    local baseline = run({ "cmd.exe", "/d", "/s", "/c", "echo" })
    assert.are.equal(0, baseline.code, baseline.stderr)

    local positional = run({ "cmd.exe", "/d", "/s", "/c", "echo %0" })
    assert.are.equal(0, positional.code, positional.stderr)
    assert.are.equal("%0", vim.trim(assert(positional.stdout)))

    local quoted = run({
      "cmd.exe", "/d", "/s", "/c", 'echo "marker">nul & echo',
    })
    assert.are.equal(0, quoted.code, quoted.stderr)
    assert.are.equal(baseline.stdout, quoted.stdout)

    root = vim.fn.tempname() .. "-process-unicode"
    assert(fs.mkdirp(root))
    local unicode = vim.fs.joinpath(root, "olá.txt")
    local created = run({
      "cmd.exe", "/d", "/s", "/c", 'echo value>"' .. unicode .. '"',
    })
    assert.are.equal(0, created.code, created.stderr)
    assert.matches("value", assert(fs.read(unicode)))
  end)

  it("executes quoted commands with metacharacters in the temporary directory", function()
    root = vim.fn.tempname() .. "&command"
    assert(fs.mkdirp(root))
    local original_create = fs.create_temp_directory
    fs.create_temp_directory = function(prefix)
      return original_create(prefix, root)
    end
    local ok, value = pcall(run, {
      "cmd.exe", "/d", "/s", "/c", 'echo "marker" & exit /b 7',
    })
    fs.create_temp_directory = original_create
    assert.is_true(ok, vim.inspect(value))
    assert.are.equal(7, value.code, vim.inspect(value))
    assert.are.equal('"marker"', vim.trim(assert(value.stdout)))
    assert.are.same({}, vim.fn.readdir(root))
  end)

  it("preserves binary stdin and both output streams through cmd", function()
    local python = vim.fn.exepath("python")
    assert.is_not.equal("", python)
    local bytes = "\0one\r\ntwo\n\255\0"
    local command = '"' .. python .. '" -c "import sys; '
      .. 'data=sys.stdin.buffer.read(); sys.stdout.buffer.write(data); '
      .. 'sys.stderr.buffer.write(data)"'
    local result = run({ "cmd.exe", "/d", "/s", "/c", command }, { stdin = bytes })
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal(bytes, result.stdout)
    assert.are.equal(bytes, result.stderr)
  end)

  it("reuses native declarations and terminates descendants", function()
    local first = run({ "cmd.exe", "/d", "/s", "/c", "exit /b 0" })
    assert.are.equal(0, first.code)

    root = vim.fn.tempname() .. "-process"
    assert(fs.mkdirp(root))
    local started = vim.fs.joinpath(root, "started.txt")
    local survived = vim.fs.joinpath(root, "survived.txt")
    local child = vim.fs.joinpath(root, "child.cmd")
    local parent = vim.fs.joinpath(root, "parent.ps1")
    assert(fs.write_all(child, table.concat({
      "@echo off",
      'echo started>"' .. started .. '"',
      "ping.exe -n 4 127.0.0.1 >nul",
      'echo survived>"' .. survived .. '"',
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

    local active = async.run(function()
      return process.run({
        "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass", "-File", parent,
      }, { kill_grace_ms = 0 })
    end)
    local child_started = vim.wait(20000, function()
      return vim.uv.fs_stat(started) ~= nil
    end, 10)
    active:cancel()
    local cancelled = wait(active)
    assert.is_true(child_started)
    assert.are.equal("cancelled", assert(cancelled.error).kind)
    assert.is_false((vim.wait(5000, function()
      return vim.uv.fs_stat(survived) ~= nil
    end, 20)))
  end)
end)
