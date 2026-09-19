local profile_compiler = require("neoagent.sandbox.macos.profile")
local access_policy = require("neoagent.sandbox.policy")
local util = require("neoagent.util")
local nvim_launch = require("neoagent.process.nvim")

local M = { name = "macos" }
local SUPERVISOR_GRACE_MS = 100
local SANDBOX_EXEC = "/usr/bin/sandbox-exec"
local CLEANUP_HELPERS = { "/bin/sh" }

---@param value unknown
---@return string
local function bounded(value)
  value = util.trim(tostring(value or ""):gsub("[%z\1-\31\127]", " "))
  if #value > 1000 then
    value = value:sub(1, 997) .. "..."
  end
  return value
end

---@param path string
---@return string?
local function runtime_file(path)
  local matches = vim.api.nvim_get_runtime_file(path, false)
  return matches[1] and vim.uv.fs_realpath(matches[1]) or matches[1]
end

---@param path unknown
---@return string?
local function executable(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local candidate = path
  if not path:find("/", 1, true) then
    candidate = vim.fn.exepath(path)
  end
  local resolved = candidate ~= "" and vim.uv.fs_realpath(candidate) or nil
  local stat = resolved and vim.uv.fs_stat(resolved)
  if resolved and stat and stat.type == "file" and vim.fn.executable(resolved) == 1 then
    return vim.fs.normalize(resolved)
  end
end

---@param path string?
---@return boolean?
local function regular_file(path)
  local stat = path and vim.uv.fs_stat(path)
  return stat and stat.type == "file"
end

---@return string?
local function sandbox_runtime()
  local path = runtime_file("scripts/sandbox_macos_runtime.lua")
  return regular_file(path) and path or nil
end

---@param nvim string
---@param runtime string
---@param command string[]
---@return string[]
local function runtime_argv(nvim, runtime, command)
  local argv = {
    nvim,
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-n",
    "-l",
    runtime,
    "--",
  }
  vim.list_extend(argv, command)
  return argv
end

---@param argv string[]
---@param opts vim.SystemOpts
---@param timeout integer
---@return vim.SystemCompleted
local function system(argv, opts, timeout)
  local completed = vim.system(argv, opts):wait(timeout)
  return completed or {
    code = 124,
    signal = 15,
    stdout = "",
    stderr = "probe timed out",
  }
end

---@param services? Neoagent.SandboxCheckServices<string>
---@return Neoagent.SandboxStatus
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
    nvim,
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-n",
    "-c",
    "qa",
  })
  local completed = (services.system or system)(argv, { text = true }, services.probe_timeout_ms or 5000)
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

---@param request Neoagent.SandboxProcessRequest
---@param services Neoagent.SandboxServices<string>
---@param protected? string[]
---@return Neoagent.ProcessResult
local function execute(request, services, protected)
  local configured = services.sandbox_exec or SANDBOX_EXEC
  local sandbox_exec = executable(configured) or configured
  access_policy.require_read(request.profile, protected or {}, nil, "runtime")
  ---@type Neoagent.SandboxFilesystemEntry[]
  local internal = {}
  for _, path in ipairs(protected or {}) do
    internal[#internal + 1] = { path = path, access = "read" }
  end
  local policy, parameters = profile_compiler.compile(request.profile, internal)
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
    max_capture_bytes = request.max_capture_bytes,
    on_output = request.on_output,
  })
  if not ok then
    local process_err = util.normalize_error(value, "sandbox_unavailable")
    if process_err.kind == "cancelled" then
      error(value, 0)
    end
    error(util.error("sandbox_unavailable", "macOS sandbox process failed to start", bounded(process_err.message)), 0)
  end
  if type(value) ~= "table" or type(value.code) ~= "number" or type(value.signal) ~= "number" then
    error(util.error("sandbox_unavailable", "macOS sandbox returned an invalid process result"), 0)
  end
  return value
end

---@param request Neoagent.SandboxProcessRequest
---@param services Neoagent.SandboxServices<string>
---@return Neoagent.ProcessResult
function M.exec(request, services)
  local runtime = sandbox_runtime()
  if not runtime then
    error(util.error("sandbox_unavailable", "macOS sandbox runtime was not found"), 0)
  end
  local nvim = assert(nvim_launch.command(services.nvim or vim.v.progpath)[1])
  local wrapped = util.copy(request)
  wrapped.argv = runtime_argv(nvim, runtime, request.argv)
  wrapped.env = util.copy(request.env or {})
  wrapped.env.NEOAGENT_SANDBOX_EXEC = "1"
  if wrapped.kill_grace_ms ~= nil and wrapped.kill_grace_ms < SUPERVISOR_GRACE_MS then
    wrapped.kill_grace_ms = SUPERVISOR_GRACE_MS
  end
  local protected = { nvim, runtime }
  vim.list_extend(protected, CLEANUP_HELPERS)
  return execute(wrapped, services, protected)
end

---@param request Neoagent.SandboxWorkerRequest
---@param services Neoagent.SandboxExecutionServices<string>
---@return Neoagent.WorkerLease
function M.start_worker(request, services)
  local runtime = sandbox_runtime()
  if not runtime then
    error(util.error("sandbox_unavailable", "macOS sandbox runtime was not found"), 0)
  end
  local nvim = assert(nvim_launch.command(services.nvim or vim.v.progpath)[1])
  local internal = { nvim, runtime }
  vim.list_extend(internal, CLEANUP_HELPERS)
  vim.list_extend(internal, request.bootstrap_paths or {})
  access_policy.require_read(request.profile, internal, nil, "bootstrap")
  ---@type Neoagent.SandboxFilesystemEntry[]
  local internal_entries = {}
  for _, path in ipairs(internal) do
    internal_entries[#internal_entries + 1] = { path = path, access = "read" }
  end
  local policy, parameters = profile_compiler.compile(request.profile, internal_entries)
  local argv = profile_compiler.argv(executable(services.sandbox_exec or SANDBOX_EXEC) or SANDBOX_EXEC, policy, parameters)
  vim.list_extend(argv, runtime_argv(nvim, runtime, request.argv))
  local env = util.copy(request.env)
  env.NEOAGENT_SANDBOX_EXEC = "1"
  env.NEOAGENT_SANDBOX_STREAM = "1"
  local start = services.start_worker or require("neoagent.rpc.worker_lease").start
  local started, child = pcall(start, {
    argv = argv,
    cwd = request.cwd,
    env = env,
    clear_env = true,
    kill_grace_ms = math.max(request.kill_grace_ms or 0, SUPERVISOR_GRACE_MS),
    on_stdout = request.on_stdout,
    on_stderr = request.on_stderr,
    on_exit = request.on_exit,
  })
  if not started then
    error(util.error("sandbox_unavailable", "Could not start macOS sandbox runtime", child), 0)
  end
  return child
end

return M
