local compiler = require("neoagent.sandbox.windows.compile")
local path_module = require("neoagent.sandbox.path")
local protocol = require("neoagent.sandbox.protocol")
local relay_lease = require("neoagent.sandbox.relay_lease")
local util = require("neoagent.util")
local nvim_launch = require("neoagent.process.nvim")

---@class Neoagent.WindowsSandboxProfile: Neoagent.SandboxProfile
---@field windows Neoagent.WindowsSandboxPolicy

---@class Neoagent.WindowsSandboxRequest
---@field argv? string[]
---@field cwd string
---@field env table<string, string>
---@field profile Neoagent.SandboxProfile
---@field probe? {write: string, deny_write: string, deny_read: string}
---@field bootstrap_paths? string[]

---@alias Neoagent.WindowsSandboxMode 'exec'|'probe'

---@class Neoagent.WindowsSandboxSpec
---@field v 1
---@field mode Neoagent.WindowsSandboxMode
---@field profile Neoagent.SandboxProfile
---@field cwd? string
---@field argv? string[]
---@field env table<string, string>
---@field probe? {write: string, deny_write: string, deny_read: string}
---@field admission_timeout_ms integer
---@field runner {argv: string[], read_roots: string[], script: string, version: 'script'}

---@class Neoagent.WindowsSandboxProbe
---@field spec Neoagent.WindowsSandboxSpec
---@field root string

local M = {
  name = "windows",
  paths = path_module.windows(),
}

