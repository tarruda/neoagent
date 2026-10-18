local config = require("neoagent.config")
local provider_resources = require("neoagent.provider_resources")
local util = require("neoagent.util")
local resolution = require("neoagent.profiles.composition")

---@class Neoagent.ProfilePromptModel: Neoagent.MessageTarget
---@field context_window? number
---@field thinking_levels? Neoagent.ThinkingLevel[]
---@field native_compaction boolean

---@class Neoagent.ProfilePromptTool: Neoagent.ToolDefinition
---@field capabilities? {read_files?: boolean}
---@field prompt_snippet? string
---@field prompt_guidelines? string[]

---@class Neoagent.ProfilePromptContext
---@field workspace {cwd: string, root: string}
---@field model? Neoagent.ProfilePromptModel
---@field tools Neoagent.ProfilePromptTool[]
---@field prompt string
---@field base_prompt? string
---@field agent_instructions Neoagent.InstructionFile[]
---@field skills Neoagent.Skill[]
---@field execution_guidance? string
---@field execution_policy? Neoagent.ExecutionPolicyFacts

---@class Neoagent.PreparedProfilePrompt
---@field system_prompt string
---@field prepare_request? Neoagent.PrepareRequest

---@class Neoagent.Profile
---@field id string
---@field label string
---@field defaults? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment> Agent settings only; shared resources belong to composition.
---@field compaction? Neoagent.CompactionComponent Fixed component; omission resolves the configured local strategy.
---@field supported_apis? string[]
---@field supports_native_context? boolean
---@field create_tools? false|fun(settings: Neoagent.AgentSettings<Neoagent.AgentToolEnvironment>): Neoagent.Tool<Neoagent.AgentToolEnvironment>[] Default Tools factory; false prohibits Tools, omission supplies no defaults.
---@field prepare_prompt? fun(context: Neoagent.ProfilePromptContext): Neoagent.PreparedProfilePrompt
---@field create_renderer? fun(): Neoagent.Renderer<unknown> Alternative to defaults.ui.style or defaults.ui.renderer.
---@field sandbox_controls? boolean

---@class Neoagent.ProfileAppletContext
---@field composition Neoagent.ProfileComposition
---@field label string
---@field workspace string
---@field ui? Neoagent.UIConfigInput

---@class Neoagent.ProfileAgentContext
---@field composition Neoagent.ProfileComposition
---@field runtime Neoagent.AgentRuntimeOptions
---@field applet? Neoagent.AgentApplet Borrowed draft; ownership transfers only after binding succeeds.
---@field resources? Neoagent.ProfileResources

---@class Neoagent.ProfileSandboxState
---@field runtime Neoagent.SandboxControls
---@field status Neoagent.SandboxActivation

---@class Neoagent.ProfileRuntimeOptions
---@field transport? Neoagent.ByteBackend
---@field store? Neoagent.CatalogStorage
---@field startup? boolean
---@field interaction? fun(options: Neoagent.AgentInteractionOptions): Neoagent.ChatRun
---@field compaction_run? fun(options: Neoagent.CompactionRunOptions): Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
---@field provider_view? fun(options: Neoagent.ProviderShellViewOptions): Neoagent.ProviderShellView
---@field provider_host? Applet.HostSource<Neoagent.ProviderShellViewState>
---@field profiles? Neoagent.Profile[]

local M = {}

-- Establish the diagnostic recipient before constructing any of its producers.
-- The completed Agent takes ownership; a failed composition releases it here.
---@param runtime Neoagent.AgentRuntimeOptions
---@param construct fun(selected: Neoagent.AgentRuntimeOptions): Neoagent.Agent
---@return Neoagent.Agent
local function with_presenter(runtime, construct)
  local selected = util.shallow_copy(runtime)
  local owned = selected.presenter == nil
  local presenter = selected.presenter or require("neoagent.presenter").new()
  selected.presenter = presenter
  if owned then
    selected._owns_presenter = true
  end
  local ok, agent = pcall(construct, selected)
  if not ok then
    if owned then
      presenter:destroy()
    end
    error(agent, 0)
  end
  return agent
end

