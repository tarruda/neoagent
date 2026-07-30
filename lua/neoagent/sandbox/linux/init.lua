local protocol = require("neoagent.sandbox.linux.protocol")
local util = require("neoagent.util")

local M = { name = "linux" }
local FS_TIMEOUT_MS = 30000
local PROCFS_STAGES = {
  ["unmount-proc"] = true,
  ["mount-proc"] = true,
  ["mask-proc"] = true,
}

local function bounded(value)
  value = util.trim(tostring(value or ""):gsub("[%z\1-\31\127]", " "))
  if #value > 1000 then value = value:sub(1, 997) .. "..." end
  return value
end

local function runtime_file()
  local matches = vim.api.nvim_get_runtime_file(
    "scripts/sandbox_linux_runtime.lua", false)
  local path = matches[1]
  path = path and (vim.uv.fs_realpath(path) or vim.fs.normalize(path)) or nil
  local stat = path and vim.uv.fs_stat(path)
  return stat and stat.type == "file" and path or nil
end

local function executable(path)
  local stat = path and vim.uv.fs_stat(path)
  return stat and stat.type == "file" and vim.fn.executable(path) == 1
end

local function process_commandline()
  local fd = vim.uv.fs_open("/proc/self/cmdline", "r", 0)
  if not fd then return nil end
  local data = vim.uv.fs_read(fd, 64 * 1024, 0)
  vim.uv.fs_close(fd)
  if not data then return nil end
  local values = {}
  for value in data:gmatch("([^%z]+)") do values[#values + 1] = value end
  return values
end

local function nvim_command(configured)
  if type(configured) == "string" then return { configured } end
  if type(configured) == "table" and util.is_list(configured)
      and #configured > 0 then
    return util.copy(configured)
  end
  local actual = vim.v.argv[1]
  local commandline = process_commandline()
  if type(actual) == "string" and commandline then
    for index, value in ipairs(commandline) do
      if value == actual then
        local command = {}
        for part = 1, index do command[part] = commandline[part] end
        return command
      end
    end
  end
  return { vim.v.progpath }
end

local function same_inode(left, right)
  return left and right and left.dev == right.dev and left.ino == right.ino
end

local function temporary_root(fs)
  local path, err = fs.create_temp_directory("neoagent-sandbox-")
  if not path then return nil, err end
  path = vim.uv.fs_realpath(path) or vim.fs.normalize(path)
  local stat, stat_err = vim.uv.fs_lstat(path)
  if not stat or stat.type ~= "directory" then
    return nil, stat_err or "temporary root is not a directory"
  end
  return { path = path, stat = stat }
end

local function valid_root(root)
  local stat = vim.uv.fs_lstat(root.path)
  return stat and stat.type == "directory"
    and same_inode(stat, root.stat)
end

local function cleanup(root)
  if not valid_root(root) then
    return nil, "sandbox root identity changed: " .. root.path
  end
  return vim.uv.fs_rmdir(root.path)
end

local function runtime_argv(nvim, script, command)
  local argv = util.copy(nvim)
  vim.list_extend(argv, {
    "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script,
  })
  if command then
    argv[#argv + 1] = "--"
    vim.list_extend(argv, command)
  end
  return argv
end

local function resolved_program(argv, env)
  local program = argv[1]
  if program:sub(1, 1) == "/" then
    local resolved = vim.uv.fs_realpath(program)
    return executable(resolved) and vim.fs.normalize(resolved) or nil
  end
  for directory in tostring(env.PATH or ""):gmatch("[^:]+") do
    local candidate = vim.fs.joinpath(directory, program)
    if executable(candidate) then
      return vim.uv.fs_realpath(candidate) or vim.fs.normalize(candidate)
    end
  end
  return nil
end

local function specification(request, root, capabilities)
  local command
  if request.mode == "exec" then
    command = util.copy(request.argv or {})
    local program = resolved_program(command, request.env or {})
    if not program then
      error(util.error("sandbox_unavailable",
        "Sandbox executable was not found: "
          .. tostring(command[1])), 0)
    end
    command[1] = program
  end
  local profile = util.copy(request.profile)
  return {
    v = 1,
    mode = request.mode,
    root = root.path,
    root_identity = {
      dev = root.stat.dev,
      ino = root.stat.ino,
    },
    profile = profile,
    cwd = request.cwd or "/",
    env = request.env or {},
    fs = request.fs,
    procfs = capabilities and capabilities.procfs or "fresh",
    protected_create = {},
  }, command
end

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
    private_tmp = true,
    protected_create = true,
    procfs = procfs,
    procfs_isolated = procfs == "fresh",
  }
end

local function procfs_fallback(terminal)
  return terminal and terminal.type == "error"
    and PROCFS_STAGES[terminal.stage] == true
end

local function environment(spec)
  return {
    NEOAGENT_SANDBOX_SPEC = util.json_encode(spec),
  }
end

local function system_environment(spec)
  local result = {}
  for name, value in pairs(environment(spec)) do
    result[#result + 1] = name .. "=" .. value
  end
  table.sort(result)
  return result
end

local function contains(root, path)
  return root == "/" or path == root
    or path:sub(1, #root + 1) == root .. "/"
end

local function parent_access(profile, path)
  local parent = vim.fs.dirname(path)
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

local function protected_create_paths(profile)
  local selected = {}
  for _, entry in ipairs(profile.filesystem.entries) do
    if entry.access ~= "write" and not vim.uv.fs_lstat(entry.path)
        and parent_access(profile, entry.path) == "write" then
      selected[entry.path] = entry.access
    end
  end
  local result = {}
  for path, access in pairs(selected) do
    result[#result + 1] = { path = path, access = access }
  end
  table.sort(result, function(left, right) return left.path < right.path end)
  return result
end

local function process_request(request, services, mode)
  local runtime = runtime_file()
  if not runtime then
    error(util.error("sandbox_unavailable",
      "Linux sandbox runtime was not found"), 0)
  end
  local root, root_err = temporary_root(services.fs)
  if not root then
    error(util.error("sandbox_unavailable",
      "Could not create Linux sandbox root", root_err), 0)
  end
  local copied = util.copy(request)
  copied.mode = mode
  local nvim = nvim_command(services.nvim)
  local prepared, spec, command = pcall(
    specification, copied, root, services.capabilities)
  if not prepared then
    local cleaned, cleanup_err = cleanup(root)
    if not cleaned then
      error(util.error("sandbox_unavailable",
        "Could not remove Linux sandbox root", cleanup_err), 0)
    end
    error(spec, 0)
  end
  spec.protected_create = protected_create_paths(spec.profile)
  if not valid_root(root) then
    error(util.error("sandbox_unavailable",
      "Linux sandbox root identity changed before use"), 0)
  end
  local stdout, stderr, output = "", "", ""
  local capture = request.capture ~= false
  local decoder_error
  local decoder = protocol.new({
    on_event = function(event)
      if event.type ~= "output" then return end
      local is_stderr = event.stream == "stderr"
      if capture then
        if is_stderr then stderr = stderr .. event.data
        else stdout = stdout .. event.data end
        output = output .. event.data
      end
      if request.on_output then
        request.on_output(event.data, is_stderr, stdout, stderr, output)
      end
    end,
  })
  local runtime_stderr = ""
  local ok, host = pcall(services.process,
    runtime_argv(nvim, runtime, command), {
      cwd = "/",
      env = environment(spec),
      clear_env = true,
      stdin = request.stdin,
      capture = false,
      timeout_ms = request.timeout_ms,
      kill_grace_ms = request.kill_grace_ms,
      on_output = function(data, is_stderr)
        if is_stderr then
          if #runtime_stderr < 1000 then
            runtime_stderr = (runtime_stderr .. data):sub(1, 1000)
          end
        elseif not decoder_error then
          local decoded, err = pcall(decoder.feed, decoder, data)
          if not decoded then decoder_error = tostring(err) end
        end
      end,
    })
  local cleaned, cleanup_err = cleanup(root)
  if not cleaned then
    error(util.error("sandbox_unavailable",
      "Could not remove Linux sandbox root", cleanup_err), 0)
  end
  if not ok then
    local err = util.normalize_error(host, "sandbox_unavailable")
    if err.kind == "cancelled" then error(host, 0) end
    error(util.error("sandbox_unavailable",
      "Linux sandbox runtime failed", bounded(err.message)), 0)
  end
  if type(host) ~= "table" or type(host.code) ~= "number"
      or type(host.signal) ~= "number" then
    error(util.error("sandbox_unavailable",
      "Linux sandbox runtime returned an invalid process result"), 0)
  end
  if host.timed_out then
    return {
      code = host.code,
      signal = host.signal,
      stdout = stdout,
      stderr = stderr,
      output = output,
      timed_out = true,
    }
  end
  if decoder_error then
    error(util.error("sandbox_unavailable",
      "Invalid Linux sandbox protocol", decoder_error), 0)
  end
  local terminal, terminal_err = decoder:finish()
  if not terminal then
    local diagnostic = bounded(runtime_stderr)
    error(util.error("sandbox_unavailable",
      terminal_err, diagnostic ~= "" and diagnostic or nil), 0)
  end
  if terminal.type == "error" then
    error(util.error("sandbox_unavailable",
      "Linux sandbox setup failed at " .. terminal.stage,
      "errno=" .. tostring(terminal.errno)), 0)
  end
  return {
    code = terminal.code,
    signal = terminal.signal,
    stdout = stdout,
    stderr = stderr,
    output = output,
    timed_out = false,
  }
end

function M.exec(request, services)
  return process_request(request, services, "exec")
end

function M.fs(request, services)
  local value = process_request({
    profile = request.profile,
    cwd = "/",
    env = {},
    argv = {},
    fs = {
      operation = request.operation,
      path = request.path,
      flags = request.flags,
      mode = request.mode,
    },
    stdin = request.data,
    capture = true,
    timeout_ms = request.timeout_ms or FS_TIMEOUT_MS,
  }, services, "fs")
  if value.code ~= 0 then
    return nil, bounded(value.stderr) ~= "" and bounded(value.stderr)
      or "sandbox filesystem operation failed"
  end
  if request.operation == "read" then return value.stdout end
  return true
end

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
  local profile = {
    id = "activation-probe",
    filesystem = { default = "read", entries = {} },
    network = "restricted",
    environment = { clear = true, inherit = {}, set = {} },
    temporary = "private",
  }
  local spec = specification({
    mode = "probe",
    profile = profile,
    cwd = "/",
    argv = {},
    env = {},
  }, root, capabilities("fresh"))
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
      degraded_reason = string.format(
        "fresh procfs setup failed at %s (errno=%s); inherited host procfs is active",
        terminal.stage, tostring(terminal.errno))
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
      message = bounded(cleanup_err
        or "could not remove the probe temporary root"),
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
  if completed.code ~= 0 or not events or terminal.type ~= "exit"
      or terminal.code ~= 0 then
    local reason
    if not events then
      reason = terminal
    elseif terminal.type == "error" then
      reason = string.format("%s failed (errno=%s)",
        terminal.stage, tostring(terminal.errno))
    else
      reason = bounded(completed.stderr)
    end
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
