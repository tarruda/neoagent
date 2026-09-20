local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local process = require("neoagent.process")

describe("worker-owned command scopes", function()
  if jit.os == "Windows" then
    pending("requires POSIX process groups")
    return
  end
  local original_system = vim.system
  ---@type Neoagent.ProcessScope[]
  local scopes = {}
  local roots = {}

  after_each(function()
    vim.system = original_system
    for _, scope in ipairs(scopes) do
      scope:close()
      assert(vim.wait(3000, function() return scope:is_settled() end, 5))
    end
    scopes = {}
    for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
    roots = {}
  end)

  local function scope()
    local value = process.scope()
    scopes[#scopes + 1] = value
    return value
  end

  local function directory()
    local root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    roots[#roots + 1] = root
    return root
  end

  ---@generic T
  ---@param run Neoagent.Run<T, unknown>
  ---@return Neoagent.RunResult<T>
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end, 5))
    return (assert(run:result()))
  end

  local function command(ready, late)
    return { "sh", "-c", "trap '' TERM; (trap '' TERM; sleep 0.5; printf late > "
      .. vim.fn.shellescape(late) .. ") </dev/null >/dev/null 2>&1 & printf ready > "
      .. vim.fn.shellescape(ready) .. "; wait" }
  end

  it("finishes pending command cleanup before shutdown and rejects later work", function()
    local owner = scope()
    local root = directory()
    local runs = {}
    for index = 1, 2 do
      runs[index] = async.run(function()
        return owner:run(command(root .. "/ready" .. index, root .. "/late" .. index))
      end)
    end
    assert(vim.wait(3000, function()
      return vim.uv.fs_stat(root .. "/ready1") ~= nil and vim.uv.fs_stat(root .. "/ready2") ~= nil
    end, 5))
    runs[1]:cancel()
    owner:close()
    owner:close()
    assert.are.equal("cancelled", assert(wait(runs[1]).error).kind)
    assert.are.equal(137, wait(runs[2]).code)
    assert(vim.wait(3000, function() return owner:is_settled() end, 5))
    local late = vim.wait(900, function()
      return vim.uv.fs_stat(root .. "/late1") ~= nil or vim.uv.fs_stat(root .. "/late2") ~= nil
    end, 5)
    assert.is_false(late)
    local rejected = wait(async.run(function() return owner:run({ "sh", "-c", "true" }) end))
    assert.is_false(rejected.ok)
    assert.matches("Process scope is closed", assert(rejected.error).message, 1, true)
  end)

  it("contains a command tree when shutdown happens during platform startup", function()
    local owner = scope()
    local root = directory()
    local ready, late = root .. "/ready", root .. "/late"
    vim.system = function(argv, options, on_exit)
      local child = original_system(argv, options, on_exit)
      assert(vim.wait(3000, function() return vim.uv.fs_stat(ready) ~= nil end, 5))
      owner:close()
      return child
    end
    local run = async.run(function() return owner:run(command(ready, late)) end)
    vim.system = original_system
    local result = wait(run)
    assert.are.equal(137, result.code)
    assert(vim.wait(3000, function() return owner:is_settled() end, 5))
    assert.is_false((vim.wait(900, function() return vim.uv.fs_stat(late) ~= nil end, 5)))
  end)

  it("releases failed startup without preventing another command", function()
    local owner = scope()
    local root = directory()
    local failed = wait(async.run(function() return owner:run({ root .. "/missing-program" }) end))
    assert.is_false(failed.ok)
    assert.matches("Failed to start process", assert(failed.error).message, 1, true)
    assert.is_true(owner:is_settled())
    local recovered = wait(async.run(function() return owner:run({ "sh", "-c", "printf recovered" }) end))
    assert.are.equal(0, recovered.code)
    assert.are.equal("recovered", recovered.stdout)
  end)

  it("bounds cleanup waits and removes cancelled observers without abandoning the command", function()
    local owner = scope()
    local root = directory()
    local ready = root .. "/ready"
    local command_run = async.run(function()
      return owner:run({ "sh", "-c", "printf ready > " .. vim.fn.shellescape(ready) .. "; sleep 10" })
    end)
    assert(vim.wait(3000, function() return vim.uv.fs_stat(ready) ~= nil end, 5))
    local timed_out = wait(async.run(function() return owner:wait(10) end))
    assert.is_false(timed_out.ok)
    assert.are.equal("process_cleanup", assert(timed_out.error).kind)
    assert.is_false(owner:is_settled())
    assert.is_false(command_run:is_done())

    local cancelled = async.run(function() return owner:wait(3000) end)
    cancelled:cancel()
    assert.are.equal("cancelled", assert(wait(cancelled).error).kind)
    assert.is_false(owner:is_settled())
    local completed = async.run(function() return owner:wait(3000) end)
    owner:close()
    assert.is_true(wait(completed))
    assert.is_true(owner:is_settled())
    assert.are.equal(137, wait(command_run).code)
    assert.is_true(wait(async.run(function() return owner:wait(3000) end)))
  end)

  it("retains a child with failed supervision until its exit is observed", function()
    local owner = scope()
    local native = require("neoagent.process.posix")
    local original_new = native.new
    native.new = function()
      local tree = original_new()
      rawset(tree, "attach", function() return nil, "supervision refused" end)
      return tree
    end
    local run = async.run(function()
      return owner:run({ "sleep", "10" })
    end)
    native.new = original_new
    local result = assert(run:result())
    assert.is_false(result.ok)
    assert.matches("Failed to supervise", assert(result.error).message, 1, true)
    assert.is_false(owner:is_settled(), "the unreaped child was removed from its scope")
    owner:close()
    assert.is_true(wait(async.run(function() return owner:wait(3000) end)))
  end)
end)
