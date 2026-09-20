local protocol = require("neoagent.sandbox.protocol")
local util = require("neoagent.util")
local nvim_command = require("neoagent.process.nvim").command

---@class Neoagent.LinuxSandboxRoot
---@field path string
---@field stat uv.fs_stat.result

---@alias Neoagent.LinuxSandboxMode 'exec'|'probe'

---@class Neoagent.LinuxSandboxRequest
---@field argv? string[]
---@field cwd string
---@field env table<string, string>
---@field profile Neoagent.SandboxProfile

---@class Neoagent.LinuxSandboxSpec
---@field v 1
---@field mode Neoagent.LinuxSandboxMode
---@field root string
---@field root_identity {dev: integer, ino: integer}
---@field profile Neoagent.SandboxProfile
---@field cwd string
---@field env table<string, string>
---@field procfs 'fresh'|'host'
---@field protected_create Neoagent.SandboxFilesystemEntry[]

local M = { name = "linux" }
local STAGING_DIRECTORIES = vim.uv.os_uname().sysname == "Linux"
    and {
      "/run/user/" .. tostring(vim.uv.getuid()),
      "/dev/shm",
    }
  or { vim.uv.os_tmpdir() }
local PROCFS_STAGES = {
  ["unmount-proc"] = true,
  ["mount-proc"] = true,
  ["mask-proc"] = true,
}

---@param value unknown
---@return string
local function bounded(value)
  value = util.trim(tostring(value or ""):gsub("[%z\1-\31\127]", " "))
  if #value > 1000 then
    value = value:sub(1, 997) .. "..."
  end
  return value
end

---@return string?
local function runtime_file()
  local matches = vim.api.nvim_get_runtime_file("scripts/sandbox_linux_runtime.lua", false)
  local path = matches[1]
  path = path and (vim.uv.fs_realpath(path) or vim.fs.normalize(path)) or nil
  local stat = path and vim.uv.fs_stat(path)
  return stat and stat.type == "file" and path or nil
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

---@param left? {sec: integer, nsec: integer}
---@param right? {sec: integer, nsec: integer}
---@return boolean?
local function same_time(left, right)
  return left and right and left.sec == right.sec and left.nsec == right.nsec
end

---@param left? uv.fs_stat.result
---@param right? uv.fs_stat.result
---@return boolean?
local function same_identity(left, right)
  return left
    and right
    and left.dev == right.dev
    and left.ino == right.ino
    and same_time(left.birthtime, right.birthtime)
end

---@param root string
---@param path string
---@return boolean
local function contains(root, path)
  return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

