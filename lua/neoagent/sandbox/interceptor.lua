local async = require("neoagent.async")
local result = require("neoagent.sandbox.result")
local common = require("neoagent.tools.common")
local util = require("neoagent.util")

local M = {}

local FILESYSTEM_DENIALS = { EACCES = true, EPERM = true, EROFS = true }

---@class Neoagent.SandboxInterceptor<C>
---@field _placement Neoagent.SandboxPlacement<Neoagent.SandboxContext<C>>
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

---@param self Neoagent.SandboxInterceptor<unknown>
---@param ctx Neoagent.ToolContext<unknown>
---@return Neoagent.SandboxProfile
local function resolve_profile(self, ctx)
  return self._placement.resolve(ctx)
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
---@generic R, E
---@param self Neoagent.SandboxInterceptor<unknown>
---@param profile Neoagent.SandboxProfile
---@param call Neoagent.ToolOperationCall
---@param owner Neoagent.Run<R, E>
---@return Neoagent.SandboxInvocation
local function create_worker(self, profile, call, owner)
  ---@type Neoagent.SandboxInvocation?
  local invocation
  local worker = require("neoagent.sandbox.worker")
  local prepared, environment = pcall(self._placement.environment, profile)
  if not prepared then
    error(util.normalize_error(environment, "worker_start"), 0)
  end
  local release = owner:_retain_diagnostics()
  local function report(err)
    if err then
      local message = err.message
      if err.detail then
        message = message .. ": " .. util.safe_message(err.detail)
      end
      owner:_diagnose("dispose", message)
    end
    release()
  end
  local started, failure = pcall(function()
    invocation = worker.start({
      profile = profile,
      platform = self._placement.platform,
      paths = self._placement.paths,
      services = self._placement.services,
      nvim = self._placement.nvim,
      cwd = call.workspace.cwd,
      environment = environment,
      mode = "tools",
      on_failure = function()
        if invocation then
          invocation:dispose("restricted Tool worker channel failed")
        end
      end,
    }, report)
  end)
  if not started then
    release()
    error(failure, 0)
  end
  return assert(invocation)
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
        backend = self._placement.platform.name,
      })
    end
    local profile_ok, profile = pcall(resolve_profile, self, ctx)
    if not profile_ok then
      local err = util.normalize_error(profile, "sandbox_unavailable")
      return result.sandbox(err.message, {
        unavailable = true,
        kind = err.kind,
        backend = self._placement.platform.name,
      })
    end
    local call_ok, call = pcall(common.call, ctx)
    if not call_ok then
      local err = util.normalize_error(call, "sandbox_unavailable")
      return result.sandbox(err.message, {
        unavailable = true,
        kind = err.kind,
        backend = self._placement.platform.name,
        profile = profile.id,
      })
    end
    local policy = require("neoagent.sandbox.tool_policy").new({
      profile = profile,
      paths = self._placement.paths,
      platform = self._placement.platform.name,
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
        invocation = create_worker(self, profile, call, async.current() or ctx.run)
        invocation:open(require("neoagent.rpc.codec").encode_context(call, { denial_keywords = DENIAL_KEYWORDS }))
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
        return sandbox_error(execution_err, profile, self._placement.platform.name)
      end
      error(execution_err, 0)
    end
    if execution_err and execution_err.kind == "cancelled" then
      invocation:cancel("restricted Tool invocation cancellation did not settle")
      error(execution_err, 0)
    end
    local cleanup_error = invocation:close(execution_err ~= nil)
    if execution_err then
      value = sandbox_error(execution_err, profile, self._placement.platform.name, ran_restricted, policy_evidence)
    end
    ---@cast value Neoagent.ToolResult
    local operation_denied = denied_result(value, self._placement.platform.name, policy_evidence)
    if cleanup_error then
      local unobserved = cleanup_error.kind == "cancelled"
      local message = cleanup_error.message
      if cleanup_error.detail then
        message = message .. ": " .. bounded(cleanup_error.detail)
      end
      value = result.cleanup(value, message, {
        backend = self._placement.platform.name,
        profile = profile.id,
        cleanup_kind = cleanup_error.kind,
        ran_restricted = ran_restricted,
        unavailable = not unobserved or nil,
        cleanup_failed = not unobserved or nil,
        cleanup_unobserved = unobserved or nil,
      })
    end
    if operation_denied then
      return result.append(value, result.SANDBOX_FAILURE, {
        ran_restricted = ran_restricted,
        backend = self._placement.platform.name,
        profile = profile.id,
      })
    end
    return value
  end
end

---@generic C
---@param placement Neoagent.SandboxPlacement<Neoagent.SandboxContext<C>>
---@return Neoagent.SandboxInterceptor<C>
function M.new(placement)
  return setmetatable({
    _placement = placement,
  }, Interceptor)
end

return M
