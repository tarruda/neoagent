local util = require("neoagent.util")
local M = {}

local SENSITIVE_ENVIRONMENT = {
  ANTHROPIC_API_KEY = true,
  AWS_ACCESS_KEY_ID = true,
  AWS_SECRET_ACCESS_KEY = true,
  BAILIAN_TOKEN_PLAN_API_KEY = true,
  DEEPSEEK_API_KEY = true,
  GIT_ASKPASS = true,
  GPG_AGENT_INFO = true,
  GOOGLE_APPLICATION_CREDENTIALS = true,
  HF_TOKEN = true,
  OPENAI_API_KEY = true,
  OPENCODE_API_KEY = true,
  SSH_ASKPASS = true,
  SSH_AUTH_SOCK = true,
  ZAI_API_KEY = true,
}

---@param profile Neoagent.SandboxProfile
---@param source table<string, string>
---@param paths Neoagent.SandboxPaths
---@return table<string, string>
function M.environment(profile, source, paths)
  local values = {}
  local output_names = {}
  local by_key = {}
  local names = vim.tbl_keys(source)
  table.sort(names)
  for _, name in ipairs(names) do
    local key = paths.environment_key(name)
    if not by_key[key] then
      by_key[key] = name
    end
  end
  local function allowed_ambient(name)
    -- The sandbox profile and native bootstrap accept portable variable
    -- names. Ambient Windows entries such as ProgramFiles(x86) and =C:
    -- must not make an otherwise valid worker specification unlaunchable.
    if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
      return false
    end
    local upper = name:upper()
    if upper == "NVIM" or upper == "NVIM_LISTEN_ADDRESS" or SENSITIVE_ENVIRONMENT[upper] then
      return false
    end
    local segmented = "_" .. upper:gsub("[^A-Z0-9]+", "_") .. "_"
    for _, token in ipairs({ "KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "CREDENTIALS" }) do
      if segmented:find("_" .. token .. "_", 1, true) then
        return false
      end
    end
    return true
  end
  local function put(name, value)
    local key = paths.environment_key(name)
    local previous = output_names[key]
    if previous and previous ~= name then
      values[previous] = nil
    end
    values[name] = value
    output_names[key] = name
  end
  if not profile.environment.clear then
    for _, name in ipairs(names) do
      if allowed_ambient(name) then
        put(name, source[name])
      end
    end
  end
  for _, name in ipairs(profile.environment.inherit) do
    local source_name = by_key[paths.environment_key(name)]
    if source_name then
      put(name, source[source_name])
    end
  end
  for name, value in pairs(profile.environment.set) do
    put(name, value)
  end
  return values
end

---@class Neoagent.SandboxWorkerLaunch
---@field platform Neoagent.SandboxPlatform<unknown>
---@field profile Neoagent.SandboxProfile
---@field paths Neoagent.SandboxPaths
---@field services Neoagent.SandboxExecutionServices
---@field nvim? string|string[]
---@field cwd string
---@field environment table<string, string>
---@field mode "tools"|"process"
---@field on_failure fun(error: Neoagent.Error)
---@field on_event? fun(message: table)

---@param options Neoagent.SandboxWorkerLaunch
---@return Neoagent.RpcConnection, Neoagent.WorkerLease
function M.start(options)
  local prepared, launch = pcall(function()
    local worker_module = require("neoagent.rpc.worker")
    local worker = worker_module.worker_file()
    local nvim = worker_module.nvim_command(options.nvim)
    local env = util.copy(options.environment)
    env.NEOAGENT_WORKER_FILE = worker
    env.NEOAGENT_WORKER_MODE = options.mode
    local required = worker_module.bootstrap_paths(worker, nvim)
    require("neoagent.sandbox.policy").require_read(options.profile, required, options.paths, "bootstrap")
    return { argv = worker_module.argv(nvim, worker), bootstrap_paths = required, env = env }
  end)
  if not prepared then
    error(util.normalize_error(launch, "worker_start"), 0)
  end
  local connection = require("neoagent.rpc.connection").new({
    on_failure = options.on_failure,
    on_event = options.on_event,
  })
  local started, lease = pcall(options.platform.start_worker, {
    argv = launch.argv,
    cwd = options.cwd,
    env = launch.env,
    profile = options.profile,
    bootstrap_paths = launch.bootstrap_paths,
    on_stdout = function(data)
      connection:feed(data)
    end,
    on_failure = function(err)
      connection:abort(util.error("protocol", err.message, err.detail))
    end,
    on_exit = function(value)
      connection:eof(value)
    end,
  }, options.services)
  if not started then
    error(util.normalize_error(lease, "sandbox_unavailable"), 0)
  end
  if
    not (
      type(lease) == "table"
      and type(lease.write) == "function"
      and type(lease.close_stdin) == "function"
      and type(lease.terminate) == "function"
      and type(lease.wait) == "function"
      and type(lease.dispose) == "function"
    )
  then
    error(util.error("sandbox_unavailable", "sandbox platform returned an invalid worker lease"), 0)
  end
  connection:attach(lease)
  return connection, lease
end

return M
