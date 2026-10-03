local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local subprocess = require("neoagent.subprocess_common")
local pipe = require("neoagent.subprocess.pipe")
local helper = require("tests.helpers.subprocess")

describe("worker-owned subprocess scopes", function()
  if jit.os == "Windows" then
    pending("requires POSIX process groups")
    return
  end
  local original_new = pipe.new
  ---@type Neoagent.SubprocessScope[]
  local scopes = {}
  local roots = {}

  after_each(function()
    pipe.new = original_new
    for _, scope in ipairs(scopes) do
      scope:close("test finished")
      assert.is_true(helper.complete(function()
        return scope:wait(4000)
      end))
    end
    scopes = {}
    for _, root in ipairs(roots) do
      vim.fn.delete(root, "rf")
    end
    roots = {}
  end)

  local function scope()
    local value = subprocess.scope()
    scopes[#scopes + 1] = value
    return value
  end

  local function directory()
    local root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    roots[#roots + 1] = root
    return root
  end

  local function command(ready, late)
    return helper.spec(
      "trap '' TERM; (trap '' TERM; sleep 0.5; printf late > "
        .. vim.fn.shellescape(late)
        .. ") </dev/null >/dev/null 2>&1 & printf ready > "
        .. vim.fn.shellescape(ready)
        .. "; wait"
    )
  end

  it("finishes descendant cleanup before shutdown and rejects later work", function()
    local owner = scope()
    local root = directory()
    local runs = {}
    for index = 1, 2 do
      runs[index] = async.run(function()
        return owner:run(command(root .. "/ready" .. index, root .. "/late" .. index), { capture = false })
      end)
    end
    assert(vim.wait(3000, function()
      return vim.uv.fs_stat(root .. "/ready1") ~= nil and vim.uv.fs_stat(root .. "/ready2") ~= nil
    end, 5))
    runs[1]:cancel()
    owner:close("request finished")
    owner:close("again")
    assert.are.equal("cancelled", assert(helper.wait(runs[1]).error).kind)
    assert.are.equal("process_disposed", assert(helper.wait(runs[2]).error).kind)
    assert.is_true(helper.complete(function()
      return owner:wait(3000)
    end))
    assert.is_false((vim.wait(900, function()
      return vim.uv.fs_stat(root .. "/late1") ~= nil or vim.uv.fs_stat(root .. "/late2") ~= nil
    end, 5)))
    local err = helper.failure(function()
      owner:spawn(helper.spec("true"))
    end)
    assert.are.equal("process_disposed", err.code)
  end)

  it("contains a command tree when shutdown happens during platform startup", function()
    local owner = scope()
    local root = directory()
    local ready, late = root .. "/ready", root .. "/late"
    pipe.new = function(spec, env, callbacks)
      local child = original_new(spec, env, callbacks)
      local start = child.start
      child.start = function()
        local pid = start()
        assert(vim.wait(3000, function()
          return vim.uv.fs_stat(ready) ~= nil
        end, 5))
        owner:close("closed during startup")
        return pid
      end
      return child
    end
    local run = async.run(function()
      return owner:run(command(ready, late), { capture = false })
    end)
    pipe.new = original_new
    assert.are.equal("process_disposed", assert(helper.wait(run).error).kind)
    assert.is_true(helper.complete(function()
      return owner:wait(3000)
    end))
    assert.is_false((vim.wait(900, function()
      return vim.uv.fs_stat(late) ~= nil
    end, 5)))
  end)

  it("releases failed startup without preventing another command", function()
    local owner = scope()
    local root = directory()
    local err = helper.failure(function()
      owner:spawn(helper.spec("", { argv = { root .. "/missing-program" } }))
    end)
    assert.are.equal("process_start", err.code)
    assert.is_true(helper.complete(function()
      return owner:wait(1000)
    end))
    local recovered = helper.complete(function()
      return owner:run(helper.spec("printf recovered"), { capture = { max_bytes = 100 } })
    end)
    assert.are.equal(0, recovered.code)
    assert.are.equal("recovered", recovered.stdout)
  end)

  it("bounds cleanup waits and removes cancelled observers without abandoning the command", function()
    local owner = scope()
    local handle = owner:spawn(helper.spec("sleep 10"))
    local timed_out = helper.complete(function()
      return owner:wait(10)
    end)
    assert.are.equal("process_cleanup", assert(timed_out.error).kind)
    assert.is_false(owner:is_settled())
    assert.are.equal("running", handle:state().phase)

    local cancelled = async.run(function()
      return owner:wait(3000)
    end)
    cancelled:cancel()
    assert.are.equal("cancelled", assert(helper.wait(cancelled).error).kind)
    assert.is_false(owner:is_settled())
    local completed = async.run(function()
      return owner:wait(3000)
    end)
    owner:close("finished")
    assert.is_true(helper.wait(completed))
    assert.is_true(owner:is_settled())
    assert.is_true(helper.complete(function()
      return owner:wait(3000)
    end))
  end)

  it("refuses to start a command when its native watcher cannot be allocated", function()
    local owner = scope()
    local new_signal, spawn = vim.uv.new_signal, vim.uv.spawn
    local started = 0
    vim.uv.new_signal = function()
      return nil
    end
    vim.uv.spawn = function(...)
      started = started + 1
      return spawn(...)
    end
    local ok, err = pcall(owner.spawn, owner, helper.spec("sleep 10"))
    vim.uv.new_signal, vim.uv.spawn = new_signal, spawn
    assert.is_false(ok)
    assert.are.equal("process_supervision", require("neoagent.util").normalize_error(err).code)
    assert.are.equal(0, started)
    assert.is_true(helper.complete(function()
      return owner:wait(3000)
    end))
  end)
end)