---@param context Neoagent.ProfileAppletContext
---@return Neoagent.AgentApplet
function M.create_applet(context)
  local resolved = context.composition
  local profile, configured = resolved.profile, resolved.config
  local presenter = require("neoagent.presenter").new()
  local built, applet = pcall(function()
    if resolved.model_error then
      presenter:notify({
        message = "neoagent: "
          .. resolved.model_error.message
          .. (resolved.model_error.detail and ": " .. resolved.model_error.detail or ""),
        level = vim.log.levels.ERROR,
      })
    end
    for _, warning in ipairs(resolved.warnings) do
      presenter:notify({ message = "neoagent: " .. warning, level = vim.log.levels.WARN })
    end
    local workspace = require("neoagent.fs").canonical(context.workspace)
    local selected_model = configured.default_model
    local ui = resolution.presentation(resolved, context.ui)
    local value = require("neoagent.agent_applet").new({
      config = ui.config,
      renderer = ui.renderer,
      persistence = configured.persistence,
      context = {
        model = selected_model and selected_model.provider .. "/" .. selected_model.model or "no model",
        thinking = configured.default_thinking_level,
        workspace = workspace,
        state = "idle",
      },
      profile_id = profile.id,
      label = context.label or configured.name or profile.label,
      presenter = presenter,
      owns_presenter = true,
      view = configured._view,
    })
    return value
  end)
  if not built then
    presenter:destroy()
    error(applet, 0)
  end
  return applet
end

---@param resolved Neoagent.ProfileComposition
---@param runtime Neoagent.AgentRuntimeOptions
---@return Neoagent.Agent
local function compose_agent(resolved, runtime)
  local profile, configured = resolved.profile, config.copy(resolved.config)
  local selected = util.shallow_copy(runtime)
  local presenter = assert(selected.presenter)
  local dialogs = selected.dialogs
  if not dialogs then
    dialogs = require("neoagent.dialog").new({
      report = function(message, level)
        presenter:notify({ message = message, level = level })
      end,
    })
    selected.dialogs = dialogs
    selected._owns_dialogs = true
  end
  local completed, value = pcall(
    ---@return Neoagent.Agent
    function()
      local tools = resolution.tools(resolved)
      configured.tools = tools
      ---@type Neoagent.AgentToolset<Neoagent.AgentToolEnvironment>
      local host_toolset = { tools = tools }
      local composition = require("neoagent.sandbox.composition")
      ---@type Neoagent.AgentToolset<Neoagent.AgentToolEnvironment>
      local toolset
      ---@type Neoagent.SandboxActivation?
      local status
      if resolved.execution == "switchable" then
        local composed, activation = composition.switchable(host_toolset, configured.sandbox, { dialogs = dialogs })
        toolset = composed
        status = activation
      else
        local composed, activation = composition.compose(host_toolset, configured.sandbox, { dialogs = dialogs })
        toolset, status = composed, activation
      end
      if configured.decorate_tool then
        local execute =
          require("neoagent.agent_loop").validate_toolset(toolset.tools, toolset.execute_tool).execute_tool
        local decorated = configured.decorate_tool(execute)
        assert(type(decorated) == "function", "decorate_tool must return an executor")
        toolset.execute_tool = decorated
      end
      local trust = selected.workspace_trust
      local protected = #tools > 0
        or configured.agent_instructions ~= false and #configured.agent_instructions.project_filenames > 0
        or configured.skills ~= false and #configured.skills.project_dirs > 0
      if not trust and configured.workspace_trust and protected then
        trust = require("neoagent.workspace_trust").new({
          path = configured.workspace_trust.path,
          dialogs = dialogs,
          sandbox_status = status,
          agent = selected.label or configured.name,
          notify = function(err)
            presenter:notify({ message = "neoagent: " .. err.message, level = vim.log.levels.ERROR })
          end,
        })
      elseif status and status.enabled and not status.active then
        selected.initial_warning = composition.warning(selected.label or configured.name, status)
      end
      if not selected.session then
        if selected.commit_workspace_preference == nil then
          selected.commit_workspace_preference = true
        end
        selected.session = assert(require("neoagent.profile_sessions").new({
          profile_id = profile.id,
          workspace = selected.workspace or vim.fn.getcwd(),
          persistence = configured.persistence,
        }))
      end
      local host_effects = selected.host_effects
      if host_effects == nil then
        host_effects = require("applet").host_effects
      end
      return require("neoagent.agent").from_config(configured, {
        toolset = toolset,
        session = assert(selected.session),
        auth = assert(selected.auth),
        runtimes = assert(selected.runtimes),
        web_search = require("neoagent.web_search").new({
          deepseek = function()
            return require("neoagent.web_search.deepseek").create({
              auth = assert(selected.auth),
              runtime = assert(selected.runtimes).deepseek,
            })
          end,
        }),
        presenter = presenter,
        dialogs = dialogs,
        host_effects = host_effects,
        presentation = assert(selected.presentation),
        compaction_component = selected.compaction_component or resolved.compaction,
        profile_id = profile.id,
        supported_apis = profile.supported_apis,
        prepare_prompt = profile.prepare_prompt,
        workspace_trust = trust,
        initial_warning = selected.initial_warning,
        process_sessions = selected.process_sessions,
        destroy_runtimes = selected.destroy_runtimes,
        _owns_dialogs = selected._owns_dialogs,
        _owns_presenter = selected._owns_presenter,
        applet = selected.applet,
        id = selected.id,
        automatic_profile = selected.automatic_profile,
        label = selected.label,
        initial_selection = selected.initial_selection,
        workspace_warnings = selected.workspace_warnings,
        interaction = selected.interaction,
        compaction_run = selected.compaction_run,
        workspace = selected.workspace,
        restore_session_selection = selected.restore_session_selection,
        commit_workspace_preference = selected.commit_workspace_preference,
      })
    end
  )
  if not completed then
    if selected._owns_dialogs then
      dialogs:cancel_pending("Agent construction failed", { presenter_unavailable = true })
    end
    error(value, 0)
  end
  return value
