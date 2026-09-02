local profile_compiler = require("neoagent.sandbox.macos.profile")
local util = require("neoagent.util")

local M = { name = "macos" }
local FS_TIMEOUT_MS = 30000
local SUPERVISOR_GRACE_MS = 100
local SANDBOX_EXEC = "/usr/bin/sandbox-exec"
local CLEANUP_HELPERS = { "/bin/sh" }

local function bounded(value)
  value = util.trim(tostring(value or ""):gsub("[%z\1-\31\127]", " "))
  if #value > 1000 then value = value:sub(1, 997) .. "..." end
  return value
end

local function runtime_file(path)
  local matches = vim.api.nvim_get_runtime_file(path, false)
  return matches[1] and vim.uv.fs_realpath(matches[1]) or matches[1]
end

local function executable(path)
  if type(path) ~= "string" or path == "" then return nil end
  local candidate = path
  if not path:find("/", 1, true) then
    candidate = vim.fn.exepath(path)
  end
  local resolved = candidate ~= "" and vim.uv.fs_realpath(candidate) or nil
  local stat = resolved and vim.uv.fs_stat(resolved)
  if stat and stat.type == "file" and vim.fn.executable(resolved) == 1 then
    return vim.fs.normalize(resolved)
  end
end

local function regular_file(path)
  local stat = path and vim.uv.fs_stat(path)
  return stat and stat.type == "file"
end

local function sandbox_runtime()
  local path = runtime_file("scripts/sandbox_macos_runtime.lua")
  return regular_file(path) and path or nil
end

local function runtime_argv(nvim, runtime, command)
  local argv = {
    nvim, "--headless", "-u", "NONE", "-i", "NONE", "-n",
    "-l", runtime, "--",
  }
  vim.list_extend(argv, command)
  return argv
end

local function system(argv, opts, timeout)
  local completed = vim.system(argv, opts):wait(timeout)
  return completed or {
    code = 124,
    signal = 15,
    stdout = "",
    stderr = "probe timed out",
  }
end

function M.check(services)
  services = services or {}
  local configured_sandbox_exec = services.sandbox_exec or SANDBOX_EXEC
  local sandbox_exec = executable(configured_sandbox_exec)
  local nvim = executable(services.nvim or vim.v.progpath)
  if not sandbox_exec then
    return {
      ok = false,
      platform = M.name,
      stage = "sandbox-exec",
      message = configured_sandbox_exec .. " is missing or not executable",
    }
  end
  if not nvim then
    return {
      ok = false,
      platform = M.name,
      stage = "nvim",
      message = "current Neovim executable cannot be resolved",
    }
  end
  if not sandbox_runtime() then
    return {
      ok = false,
      platform = M.name,
      stage = "runtime",
      message = "macOS sandbox runtime was not found",
    }
  end
  local policy, parameters = profile_compiler.compile({
    filesystem = { default = "read", entries = {} },
    network = "restricted",
  }, { { path = nvim, access = "read" } })
  local argv = profile_compiler.argv(sandbox_exec, policy, parameters)
  vim.list_extend(argv, {
    nvim, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-c", "qa",
  })
  local completed = (services.system or system)(
    argv, { text = true }, services.probe_timeout_ms or 5000)
  if not completed or completed.code ~= 0 then
    return {
      ok = false,
      platform = M.name,
      stage = "sandbox-exec-probe",
      message = bounded(completed and completed.stderr or "probe failed"),
    }
  end
  return {
    ok = true,
    platform = M.name,
    degraded = false,
    capabilities = {
      filesystem = true,
      network = true,
      process = true,
      process_supervision = true,
      shared_tmp = true,
      seatbelt = true,
    },
  }
end

local function execute(request, services, protected)
  local configured = services.sandbox_exec or SANDBOX_EXEC
  local sandbox_exec = executable(configured) or configured
  local internal = {}
  for _, path in ipairs(protected or {}) do
    internal[#internal + 1] = { path = path, access = "read" }
  end
  local policy, parameters =
    profile_compiler.compile(request.profile, internal)
  local argv = profile_compiler.argv(sandbox_exec, policy, parameters)
  for _, argument in ipairs(request.argv) do
    argv[#argv + 1] = argument
  end
  local ok, value = pcall(services.process, argv, {
    cwd = request.cwd,
    env = util.copy(request.env or {}),
    clear_env = true,
    stdin = request.stdin,
    capture = request.capture,
    timeout_ms = request.timeout_ms,
    kill_grace_ms = request.kill_grace_ms,
    on_output = request.on_output,
  })
  if not ok then
    local process_err = util.normalize_error(
      value, "sandbox_unavailable")
    if process_err.kind == "cancelled" then error(value, 0) end
    error(util.error("sandbox_unavailable",
      "macOS sandbox process failed to start",
      bounded(process_err.message)), 0)
  end
  if type(value) ~= "table" or type(value.code) ~= "number"
      or type(value.signal) ~= "number" then
    error(util.error("sandbox_unavailable",
      "macOS sandbox returned an invalid process result"), 0)
  end
  return value
end

function M.exec(request, services)
  local runtime = sandbox_runtime()
  if not runtime then
    error(util.error("sandbox_unavailable",
      "macOS sandbox runtime was not found"), 0)
  end
  local configured = services.nvim or vim.v.progpath
  local nvim = executable(configured) or configured
  local wrapped = util.copy(request)
  wrapped.argv = runtime_argv(nvim, runtime, request.argv)
  wrapped.env = util.copy(request.env or {})
  wrapped.env.NEOAGENT_SANDBOX_EXEC = "1"
  if wrapped.kill_grace_ms ~= nil
      and wrapped.kill_grace_ms < SUPERVISOR_GRACE_MS then
    wrapped.kill_grace_ms = SUPERVISOR_GRACE_MS
  end
  local protected = { nvim, runtime }
  vim.list_extend(protected, CLEANUP_HELPERS)
  return execute(wrapped, services, protected)
end

function M.fs(request, services)
  local runtime = sandbox_runtime()
  if not runtime then
    error(util.error("sandbox_unavailable",
      "macOS sandbox runtime was not found"), 0)
  end
  local env = util.copy(request.profile.environment.set)
  env.NEOAGENT_SANDBOX_FS = util.json_encode({
    operation = request.operation,
    path = request.path,
    flags = request.flags,
    mode = request.mode,
    policy = request.policy,
    suffix = request.suffix,
  })
  local configured = services.nvim or vim.v.progpath
  local nvim = executable(configured) or configured
  local process_request = {
    argv = {
      nvim, "--headless", "-u", "NONE", "-i", "NONE", "-n",
      "-l", runtime,
    },
    cwd = "/",
    env = env,
    clear_env = true,
    stdin = request.data,
    capture = true,
    timeout_ms = request.timeout_ms or FS_TIMEOUT_MS,
    profile = request.profile,
  }
  local value = execute(process_request, services, { nvim, runtime })
  if value.code ~= 0 then
    return nil, bounded(value.stderr) ~= "" and bounded(value.stderr)
      or "sandbox filesystem operation failed"
  end
  if request.operation == "read" then return value.stdout end
  return true
end

return M
