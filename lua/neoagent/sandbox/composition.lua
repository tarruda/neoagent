local util = require("neoagent.util")
local path_module = require("neoagent.sandbox.path")
local result = require("neoagent.sandbox.result")
local identities = require("neoagent.tools.identities")

---@class Neoagent.SandboxActivation: Neoagent.SandboxInfo
---@field enabled boolean
---@field active boolean

---@class Neoagent.SandboxControls
---@field status fun(self: table): Neoagent.SandboxActivation
---@field set_enabled? fun(self: table, enabled: boolean): Neoagent.SandboxActivation?, Neoagent.Error?

---@class Neoagent.SandboxCompositionOptions<C>: Neoagent.SandboxCheckServices<string>
---@field os? string
---@field platforms? Neoagent.SandboxPlatforms<Neoagent.SandboxContext<C>>
---@field platform? Neoagent.SandboxPlatform<Neoagent.SandboxContext<C>>
---@field status? Neoagent.SandboxStatus
---@field paths? Neoagent.SandboxPaths
---@field environ? fun(): table<string, string>
---@field dialogs? Neoagent.Dialogs
---@field start_worker? fun(request: Neoagent.WorkerRequest): Neoagent.WorkerLease

---@class Neoagent.SandboxRuntime<C>
---@field _active_execute? Neoagent.ToolExecutor<C>
---@field _placement? Neoagent.SandboxPlacement<Neoagent.SandboxContext<C>>
---@field _enabled boolean
---@field _host_execute Neoagent.ToolExecutor<C>
---@field _opts Neoagent.SandboxCompositionOptions<C>
---@field _settings Neoagent.SandboxSettings<C>
---@field _status Neoagent.SandboxActivation
---@field _toolset Neoagent.AgentToolset<C>
---@field _escalation Neoagent.SandboxEscalation<C>
local Runtime = {}
Runtime.__index = Runtime

local M = {}

---@generic C
---@param toolset Neoagent.AgentToolset<C>
---@param settings Neoagent.SandboxSettings<C>
---@return fun(tool: Neoagent.Tool<C>): boolean
local function parent_selector(toolset, settings)
  ---@type table<function, table<string, boolean>>
  local allowed = {}
  local function grant(tool)
    local names = allowed[tool.execute] or {}
    names[tool.name] = true
    allowed[tool.execute] = names
  end
  local selected = {}
  for _, tool in ipairs(toolset.tools) do
    local names = selected[tool.execute] or {}
    names[tool.name] = true
    selected[tool.execute] = names
  end
  for index, tool in ipairs(settings.parent_tools or {}) do
    assert(
      type(tool) == "table" and type(tool.name) == "string" and type(tool.execute) == "function",
      "sandbox.parent_tools[" .. index .. "] must be a Tool"
    )
    assert(
      selected[tool.execute] and selected[tool.execute][tool.name],
      "sandbox.parent_tools[" .. index .. "] must reference a configured Tool"
    )
    grant(tool)
  end
  return function(tool)
    if identities.is_parent(tool) then
      return true
    end
    local names = type(tool) == "table" and allowed[tool.execute] or nil
    return names ~= nil and names[tool.name] == true
  end
end

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
---@param setting? Neoagent.SandboxProfileSetting<Neoagent.SandboxContext<C>>
---@param paths Neoagent.SandboxPaths
---@param temporary_root? string
---@return Neoagent.SandboxProfileSource<Neoagent.SandboxContext<C>>
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

---@param name string?
---@param status? Neoagent.SandboxAvailability
---@return string
function M.warning(name, status)
  local reason = status and status.message or "sandbox requirements are unavailable"
  if status and status.stage then
    reason = status.stage .. ": " .. reason
  end
  return string.format(
    "neoagent: sandbox unavailable for %s; restricted tool execution is blocked: %s",
    bounded(name or "Neo"),
    bounded(reason)
  )
