local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}

function M.workspace(ctx)
  local context = ctx and ctx.context
  local workspace = context and context.workspace or context
  if type(workspace) ~= "table" or type(workspace.resolve) ~= "function" then
    error(util.error("workspace", "Tool requires a workspace in ctx.context.workspace"), 0)
  end
  return workspace
end

function M.require_string(arguments, key, allow_empty)
  local value = arguments[key]
  if type(value) ~= "string" or not allow_empty and value == "" then
    error(util.error("tool", key .. " must be " .. (allow_empty and "a string" or "a non-empty string")), 0)
  end
  return value
end

function M.process(command, opts)
  opts = opts or {}
  local stdout, stderr, output = "", "", ""
  local timed_out = false
  local result = async.await(function(done)
    local process
    local timer
    local timer_closed = false
    local function close_timer()
      if timer and not timer_closed then
        timer_closed = true
        timer:stop()
        timer:close()
      end
    end
    process = vim.system(command, {
      cwd = opts.cwd,
      env = opts.env,
      stdin = opts.stdin,
      text = false,
      stdout = function(err, data)
        if err then
          done.reject(util.error("tool", "Failed reading process stdout", err))
        elseif data then
          stdout = stdout .. data
          output = output .. data
          if opts.on_output then
            opts.on_output(data, false, stdout, stderr, output)
          end
        end
      end,
      stderr = function(err, data)
        if err then
          done.reject(util.error("tool", "Failed reading process stderr", err))
        elseif data then
          stderr = stderr .. data
          output = output .. data
          if opts.on_output then
            opts.on_output(data, true, stdout, stderr, output)
          end
        end
      end,
    }, function(completed)
      close_timer()
      done.resolve({ code = completed.code, signal = completed.signal, stdout = stdout, stderr = stderr, output = output, timed_out = timed_out })
    end)
    if opts.timeout_ms then
      timer = vim.uv.new_timer()
      timer:start(opts.timeout_ms, 0, function()
        timed_out = true
        if process then
          pcall(process.kill, process, 15)
        end
      end)
    end
    return function()
      close_timer()
      if process then
        pcall(process.kill, process, 15)
      end
    end
  end)
  return result
end

return M
