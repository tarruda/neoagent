local util = require("neoagent.util")
local path_module = require("neoagent.sandbox.path")
local result = require("neoagent.sandbox.result")

---@alias Neoagent.SandboxProfileSetting<C> Neoagent.SandboxProfileOverrides|(fun(default: Neoagent.SandboxProfile, ctx: C): Neoagent.SandboxProfile)

---@class Neoagent.SandboxSettings<C = unknown>
---@field enabled boolean
---@field profile? Neoagent.SandboxProfileSetting<Neoagent.ToolContext<C>>

---@class Neoagent.SandboxActivation: Neoagent.SandboxInfo
---@field enabled boolean
---@field active boolean

---@class Neoagent.SandboxToolset<C>
---@field tools Neoagent.Tool<C>[]
---@field execute_tool? Neoagent.ToolExecutor<C>

---@class Neoagent.SandboxComposition<C>: Neoagent.AgentToolset<C>
---@field execute_tool Neoagent.ToolExecutor<C>
---@field system_prompt? string

---@class Neoagent.SandboxCompositionOptions<C>: Neoagent.SandboxCheckServices<string>
---@field process? fun(argv: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult
---@field os? string
---@field platforms? Neoagent.SandboxPlatforms<Neoagent.ToolContext<C>>
---@field platform? Neoagent.SandboxPlatform<Neoagent.ToolContext<C>>
---@field status? Neoagent.SandboxStatus
---@field paths? Neoagent.SandboxPaths
---@field environ? fun(): table<string, string>
---@field dialogs? Neoagent.Dialogs

---@class Neoagent.SandboxRuntime<C>
---@field _active_execute? Neoagent.ToolExecutor<C>
---@field _enabled boolean
---@field _host_execute Neoagent.ToolExecutor<C>
---@field _opts Neoagent.SandboxCompositionOptions<C>
---@field _settings Neoagent.SandboxSettings<C>
---@field _status Neoagent.SandboxActivation
---@field _toolset Neoagent.SandboxToolset<C>
---@field _dialogs Neoagent.Dialogs
local Runtime = {}
Runtime.__index = Runtime

local M = {}

local sandbox_guidance_template = [[Sandboxed execution:
- Tool calls run inside a native {platform} sandbox with restricted filesystem, network, and process authority.
- Some operations the sandbox blocks fail with an explicit sandbox error. Networking command failures might fail with a different error, so always request escalation to run those.
- To run one tool call with full user authority, keep the same arguments and merge `require_escalation` and `escalation_justification` to the tool params.
- The user approves or denies each request. After a denial, continue inside the sandbox or use a different approach; do not repeat the same request.
]]

local switchable_guidance = [[Sandbox controls:
- The editor's current sandbox toggle selects native restricted or host execution for each tool call.
- Restricted operations can fail with an explicit sandbox error. Networking command failures can use a different error, so request escalation when the sandbox blocks required work.
- To request one tool call with full user authority, keep the same arguments and merge `require_escalation` and `escalation_justification` into the tool params.
- Escalation options apply only while restricted execution is active.
]]

---@param value unknown
---@return string
local function bounded(value)
  value = util.trim(tostring(value or ""):gsub("[%z\1-\31\127]", " "))
  if value == "" then
    value = "requirements check failed"
  end
  if #value > 1000 then
    value = value:sub(1, 997) .. "..."
  end
  return value
end

---@param ctx {context?: {root?: string, workspace?: {root?: string}}}
---@param paths Neoagent.SandboxPaths
---@return string
local function workspace_root(ctx, paths)
  local context = ctx and ctx.context
  local workspace = context and context.workspace or context
  local root = type(workspace) == "table" and workspace.root or nil
  if type(root) ~= "string" or root == "" then
    error(util.error("sandbox", "Sandbox requires a workspace root"), 0)
  end
  return paths.normalize(root)
end

---@param path unknown
---@param paths Neoagent.SandboxPaths
---@return string?
local function canonical_directory(path, paths)
  if type(path) ~= "string" or path == "" then
    return
  end
  local normalized = paths.normalize(path)
  local canonical = paths.realpath(normalized)
  local stat = canonical and paths.stat(canonical)
  if stat and stat.type == "directory" then
    return canonical
  end
end

---@param paths Neoagent.SandboxPaths
---@param configured? string
---@return string, string[]
local function temporary_roots(paths, configured)
  local active = canonical_directory(configured or vim.uv.os_tmpdir(), paths)
  if not active and paths == path_module.posix then
    active = canonical_directory("/tmp", paths)
  end
  if not active then
    error(util.error("sandbox", "Sandbox requires a host temporary directory"), 0)
  end
  local roots, seen = {}, {}
  local sources = { active }
  if not configured and paths == path_module.posix then
    table.insert(sources, 1, "/tmp")
  end
  for _, source in ipairs(sources) do
    local path = canonical_directory(source, paths)
    if path and not seen[path] then
      seen[path] = true
      roots[#roots + 1] = path
    end
  end
  return active, roots
end

---@generic C
---@param ctx {context?: C}
---@param paths? Neoagent.SandboxPaths
---@param temporary_root? string
---@return Neoagent.SandboxProfile
function M.default_profile(ctx, paths, temporary_root)
  paths = paths or path_module.posix
  local root = workspace_root(ctx --[[@as {context?: {root?: string, workspace?: {root?: string}}}]], paths)
  local temporary, shared_roots = temporary_roots(paths, temporary_root)
  ---@type Neoagent.SandboxFilesystemEntry[]
  local entries = {}
  if paths.key(root) ~= paths.key((assert(paths.root(root)))) then
    entries[#entries + 1] = { path = root, access = "write" }
  end
  for _, path in ipairs(shared_roots) do
    entries[#entries + 1] = { path = path, access = "write" }
  end
  entries[#entries + 1] = {
    path = paths.join(root, ".git"),
    access = "read",
  }
  ---@type string[]
  local inherited = { "HOME", "PATH", "LANG", "LC_ALL", "TERM", "USER" }
  if paths.name == "windows" then
    inherited = {
      "PATH",
      "SystemRoot",
      "WINDIR",
      "COMSPEC",
      "PATHEXT",
    }
  end
  return {
    id = "neo-workspace",
    filesystem = {
      default = "read",
      entries = entries,
    },
    network = "restricted",
    environment = {
      clear = true,
      inherit = inherited,
      set = { TMPDIR = temporary, TMP = temporary, TEMP = temporary },
    },
  }
end

---@generic C
---@param setting? Neoagent.SandboxProfileSetting<Neoagent.ToolContext<C>>
---@param paths Neoagent.SandboxPaths
---@param temporary_root? string
---@return Neoagent.SandboxProfileSource<Neoagent.ToolContext<C>>
local function profile_source(setting, paths, temporary_root)
  if setting == nil then
    return function(ctx)
      return M.default_profile(ctx, paths, temporary_root)
    end
  end
  if type(setting) == "table" then
    local override = util.copy(setting)
    return function(ctx)
      return util.deep_merge(M.default_profile(ctx, paths, temporary_root), override)
    end
  end
  assert(type(setting) == "function", "sandbox.profile must be a table or function")
  return function(ctx)
    local default = M.default_profile(ctx, paths, temporary_root)
    return setting(util.copy(default), ctx)
  end
end

---@generic C
---@param settings Neoagent.SandboxSettings<C>
local function validate_settings(settings)
  assert(type(settings) == "table" and not util.is_list(settings), "sandbox must be a table")
  for key in pairs(settings) do
    assert(key == "enabled" or key == "profile", "unsupported sandbox setting: " .. tostring(key))
  end
  assert(type(settings.enabled) == "boolean", "sandbox.enabled must be boolean")
  if settings.profile ~= nil then
    assert(
      type(settings.profile) == "table" or type(settings.profile) == "function",
      "sandbox.profile must be a table or function"
    )
  end
end

---@param name string?
---@param status? Neoagent.SandboxAvailability
---@return string
function M.warning(name, status)
  local reason = status and status.message or "sandbox requirements are unavailable"
  if status and status.stage then
    reason = status.stage .. ": " .. reason
  end
  return string.format(
    "neoagent: sandbox unavailable for %s; tool execution is blocked: %s",
    bounded(name or "Neo"),
    bounded(reason)
  )
end

---@param status Neoagent.SandboxActivation
---@return Neoagent.ToolResult
local function unavailable(status)
  return result.sandbox(
    "Sandbox unavailable; tool execution is blocked: "
      .. bounded(status.message)
      .. "\nDisable sandboxing explicitly to run tools on the host.",
    {
      unavailable = true,
      kind = "sandbox_unavailable",
      backend = status.platform,
    }
  )
end

---@param status Neoagent.SandboxActivation
---@return string
local function sandbox_guidance(status)
  local platform = type(status.platform) == "string" and status.platform ~= "" and status.platform or "workspace"
  return (sandbox_guidance_template:gsub("{platform}", platform))
end

---@generic C
---@param toolset Neoagent.SandboxToolset<C>
---@return fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): Neoagent.ToolResult
local function executor(toolset)
  if toolset.execute_tool then
    -- Expand the recursive executor alias at this generic boundary.
    return toolset.execute_tool --[[@as fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): Neoagent.ToolResult]]
  end
  return function(tool, arguments, ctx)
    return tool.execute(arguments, ctx)
  end
end

---@generic C
---@param toolset Neoagent.SandboxToolset<C>
---@return Neoagent.SandboxToolset<C>
local function copy_toolset(toolset)
  assert(type(toolset) == "table" and not util.is_list(toolset), "sandbox toolset must be an object")
  assert(type(toolset.tools) == "table" and util.is_list(toolset.tools), "sandbox toolset tools must be a list")
  assert(
    toolset.execute_tool == nil or type(toolset.execute_tool) == "function",
    "sandbox toolset executor must be a function"
  )
  return {
    tools = util.copy(toolset.tools),
    execute_tool = toolset.execute_tool,
  }
end

---@generic C
---@param toolset Neoagent.SandboxToolset<C>
---@param settings? Neoagent.SandboxSettings<C>
---@param opts? Neoagent.SandboxCompositionOptions<C>
---@return Neoagent.SandboxComposition<C>?, Neoagent.SandboxActivation, Neoagent.Dialogs?
function M.compose(toolset, settings, opts)
  toolset = copy_toolset(toolset)
  settings = util.copy(settings or { enabled = false })
  validate_settings(settings)
  if not settings.enabled then
    return nil, { enabled = false, active = false }
  end

  opts = opts or {}
  local dispatch = require("neoagent.sandbox.platform")
  local selected, status = opts.platform, opts.status
  if selected == nil and status == nil then
    selected, status = dispatch.select(opts.os, opts.platforms)
  end
  local fs = opts.fs or require("neoagent.fs")
  local process = opts.process or require("neoagent.process").run
  local services = {
    fs = fs,
    process = process,
    nvim = opts.nvim,
    system = opts.system,
    sandbox_exec = opts.sandbox_exec,
    probe_timeout_ms = opts.probe_timeout_ms,
  }
  if selected and status == nil then
    local checked, value = pcall(selected.check, services)
    status = checked and value
      or {
        ok = false,
        platform = selected.name,
        stage = "requirements",
        message = util.normalize_error(value, "sandbox_unavailable").message,
      }
  end

  local recorded = util.copy(status or {
    ok = false,
    stage = "platform",
    message = "sandbox platform is unavailable",
  }) --[[@as Neoagent.SandboxActivation]]
  recorded.enabled = true
  recorded.active = selected ~= nil and recorded.ok == true
  if not recorded.active then
    return nil, recorded
  end
  selected = assert(selected)

  local dialogs = opts.dialogs or require("neoagent.dialog").new()
  local paths = opts.paths or selected.paths or path_module.posix
  local temporary_root = type(selected.temporary_root) == "function" and selected.temporary_root(services) or nil
  ---@type Neoagent.SandboxEnforcementOptions<C>
  local enforcement_options = {
    platform = selected,
    profile = profile_source(settings.profile, paths, temporary_root),
    paths = paths,
    temporary_root = temporary_root,
    fs = fs,
    process = process,
    environ = opts.environ,
    nvim = opts.nvim,
    capabilities = recorded.capabilities,
  }
  local enforcement = require("neoagent.sandbox.enforce").new(enforcement_options)
  ---@type Neoagent.SandboxEscalationOptions<C>
  local escalation_options = { fs = fs, process = process }
  local escalation = require("neoagent.sandbox.escalation").new(escalation_options)
  local base = executor(toolset)
  local execute_tool = require("neoagent.dialog").wrap(
    dialogs,
    escalation:wrap({
      restricted = enforcement:wrap(base),
      elevated = base,
    })
  )
  ---@cast execute_tool fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): Neoagent.ToolResult
  return {
    tools = escalation:tools(toolset.tools),
    execute_tool = execute_tool,
    system_prompt = sandbox_guidance(recorded),
  },
    recorded,
    dialogs
end

---@return Neoagent.SandboxActivation
function Runtime:status()
  return util.copy(self._status)
end

---@param enabled boolean
---@return Neoagent.SandboxActivation?, Neoagent.Error?
function Runtime:set_enabled(enabled)
  assert(type(enabled) == "boolean", "sandbox state must be boolean")
  if not enabled then
    self._enabled = false
    self._status.enabled = false
    self._status.active = false
    return self:status()
  end
  self._enabled = true
  if not self._active_execute then
    local requested = util.copy(self._settings)
    requested.enabled = true
    local compose_opts = util.copy(self._opts)
    compose_opts.dialogs = self._dialogs
    local ok, composed, status = pcall(function()
      return M.compose(self._toolset, requested, compose_opts)
    end)
    if not ok then
      local err = util.normalize_error(composed, "sandbox")
      self._status = {
        enabled = true,
        active = false,
        ok = false,
        stage = "activation",
        message = err.message,
      }
      return nil, err
    end
    self._status = util.copy(status)
    if composed then
      ---@cast composed Neoagent.SandboxComposition<C>
      self._active_execute = composed.execute_tool
    end
  else
    self._status.enabled = true
    self._status.active = true
  end
  return self:status()
end

---@generic C
---@param toolset Neoagent.SandboxToolset<C>
---@param settings? Neoagent.SandboxSettings<C>
---@param opts? Neoagent.SandboxCompositionOptions<C>
---@return Neoagent.SandboxComposition<C>, Neoagent.SandboxActivation, Neoagent.Dialogs, Neoagent.SandboxRuntime<C>
function M.switchable(toolset, settings, opts)
  toolset = copy_toolset(toolset)
  settings = util.copy(settings or { enabled = false })
  assert(type(settings) == "table" and not util.is_list(settings), "sandbox must be a table")
  assert(type(settings.enabled) == "boolean", "sandbox.enabled must be boolean")
  ---@type Neoagent.SandboxCompositionOptions<C>
  opts = opts or {}
  local dialogs = opts.dialogs or require("neoagent.dialog").new()
  ---@type Neoagent.SandboxEscalationOptions<C>
  local escalation_options = { fs = opts.fs, process = opts.process }
  local escalation = require("neoagent.sandbox.escalation").new(escalation_options)
  local base = executor(toolset)
  ---@type Neoagent.SandboxRuntime<C>
  local runtime = setmetatable({
    _active_execute = nil,
    _enabled = false,
    _host_execute = escalation:bypass(base),
    _opts = opts,
    _settings = settings,
    _status = { enabled = false, active = false },
    _toolset = toolset,
    _dialogs = dialogs,
  }, Runtime)

  local stable = {
    tools = escalation:tools(toolset.tools),
    execute_tool = function(tool, arguments, ctx)
      local execute = runtime._host_execute
      if runtime._enabled then
        if not runtime._active_execute then
          return unavailable(runtime._status)
        end
        execute = runtime._active_execute
      end
      return execute(tool, arguments, ctx)
    end,
    system_prompt = #toolset.tools > 0 and switchable_guidance or nil,
  }
  if settings.enabled then
    local status, err = runtime:set_enabled(true)
    if not status then
      error(err, 0)
    end
  end
  return stable, runtime:status(), dialogs, runtime
end

---@generic C
---@param configured Neoagent.Config<C>
---@param opts? Neoagent.SandboxCompositionOptions<C>
---@return Neoagent.Config<C>, Neoagent.Dialogs?
function M.agent(configured, opts)
  assert(type(configured) == "table", "sandbox Agent configuration is required")
  opts = opts or {}
  local copied = util.copy(configured)
  local settings = copied.sandbox or { enabled = false }
  local selected_tools = copied._tools_supplied and assert(copied.tools)
    or require("neoagent.tools").coding({
      shell_timeout = copied.shell_timeout,
    }) --[[@as Neoagent.Tool<C>[] ]]
  ---@cast selected_tools Neoagent.Tool<C>[]
  local toolset, status, dialogs = M.compose({
    tools = selected_tools,
    execute_tool = copied.execute_tool,
  }, settings, opts)
  copied._sandbox_status = status
  if not settings.enabled then
    return copied
  end
  if not toolset then
    copied._sandbox_warning = M.warning(copied.name or "Neo", status)
    copied.execute_tool = function()
      return unavailable(status)
    end
    return copied
  end
  copied.tools = toolset.tools
  copied._tools_supplied = true
  copied.execute_tool = toolset.execute_tool
  copied._sandbox_system_prompt = toolset.system_prompt
  return copied, dialogs
end

return M