end

---@param status Neoagent.SandboxActivation
---@return Neoagent.ToolResult
local function unavailable(status)
  return result.sandbox(
    "Sandbox unavailable; restricted tool execution is blocked: "
      .. bounded(status.message)
      .. "\nDisable sandboxing explicitly to run tools on the host.",
    {
      unavailable = true,
      kind = "sandbox_unavailable",
      backend = status.platform,
    }
  )
end

---@generic C
---@param toolset Neoagent.AgentToolset<C>
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
---@param toolset Neoagent.AgentToolset<C>
---@return Neoagent.AgentToolset<C>
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

-- Process Tools execute in the parent, but their admission capability comes
-- from this executor's authority. Never trust the manager's independently
-- configured default placement when routing a restricted Tool call.
---@generic C
---@param base async fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): Neoagent.ToolResult
---@param select fun(ctx: Neoagent.ToolContext<C>, spec: Neoagent.SubprocessSpec): Neoagent.ProcessControllerFactory
---@param metadata Neoagent.JsonObject
---@param ordinary? async fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): Neoagent.ToolResult
---@return async fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): Neoagent.ToolResult
local function process_executor(base, select, metadata, ordinary)
  ---@generic T: table
  ---@param value T
  ---@return T
  local function shallow(value)
    local copied = {}
    for key, item in pairs(value) do
      copied[key] = item
    end
    return copied
  end
  ---@async
  return function(tool, arguments, ctx)
    local identity = identities.identity(tool)
    if not identity or identity.token ~= identities.exec_command and identity.token ~= identities.write_stdin then
      return (ordinary or base)(tool, arguments, ctx)
    end
    local context = ctx.context
    assert(type(context) == "table", "Process execution requires a Tool context")
    local owner = rawget(context, "processes")
    assert(
      type(owner) == "table" and type(owner.reserve) == "function" and type(owner.begin_interaction) == "function",
      "Process execution requires an Agent process manager"
    )
    ---@cast owner Neoagent.ProcessSessions
    local authority = util.copy(metadata)
    local kind = identity.token == identities.write_stdin and "interaction" or "command"
    ---@type (fun(): Neoagent.ProcessControllerState)?
    local inspect
    local failure = require("neoagent.sandbox.failure")
    local capability = {
      reserve = function(_, spec)
        local admission = owner:reserve(spec, function(prepared, maximum, cleanup, released)
          return select(ctx, prepared)(prepared, maximum, cleanup, released)
        end, authority)
        inspect = admission.state
        return admission
      end,
      begin_interaction = function(_, id)
        local interaction = owner:begin_interaction(id)
        authority = interaction.metadata or {}
        inspect = interaction.state
        return interaction
      end,
    }
    local forwarded = shallow(ctx)
    forwarded.context = shallow(context)
    rawset(forwarded.context, "processes", capability)
    ---@param publication Neoagent.ToolResultOwner
    forwarded.on_result = function(publication)
      local recover = assert(publication.recover, "Process result owner must recover failures")
      assert(ctx.on_result)({
        finish = publication.finish,
        recover = function(err)
          -- The Tool owns operation recovery in every composition. Add only
          -- authority and denial facts, including post-executor validation.
          return failure.process(recover(err), authority, kind, inspect and inspect(), err)
        end,
      })
    end
    local value = base(tool, arguments, forwarded)
    return failure.process(value, authority, kind, inspect and inspect())
  end
end

