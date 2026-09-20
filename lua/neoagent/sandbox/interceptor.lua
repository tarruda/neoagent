local async = require("neoagent.async")
local invocation_module = require("neoagent.sandbox.invocation")
local path_module = require("neoagent.sandbox.path")
local profile_module = require("neoagent.sandbox.profile")
local result = require("neoagent.sandbox.result")
local common = require("neoagent.tools.common")
local util = require("neoagent.util")

local M = {}

local FILESYSTEM_DENIALS = { EACCES = true, EPERM = true, EROFS = true }

---@class Neoagent.SandboxInterceptorOptions<C>
---@field profile Neoagent.SandboxProfileSource<Neoagent.ToolContext<C>>
---@field platform Neoagent.SandboxPlatform<Neoagent.ToolContext<C>>
---@field paths? Neoagent.SandboxPaths
---@field fs? Neoagent.SandboxFilesystemService
---@field environ? fun(): table<string, string>
---@field nvim? string|string[]
---@field capabilities? Neoagent.SandboxCapabilities
---@field start_worker? fun(request: Neoagent.WorkerRequest): Neoagent.WorkerLease

---@class Neoagent.SandboxInterceptor<C>
---@field _profile_source Neoagent.SandboxProfileSource<Neoagent.ToolContext<C>>
---@field _configured_profile? Neoagent.SandboxProfile
---@field _platform Neoagent.SandboxPlatform<Neoagent.ToolContext<C>>
---@field _paths Neoagent.SandboxPaths
---@field _environ fun(): table<string, string>
---@field _services Neoagent.SandboxExecutionServices
---@field _nvim? string|string[]
local Interceptor = {}
Interceptor.__index = Interceptor

local DENIAL_KEYWORDS = {
  "operation not permitted",
  "permission denied",
  "read-only file system",
  "seccomp",
  "sandbox",
  "failed to write file",
}

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

---@param value unknown
---@return string
local function bounded(value)
  return util.safe_message(value, {
    fallback = "sandbox execution failed",
    max_characters = 2000,
    max_source_bytes = 8000,
  })
end

---@param value string
---@return boolean
local function denial_text(value)
  value = value:lower():sub(1, 1024 * 1024)
  for _, keyword in ipairs(DENIAL_KEYWORDS) do
    if value:find(keyword, 1, true) then
      return true
    end
  end
  return false
end

---@param platform string
---@param evidence? Neoagent.ToolRpcPolicyEvidence
---@return boolean
local function denied_evidence(platform, evidence)
  if not evidence then
    return false
  end
  if evidence.denial_output and denial_text(evidence.denial_output) then
    return true
  end
  local exit = evidence.process_exit
  if platform == "linux" and exit then
    local constants = (vim.uv --[[@as {constants?: table<string, integer>}]]).constants
    local sigsys = constants and constants.SIGSYS
    return sigsys ~= nil and (exit.signal == sigsys or exit.code == 128 + sigsys)
  end
  return false
end

---@param value Neoagent.ToolResult
---@param platform string
---@param evidence? Neoagent.ToolRpcPolicyEvidence
---@return boolean
local function denied_result(value, platform, evidence)
  if value.isError ~= true and value.is_error ~= true then
    return false
  end
  for _, block in ipairs(value.content or {}) do
    if block.type == "text" and denial_text(block.text or "") then
      return true
    end
  end
  if denied_evidence(platform, evidence) then
    return true
  end
  if platform == "linux" and type(value.details) == "table" then
    local constants = (vim.uv --[[@as {constants?: table<string, integer>}]]).constants
    local sigsys = constants and constants.SIGSYS
    if sigsys and rawget(value.details, "exit_code") == 128 + sigsys then
      return true
    end
  end
  return false
end

---@param profile Neoagent.SandboxProfile
---@param source table<string, string>
---@param paths Neoagent.SandboxPaths
---@return table<string, string>
local function worker_environment(profile, source, paths)
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

