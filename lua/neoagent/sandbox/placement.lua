local util = require("neoagent.util")
local profiles = require("neoagent.sandbox.profile")
local worker = require("neoagent.sandbox.worker")
local M = {}

---@class Neoagent.SandboxContext<C>
---@field context? C
---@field call? Neoagent.ToolCallBlock Present for Tool execution.
---@field process? Neoagent.SubprocessSpec Present for retained admission.

---@class Neoagent.SandboxPlacementOptions<C>
---@field profile Neoagent.SandboxProfileSource<C>
---@field platform Neoagent.SandboxPlatform<C>
---@field paths? Neoagent.SandboxPaths
---@field fs? Neoagent.SandboxFilesystemService
---@field environ? fun(): table<string, string>
---@field nvim? string|string[]
---@field capabilities? Neoagent.SandboxCapabilities
---@field start_worker? fun(request: Neoagent.WorkerRequest): Neoagent.WorkerLease

---@class Neoagent.SandboxPlacement<C>
---@field platform Neoagent.SandboxPlatform<C>
---@field paths Neoagent.SandboxPaths
---@field services Neoagent.SandboxExecutionServices
---@field nvim? string|string[]
---@field resolve fun(context: C): Neoagent.SandboxProfile
---@field environment fun(profile: Neoagent.SandboxProfile): table<string, string>

-- Both execution domains prepare authority here. Activation selects and
-- checks the platform; each admission resolves its profile and environment.
---@generic C
---@param options Neoagent.SandboxPlacementOptions<C>
---@return Neoagent.SandboxPlacement<C>
function M.new(options)
  assert(type(options) == "table", "sandbox placement options must be a table")
  assert(type(options.profile) == "table" or type(options.profile) == "function", "sandbox profile is required")
  assert(
    type(options.platform) == "table" and type(options.platform.start_worker) == "function",
    "sandbox platform must start workers"
  )
  local paths = options.paths or options.platform.paths or require("neoagent.sandbox.path").posix
  local configured = type(options.profile) == "table" and profiles.validate(options.profile, { paths = paths }) or nil
  local source, platform = options.profile, options.platform
  local services = {
    fs = options.fs or require("neoagent.fs"),
    nvim = options.nvim,
    capabilities = util.copy(options.capabilities or {}),
    start_worker = options.start_worker,
  }
  local environ = options.environ or function()
    return assert(vim.uv.os_environ())
  end
  return {
    platform = platform,
    paths = paths,
    services = services,
    nvim = options.nvim,
    resolve = function(context)
      local profile = configured and util.copy(configured) or profiles.resolve(source, context, { paths = paths })
      if platform.prepare then
        profile = platform.prepare(profile, context, services)
      end
      if platform.compile then
        profile = platform.compile(profile, context, services)
      end
      return profile
    end,
    environment = function(profile)
      return worker.environment(profile, environ(), paths)
    end,
  }
end

return M