---@generic C
---@param toolset Neoagent.AgentToolset<C>
---@param settings Neoagent.SandboxSettings<C>
---@param opts Neoagent.SandboxCompositionOptions<C>
---@param escalation Neoagent.SandboxEscalation<C>
---@return Neoagent.ToolExecutor<C>?, Neoagent.SandboxActivation
---@return Neoagent.SandboxPlacement<Neoagent.SandboxContext<C>>?
local function compose_restricted(toolset, settings, opts, escalation)
  local dispatch = require("neoagent.sandbox.platform")
  local selected, status = opts.platform, opts.status
  if selected == nil and status == nil then
    selected, status = dispatch.select(opts.os, opts.platforms)
  end
  local fs = opts.fs or require("neoagent.fs")
  local services = {
    fs = fs,
    nvim = opts.nvim,
    system = opts.system,
    sandbox_exec = opts.sandbox_exec,
    probe_timeout_ms = opts.probe_timeout_ms,
    start_worker = opts.start_worker,
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

  local paths = opts.paths or selected.paths or path_module.posix
  local temporary_root = type(selected.temporary_root) == "function" and selected.temporary_root(services) or nil
  local placement = require("neoagent.sandbox.placement").new({
    platform = selected,
    profile = profile_source(settings.profile, paths, temporary_root),
    paths = paths,
    fs = fs,
    environ = opts.environ,
    nvim = opts.nvim,
    capabilities = recorded.capabilities,
    start_worker = opts.start_worker,
  })
  local interceptor = require("neoagent.sandbox.interceptor").new(placement)
  local base = executor(toolset)
  local restricted = process_executor(base, function(ctx, spec)
    return require("neoagent.sandbox.process_session").factory(placement, {
      context = ctx.context,
      call = ctx.call,
      process = spec,
    }, true)
  end, { restricted = true, backend = selected.name }, interceptor:wrap(base))
  -- The process adapter itself stays local; ordinary recognized Tools still
  -- execute through the interceptor. Share approval selection between them.
  local execute_tool = escalation:wrap({
    restricted = restricted,
    elevated = process_executor(base, function()
      return require("neoagent.sandbox.placement").host_process
    end, { elevated = true }),
  })
  ---@cast execute_tool fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): Neoagent.ToolResult
  return execute_tool, recorded, placement
end

---@return Neoagent.SandboxActivation
function Runtime:status()
  return util.copy(self._status)
end

---@class Neoagent.ExecutionPolicyFacts
---@field mode 'host'|'sandbox'|'blocked'|'external'
---@field platform? string
---@field filesystem? Neoagent.SandboxFilesystem
---@field network? Neoagent.SandboxNetwork
---@field dynamic_grants? boolean
---@field parent_tools string[]

