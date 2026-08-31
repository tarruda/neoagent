local platform_dispatch = require("neoagent.sandbox.platform")
local profile_module = require("neoagent.sandbox.profile")
local path_module = require("neoagent.sandbox.path")
local util = require("neoagent.util")

local M = {}

local function services(opts)
  return {
    fs = opts.fs or require("neoagent.fs"),
    process = opts.process or require("neoagent.process").run,
    nvim = opts.nvim,
    system = opts.system,
    sandbox_exec = opts.sandbox_exec,
    probe_timeout_ms = opts.probe_timeout_ms,
    capabilities = util.copy(opts.capabilities or {}),
  }
end

function M.sandbox_exec(argv, opts)
  opts = opts or {}
  assert(type(argv) == "table" and util.is_list(argv) and #argv > 0,
    "sandbox argv must be a non-empty list")
  local selected, status = platform_dispatch.select(opts.os, opts.platforms)
  if not selected then error(platform_dispatch.status_error(status), 0) end
  local active_services = services(opts)
  if opts.capabilities == nil then
    local checked, value = pcall(selected.check, active_services)
    status = checked and value or {
      ok = false,
      platform = selected.name,
      stage = "requirements",
      message = util.normalize_error(value, "sandbox_unavailable").message,
    }
    if type(status) ~= "table" or not status.ok then
      error(platform_dispatch.status_error(status), 0)
    end
    active_services.capabilities = util.copy(status.capabilities or {})
  end
  local paths = opts.paths or selected.paths or path_module.posix
  local profile = profile_module.resolve(
    opts.profile, opts.ctx, { paths = paths })
  if type(selected.compile) == "function" then
    profile = selected.compile(profile, opts.ctx, active_services)
  end
  local request = util.copy(opts)
  request.profile = profile
  request.argv = vim.list_slice(argv)
  return selected.exec(request, active_services)
end

function M.new(opts)
  return require("neoagent.sandbox.enforce").new(opts)
end

function M.info(agent)
  local configured = agent
  if type(agent) == "table" and type(agent.config) == "function" then
    configured = agent:config()
  end
  configured = type(configured) == "table" and configured or {}
  local enabled = configured.sandbox
    and configured.sandbox.enabled == true or false
  local recorded = util.copy(configured._sandbox_status or {})
  recorded.enabled = enabled
  if not enabled then recorded.active = false end
  return recorded
end

function M.format_info(status)
  status = status or {}
  local lines = {
    "Neoagent sandbox",
    "enabled: " .. (status.enabled and "yes" or "no"),
    "active: " .. (status.active and "yes" or "no"),
  }
  if status.platform then
    lines[#lines + 1] = "platform: " .. tostring(status.platform)
  end
  if status.enabled and status.active then
    lines[#lines + 1] =
      "isolation: " .. (status.degraded and "degraded" or "full")
    if status.degraded_reason then
      lines[#lines + 1] =
        "reason: " .. tostring(status.degraded_reason)
    end
    local capabilities = status.capabilities or {}
    local names = vim.tbl_keys(capabilities)
    table.sort(names)
    for _, name in ipairs(names) do
      local value = capabilities[name]
      if type(value) == "boolean" then value = value and "yes" or "no" end
      lines[#lines + 1] =
        "capability." .. name .. ": " .. tostring(value)
    end
  elseif status.enabled then
    if status.stage then
      lines[#lines + 1] = "stage: " .. tostring(status.stage)
    end
    if status.message then
      lines[#lines + 1] = "reason: " .. tostring(status.message)
    end
  end
  return table.concat(lines, "\n")
end

return M
