local util = require("neoagent.util")
local preferences = require("neoagent.workspace_preferences")
local config = require("neoagent.config")
local RequestSelection = require("neoagent.request_selection")

local M = {}

---@param policy Neoagent.DefaultProfile
---@param selection? Neoagent.ModelSelection
---@return string
function M.choose(policy, selection)
  if type(policy) == "string" then
    assert(policy ~= "", "default_profile must identify a Profile")
    return policy
  end
  assert(type(policy) == "function", "default_profile must be a Profile ID or selector")
  local ok, selected = pcall(policy, util.copy(selection))
  if not ok then
    error("default_profile failed: " .. util.normalize_error(selected, "profile").message, 0)
  end
  assert(selected == nil or type(selected) == "string" and selected ~= "", "default_profile returned an invalid ID")
  return selected or "pi"
end

---@param configured Neoagent.Config<Neoagent.AgentToolEnvironment>
---@param auth? Neoagent.AuthManager
---@param runtimes Neoagent.ProviderRuntimes
---@param settings Neoagent.JsonObject
---@param restored? Neoagent.ModelSelection
---@param profile_id? string Explicit Profile scope; automatic selection uses the shared preference.
---@param supported_apis? string[]
---@param warnings string[]
---@return Neoagent.ModelSelection?
---@return Neoagent.Error?
local function seed(configured, auth, runtimes, settings, restored, profile_id, supported_apis, warnings)
  local contract = require("neoagent.model_config")
  ---@param value unknown
  ---@param origin? "Session"|"Workspace"
  ---@return Neoagent.ModelSelection?
  local function eligible(value, origin)
    if type(value) ~= "table" or not contract.safe_provider_id(value.provider) or not contract.safe_id(value.model) then
      return nil
    end
    local model = { provider = value.provider, model = value.model }
    if origin then
      local err
      if origin == "Session" then
        err = RequestSelection.catalog_model_error(runtimes, model, supported_apis, true)
      else
        err = RequestSelection.saved_model_error(runtimes, model, supported_apis)
      end
      if err and (origin ~= "Session" or rawget(err, "pending") ~= true) then
        local warning = ("Ignoring unavailable %s Model %s/%s: %s"):format(
          origin,
          model.provider,
          model.model,
          err.message
        )
        if not vim.tbl_contains(warnings, warning) then
          warnings[#warnings + 1] = warning
        end
        return nil
      end
    elseif RequestSelection.api_compatible(runtimes, model, supported_apis) == false then
      return nil
    end
    return model
  end
  local agents = settings and settings.agents
  local scope = type(agents) == "table" and profile_id and agents[profile_id] or nil
  local selected = eligible(restored, "Session")
    or eligible(type(scope) == "table" and scope.default_model, "Workspace")
    or eligible(settings and settings.default_model, "Workspace")
    or eligible(configured.default_model)
  if selected then
    return selected
  end
  return require("neoagent.models").first_available(configured, auth, runtimes, supported_apis)
end

---@class Neoagent.ProfileSelectionContext
---@field profiles table<string, Neoagent.Profile>
---@field policy Neoagent.DefaultProfile
---@field snapshot Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>
---@field workspace? string
---@field auth? Neoagent.AuthManager
---@field runtimes Neoagent.ProviderRuntimes

---@class Neoagent.ProfileSelectionOptions: Neoagent.ProfileSelectionContext
---@field profile_id? string
---@field model? Neoagent.ModelSelection
---@field thinking_level? Neoagent.ThinkingLevel
---@field restored_model? Neoagent.ModelSelection
---@field session? Neoagent.Session
---@field restore_session_selection? boolean
---@field overrides? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@field preference_source? Neoagent.WorkspacePreferenceSource

-- An automatic draft can still have a fixed Profile policy. Its inventory is
-- constrained independently of the scope used for Workspace preferences.
---@param context Neoagent.ProfileSelectionContext
---@param explicit? string
---@return Neoagent.Profile?
function M.constraint(context, explicit)
  local id = explicit or type(context.policy) == "string" and M.choose(context.policy) or nil
  return id and assert(context.profiles[id], "Unknown Profile: " .. id) or nil
end

-- All Profile defaults and caller/draft overrides meet here. Recipes never
-- carry a resolved configuration; the snapshot owns shared resources and the
-- caller's original precedence. An unknown automatic Profile seeds from shared
-- settings before the selected recipe contributes its defaults.
---@param snapshot Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>
---@param profile? Neoagent.Profile
---@param overrides? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@param workspace? string
---@return Neoagent.Config<Neoagent.AgentToolEnvironment>
function M.configuration(snapshot, profile, overrides, workspace)
  if overrides == nil then
    overrides = {}
  end
  local explicit = config.merge_agent_options(config.agent_options(snapshot.overrides), overrides)
  local defaults = profile and profile.defaults
  if defaults == nil then
    defaults = {}
  end
  local configured = config.extend(snapshot.config, config.merge_agent_options(defaults, explicit))
  local fs = require("neoagent.fs")
  local directory = fs.normalize(configured.persistence.directory)
  if not fs.is_absolute(directory) then
    directory = fs.join(workspace or vim.fn.getcwd(), directory)
  end
  configured.persistence.directory = fs.canonical(directory)
  return configured
end

-- Compose effective values. Selection owners resolve a runtime Model only
-- when its capabilities are needed; presentation remains lazy.
---@param input Neoagent.ProfileCompositionOptions
---@param context Neoagent.ProfileSelectionContext
---@param configured? Neoagent.Config<Neoagent.AgentToolEnvironment>
---@return Neoagent.ProfileComposition
local function compose(input, context, configured)
  local profile = input.profile
  local options = input.options
  if options == nil then
    options = {}
  end
  options = config.copy(options)
  local workspace = input.workspace or context.workspace or input.preference_source and input.preference_source.root
  configured = configured or M.configuration(context.snapshot, profile, options, workspace)
  local source = preferences.load(configured, workspace or vim.fn.getcwd(), input.preference_source)
  local remembered, issues = preferences.scope(source.settings, {
    default_model = configured.default_model,
    default_thinking_level = configured.default_thinking_level,
    ui_position = configured.ui.position,
  }, profile.id, input.automatic)
  local warnings = util.copy(source.warnings)
  if #issues > 0 and source.directory then
    local warning = preferences.warning(
      issues,
      require("neoagent.workspace_settings")
        .new({ directory = source.directory, root = source.root })
        :metadata().settings_path
    )
    warnings[#warnings + 1] = assert(warning)
  end
  if remembered.ui_position and not (options.ui and options.ui.position) then
    configured.ui.position = remembered.ui_position
  end
  if profile.create_tools == false then
    assert(not configured.tools or #configured.tools == 0, "Profile " .. profile.id .. " does not accept Tools")
    configured.tools = {}
  end
  configured.name = configured.name or profile.label
  configured.default_model = util.copy(input.model)
  configured.default_thinking_level = input.thinking_level
    or options.default_thinking_level
    or remembered.default_thinking_level
    or configured.default_thinking_level
  if configured.sandbox.enabled == nil then
    configured.sandbox.enabled = false
  end
  local factory = not configured.ui.style and not configured.ui.renderer and profile.create_renderer or nil
  configured.ui.style = configured.ui.style or "codex"
  local settings, renderer = config.ui_settings(configured.ui)
  configured.ui = settings
  local execution = profile.sandbox_controls and "switchable" or "fixed"
  return {
    profile = profile,
    config = configured,
    options = options,
    automatic = input.automatic == true,
    preference_source = source,
    warnings = warnings,
    model_error = util.copy(input.model_error),
    execution = execution,
    compaction = profile.compaction or require("neoagent.compaction").for_config(configured.compaction),
    renderer = renderer,
    renderer_factory = factory,
  }
end

---@param resolved Neoagent.ProfileComposition
---@param context Neoagent.ProfileSelectionContext
---@return Neoagent.RequestSelection
local function request_selection(resolved, context)
  return RequestSelection.new({
    config = resolved.config,
    supported_apis = resolved.profile.supported_apis,
    auth = context.auth,
    runtimes = context.runtimes,
    initial_selection = resolved.config.default_model and {
      model = resolved.config.default_model,
      thinking_level = resolved.config.default_thinking_level,
    } or nil,
    request_context = { workspace = context.workspace },
  })
end

---@param resolved Neoagent.ProfileComposition
---@param context Neoagent.ProfileSelectionContext
function M.validate(resolved, context)
  request_selection(resolved, context)
end

-- Initial seeding and edits have different precedence, but produce candidates
-- through the same configuration and selection validation boundary. Initial
-- construction remains lazy; explicit edits resolve a Model before acceptance.
---@param input Neoagent.ProfileCompositionOptions
---@param context Neoagent.ProfileSelectionContext
---@param change? 'model'|'thinking'|'cycle'
---@param configured? Neoagent.Config<Neoagent.AgentToolEnvironment>
---@return Neoagent.ProfileComposition
local function candidate(input, context, change, configured)
  local resolved = compose(input, context, configured)
  local selected = request_selection(resolved, context)
  if change then
    local value, err
    if change == "model" then
      value, err = selected:resolve()
    elseif change == "thinking" then
      value, err = selected:set_thinking_level(resolved.config.default_thinking_level)
    else
      value, err = selected:cycle_thinking_level()
    end
    if not value then
      error(err, 0)
    end
    resolved.config.default_thinking_level = selected:thinking_level() or resolved.config.default_thinking_level
    if change == "cycle" then
      resolved.options.default_thinking_level = resolved.config.default_thinking_level
    end
  end
  return resolved
end

-- Resolve identity once, before applying Profile defaults or constructing owners.
-- A supplied Model is authoritative, including when the policy rejects it.
---@param options Neoagent.ProfileSelectionOptions
---@return Neoagent.ProfileComposition
function M.resolve(options)
  local explicit = options.profile_id or options.snapshot.config.profile
  local restored = options.restored_model
  if options.session then
    local recorded, err = require("neoagent.profile_sessions").binding(options.session)
    assert(not err, err and err.message)
    assert(
      not recorded or not explicit or recorded == explicit,
      "The Session belongs to another Profile; derive a copy to change its Profile"
    )
    explicit = recorded or explicit
    if options.restore_session_selection then
      local state, state_err = options.session:state()
      assert(state, state_err and state_err.message)
      restored = state.model
    end
  end
  local constrained = M.constraint(options, explicit)
  local root = options.workspace or vim.fn.getcwd()
  local configured = M.configuration(options.snapshot, constrained, options.overrides, root)
  local source = preferences.load(configured, root, options.preference_source)
  local model = util.copy(options.model)
  local model_error
  local warnings = {}
  if not model then
    model, model_error = seed(
      configured,
      options.auth,
      options.runtimes,
      source.settings,
      restored,
      explicit,
      constrained and constrained.supported_apis,
      warnings
    )
  end
  local profile = constrained
  if not profile then
    local id = M.choose(options.policy, model)
    profile = assert(options.profiles[id], "Unknown Profile: " .. id)
  end
  assert(
    not model or RequestSelection.api_compatible(options.runtimes, model, profile.supported_apis) ~= false,
    "The selected Model is incompatible with Profile " .. profile.id
  )
  local resolved = candidate({
    profile = profile,
    options = options.overrides,
    model = model,
    thinking_level = options.thinking_level,
    automatic = explicit == nil,
    model_error = model_error,
    preference_source = source,
  }, options, nil, constrained and configured or nil)
  vim.list_extend(resolved.warnings, warnings)
  return resolved
end

---@param accepted Neoagent.ProfileComposition
---@param patch Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@param context Neoagent.ProfileSelectionContext
---@param cycle? boolean
---@return Neoagent.ProfileComposition
function M.update(accepted, patch, context, cycle)
  local profile = accepted.profile
  if
    accepted.automatic
    and patch.default_model
    and not RequestSelection.same_model(accepted.config.default_model, patch.default_model)
  then
    local constrained = M.constraint(context)
    if constrained then
      profile = constrained
    else
      local id = M.choose(context.policy, patch.default_model)
      profile = assert(context.profiles[id], "Unknown Profile: " .. id)
    end
  end
  return candidate(
    {
      profile = profile,
      options = config.merge_agent_options(accepted.options, patch),
      model = patch.default_model or accepted.config.default_model,
      thinking_level = patch.default_thinking_level
        or profile == accepted.profile and accepted.config.default_thinking_level
        or nil,
      preference_source = accepted.preference_source,
      automatic = accepted.automatic,
      model_error = not patch.default_model and accepted.model_error or nil,
    },
    context,
    cycle and "cycle" or patch.default_model and "model" or patch.default_thinking_level and "thinking" or nil
  )
end

---@param accepted Neoagent.ProfileComposition
---@param context Neoagent.ProfileSelectionContext
---@return Neoagent.ThinkingLevel[]?, Neoagent.Error?
function M.levels(accepted, context)
  return request_selection(accepted, context):levels()
end

return M
