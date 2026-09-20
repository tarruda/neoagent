local profile_compiler = require("neoagent.sandbox.macos.profile")
local access_policy = require("neoagent.sandbox.policy")
local util = require("neoagent.util")
local nvim_launch = require("neoagent.process.nvim")

local M = { name = "macos" }
local SUPERVISOR_GRACE_MS = 100
local SANDBOX_EXEC = "/usr/bin/sandbox-exec"

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

---@param nvim string[]
---@param runtime string
---@return string[]
local function runtime_argv(nvim, runtime)
  local argv = util.copy(nvim)
  vim.list_extend(argv, {
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-n",
    "-l",
    runtime,
  })
  return argv
end

---@param specification table
---@return table<string, string>
local function runtime_environment(specification)
  return { NEOAGENT_MACOS_SANDBOX_SPEC = util.json_encode(specification) }
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

---@param services? Neoagent.SandboxCheckServices
---@return Neoagent.SandboxStatus
function M.check(services)
  services = services or {}
  local configured_sandbox_exec = services.sandbox_exec or SANDBOX_EXEC
  local sandbox_exec = executable(configured_sandbox_exec)
  local configured_nvim = services.nvim
  local valid_nvim = configured_nvim == nil
    or type(configured_nvim) == "string" and configured_nvim ~= ""
    or type(configured_nvim) == "table" and util.is_list(configured_nvim) and #configured_nvim > 0
  local nvim = valid_nvim and nvim_launch.command(configured_nvim) or {}
  local nvim_program = executable(nvim[1])
  if not sandbox_exec then
    return {
      ok = false,
      platform = M.name,
      stage = "sandbox-exec",
      message = configured_sandbox_exec .. " is missing or not executable",
    }
  end
  if not nvim_program then
    return {
      ok = false,
      platform = M.name,
      stage = "nvim",
      message = "current Neovim executable cannot be resolved",
    }
  end
  local runtime = sandbox_runtime()
  if not runtime then
    return {
      ok = false,
      platform = M.name,
      stage = "runtime",
      message = "macOS sandbox runtime was not found",
    }
  end
  local supervisor = (services.system or system)(runtime_argv(nvim, runtime), {
    env = runtime_environment({ mode = "probe" }),
    clear_env = true,
    text = true,
  }, services.probe_timeout_ms or 5000)
  if not supervisor or supervisor.code ~= 0 then
    return {
      ok = false,
      platform = M.name,
      stage = "runtime-probe",
      message = bounded(supervisor and supervisor.stderr or "guardian probe failed"),
    }
  end
  local policy, parameters = profile_compiler.compile({
    filesystem = { default = "read", entries = {} },
    network = "restricted",
  }, { { path = nvim_program, access = "read" } })
  local argv = profile_compiler.argv(sandbox_exec, policy, parameters)
  vim.list_extend(argv, nvim)
  vim.list_extend(argv, {
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

---@param request Neoagent.SandboxWorkerRequest
---@param services Neoagent.SandboxExecutionServices<string|string[]>
---@return Neoagent.WorkerLease
function M.start_worker(request, services)
  local runtime = sandbox_runtime()
  if not runtime then
    error(util.error("sandbox_unavailable", "macOS sandbox runtime was not found"), 0)
  end
  local nvim = nvim_launch.command(services.nvim)
  local nvim_program = assert(nvim[1])
  local internal = { nvim_program, runtime, "/bin/sh" }
  vim.list_extend(internal, request.bootstrap_paths or {})
  access_policy.require_read(request.profile, internal, nil, "bootstrap")
  ---@type Neoagent.SandboxFilesystemEntry[]
  local internal_entries = {}
  for _, path in ipairs(internal) do
    internal_entries[#internal_entries + 1] = { path = path, access = "read" }
  end
  local policy, parameters = profile_compiler.compile(request.profile, internal_entries)
  local random = assert(vim.uv.random(16))
  local scope = "neoagent.sandbox."
    .. (random:gsub(".", function(byte)
      return string.format("%02x", byte:byte())
    end))
  policy = policy .. '\n(allow mach-lookup (global-name "' .. scope .. '"))'
  local worker_argv =
    profile_compiler.argv(executable(services.sandbox_exec or SANDBOX_EXEC) or SANDBOX_EXEC, policy, parameters)
  vim.list_extend(worker_argv, {
    "/bin/sh",
    "-c",
    'printf "ready\\n" >&3; exec 3>&-; exec "$@"',
    "neoagent-worker",
  })
  vim.list_extend(worker_argv, request.argv)
  local argv = runtime_argv(nvim, runtime)
  local relay = require("neoagent.sandbox.relay_lease").new({
    framed_input = true,
    on_failure = request.on_failure,
    on_stdout = request.on_stdout,
    on_stderr = request.on_stderr,
    on_exit = request.on_exit,
    cleanup = function(result)
      if result.code == 0 and not result.error then
        return true
      end
      local recovered = require("neoagent.process").run(argv, {
        env = runtime_environment({ mode = "cleanup", scope = scope }),
        clear_env = true,
        timeout_ms = 10000,
        max_capture_bytes = 16 * 1024,
      })
      if recovered.code ~= 0 then
        return nil, "macOS sandbox cleanup did not complete"
      end
      return true
    end,
  })
  local start = services.start_worker or require("neoagent.rpc.worker_lease").start
  local started, child = pcall(start, {
    argv = argv,
    cwd = request.cwd,
    env = runtime_environment({ mode = "run", scope = scope, argv = worker_argv, cwd = request.cwd, env = request.env }),
    clear_env = true,
    kill_grace_ms = math.max(request.kill_grace_ms or 0, SUPERVISOR_GRACE_MS),
    on_stdout = function(data)
      relay:feed(data)
    end,
    on_exit = function(result)
      relay:host_exited(result)
    end,
  })
  if not started then
    error(util.error("sandbox_unavailable", "Could not start macOS sandbox runtime", child), 0)
  end
  relay:attach(child)
  return relay
end

return M