local PROBE_TIMEOUT_MS = 30000
local MINIMUM_NVIM = { 0, 12, 0 }
local CAPABILITIES = {
  filesystem = true,
  network = true,
  process = true,
  process_supervision = true,
  shared_tmp = true,
  restricted_token = true,
  restricting_sids = true,
  job_object = true,
  private_desktop = true,
  windows_filtering_platform = true,
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

---@param stage string
---@param message unknown
---@return Neoagent.SandboxStatus
local function unavailable(stage, message)
  return {
    ok = false,
    platform = M.name,
    stage = stage,
    message = bounded(message),
  }
end

---@return string?
local function runtime_file()
  local matches = vim.api.nvim_get_runtime_file("scripts/sandbox_windows_runtime.lua", false)
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
  local resolved = vim.uv.fs_realpath(path)
  local stat = resolved and vim.uv.fs_stat(resolved)
  if resolved and stat and stat.type == "file" then
    return vim.fs.normalize(resolved)
  end
end

---@param configured? string|string[]
---@return string[]
local function nvim_command(configured)
  return nvim_launch.command(configured or vim.v.progpath)
end

---@param required [integer, integer, integer]
---@return boolean
local function version_at_least(required)
  local version = (vim.version --[[@as fun(): vim.Version]])()
  for index, name in ipairs({ "major", "minor", "patch" }) do
    local actual = tonumber(version[name])
    local minimum = assert(required[index])
    if not actual then
      return false
    end
    if actual ~= minimum then
      return actual > minimum
    end
  end
  return true
end

---@return boolean
local function supported_version()
  return version_at_least(MINIMUM_NVIM)
end

---@param nvim string[]
---@param script string
---@return string[]
local function runtime_argv(nvim, script)
  local argv = util.copy(nvim)
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
  return argv
end

---@param runtime string
---@return string
local function command_module(runtime)
  local checkout = M.paths.dirname(M.paths.dirname(runtime))
  return M.paths.join(checkout, "lua", "neoagent", "process", "windows_command.lua")
end

---@param nvim string[]
---@param script string
---@return string[]
local function runner_read_roots(nvim, script)
  if not M.paths.is_absolute(nvim[1]) then
    return {}
  end
  local executable_root = M.paths.dirname((assert(nvim[1])))
  local roots = { executable_root, command_module(script) }
  local installation = M.paths.dirname(executable_root)
  -- Release archives place the runtime below the installation root. Custom
  -- distributions expose their initialized runtime through VIMRUNTIME.
  local runtime = M.paths.join(installation, "share", "nvim", "runtime")
  local stat = vim.uv.fs_stat(runtime)
  if not stat or stat.type ~= "directory" then
    runtime = vim.env.VIMRUNTIME
    stat = M.paths.is_absolute(runtime) and vim.uv.fs_stat(runtime) or nil
  end
  if stat and stat.type == "directory" and M.paths.key(runtime) ~= M.paths.key(executable_root) then
    roots[#roots + 1] = M.paths.normalize(vim.uv.fs_realpath(runtime) or runtime)
  end
  return roots
end

---@return string
local function state_dir()
  local configured = vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE
  if type(configured) == "string" and configured ~= "" then
    return M.paths.normalize(configured)
  end
  return M.paths.normalize(vim.fs.joinpath(vim.fn.stdpath("state") --[[@as string]], "neoagent", "windows-sandbox"))
end

---@return string
function M.temporary_root()
  return M.paths.join(state_dir(), "shared-tmp")
end

---@param spec Neoagent.WindowsSandboxSpec
---@return table<string, string>
local function environment(spec)
  local values = {
    NEOAGENT_SANDBOX_SPEC = util.json_encode(spec),
    NEOAGENT_WINDOWS_SANDBOX_STATE = state_dir(),
    TEMP = M.temporary_root(),
    TMP = M.temporary_root(),
  }
  for _, name in ipairs({ "SystemRoot", "WINDIR" }) do
    local value = vim.uv.os_getenv(name)
    if type(value) == "string" and value ~= "" then
      values[name] = value
    end
  end
  return values
end

---@param environment_map table<string, string>
---@param name string
---@return string?
local function environment_value(environment_map, name)
  local selected
  for key, value in pairs(environment_map or {}) do
    if key:lower() == name:lower() then
      selected = value
    end
  end
  return selected
end

---@param program string
---@param environment_map table<string, string>
---@return string[]
local function candidate_names(program, environment_map)
  local result = { program }
  local basename = program:gsub("/", "\\"):match("([^\\]+)$") or program
  if not basename:find("%.[^%.\\]+$") then
    local extensions = environment_value(environment_map, "PATHEXT") or ".COM;.EXE;.BAT;.CMD"
    for extension in extensions:gmatch("[^;]+") do
      if extension:sub(1, 1) ~= "." then
        extension = "." .. extension
      end
      result[#result + 1] = program .. extension
    end
  end
  return result
end

---@param program string
---@param cwd? string
---@param environment_map table<string, string>
---@return string?
local function resolve_candidate(program, cwd, environment_map)
  local roots = {}
  if M.paths.is_absolute(program) then
    roots[1] = ""
  elseif program:find("[/\\]") then
    roots[1] = cwd
  else
    roots[1] = cwd
    local path = environment_value(environment_map, "PATH") or ""
    for directory in path:gmatch("[^;]+") do
      directory = util.trim(directory:gsub('^"', ""):gsub('"$', ""))
      if directory ~= "" then
        roots[#roots + 1] = directory
      end
    end
  end
  for _, root in ipairs(roots) do
    for _, name in ipairs(candidate_names(program, environment_map)) do
      local candidate = root == "" and name or M.paths.join(root, name)
      local resolved = executable(candidate)
      if resolved then
        return resolved
      end
    end
  end
end

---@param request Neoagent.WindowsSandboxRequest
---@param mode Neoagent.WindowsSandboxMode
---@param runtime string
---@param nvim string[]
---@return Neoagent.WindowsSandboxSpec
local function specification(request, mode, runtime, nvim)
  local argv
  if mode == "exec" then
    argv = util.copy(request.argv or {})
    local program = argv[1] and resolve_candidate(argv[1], request.cwd, request.env or {})
    if not program then
      error(util.error("sandbox_unavailable", "Sandbox executable was not found: " .. tostring(argv[1])), 0)
    end
    argv[1] = program
  end
  return {
    v = 1,
    mode = mode,
    profile = util.copy(request.profile),
    cwd = request.cwd,
    argv = argv,
    env = util.copy(request.env or {}),
    probe = util.copy(request.probe),
    admission_timeout_ms = relay_lease.DEFAULT_ADMISSION_TIMEOUT_MS,
    runner = {
      argv = util.copy(nvim),
      -- CreateProcessWithLogonW uses a separate local account. Initialized
      -- Neovim reads adjacent DLLs and its packaged runtime before the Lua
      -- runner can connect, so those installation roots need inherited read
      -- and execute access in addition to the executable itself.
      read_roots = runner_read_roots(nvim, runtime),
      script = runtime,
      version = "script",
    },
  }
end

---@param profile Neoagent.SandboxProfile
---@return Neoagent.WindowsSandboxProfile
function M.compile(profile)
  local compiled = util.copy(profile) --[[@as Neoagent.WindowsSandboxProfile]]
  compiled.windows = compiler.compile(profile, { paths = M.paths })
  return compiled
end

---@param request Neoagent.SandboxWorkerRequest
---@param services Neoagent.SandboxExecutionServices<string|string[]>
---@return Neoagent.WorkerLease
function M.start_worker(request, services)
  if not supported_version() then
    error(util.error("sandbox_unavailable", "Windows sandboxing requires Neovim 0.12 or newer"), 0)
  end
  local runtime = runtime_file()
  if not runtime then
    error(util.error("sandbox_unavailable", "Windows sandbox runtime was not found"), 0)
  end
  local nvim = nvim_command(services.nvim)
  if not executable(nvim[1]) then
    error(util.error("sandbox_unavailable", "Current Neovim executable cannot be resolved"), 0)
  end
  local required = util.copy(request.bootstrap_paths or {})
  required[#required + 1] = command_module(runtime)
  local bootstrap = require("neoagent.sandbox.policy").require_read(request.profile, required, M.paths, "bootstrap")
  local spec = specification(request --[[@as Neoagent.WindowsSandboxRequest]], "exec", runtime, nvim)
  local seen = {}
  for _, path in ipairs(spec.runner.read_roots) do
    seen[M.paths.key(path)] = true
  end
  for _, normalized in ipairs(bootstrap) do
    local key = M.paths.key(normalized)
    if not seen[key] then
      seen[key] = true
      spec.runner.read_roots[#spec.runner.read_roots + 1] = normalized
    end
  end
  local relay = relay_lease.new({
    on_failure = request.on_failure,
    on_stdout = request.on_stdout,
    on_stderr = request.on_stderr,
    on_exit = request.on_exit,
    admission_timeout_ms = spec.admission_timeout_ms,
  })
  local start = services.start_worker or require("neoagent.rpc.worker_lease").start
  local started, child = pcall(start, {
    argv = runtime_argv(nvim, runtime),
    cwd = assert(vim.fs.dirname(runtime)),
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
    error(util.error("sandbox_unavailable", "Could not start Windows sandbox runtime", child), 0)
  end
  relay:attach(child)
  return relay
end

---@param path? string
local function cleanup_probe(path)
  if path then
    pcall(vim.fn.delete, path, "rf")
  end
end

---@param services Neoagent.SandboxCheckServices
---@param runtime string
---@param nvim string[]
---@return Neoagent.WindowsSandboxProbe?, string?, unknown
---@return_overload Neoagent.WindowsSandboxProbe
---@return_overload nil, string, unknown
local function check_request(services, runtime, nvim)
  local fs = services.fs or require("neoagent.fs")
  local root, root_err = fs.create_temp_directory("neoagent-windows-probe-", vim.uv.os_tmpdir())
  if not root then
    return nil, "probe-directory", root_err
  end
  root = vim.uv.fs_realpath(root) or M.paths.normalize(root)
  local denied_write = M.paths.join(root, "read-only.txt")
  local denied_read = M.paths.join(root, "denied")
  local write_probe = M.paths.join(root, "created.txt")
  local wrote, write_err = fs.write_all(denied_write, "protected", "wx", 384)
  if not wrote then
    cleanup_probe(root)
    return nil, "probe-file", write_err
  end
  local made, mkdir_err = fs.mkdirp(denied_read)
  if not made then
    cleanup_probe(root)
    return nil, "probe-directory", mkdir_err
  end
  ---@type Neoagent.SandboxProfile
  local profile = {
    id = "windows-probe",
    network = "restricted",
    filesystem = {
      default = "read",
      entries = {
        { path = root, access = "write" },
        { path = denied_write, access = "read" },
        { path = denied_read, access = "deny" },
      },
    },
    environment = {
      clear = true,
      inherit = {},
      set = {},
    },
  }
  local compiled, profile_or_error = pcall(M.compile, profile)
  if not compiled then
    cleanup_probe(root)
    return nil, "profile", profile_or_error
  end
  return {
    spec = specification({
      profile = profile_or_error,
      cwd = root,
      env = {},
      probe = {
        write = write_probe,
        deny_write = denied_write,
        deny_read = denied_read,
      },
    }, "probe", runtime, nvim),
    root = root,
  }
end

---@param argv string[]
---@param opts vim.SystemOpts
---@param timeout integer
---@return vim.SystemCompleted?
local function system(argv, opts, timeout)
  return vim.system(argv, opts):wait(timeout)
end

---@param services? Neoagent.SandboxCheckServices
---@return Neoagent.SandboxStatus
function M.check(services)
  ---@type Neoagent.SandboxCheckServices
  services = services or {}
  if not supported_version() then
    return unavailable("version", "Windows sandboxing requires Neovim 0.12 or newer")
  end
  if jit.arch ~= "x64" then
    return unavailable("architecture", "unsupported LuaJIT architecture " .. tostring(jit.arch))
  end
  local runtime = runtime_file()
  if not runtime then
    return unavailable("runtime", "Windows sandbox runtime was not found")
  end
  local nvim = nvim_command(services.nvim)
  if not executable(nvim[1]) then
    return unavailable("nvim", "current Neovim executable cannot be resolved")
  end
  local prepared, stage, message = check_request(services, runtime, nvim)
  if not prepared then
    return unavailable(stage, message)
  end
  local completed = (services.system or system)(runtime_argv(nvim, runtime), {
    cwd = vim.fs.dirname(runtime),
    env = environment(prepared.spec),
    clear_env = true,
    text = false,
  }, services.probe_timeout_ms or PROBE_TIMEOUT_MS)
  cleanup_probe(prepared.root)
  if not completed then
    return unavailable("probe", "Windows sandbox probe timed out")
  end
  local events, terminal = protocol.decode_all(completed.stdout or "")
  if not events then
    local detail = bounded(completed.stderr)
    return unavailable("protocol", tostring(terminal) .. (detail ~= "" and ": " .. detail or ""))
  end
  assert(type(terminal) == "table")
  if terminal.type == "error" then
    local hint = terminal.stage == "state-missing" and "; run the documented elevated Windows sandbox setup command"
      or ""
    return unavailable(
      terminal.stage,
      "Windows sandbox probe failed (win32=" .. tostring(terminal.errno) .. ")" .. hint
    )
  end
  if completed.code ~= 0 or terminal.code ~= 0 then
    return unavailable("probe", "Windows sandbox probe failed")
  end
  return {
    ok = true,
    platform = M.name,
    degraded = false,
    capabilities = util.copy(CAPABILITIES),
  }
end

return M
