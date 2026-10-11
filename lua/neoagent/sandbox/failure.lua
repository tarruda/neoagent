local util = require("neoagent.util")
local result = require("neoagent.sandbox.result")
local M = {}

local FILESYSTEM_DENIALS = { EACCES = true, EPERM = true, EROFS = true }

M.DENIAL_KEYWORDS = {
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
  for _, keyword in ipairs(M.DENIAL_KEYWORDS) do
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
function M.denied_result(value, platform, evidence)
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
    if sigsys and (rawget(value.details, "exit_code") == 128 + sigsys or rawget(value.details, "signal") == sigsys) then
      return true
    end
  end
  return false
end

---@param err Neoagent.Error
---@param profile Neoagent.SandboxProfile
---@param platform string
---@param ran_restricted? boolean
---@param evidence? Neoagent.ToolRpcPolicyEvidence
---@return Neoagent.ToolResult
function M.error(err, profile, platform, ran_restricted, evidence)
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

---@param value Neoagent.ToolResult
---@param authority Neoagent.JsonObject
---@param kind "command"|"interaction"
---@param observation? Neoagent.ProcessControllerState
---@param err? Neoagent.Error
---@return Neoagent.ToolResult
function M.process(value, authority, kind, observation, err)
  authority = util.copy(authority)
  if err then
    authority.kind = err.kind
    authority.denied = err.kind == "sandbox_denied" or FILESYSTEM_DENIALS[err.code] or nil
  end
  if observation then
    local outcome = observation.outcome
    local failed = observation.error ~= nil
      or outcome and (outcome.code ~= 0 or outcome.signal ~= 0 or outcome.timed_out)
    if authority.restricted and failed and (value.isError or value.is_error) then
      authority.denied = authority.denied
        or denied_evidence(tostring(authority.backend), {
          denial_output = observation.output_match,
          process_exit = outcome,
        })
        or nil
    end
  end
  if authority.restricted then
    if authority.denied then
      authority.denied, authority.can_escalate = true, true
      local guidance = kind == "command" and result.SANDBOX_FAILURE
        or "The retained command was blocked by its sandbox. To request full user authority, submit the original exec_command with escalation options. Do not retry automatically; earlier effects may have completed."
      value = result.append(value, guidance)
    end
  end
  return result.annotate(value, authority)
end

return M