end

---@param context Neoagent.ProfileAgentContext
---@return Neoagent.Agent
function M.create_agent(context)
  local selected = util.shallow_copy(context.runtime)
  local resolved = context.composition
  local resources, applet = context.resources, context.applet
  if resources then
    selected.auth, selected.runtimes = resources.auth, resources.runtimes
    selected.interaction = resources.interaction
    selected.compaction_run = resources.compaction_run
  end
  if applet then
    selected.presenter, selected.dialogs = applet:presenter(), applet:dialogs()
  end
  selected.presentation = function(overrides)
    return resolution.presentation(resolved, overrides)
  end
  selected.workspace_warnings = resolved.warnings
  selected.automatic_profile = resolved.automatic
  selected.initial_selection = resolved.config.default_model
      and { model = util.copy(resolved.config.default_model), thinking_level = resolved.config.default_thinking_level }
    or nil
  local agent = with_presenter(selected, function(ready)
    return compose_agent(resolved, ready)
  end)
  local trust = agent:workspace_trust()
  if trust and applet then
    trust:attach({
      close = function()
        applet:close()
      end,
      on_result = function(result)
        if applet:is_destroyed() then
          return
        end
        if applet:pending_message() then
          applet:trust_submission_result(result)
        elseif result.ok then
          local prepared, err = agent:prepare()
          if not prepared and err then
            applet:presenter():notify({ message = "neoagent: " .. err.message, level = vim.log.levels.ERROR })
          end
        end
      end,
    })
  end
  return agent
end

