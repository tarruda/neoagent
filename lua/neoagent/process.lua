local async = require("neoagent.async")
local util = require("neoagent.util")

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
  local stdout, stderr, output = "", "", ""
  local capture = opts.capture ~= false
  local timed_out = false
  local result = async.await(function(done)
    local process
    local timer
    local kill_timer
    local timer_closed = false
    local kill_timer_closed = false
    local accepting_output = true
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
    local function terminate()
      if not process then return end
      pcall(process.kill, process, 15)
      if opts.kill_grace_ms == 0 then
        pcall(process.kill, process, 9)
        return
      end
      if not kill_timer then
        kill_timer = vim.uv.new_timer()
        kill_timer:start(opts.kill_grace_ms or 1000, 0, function()
          close_kill_timer()
          if process then pcall(process.kill, process, 9) end
        end)
      end
    end
    process = vim.system(command, {
      cwd = opts.cwd,
      env = spawn_environment(opts.env, opts.clear_env),
      clear_env = opts.clear_env,
      stdin = opts.stdin,
      text = false,
      stdout = function(err, data)
        if err then
          done.reject(util.error("tool", "Failed reading process stdout", err))
        elseif data and accepting_output then
          if capture then
            stdout = stdout .. data
            output = output .. data
          end
          if opts.on_output then
            opts.on_output(data, false, stdout, stderr, output)
          end
        end
      end,
      stderr = function(err, data)
        if err then
          done.reject(util.error("tool", "Failed reading process stderr", err))
        elseif data and accepting_output then
          if capture then
            stderr = stderr .. data
            output = output .. data
          end
          if opts.on_output then
            opts.on_output(data, true, stdout, stderr, output)
          end
        end
      end,
    }, function(completed)
      close_timer()
      close_kill_timer()
      done.resolve({
        code = completed.signal ~= 0 and 128 + completed.signal or completed.code,
        signal = completed.signal,
        stdout = stdout,
        stderr = stderr,
        output = output,
        timed_out = timed_out,
      })
    end)
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