---@param workspace {root: string, cwd: string}
---@return Neoagent.ExecutionPolicyFacts
function Runtime:facts(workspace)
  local parent = parent_selector(self._toolset, self._settings)
  local names = {}
  for _, tool in ipairs(self._toolset.tools) do
    if parent(tool) then
      names[#names + 1] = tool.name
    end
  end
  local status = self:status()
  local mode = not status.enabled and "host" or status.active and "sandbox" or "blocked"
  local facts = { mode = mode, platform = status.platform, parent_tools = names }
  if mode == "sandbox" then
    if type(self._settings.profile) == "function" then
      facts.dynamic_grants = true
    else
      local paths = self._opts.paths or self._placement and self._placement.paths or path_module.posix
      local placement = assert(self._placement)
      local platform = placement.platform
      local temporary_root = type(platform.temporary_root) == "function" and platform.temporary_root(placement.services)
        or nil
      local profile = require("neoagent.sandbox.profile").resolve(
        profile_source(self._settings.profile, paths, temporary_root),
        { context = { workspace = workspace } },
        { paths = paths }
      )
      facts.filesystem, facts.network = profile.filesystem, profile.network
    end
  end
  return util.copy(facts)
end

-- Select authority for this admission. Existing factories and controllers
-- retain their captured authority when the runtime toggle later changes.
---@param context Neoagent.SandboxContext<C>
---@return Neoagent.ProcessControllerFactory
function Runtime:process_factory(context)
  if not self._enabled then
    return require("neoagent.sandbox.placement").host_process
  end
  if not self._placement then
    error(
      util.error(
        "sandbox_unavailable",
        "Sandbox unavailable; retained process admission is blocked: " .. bounded(self._status.message)
      ),
      0
    )
  end
  return require("neoagent.sandbox.process_session").factory(self._placement, context)
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
    local ok, composed, status, placement = pcall(function()
      return compose_restricted(self._toolset, requested, compose_opts, self._escalation)
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
      assert(type(composed) == "function")
      ---@cast composed Neoagent.ToolExecutor<C>
      self._active_execute = composed
      self._placement = placement
    end
  else
    self._status.enabled = true
    self._status.active = true
  end
  return self:status()
end

---@generic C
---@param toolset Neoagent.AgentToolset<C>
---@param settings? Neoagent.SandboxSettings<C>
---@param opts? Neoagent.SandboxCompositionOptions<C>
---@param allow_toggle boolean
---@return Neoagent.AgentToolset<C>, Neoagent.SandboxActivation, Neoagent.Dialogs, Neoagent.SandboxRuntime<C>
local function build(toolset, settings, opts, allow_toggle)
  toolset = copy_toolset(toolset)
  settings = util.copy(settings or { enabled = false })
  require("neoagent.sandbox.settings").validate(settings)
  ---@type Neoagent.SandboxCompositionOptions<C>
  opts = opts or {}
  local dialogs = opts.dialogs or require("neoagent.dialog").new()
  local is_parent = parent_selector(toolset, settings)
  local escalation = require("neoagent.sandbox.escalation").new()
  local base = process_executor(executor(toolset), function()
    return require("neoagent.sandbox.placement").host_process
  end, { restricted = false })
  local needs_escalation = settings.enabled or allow_toggle
  ---@type Neoagent.SandboxRuntime<C>
  local runtime = setmetatable({
    _active_execute = nil,
    _enabled = false,
    _host_execute = needs_escalation and escalation:bypass(base) or base,
    _opts = opts,
    _settings = settings,
    _status = { enabled = false, active = false },
    _toolset = toolset,
    _escalation = escalation,
  }, Runtime)

  ---@async
  local function route(tool, arguments, ctx)
    if is_parent(tool) then
      return base(tool, arguments, ctx)
    end
    local execute = runtime._host_execute
    if runtime._enabled then
      if not runtime._active_execute then
        return unavailable(runtime._status)
      end
      execute = runtime._active_execute
    end
    return execute(tool, arguments, ctx)
  end
  ---@type Neoagent.SandboxControls
  local controls = {
    status = function()
      return runtime:status()
    end,
  }
  if allow_toggle then
    controls.set_enabled = function(_, enabled)
      return runtime:set_enabled(enabled)
    end
  end
  local stable = {
    tools = toolset.tools,
    execute_tool = require("neoagent.dialog").wrap(dialogs, route),
    execution_policy = function(workspace)
      return runtime:facts(workspace)
    end,
    process_placement = function(environment, spec)
      return runtime:process_factory({ context = environment, process = spec })
    end,
    sandbox = controls,
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
---@param toolset Neoagent.AgentToolset<C>
---@param settings? Neoagent.SandboxSettings<C>
---@param opts? Neoagent.SandboxCompositionOptions<C>
---@return Neoagent.AgentToolset<C>, Neoagent.SandboxActivation, Neoagent.Dialogs, Neoagent.SandboxRuntime<C>
function M.switchable(toolset, settings, opts)
  return build(toolset, settings, opts, true)
end

---@generic C
---@param toolset Neoagent.AgentToolset<C>
---@param settings? Neoagent.SandboxSettings<C>
---@param opts? Neoagent.SandboxCompositionOptions<C>
---@return Neoagent.AgentToolset<C>, Neoagent.SandboxActivation, Neoagent.Dialogs
function M.compose(toolset, settings, opts)
  local composed, status, dialogs = build(toolset, settings, opts, false)
  return composed, status, dialogs
end

return M
