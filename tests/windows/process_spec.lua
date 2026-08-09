local async = require("neoagent.async")
local fs = require("neoagent.fs")
local process = require("neoagent.process")

local function wait(run, timeout)
  assert(vim.wait(timeout or 10000, function() return run:is_done() end, 10))
  return run:result()
end

local function run(command, opts)
  return wait(async.run(function() return process.run(command, opts) end))
end

describe("neoagent Windows process runner", function()
  if jit.os ~= "Windows" then
    pending("requires Windows")
    return
  end

  local root

  after_each(function()
    if root then vim.fn.delete(root, "rf") end
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
    local child_started = vim.wait(5000, function()
      return vim.uv.fs_stat(started) ~= nil
    end, 10)
    active:cancel()
    local cancelled = wait(active)
    assert.is_true(child_started)
    assert.are.equal("cancelled", cancelled.error.kind)
    assert.is_false(vim.wait(5000, function()
      return vim.uv.fs_stat(survived) ~= nil
    end, 20))
  end)
end)