---@param profiles Neoagent.Profile[]
---@return table<string, Neoagent.Profile>
function M.index(profiles)
  assert(type(profiles) == "table" and util.is_list(profiles), "Profiles must be a list")
  local indexed = {}
  for _, profile in ipairs(profiles) do
    assert(type(profile) == "table" and not util.is_list(profile), "Profiles must be objects")
    assert(type(profile.id) == "string" and profile.id ~= "", "Profile id must be a non-empty string")
    assert(type(profile.label) == "string" and profile.label ~= "", "Profile label must be a non-empty string")
    assert(not indexed[profile.id], "Profile ids must be unique: " .. profile.id)
    assert(
      rawget(profile, "create_agent") == nil and rawget(profile, "create_applet") == nil,
      "Profiles supply facets, not constructors"
    )
    assert(rawget(profile, "config") == nil, "Profile configuration belongs to the shared snapshot")
    assert(
      rawget(profile, "sandbox_enabled") == nil and rawget(profile, "transcript_style") == nil,
      "Profile sandbox and style defaults belong in defaults"
    )
    config.validate_agent_options(profile.defaults or {})
    assert(
      not profile.defaults or profile.defaults.default_model == nil,
      "default_model belongs to top-level selection, not Profile defaults"
    )
    if profile.supports_native_context then
      assert(
        type(profile.supported_apis) == "table" and util.is_list(profile.supported_apis) and #profile.supported_apis > 0,
        "Native context Profiles must declare supported APIs"
      )
    end
    assert(
      profile.sandbox_controls == nil or type(profile.sandbox_controls) == "boolean",
      "Profile sandbox_controls must be boolean"
    )
    assert(
      profile.create_tools == nil or profile.create_tools == false or type(profile.create_tools) == "function",
      "Profile create_tools must be a function or false"
    )
    for _, field in ipairs({ "prepare_prompt", "create_renderer" }) do
      assert(profile[field] == nil or type(profile[field]) == "function", "Profile " .. field .. " must be a function")
    end
    if profile.create_renderer then
      local ui = profile.defaults and profile.defaults.ui
      assert(not ui or not (ui.style or ui.renderer), "Profile renderer factory replaces default UI style or renderer")
    end
    if profile.compaction ~= nil then
      assert(type(profile.compaction) == "table", "Profile compaction must be a component")
      for _, field in ipairs({ "evaluate", "prepare", "run" }) do
        assert(type(profile.compaction[field]) == "function", "Profile compaction requires " .. field)
      end
    end
    indexed[profile.id] = profile
  end
  return indexed
end

---@return Neoagent.Profile[]
local function create_profiles()
  ---@type Neoagent.Profile[]
  local definitions = {
    {
      id = "pi",
      label = "Pi",
      defaults = { ui = { style = "pi" }, sandbox = { enabled = true } },
      sandbox_controls = true,
      create_tools = function(options)
        return require("neoagent.tools.pi").coding({ shell_timeout = options.shell_timeout })
      end,
      prepare_prompt = function(context)
        return require("neoagent.profiles.pi.prompt").prepare(context)
      end,
    },
    {
      id = "chat",
      label = "Chat",
      defaults = {
        name = "Chat",
        agent_instructions = false,
        skills = false,
        sandbox = { enabled = false },
      },
      create_tools = false,
      sandbox_controls = false,
      prepare_prompt = function(context)
        local instructions = require("neoagent.agent_instructions").format(context.agent_instructions)
        return {
          system_prompt = context.base_prompt or "",
          prepare_request = instructions ~= "" and function(request)
            return {
              messages = request.messages,
              system_prompt = (request.system_prompt or "") .. "\n\n" .. instructions,
            }
          end or nil,
        }
      end,
    },
    {
      id = "codex",
      label = "Codex",
      defaults = { ui = { style = "codex" }, sandbox = { enabled = true } },
      sandbox_controls = true,
      supported_apis = { "openai-responses", "openai-codex-responses" },
      supports_native_context = true,
      create_tools = function()
        return require("neoagent.tools.codex").coding()
      end,
      prepare_prompt = function(context)
        return require("neoagent.profiles.codex.prompt").prepare(context)
      end,
      compaction = require("neoagent.compaction.codex").profile_component,
    },
  }
  return definitions
end

