local common = require("neoagent.tools.common")
local policy = require("neoagent.sandbox.policy")
local util = require("neoagent.util")

local M = {}

-- The command gets its own timeout and SIGKILL grace inside the worker.
-- The parent must still bound a stopped worker or a stalled response.
local SHELL_COMPLETION_GRACE_MS = 2000

---@class Neoagent.SandboxOperationPolicy
---@field access "read"|"write"
---@field target "resolved_path"|"cwd"
---@field read_only boolean
---@field timeout_ms? integer

---@type table<string, Neoagent.SandboxOperationPolicy>
local operations = {
  read_file = { access = "read", target = "resolved_path", read_only = true, timeout_ms = 30000 },
  write_file = { access = "write", target = "resolved_path", read_only = false, timeout_ms = 30000 },
  edit_file = { access = "write", target = "resolved_path", read_only = false, timeout_ms = 30000 },
  shell = { access = "read", target = "cwd", read_only = false },
  grep = { access = "read", target = "resolved_path", read_only = true },
  find = { access = "read", target = "resolved_path", read_only = true },
}

---@class Neoagent.SandboxApiPolicyOptions
---@field profile Neoagent.SandboxProfile
---@field paths Neoagent.SandboxPaths
---@field platform string

---@class Neoagent.SandboxApiPolicy
---@field _profile Neoagent.SandboxProfile
---@field _paths Neoagent.SandboxPaths
---@field _platform string
local ApiPolicy = {}
ApiPolicy.__index = ApiPolicy

---@class Neoagent.SandboxApiDenial: Neoagent.Error
---@field sandbox Neoagent.JsonObject

---@param self Neoagent.SandboxApiPolicy
---@param path string
---@param required 'read'|'write'
---@return string
local function authorize_path(self, path, required)
  local paths = self._paths
  assert(paths.is_absolute(path), "Tool authorization target must be absolute")
  local lexical = paths.normalize(path)
  local canonical = paths.canonical_candidate(lexical)
  local allowed, granted = policy.allows(self._profile, lexical, canonical, required, paths)
  if not allowed then
    local action = required == "read" and "Read" or "Write"
    local err = util.error("sandbox_denied", action .. " access is denied: " .. lexical) --[[@as Neoagent.SandboxApiDenial]]
    err.sandbox = {
      denied = true,
      can_escalate = true,
      operation = "filesystem." .. required,
      path = lexical,
      profile = self._profile.id,
      backend = self._platform,
      granted = granted,
    }
    error(err, 0)
  end
  return lexical
end

---@param method string
---@param request unknown
---@param call Neoagent.ToolOperationCall
---@return table request
---@return boolean read_only
---@return integer? timeout_ms
function ApiPolicy:authorize(method, request, call)
  call = common.validate_call(call)
  local operation = operations[method]
  if not operation then
    error(util.error("sandbox", "Unsupported Tool RPC method"), 0)
  end
  local target = operation.target == "cwd" and call.workspace.cwd or request.resolved_path
  authorize_path(self, target, operation.access)
  local timeout_ms = operation.timeout_ms
  if method == "shell" and request.timeout_ms then
    timeout_ms = request.timeout_ms + SHELL_COMPLETION_GRACE_MS
  end
  return request, operation.read_only, timeout_ms
end

---@param opts Neoagent.SandboxApiPolicyOptions
---@return Neoagent.SandboxApiPolicy
function M.new(opts)
  assert(type(opts) == "table", "sandbox Tool RPC policy options are required")
  assert(type(opts.profile) == "table", "sandbox Tool RPC policy profile is required")
  assert(type(opts.paths) == "table", "sandbox Tool RPC policy paths are required")
  assert(type(opts.platform) == "string" and opts.platform ~= "", "sandbox Tool RPC policy platform is required")
  return setmetatable({
    _profile = opts.profile,
    _paths = opts.paths,
    _platform = opts.platform,
  }, ApiPolicy)
end

return M
