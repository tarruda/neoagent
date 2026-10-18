local async = require("neoagent.async")
local result = require("neoagent.sandbox.result")
local common = require("neoagent.tools.common")
local util = require("neoagent.util")

local M = {}

local failure = require("neoagent.sandbox.failure")

---@class Neoagent.SandboxInterceptor<C>
---@field _placement Neoagent.SandboxPlacement<Neoagent.SandboxContext<C>>
local Interceptor = {}
Interceptor.__index = Interceptor

---@param self Neoagent.SandboxInterceptor<unknown>
---@param ctx Neoagent.ToolContext<unknown>
---@return Neoagent.SandboxProfile
local function resolve_profile(self, ctx)
  return self._placement.resolve(ctx)
end

---@async
---@param self Neoagent.SandboxInterceptor<unknown>
---@param profile Neoagent.SandboxProfile
---@param call Neoagent.ToolOperationCall
---@param owner Neoagent.Run<unknown, unknown>
---@param paths? string[]
---@return Neoagent.SandboxInvocation
local function create_worker(self, profile, call, owner, paths)
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
    local published = {}
    invocation = worker.new({
      profile = profile,
      platform = self._placement.platform,
      paths = self._placement.paths,
      services = self._placement.services,
      nvim = self._placement.nvim,
      cwd = call.workspace.cwd,
      environment = environment,
      mode = "tools",
      on_event = function(message)
        assert(
          message.name == require("neoagent.rpc.codec").events.file_changed,
          "Tool worker sent an unknown connection event"
        )
        assert(common.object(message.value), "invalid file publication event")
        common.fields(message.value, { path = true }, "file publication event")
        local path = common.absolute_path(message.value.path, "published path")
        assert(paths and vim.tbl_contains(paths, path), "worker publication is outside the prepared patch")
        assert(not published[path], "worker sent duplicate file publication")
        published[path] = true
        if call.on_file_changed then
          call.on_file_changed(path)
        end
      end,
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
    ---@param method string
    ---@param request_value table
    ---@param operation_call Neoagent.ToolOperationCall
    ---@return Neoagent.ToolResult
    local function invoke(method, request_value, operation_call)
      intercepted = true
      local read_only, timeout_ms
      request_value, read_only, timeout_ms = policy:authorize(method, request_value, operation_call)
      if not invocation then
        local started = create_worker(
          self,
          profile,
          call,
          async.current() or ctx.run,
          method == "apply_patch" and request_value.paths or nil
        )
        invocation = started
        started:open(require("neoagent.rpc.codec").encode_context(call, { denial_keywords = failure.DENIAL_KEYWORDS }))
      end
      local owned = assert(invocation)
      ran_restricted = true
      local timed_out = false
      local owner = async.current()
      if timeout_ms then
        owned:deadline(timeout_ms, "restricted Tool execution timed out", function()
          timed_out = true
          -- A channel failure preserves validation of received responses.
          -- A deadline must also revoke a pending parent artifact import.
          owned.connection:cancel()
          owned.connection:abort()
        end)
      end
      local completed, value = pcall(
        require("neoagent.rpc.tool_client").invoke,
        owned.connection,
        method,
        request_value,
        operation_call,
        function(value)
          policy_evidence = value
        end
      )
      owned:stop_timer()
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
        return failure.error(execution_err, profile, self._placement.platform.name)
      end
      error(execution_err, 0)
    end
    if execution_err and execution_err.kind == "cancelled" then
      invocation:cancel("restricted Tool invocation cancellation did not settle")
      error(execution_err, 0)
    end
    local cleanup_error = invocation:close(execution_err ~= nil)
    if execution_err then
      value = failure.error(execution_err, profile, self._placement.platform.name, ran_restricted, policy_evidence)
    end
    ---@cast value Neoagent.ToolResult
    local operation_denied = failure.denied_result(value, self._placement.platform.name, policy_evidence)
    if cleanup_error then
      local unobserved = cleanup_error.kind == "cancelled"
      local message = cleanup_error.message
      if cleanup_error.detail then
        message = message
          .. ": "
          .. util.safe_message(cleanup_error.detail, { max_characters = 2000, max_source_bytes = 8000 })
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