---@param supplied? Neoagent.Profile[]
---@return Neoagent.Profile[]
local function definitions(supplied)
  local result = {}
  for _, recipe in ipairs(supplied or create_profiles()) do
    local definition = util.shallow_copy(recipe)
    definition.defaults = config.copy(recipe.defaults or {})
    definition.supported_apis = util.copy(recipe.supported_apis)
    result[#result + 1] = definition
  end
  M.index(result)
  return result
end

---@param snapshot Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>
---@param runtime Neoagent.AgentRuntimeOptions
---@return Neoagent.Agent
local function direct(snapshot, runtime)
  local configured = snapshot.config
  local selection = runtime.initial_selection and runtime.initial_selection.model or snapshot.overrides.default_model
  local explicit = configured.profile or runtime.profile_id
  local session_metadata = runtime.session and runtime.session:metadata()
  local definitions = assert(runtime.profiles)
  local choice = require("neoagent.profiles.selection").resolve({
    profiles = M.index(definitions),
    snapshot = snapshot,
    policy = configured.default_profile,
    profile_id = explicit,
    model = selection,
    thinking_level = runtime.initial_selection and runtime.initial_selection.thinking_level,
    session = runtime.session,
    restore_session_selection = runtime.restore_session_selection,
    workspace = runtime.workspace or session_metadata and session_metadata.cwd,
    auth = runtime.auth,
    runtimes = runtime.runtimes or {},
  })
  ---@type Neoagent.ProfileAgentContext
  local context = { composition = choice, runtime = runtime }
  return (M.create_agent(context))
end

---@param opts Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>?
---@param runtime Neoagent.AgentRuntimeOptions?
---@return Neoagent.Agent
function M.new(opts, runtime)
  local snapshot = config.snapshot(opts)
  local options = snapshot.config
  local selected = util.shallow_copy(runtime or {})
  selected.profiles = definitions(selected.profiles)
  return with_presenter(selected, function(ready)
    local owned
    if ready.runtimes == nil then
      local presenter = assert(ready.presenter)
      owned = provider_resources.new(options, {
        auth = ready.auth,
        transport = ready.transport,
        report = function(message, level)
          return presenter:notify({ message = message, level = level })
        end,
      })
      ready.auth, ready.runtimes = owned.auth, owned.runtimes
      ready.destroy_runtimes = function()
        owned:destroy()
      end
    end
    if ready.auth == nil then
      ready.auth = require("neoagent.auth").configured({ auth = options.auth })
    end
    local ok, agent = pcall(direct, snapshot, ready)
    if not ok then
      if owned then
        owned:destroy()
      end
      error(agent, 0)
    end
    return agent
  end)
end

---@param snapshot Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>
---@param runtime Neoagent.ProfileRuntimeOptions?
---@return Neoagent.Profile[], Neoagent.DefaultProfile, Neoagent.ProfileResources
function M.bundled(snapshot, runtime)
  local configured = snapshot.config
  assert(
    type(configured) == "table" and type(snapshot.overrides) == "table",
    "Profile configuration snapshot is required"
  )
  runtime = runtime or {}
  assert(
    type(runtime) == "table" and (next(runtime) == nil or not util.is_list(runtime)),
    "Profile runtime must be an object"
  )
  local profiles = definitions(runtime.profiles)
  ---@type [string, integer?][]
  local pending_reports = {}
  ---@type (fun(message: string, level?: integer): unknown)?
  local report_target
  ---@param message string
  ---@param level integer?
  ---@return unknown
  local function provider_report(message, level)
    if report_target then
      return report_target(message, level)
    end
    if #pending_reports < 64 then
      pending_reports[#pending_reports + 1] = { message, level }
    end
    return true
  end
  local owned = provider_resources.new(configured, {
    store = runtime.store,
    startup = runtime.startup,
    report = provider_report,
    transport = runtime.transport,
  })
  local auth, runtimes = owned.auth, owned.runtimes
  local shell_ok, shell = pcall(require("neoagent.provider_shell").new, {
    config = configured,
    auth = auth,
    runtimes = runtimes,
    view = runtime.provider_view,
    host = runtime.provider_host,
  })
  if not shell_ok then
    owned:destroy()
    error(shell, 0)
  end
  report_target = function(message, level)
    return shell:report(message, level)
  end
  for _, entry in ipairs(pending_reports) do
    report_target(entry[1], entry[2])
  end
  pending_reports = {}
  ---@class Neoagent.ProfileResources
  ---@field auth Neoagent.AuthManager
  ---@field runtimes Neoagent.ProviderRuntimes
  ---@field provider_shell Neoagent.ProviderShell
  ---@field recorder? Neoagent.Recorder
  ---@field interaction? fun(options: Neoagent.AgentInteractionOptions): Neoagent.ChatRun
  ---@field compaction_run? fun(options: Neoagent.CompactionRunOptions): Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
  ---@field destroyed boolean
  local resources = {
    auth = auth,
    runtimes = runtimes,
    provider_shell = shell,
    recorder = owned.recorder,
    interaction = runtime.interaction,
    compaction_run = runtime.compaction_run,
    destroyed = false,
  }
  function resources:destroy()
    if self.destroyed then
      return
    end
    self.destroyed = true
    self.provider_shell:destroy()
    owned:destroy()
  end
  return profiles, configured.profile or configured.default_profile, resources
end

return M