---@param self Neoagent.SandboxInterceptor<unknown>
---@param ctx Neoagent.ToolContext<unknown>
---@return Neoagent.SandboxProfile
local function resolve_profile(self, ctx)
  local profile
  if self._configured_profile then
    profile = util.copy(self._configured_profile)
  else
    profile = profile_module.resolve(self._profile_source, ctx, { paths = self._paths })
  end
  if self._platform.compile then
    profile = self._platform.compile(profile, ctx, self._services)
  end
  return profile
end

---@param err Neoagent.Error
---@param profile Neoagent.SandboxProfile
---@param platform string
---@param ran_restricted? boolean
---@param evidence? Neoagent.ToolRpcPolicyEvidence
---@return Neoagent.ToolResult
local function sandbox_error(err, profile, platform, ran_restricted, evidence)
  local inherited = rawget(err, "sandbox")
  local fields = util.deep_merge(type(inherited) == "table" and inherited or nil, {
    backend = platform,
    profile = profile.id,
    kind = err.kind,
    ran_restricted = ran_restricted or nil,
  })
  if
    err.kind == "sandbox_denied"
    or err.kind == "tool" and (FILESYSTEM_DENIALS[rawget(err, "code")] or denied_evidence(platform, evidence))
  then
    fields.denied = true
    fields.can_escalate = true
    return result.sandbox(result.denied(err.message), fields)
  end
  if err.kind == "tool_timeout" then
    fields.timed_out = true
    return result.sandbox(err.message, fields)
  end
  if err.kind == "outcome_uncertain" then
    fields.outcome_uncertain = true
    local diagnostic = err.detail ~= nil and bounded(err.detail) or nil
    local message = err.message
    if diagnostic and diagnostic ~= "" then
      message = message .. "\nWorker diagnostic: " .. diagnostic
    end
    return result.sandbox(message .. "\nThe operation was not retried because its effects may be incomplete.", fields)
  end
  if
    err.kind == "sandbox_unavailable"
    or err.kind == "worker_start"
    or err.kind == "protocol"
    or err.kind == "artifact"
    or err.kind == "sandbox"
  then
    fields.unavailable = true
    local diagnostic = err.detail ~= nil and bounded(err.detail) or nil
    local message = err.message
    if diagnostic and diagnostic ~= "" then
      message = message .. "\nWorker diagnostic: " .. diagnostic
    end
    return result.sandbox(message, fields)
  end
  error(err, 0)
end

