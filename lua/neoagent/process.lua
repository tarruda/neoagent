local async = require("neoagent.async")
local util = require("neoagent.util")
local process_tree = require(jit.os == "Windows"
  and "neoagent.process.windows" or "neoagent.process.posix")

local M = {}

local function spawn_environment(env, clear)
  if clear and env ~= nil and vim.fn.has("nvim-0.12") == 0
      and not vim.islist(env) then
    return vim.tbl_map(function(name)
      return name .. "=" .. tostring(env[name])
    end, vim.tbl_keys(env))
  end
  return env
end

function M.run(command, opts)
  opts = opts or {}
  if opts.max_capture_bytes ~= nil then
    assert(type(opts.max_capture_bytes) == "number"
      and opts.max_capture_bytes > 0
      and opts.max_capture_bytes % 1 == 0,
    "max_capture_bytes must be a positive integer")
  end
  local stdout, stderr, output = "", "", ""
  local capture = opts.capture ~= false
  local captured_bytes = 0
  local timed_out = false
  local result = async.await(function(done)
    local process
    local tree
    local timer
    local kill_timer
    local timer_closed = false
    local kill_timer_closed = false
    local accepting_output = true
    local termination_requested = false
    local function close_timer()
      if timer and not timer_closed then
        timer_closed = true
        timer:stop()
        timer:close()
      end
    end
    local function close_kill_timer()
      if kill_timer and not kill_timer_closed then
        kill_timer_closed = true
        kill_timer:stop()
        kill_timer:close()
      end
    end
    local function signal(value)
      local signalled = tree and tree:terminate(value)
      if not signalled and process then pcall(process.kill, process, value) end
    end
    local function terminate()
      termination_requested = true
      if not process then return end
      signal(15)
      if opts.kill_grace_ms == 0 then
        signal(9)
        return
      end
      if not kill_timer then
        kill_timer = vim.uv.new_timer()
        kill_timer:start(opts.kill_grace_ms or 1000, 0, function()
          close_kill_timer()
          signal(9)
        end)
      end
    end
    local function retain(data, is_stderr)
      if not capture then return true end
      local next_bytes = captured_bytes + #data
      if opts.max_capture_bytes and next_bytes > opts.max_capture_bytes then
        accepting_output = false
        done.reject(util.error("tool", "Process output exceeded "
          .. opts.max_capture_bytes .. " bytes"))
        terminate()
        return nil
      end
      captured_bytes = next_bytes
      if is_stderr then stderr = stderr .. data else stdout = stdout .. data end
      output = output .. data
      return true
    end
    local tree_err
    tree, tree_err = process_tree.new()
    if not tree then
      done.reject(util.error("tool", "Failed to create process supervisor", tree_err))
      return
    end
    local started, started_process = pcall(vim.system, command, {
      cwd = opts.cwd,
      env = spawn_environment(opts.env, opts.clear_env),
      clear_env = opts.clear_env,
      stdin = opts.stdin,
      text = false,
      detach = process_tree.detach,
      stdout = function(err, data)
        if err then
          accepting_output = false
          done.reject(util.error("tool", "Failed reading process stdout", err))
          terminate()
        elseif data and accepting_output then
          if not retain(data, false) then return end
          if opts.on_output then
            opts.on_output(data, false, stdout, stderr, output)
          end
        end
      end,
      stderr = function(err, data)
        if err then
          accepting_output = false
          done.reject(util.error("tool", "Failed reading process stderr", err))
          terminate()
        elseif data and accepting_output then
          if not retain(data, true) then return end
          if opts.on_output then
            opts.on_output(data, true, stdout, stderr, output)
          end
        end
      end,
    }, function(completed)
      close_timer()
      close_kill_timer()
      if tree then tree:close(true) end
      done.resolve({
        code = completed.signal ~= 0 and 128 + completed.signal or completed.code,
        signal = completed.signal,
        stdout = stdout,
        stderr = stderr,
        output = output,
        timed_out = timed_out,
      })
    end)
    if not started then
      tree:close(true)
      done.reject(util.error("tool", "Failed to start process", started_process))
      return
    end
    process = started_process
    local attached, attach_err = tree:attach(process.pid)
    if not attached then
      pcall(process.kill, process, 9)
      tree:close(true)
      done.reject(util.error("tool", "Failed to supervise process tree", attach_err))
      return
    end
    if termination_requested then terminate() end
    if opts.timeout_ms then
      timer = vim.uv.new_timer()
      timer:start(opts.timeout_ms, 0, function()
        timed_out = true
        terminate()
      end)
    end
    return function()
      accepting_output = false
      close_timer()
      terminate()
    end
  end)
  return result
end

return M