---@param fs Neoagent.SandboxFilesystemService
---@param profile? Neoagent.SandboxProfile
---@return Neoagent.LinuxSandboxRoot?, string?
local function temporary_root(fs, profile)
  local problems = {}
  for _, source in ipairs(STAGING_DIRECTORIES) do
    local directory = vim.uv.fs_realpath(source)
    local directory_stat = directory and vim.uv.fs_stat(directory)
    if not directory or not directory_stat or directory_stat.type ~= "directory" then
      problems[#problems + 1] = source .. " is unavailable"
    else
      local exposed = false
      for _, entry in ipairs(profile and profile.filesystem.entries or {}) do
        if entry.access ~= "deny" and contains(entry.path, directory) then
          exposed = true
          break
        end
      end
      if exposed then
        problems[#problems + 1] = "filesystem profile exposes " .. directory
      else
        local path, err = fs.create_temp_directory("neoagent-sandbox-", directory)
        if path then
          path = vim.uv.fs_realpath(path) or vim.fs.normalize(path)
          local stat, stat_err = vim.uv.fs_lstat(path)
          if not stat or stat.type ~= "directory" then
            return nil, stat_err or "temporary root is not a directory"
          end
          return { path = path, stat = stat }
        end
        problems[#problems + 1] = directory .. ": " .. tostring(err)
      end
    end
  end
  return nil, "Linux sandbox staging directory is unavailable: " .. table.concat(problems, "; ")
end

---@param root Neoagent.LinuxSandboxRoot
---@return boolean?
local function valid_root(root)
  local stat = vim.uv.fs_lstat(root.path)
  return stat and stat.type == "directory" and same_identity(stat, root.stat)
end

---@param root Neoagent.LinuxSandboxRoot
---@return boolean?, string?, string?
local function cleanup(root)
  if not valid_root(root) then
    return nil, "sandbox root identity changed: " .. root.path
  end
  return vim.uv.fs_rmdir(root.path)
end

---@param nvim string[]
---@param script string
---@param command? string[]
---@return string[]
local function runtime_argv(nvim, script, command)
  local argv = util.copy(nvim)
  local version = (vim.version --[[@as fun(): vim.Version]])()
  -- Neovim 0.10-0.12 expose -ll for Lua execution before editor
  -- initialization. Neovim 0.13+ provides script mode through headless -l.
  if version.major == 0 and version.minor < 13 then
    vim.list_extend(argv, { "-ll", script })
  else
    vim.list_extend(argv, {
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-n",
      "-l",
      script,
    })
  end
  if command then
    argv[#argv + 1] = "--"
    vim.list_extend(argv, command)
  end
  return argv
end

---@param argv string[]
---@param env table<string, string>
---@return string?
local function resolved_program(argv, env)
  local program = assert(argv[1])
  if program:sub(1, 1) == "/" then
    local resolved = vim.uv.fs_realpath(program)
    return resolved and executable(resolved) and vim.fs.normalize(resolved) or nil
  end
  for directory in tostring(env.PATH or ""):gmatch("[^:]+") do
    local candidate = vim.fs.joinpath(directory, program)
    if executable(candidate) then
      return vim.uv.fs_realpath(candidate) or vim.fs.normalize(candidate)
    end
  end
  return nil
end

---@param request Neoagent.LinuxSandboxRequest
---@param root Neoagent.LinuxSandboxRoot
---@param capabilities? Neoagent.SandboxCapabilities
---@param mode Neoagent.LinuxSandboxMode
---@return Neoagent.LinuxSandboxSpec, string[]?
local function specification(request, root, capabilities, mode)
  local command
  if mode == "exec" then
    command = util.copy(request.argv or {})
    local program = resolved_program(command, request.env or {})
    if not program then
      error(util.error("sandbox_unavailable", "Sandbox executable was not found: " .. tostring(command[1])), 0)
    end
    command[1] = program
  end
  local profile = util.copy(request.profile)
  return {
    v = 1,
    mode = mode,
    root = root.path,
    root_identity = {
      dev = root.stat.dev,
      ino = root.stat.ino,
    },
    profile = profile,
    cwd = request.cwd or "/",
    env = request.env or {},
    procfs = capabilities and capabilities.procfs or "fresh",
    protected_create = {},
  },
    command
end

---@param procfs "fresh"|"host"
---@return Neoagent.SandboxCapabilities
local function capabilities(procfs)
  return {
    filesystem = true,
    user_namespace = true,
    mount_namespace = true,
    pid_namespace = true,
    ipc_namespace = true,
    uts_namespace = true,
    network_namespace = true,
    seccomp = true,
    capability_drop = true,
    process_supervision = true,
    shared_tmp = true,
    protected_create = true,
    procfs = procfs,
    procfs_isolated = procfs == "fresh",
  }
end

---@param terminal Neoagent.SandboxTerminalEvent|string|nil
---@return boolean
local function procfs_fallback(terminal)
  return type(terminal) == "table" and terminal.type == "error" and PROCFS_STAGES[terminal.stage] == true
end

---@param terminal Neoagent.SandboxTerminalEvent|string
---@param stderr string?
---@return string?
local function probe_failure(terminal, stderr)
  if type(terminal) == "string" then
    return terminal
  end
  if terminal.type == "error" then
    return string.format("%s failed (errno=%s)", terminal.stage, tostring(terminal.errno))
  elseif terminal.code ~= 0 then
    return bounded(stderr)
  end
end

---@param spec Neoagent.LinuxSandboxSpec
---@return table<string, string>
local function environment(spec)
  return {
    NEOAGENT_SANDBOX_SPEC = util.json_encode(spec),
  }
end

---@param spec Neoagent.LinuxSandboxSpec
---@return table<string, string>|string[]
local function system_environment(spec)
  local variables = environment(spec)
  if
    not vim.version.lt((vim.version --[[@as fun(): vim.Version]])(), { 0, 11, 0 })
  then
    return variables
  end
  local result = {}
  for name, value in pairs(variables) do
    result[#result + 1] = name .. "=" .. value
  end
  table.sort(result)
  return result
end

---@param profile Neoagent.SandboxProfile
---@param path string
---@return Neoagent.SandboxAccess
local function parent_access(profile, path)
  local parent = vim.fs.dirname(path)
  ---@type Neoagent.SandboxAccess
  local selected = profile.filesystem.default
  local specificity = -1
  for _, entry in ipairs(profile.filesystem.entries) do
    if entry.path ~= path and contains(entry.path, parent) then
      local length = #entry.path
      if length > specificity then
        selected = entry.access
        specificity = length
      end
    end
  end
  return selected
end

---@param profile Neoagent.SandboxProfile
---@return Neoagent.SandboxFilesystemEntry[]
local function protected_create_paths(profile)
  local selected = {}
  for _, entry in ipairs(profile.filesystem.entries) do
    if
      entry.access ~= "write"
      and not vim.uv.fs_lstat(entry.path)
      and parent_access(profile, entry.path) == "write"
    then
      selected[entry.path] = entry.access
    end
  end
  local result = {}
  for path, access in pairs(selected) do
    result[#result + 1] = { path = path, access = access }
  end
  table.sort(result, function(left, right)
    return left.path < right.path
  end)
  return result
end

---@param request Neoagent.SandboxWorkerRequest
---@param services Neoagent.SandboxExecutionServices<string|string[]>
---@return Neoagent.WorkerLease
function M.start_worker(request, services)
  local runtime = runtime_file()
  if not runtime then
    error(util.error("sandbox_unavailable", "Linux sandbox runtime was not found"), 0)
  end
  require("neoagent.sandbox.policy").require_read(request.profile, request.bootstrap_paths or {}, nil, "bootstrap")
  local root, root_err = temporary_root(assert(services.fs), request.profile)
  if not root then
    error(util.error("sandbox_unavailable", "Could not create Linux sandbox root", root_err), 0)
  end
  local prepared, spec, command =
    pcall(specification, request --[[@as Neoagent.LinuxSandboxRequest]], root, services.capabilities, "exec")
  if not prepared then
    local cleaned, cleanup_err = cleanup(root)
    if not cleaned then
      error(util.error("sandbox_unavailable", "Could not remove Linux sandbox root", cleanup_err), 0)
    end
    error(spec, 0)
  end
  spec.protected_create = protected_create_paths(spec.profile)
  if not valid_root(root) then
    cleanup(root)
    error(util.error("sandbox_unavailable", "Linux sandbox root identity changed before use"), 0)
  end
  local relay = require("neoagent.sandbox.relay_lease").new({
    on_failure = request.on_failure,
    on_stdout = request.on_stdout,
    on_stderr = request.on_stderr,
    on_exit = request.on_exit,
    cleanup = function()
      local cleaned, cleanup_err = cleanup(root)
      return cleaned and true or nil, cleanup_err
    end,
  })
  local start = services.start_worker or require("neoagent.rpc.worker_lease").start
  local started, child = pcall(start, {
    argv = runtime_argv(nvim_command(services.nvim), runtime, command),
    cwd = "/",
    env = environment(spec),
    clear_env = true,
    kill_grace_ms = request.kill_grace_ms,
    on_stdout = function(data)
      relay:feed(data)
    end,
    on_exit = function(result)
      relay:host_exited(result)
    end,
  })
  if not started then
    local cleaned, cleanup_err = cleanup(root)
    if not cleaned then
      error(util.error("sandbox_unavailable", "Could not remove Linux sandbox root", cleanup_err), 0)
    end
    error(util.error("sandbox_unavailable", "Could not start Linux sandbox runtime", child), 0)
  end
  relay:attach(child)
  return relay
end

---@param services? Neoagent.SandboxCheckServices
---@return Neoagent.SandboxStatus
function M.check(services)
  services = services or {}
  local runtime = runtime_file()
  local nvim = nvim_command(services.nvim)
  if jit.arch ~= "x64" and jit.arch ~= "arm64" then
    return {
      ok = false,
      platform = M.name,
      stage = "architecture",
      message = "unsupported LuaJIT architecture " .. tostring(jit.arch),
    }
  end
  if not executable(nvim[1]) then
    return {
      ok = false,
      platform = M.name,
      stage = "nvim",
      message = "current Neovim executable cannot be resolved",
    }
  end
  if not runtime then
    return {
      ok = false,
      platform = M.name,
      stage = "runtime",
      message = "Linux sandbox runtime was not found",
    }
  end
  local fs = services.fs or require("neoagent.fs")
  local root, root_err = temporary_root(fs)
  if not root then
    return {
      ok = false,
      platform = M.name,
      stage = "temporary-root",
      message = bounded(root_err),
    }
  end
  ---@type Neoagent.SandboxProfile
  local profile = {
    id = "activation-probe",
    filesystem = { default = "read", entries = {} },
    network = "restricted",
    environment = { clear = true, inherit = {}, set = {} },
  }
  local spec = specification({
    profile = profile,
    cwd = "/",
    argv = {},
    env = {},
  }, root, capabilities("fresh"), "probe")
  spec.protected_create = {
    {
      path = vim.fs.joinpath(root.path, "protected-create-probe"),
      access = "deny",
    },
  }
  local system = services.system or function(argv, opts, timeout)
    return vim.system(argv, opts):wait(timeout)
  end
  local function run_probe()
    return system(runtime_argv(nvim, runtime), {
      cwd = "/",
      env = system_environment(spec),
      clear_env = true,
      text = false,
    }, services.probe_timeout_ms or 5000)
  end
  local completed = run_probe()
  local events, terminal
  local degraded_reason
  if completed then
    events, terminal = protocol.decode_all(completed.stdout or "")
    if procfs_fallback(terminal) then
      local fallback = terminal --[[@as Neoagent.SandboxErrorEvent]]
      degraded_reason = string.format(
        "fresh procfs setup failed at %s (errno=%s); inherited host procfs is active",
        fallback.stage,
        tostring(fallback.errno)
      )
      spec.procfs = "host"
      completed = run_probe()
      if completed then
        events, terminal = protocol.decode_all(completed.stdout or "")
      else
        events, terminal = nil, nil
      end
    end
  end
  local cleaned, cleanup_err = cleanup(root)
  if not cleaned then
    return {
      ok = false,
      platform = M.name,
      stage = "probe-cleanup",
      message = bounded(cleanup_err or "could not remove the probe temporary root"),
    }
  end
  if not completed then
    return {
      ok = false,
      platform = M.name,
      stage = "probe",
      message = "probe timed out",
    }
  end
  if not events then
    events, terminal = protocol.decode_all(completed.stdout or "")
  end
  local reason = probe_failure((assert(terminal)), completed.stderr)
  if completed.code ~= 0 or reason then
    reason = reason or bounded(completed.stderr)
    return {
      ok = false,
      platform = M.name,
      stage = "probe",
      message = reason ~= "" and reason or "native probe failed",
    }
  end
  local available = capabilities(spec.procfs)
  return {
    ok = true,
    platform = M.name,
    degraded = spec.procfs ~= "fresh",
    degraded_reason = degraded_reason,
    capabilities = available,
  }
end

return M