---@async
---@param self Neoagent.SandboxInterceptor<unknown>
---@param profile Neoagent.SandboxProfile
---@param call Neoagent.ToolOperationCall
---@return Neoagent.SandboxInvocation
local function open_worker(self, profile, call)
  local prepared, launch = pcall(function()
    local worker_module = require("neoagent.rpc.worker")
    local worker = worker_module.worker_file()
    local nvim = worker_module.nvim_command(self._nvim)
    local env = worker_environment(profile, self._environ(), self._paths)
    env.NEOAGENT_WORKER_FILE = worker
    local required = worker_module.bootstrap_paths(worker, nvim)
    require("neoagent.sandbox.policy").require_read(profile, required, self._paths, "bootstrap")
    return {
      argv = worker_module.argv(nvim, worker),
      bootstrap_paths = required,
      env = env,
    }
  end)
  if not prepared then
    error(util.normalize_error(launch, "worker_start"), 0)
  end
  ---@cast launch {argv: string[], bootstrap_paths: string[], env: table<string, string>}
  ---@type Neoagent.SandboxInvocation?
  local invocation
  local connection = require("neoagent.rpc.connection").new({
    on_failure = function()
      if invocation then
        invocation:dispose("restricted Tool worker channel failed")
      end
    end,
  })
  ---@type Neoagent.SandboxWorkerRequest
  local request = {
    argv = launch.argv,
    cwd = call.workspace.cwd,
    env = launch.env,
    profile = profile,
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
  }
  local start_worker = self._platform.start_worker
  assert(type(start_worker) == "function", "sandbox platform must start workers")
  ---@cast start_worker fun(request: Neoagent.SandboxWorkerRequest, services: Neoagent.SandboxExecutionServices): Neoagent.WorkerLease
  local started, lease = pcall(function()
    local value = start_worker(request, self._services)
    assert(
      type(value) == "table"
        and type(value.write) == "function"
        and type(value.close_stdin) == "function"
        and type(value.terminate) == "function"
        and type(value.wait) == "function"
        and type(value.dispose) == "function",
      "sandbox platform returned an invalid worker lease"
    )
    return value
  end)
  if not started then
    error(util.normalize_error(lease, "sandbox_unavailable"), 0)
  end
  ---@cast lease Neoagent.WorkerLease
  connection:attach(lease)
  invocation = invocation_module.new(connection, lease)
  local admitted, admission_err = pcall(function()
    if lease.wait_ready then
      lease:wait_ready()
    end
  end)
  if not admitted then
    local err = util.normalize_error(admission_err, "sandbox_unavailable")
    if err.kind == "cancelled" then
      invocation:cancel("restricted Tool worker admission cancelled")
      error(err, 0)
    end
    invocation:abort("restricted Tool worker failed platform admission")
    error(err, 0)
  end
  local opened, open_err = pcall(
    connection.open,
    connection,
    require("neoagent.rpc.codec").encode_context(call, { denial_keywords = DENIAL_KEYWORDS })
  )
  if not opened then
    local err = util.normalize_error(open_err, "worker_start")
    if err.kind == "cancelled" then
      invocation:cancel("restricted Tool worker opening cancelled")
      error(err, 0)
    end
    invocation:abort("restricted Tool worker failed to open")
    error(err, 0)
  end
  return invocation
end

