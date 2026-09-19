local assert = require("luassert")
local async = require("neoagent.async")
local util = require("neoagent.util")

local process_module = jit.os == "Windows" and "neoagent.process.windows" or "neoagent.process.posix"
local original_process_tree = package.loaded[process_module]
local original_lease = package.loaded["neoagent.rpc.worker_lease"]
local original_system = vim.system
local original_has = vim.fn.has

---@class Neoagent.TestSandboxTreeState
---@field attached? boolean
---@field closed integer
---@field signals integer[]
---@field terminate_result? boolean

---@class Neoagent.TestSandboxProcessState
---@field callbacks Neoagent.TestSandboxProcessCallbacks[]
---@field killed integer[]
---@field writes unknown[]

---@class Neoagent.TestSandboxProcessCallbacks
---@field opts vim.SystemOpts
---@field on_exit fun(result: vim.SystemCompleted)
---@field process Neoagent.TestSandboxSystem

---@class Neoagent.TestSandboxSystem
---@field pid integer
---@field write fun(self: Neoagent.TestSandboxSystem, value?: string)
---@field kill fun(self: Neoagent.TestSandboxSystem, signal: integer)

---@param configure? fun(tree: Neoagent.TestSandboxTreeState)
---@return table, Neoagent.TestSandboxTreeState[]
local function process_trees(configure)
  local states = {}
  local module = { detach = false }
  module.new = function()
    local state = { attached = true, closed = 0, signals = {} }
    if configure then
      configure(state)
    end
    states[#states + 1] = state
    local tree = {
      attach = function(_, _)
        return state.attached, state.attached and nil or "attach denied"
      end,
      terminate = function(_, signal)
        state.signals[#state.signals + 1] = signal
        return state.terminate_result == true
      end,
      close = function()
        state.closed = state.closed + 1
      end,
    }
    return tree
  end
  return module, states
end

---@param tree_module table
---@return table
local function load_child(tree_module)
  package.loaded[process_module] = tree_module
  package.loaded["neoagent.rpc.worker_lease"] = nil
  return require("neoagent.rpc.worker_lease")
end

---@return Neoagent.TestSandboxProcessState
local function fake_processes()
  ---@type Neoagent.TestSandboxProcessState
  local state = { callbacks = {}, killed = {}, writes = {} }
  vim.system = function(_, opts, on_exit)
    if not opts then error("missing process options") end
    if not on_exit then error("missing process exit callback") end
    local process = {
      pid = #state.callbacks + 100,
      write = function(_, value)
        state.writes[#state.writes + 1] = value == nil and false or value
      end,
      kill = function(_, signal)
        state.killed[#state.killed + 1] = signal
      end,
    }
    state.callbacks[#state.callbacks + 1] = { opts = opts, on_exit = on_exit, process = process }
    return process
  end
  return state
end

---@param callback (fun(err: string?, data: string?)|false)?
---@param err? string
---@param data? string
local function stream(callback, err, data)
  if type(callback) ~= "function" then
    error("expected stream callback")
  end
  callback(err, data)
end

---@param child_module table
---@param overrides? table
---@return Neoagent.WorkerLease
local function start(child_module, overrides)
  return child_module.start(vim.tbl_extend("force", {
    argv = { "worker" },
    cwd = "/workspace",
    env = { PATH = "/bin" },
    kill_grace_ms = 0,
  }, overrides or {}))
end

describe("neoagent worker process lease", function()
  after_each(function()
    vim.system = original_system
    vim.fn.has = original_has
    package.loaded[process_module] = original_process_tree
    package.loaded["neoagent.rpc.worker_lease"] = original_lease
  end)

  it("streams, waits, closes stdin, and terminates the complete process tree", function()
    local tree_module, trees = process_trees()
    local child_module = load_child(tree_module)
    local processes = fake_processes()
    local stdout, stderr, exits = {}, {}, {}
    local child = start(child_module, {
      on_stdout = function(data)
        stdout[#stdout + 1] = data
      end,
      on_stderr = function(data)
        stderr[#stderr + 1] = data
      end,
      on_exit = function(result)
        exits[#exits + 1] = result
      end,
    })
    local callbacks = processes.callbacks[1] or error("missing process callbacks")
    stream(callbacks.opts.stdout, nil, "out\0")
    stream(callbacks.opts.stderr, nil, "err")
    local wrote = child:write("input")
    assert.is_true(wrote)
    local closed = child:close_stdin()
    assert.is_true(closed)
    closed = child:close_stdin()
    assert.is_true(closed)
    local written, write_err = child:write("late")
    assert.is_nil(written)
    assert.matches("stdin is closed", assert(write_err).message)
    callbacks.on_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
    assert.are.same({ "out\0" }, stdout)
    assert.are.same({ "err" }, stderr)
    assert.are.equal("err", child:wait().stderr)
    assert.are.equal(1, #exits)
    child:dispose("test complete")
    child:dispose("test complete")

    local terminating = start(child_module)
    terminating:terminate("cancelled")
    local terminating_tree = trees[2] or error("missing terminating tree")
    assert(vim.wait(1000, function()
      return #terminating_tree.signals == 2
    end))
    assert.are.same({ 15, 9 }, terminating_tree.signals)
    assert.are.same({ 15, 9 }, processes.killed)
    assert(processes.callbacks[2]).on_exit({ code = 0, signal = 9, stdout = "", stderr = "" })
    terminating:dispose("test complete")

    local waiting = start(child_module)
    local run = async.run(function()
      return waiting:wait()
    end)
    run:cancel()
    local waiting_tree = trees[3] or error("missing waiting tree")
    assert(vim.wait(1000, function()
      return run:is_done()
    end))
    assert.are.same({}, waiting_tree.signals)
    waiting:dispose("test complete")
    assert.are.equal(15, waiting_tree.signals[1])
    assert(processes.callbacks[3]).on_exit({ code = 0, signal = 15, stdout = "", stderr = "" })

    local unsettled = start(child_module)
    unsettled:dispose("test complete")
    assert.are.equal(15, (trees[4] or error("missing unsettled tree")).signals[1])
    assert(processes.callbacks[4]).on_exit({ code = 0, signal = 15, stdout = "", stderr = "" })
  end)

  it("force-reaps an unresponsive disposed process lease once", function()
    local tree_module, trees = process_trees()
    local child_module = load_child(tree_module)
    local processes = fake_processes()
    local exits = 0
    local child = start(child_module, {
      reap_grace_ms = 0,
      on_exit = function() exits = exits + 1 end,
    })
    local waiting = async.run(function()
      return child:wait()
    end)

    child:dispose("test forced reaping")

    assert(vim.wait(1000, function() return waiting:is_done() end, 5))
    local result = assert(waiting:result())
    assert.are.equal("worker_exit", assert(result.error).kind)
    assert.are.same({ 15, 9 }, assert(trees[1]).signals)
    assert.are.same({ 15, 9 }, processes.killed)
    assert.are.equal(1, assert(trees[1]).closed)
    assert.are.equal(1, exits)
    child:dispose("ignored duplicate disposal")
    assert(processes.callbacks[1]).on_exit({ code = 0, signal = 9, stdout = "", stderr = "" })
    assert.are.equal(1, exits)
  end)

  it("contains stream, write, startup, supervision, and early-exit failures", function()
    local tree_module, trees = process_trees()
    local child_module = load_child(tree_module)
    local processes = fake_processes()

    local quiet = start(child_module)
    local quiet_callbacks = processes.callbacks[1] or error("missing quiet callbacks")
    stream(quiet_callbacks.opts.stdout, nil, "ignored")
    stream(quiet_callbacks.opts.stderr, nil, string.rep("e", 20000))
    stream(quiet_callbacks.opts.stdout, "read failed", nil)
    stream(quiet_callbacks.opts.stderr, "read failed", nil)
    assert.are.equal(15, (trees[1] or error("missing quiet tree")).signals[1])
    quiet_callbacks.on_exit({ code = 0, signal = 9, stdout = "", stderr = "" })
    assert.are.equal(137, quiet:wait().code)
    quiet_callbacks.on_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
    quiet:dispose("test complete")

    local failing_write = start(child_module)
    local write_callbacks = processes.callbacks[2] or error("missing write callbacks")
    write_callbacks.process.write = function()
      error("write exploded")
    end
    local written, write_err = failing_write:write("bytes")
    assert.is_nil(written)
    assert.matches("write exploded", tostring(assert(write_err).detail))
    local closed, close_err = failing_write:close_stdin()
    assert.is_nil(closed)
    assert.matches("write exploded", tostring(assert(close_err).detail))
    failing_write:dispose("test complete")
    assert(processes.callbacks[2]).on_exit({ code = 0, signal = 15, stdout = "", stderr = "" })

    local callback_child = start(child_module, {
      on_stdout = function()
        error("stdout consumer exploded")
      end,
    })
    local callback_callbacks = processes.callbacks[3] or error("missing callback callbacks")
    stream(callback_callbacks.opts.stdout, nil, "output")
    assert.are.equal(15, (trees[3] or error("missing callback tree")).signals[1])
    callback_child:dispose("test complete")
    callback_callbacks.on_exit({ code = 0, signal = 15, stdout = "", stderr = "" })

    vim.system = function(_, opts, on_exit)
      stream(opts and opts.stdout, nil, "early")
      if not on_exit then error("missing exit callback") end
      on_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
      return {
        pid = 500,
        write = function() end,
        kill = function() end,
      }
    end
    local early = start(child_module, {
      on_stdout = function()
        error("early callback exploded")
      end,
    })
    assert.are.equal(0, early:wait().code)
    early:dispose("test complete")

    vim.system = function()
      error("spawn exploded")
    end
    local spawned, spawn_err = pcall(start, child_module)
    assert.is_false(spawned)
    local spawn_failure = util.normalize_error(spawn_err)
    assert.are.equal("worker_start", spawn_failure.kind)
    assert.matches("spawn exploded", tostring(spawn_failure.detail))

    local unattached_module = process_trees(function(tree)
      tree.attached = false
    end)
    child_module = load_child(unattached_module)
    processes = fake_processes()
    local attached, attach_err = pcall(start, child_module)
    assert.is_false(attached)
    assert.matches("Could not supervise", util.normalize_error(attach_err).message)
    assert.are.same({ 9 }, processes.killed)

    local missing_tree = { detach = false, new = function()
      return nil, "tree unavailable"
    end }
    child_module = load_child(missing_tree)
    local supervised, supervise_err = pcall(start, child_module)
    assert.is_false(supervised)
    assert.matches("process supervisor", util.normalize_error(supervise_err).message)
  end)

  it("encodes environments for each supported Neovim generation", function()
    local tree_module = process_trees()
    local child_module = load_child(tree_module)
    local processes = fake_processes()
    local supports_map = true
    vim.fn.has = function(feature)
      if feature == "nvim-0.12" then
        return supports_map and 1 or 0
      end
      return original_has(feature)
    end
    local current = start(child_module, { env = { Z = "last", A = "first" } })
    local current_callbacks = processes.callbacks[1] or error("missing current environment callbacks")
    assert.are.same({ Z = "last", A = "first" }, current_callbacks.opts.env)

    supports_map = false
    local legacy = start(child_module, { env = { Z = "last", A = "first" } })
    local legacy_callbacks = processes.callbacks[2] or error("missing legacy environment callbacks")
    assert.are.same({ "A=first", "Z=last" }, legacy_callbacks.opts.env)

    current:dispose("test complete")
    current_callbacks.on_exit({ code = 0, signal = 15, stdout = "", stderr = "" })
    legacy:dispose("test complete")
    legacy_callbacks.on_exit({ code = 0, signal = 15, stdout = "", stderr = "" })
  end)
end)
