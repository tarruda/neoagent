local fs = require("neoagent.fs")
local process = require("neoagent.process")
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

function M.fs(ctx)
  return ctx and ctx.fs or fs
end

function M.process(ctx, command, opts)
  local run = ctx and ctx.process or process.run
  return run(command, opts)
end

return M