---@param next_execute? Neoagent.ToolExecutor<C>
---@return Neoagent.ToolExecutor<C>
function Interceptor:wrap(next_execute)
  next_execute = next_execute or function(tool, arguments, ctx)
    return tool.execute(arguments, ctx)
  end
  assert(type(next_execute) == "function", "sandbox next executor must be a function")
  ---@async
  return function(tool, arguments, ctx)
    local registry = require("neoagent.rpc.registry")
    if not registry.resolve(tool) then
      return result.sandbox("Restricted execution is unavailable for this Tool", {
        unavailable = true,
        kind = "unsupported_tool",
        backend = self._platform.name,
      })
    end
    local profile_ok, profile = pcall(resolve_profile, self, ctx)
    if not profile_ok then
      local err = util.normalize_error(profile, "sandbox_unavailable")
      return result.sandbox(err.message, {
        unavailable = true,
        kind = err.kind,
        backend = self._platform.name,
      })
    end
    local call_ok, call = pcall(common.call, ctx)
    if not call_ok then
      local err = util.normalize_error(call, "sandbox_unavailable")
      return result.sandbox(err.message, {
        unavailable = true,
        kind = err.kind,
        backend = self._platform.name,
        profile = profile.id,
      })
    end
    local policy = require("neoagent.sandbox.api_policy").new({
      profile = profile,
      paths = self._paths,
      platform = self._platform.name,
    })
    ---@type Neoagent.SandboxInvocation?
    local invocation
    local intercepted = false
    local ran_restricted = false
    ---@type Neoagent.ToolRpcPolicyEvidence?
    local policy_evidence
    ---@async
    local function invoke(method, request_value, operation_call)
      intercepted = true
      local read_only, timeout_ms
      request_value, read_only, timeout_ms = policy:authorize(method, request_value, operation_call)
      if not invocation then
        invocation = open_worker(self, profile, call)
      end
      ran_restricted = true
      local timed_out = false
      local owner = async.current()
      if timeout_ms then
        invocation:deadline(timeout_ms, "restricted Tool execution timed out", function()
          timed_out = true
          -- A channel failure preserves validation of received responses.
          -- A deadline must also revoke a pending parent artifact import.
          invocation.connection:cancel()
          invocation.connection:abort()
        end)
      end
      local completed, value = pcall(
        require("neoagent.rpc.tool_client").invoke,
        invocation.connection,
        method,
        request_value,
        operation_call,
        function(value)
          policy_evidence = value
        end
      )
      invocation:stop_timer()
      if not completed then
        local err = util.normalize_error(value, "tool")
        if timed_out and (not owner or not owner:is_cancelled()) then
          local timeout = util.error(
            read_only and "tool_timeout" or "outcome_uncertain",
            string.format("Restricted Tool execution timed out after %g seconds", assert(timeout_ms) / 1000)
          )
          rawset(timeout, "sandbox", { timed_out = true, cause_kind = "timeout" })
          error(timeout, 0)
        end
        -- Once a mutating request is handed to RPC, a broken channel or invalid
        -- semantic result cannot establish whether its changes took effect.
        -- Keep this Tool-specific retry classification outside RpcConnection.
        if not read_only and (err.kind == "protocol" or err.kind == "artifact") then
          local uncertain = util.error("outcome_uncertain", err.message, err.detail)
          rawset(uncertain, "sandbox", { cause_kind = err.kind })
          error(uncertain, 0)
        end
        error(err, 0)
      end
      return value
    end
    local proxy, revoke = registry.proxy(tool, {
      call = call,
      invoke = invoke,
    })
    assert(proxy and revoke, "registered Tool RPC adapter could not create a proxy")
    local executed, value = pcall(next_execute, proxy, arguments, ctx)
    revoke()
    local execution_err = not executed and util.normalize_error(value, "tool") or nil
    if not invocation then
      if not execution_err then
        return value
      end
      if execution_err.kind == "cancelled" then
        error(execution_err, 0)
      end
      if intercepted then
        return sandbox_error(execution_err, profile, self._platform.name)
      end
      error(execution_err, 0)
    end
    if execution_err and execution_err.kind == "cancelled" then
      invocation:cancel("restricted Tool invocation cancellation did not settle")
      error(execution_err, 0)
    end
    local cleanup_error = invocation:close()
    if execution_err then
      return sandbox_error(execution_err, profile, self._platform.name, ran_restricted, policy_evidence)
    end
    ---@cast value Neoagent.ToolResult
    local operation_denied = denied_result(value, self._platform.name, policy_evidence)
    if cleanup_error then
      local unobserved = cleanup_error.kind == "cancelled"
      value = result.cleanup(value, cleanup_error.message, {
        backend = self._platform.name,
        profile = profile.id,
        kind = cleanup_error.kind,
        ran_restricted = ran_restricted,
        unavailable = not unobserved or nil,
        cleanup_failed = not unobserved or nil,
        cleanup_unobserved = unobserved or nil,
      })
    end
    if operation_denied then
      return result.append(value, result.SANDBOX_FAILURE, {
        ran_restricted = ran_restricted,
        backend = self._platform.name,
        profile = profile.id,
      })
    end
    return value
  end
end

---@generic C
---@param opts Neoagent.SandboxInterceptorOptions<C>
---@return Neoagent.SandboxInterceptor<C>
function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "sandbox interceptor options must be a table")
  assert(type(opts.profile) == "table" or type(opts.profile) == "function", "sandbox profile is required")
  assert(
    type(opts.platform) == "table" and type(opts.platform.start_worker) == "function",
    "sandbox platform must start workers"
  )
  local paths = opts.paths or opts.platform.paths or path_module.posix
  local configured
  if type(opts.profile) == "table" then
    configured = profile_module.validate(opts.profile, { paths = paths })
  end
  local fs = opts.fs or require("neoagent.fs")
  return setmetatable({
    _profile_source = opts.profile,
    _configured_profile = configured,
    _platform = opts.platform,
    _paths = paths,
    _environ = opts.environ or vim.fn.environ,
    _nvim = opts.nvim,
    _services = {
      fs = fs,
      nvim = opts.nvim,
      capabilities = util.copy(opts.capabilities or {}),
      start_worker = opts.start_worker,
    },
  }, Interceptor)
end

return M
