local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local fs = require("neoagent.fs")
local workers = require("neoagent.rpc.worker_lease")

describe("native worker ownership", function()
  if jit.os ~= "Linux" then
    pending("Linux native identity inspection")
    return
  end
  ---@type string
  local directory
  ---@type Neoagent.WorkerLease?
  local lease
  before_each(function()
    directory = vim.fn.tempname()
    assert(fs.mkdirp(directory))
  end)
  after_each(function()
    if lease then
      lease:dispose("test complete")
      helper.complete(function()
        return assert(lease):wait()
      end)
    end
    vim.fn.delete(directory, "rf")
  end)

  it("retains the worker identity through output delivery and final group cleanup", function()
    local marker = directory .. "/pid"
    local output = ""
    lease = workers.start({
      argv = { "sh", "-c", "printf '%s' $$ > " .. vim.fn.shellescape(marker) .. "; printf ready" },
      cwd = directory,
      env = { PATH = assert(vim.env.PATH) },
      on_stdout = function(bytes)
        output = output .. bytes
      end,
    })
    local observed = false
    local timer = assert(vim.uv.new_timer())
    timer:start(100, 0, function()
      timer:close()
      observed = true
    end)
    local pid, status
    assert(vim.wait(2000, function()
      if not observed then
        return false
      end
      local bytes = fs.read(marker)
      pid = bytes and tonumber(bytes)
      if not pid then
        return false
      end
      local stat = fs.read("/proc/" .. pid .. "/stat")
      status = stat and stat:match("^%d+ %b() (%a)") or "reaped"
      return status == "Z" or status == "reaped"
    end, 5, true))
    assert.are.equal("Z", status, "worker identity was released before native ownership ended")
    local result = helper.complete(function()
      return assert(lease):wait()
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("ready", output)
    assert.is_nil(vim.uv.fs_stat("/proc/" .. assert(pid)))
  end)

  it("delivers protocol-sized input and drains binary output before completing", function()
    local bytes, errors = 0, ""
    lease = workers.start({
      argv = { "sh", "-c", "cat; printf diagnostic >&2" },
      cwd = directory,
      env = { PATH = assert(vim.env.PATH) },
      on_stdout = function(data)
        bytes = bytes + #data
      end,
      on_stderr = function(data)
        errors = errors .. data
      end,
    })
    local payload = string.rep("\0", 1024 * 1024)
    assert.is_true((lease:write(payload)))
    assert.is_true((lease:write(payload)))
    assert.is_true((lease:close_stdin()))
    local result = helper.complete(function()
      return assert(lease):wait()
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.is_nil(result.error)
    assert.is_nil(result.cleanup_error)
    assert.are.equal(2 * #payload, bytes)
    assert.are.equal("diagnostic", errors)
    assert.are.equal(errors, result.stderr)
  end)

  it("preserves explicitly empty and inherited worker environments", function()
    for _, inherit in ipairs({ false, true }) do
      local output = ""
      lease = workers.start({
        argv = { vim.fn.exepath("env") },
        cwd = directory,
        env = {},
        clear_env = not inherit,
        on_stdout = function(data)
          output = output .. data
        end,
      })
      local result = helper.complete(function()
        return assert(lease):wait()
      end)
      assert.are.equal(0, result.code, vim.inspect(result))
      if inherit then
        assert.matches("PATH=", output, 1, true)
      else
        assert.are.equal("", output)
      end
    end
  end)
end)
