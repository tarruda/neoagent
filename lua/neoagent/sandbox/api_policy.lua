local codec = require("neoagent.rpc.codec")
local common = require("neoagent.tools.common")
local policy = require("neoagent.sandbox.policy")
local util = require("neoagent.util")

local M = {}

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
---@param path string?
---@param required 'read'|'write'
---@param call Neoagent.ToolOperationCall
local function authorize_path(self, path, required, call)
  call = common.validate_call(call)
  path = path or call.workspace.cwd
  local paths = self._paths
  local lexical = paths.is_absolute(path)
      and paths.normalize(path)
    or paths.join(call.workspace.cwd, path)
  local canonical = paths.canonical_candidate(lexical)
  local allowed, granted = policy.allows(
    self._profile,
    lexical,
    canonical,
    required,
    paths
  )
  if not allowed then
    local action = required == "read" and "Read" or "Write"
    local err = util.error(
      "sandbox_denied",
      action .. " access is denied: " .. lexical
    ) --[[@as Neoagent.SandboxApiDenial]]
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
end

---@param method string
---@param request unknown
---@param call Neoagent.ToolOperationCall
function ApiPolicy:authorize(method, request, call)
  if method == codec.methods.read_file then
    authorize_path(self, request.path, "read", call)
  elseif method == codec.methods.write_file or method == codec.methods.edit_file then
    authorize_path(self, request.path, "write", call)
  elseif method == codec.methods.shell then
    authorize_path(self, nil, "read", call)
  elseif method == codec.methods.grep or method == codec.methods.find then
    authorize_path(self, request.path, "read", call)
  end
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
