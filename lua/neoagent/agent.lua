local config = require("neoagent.config")
local async = require("neoagent.async")
local context_metrics = require("neoagent.agent.context")
local provider_service = require("neoagent.provider_service")
local RequestSelection = require("neoagent.request_selection")
local session_lifecycle = require("neoagent.agent.session_lifecycle")
local util = require("neoagent.util")
local workspace_preferences = require("neoagent.workspace_preferences")

local M = {}
local next_id = 0
local ui_positions = {
  auto = true,
  left = true,
  right = true,
  top = true,
  bottom = true,
  center = true,
}

function M.from_config(options, runtime)
  assert(type(options) == "table", "agent configuration is required")
  runtime = runtime or {}
  assert(type(runtime) == "table",
    "agent runtime must be an object")
  if runtime.workspace_trust ~= nil then
    assert(type(runtime.workspace_trust) == "table"
        and type(runtime.workspace_trust.is_trusted) == "function"
        and type(runtime.workspace_trust.check) == "function",
      "agent workspace trust policy is invalid")
  end
  if runtime.runtimes ~= nil then
    assert(type(runtime.runtimes) == "table"
        and (next(runtime.runtimes) == nil or not util.is_list(runtime.runtimes)),
      "agent provider runtimes must be a keyed table")
  end
  if runtime.destroy_runtimes ~= nil then
    assert(type(runtime.destroy_runtimes) == "function",
      "agent provider runtime cleanup must be a function")
  end
  if runtime.presenter ~= nil then
    assert(type(runtime.presenter) == "table"
        and type(runtime.presenter.select) == "function"
        and type(runtime.presenter.input) == "function"
        and type(runtime.presenter.confirm) == "function"
        and type(runtime.presenter.notify) == "function"
        and type(runtime.presenter.open_uri) == "function",
      "agent Presenter is invalid")
  end
  if runtime.dialogs ~= nil then
    assert(type(runtime.dialogs) == "table"
        and type(runtime.dialogs.snapshot) == "function"
        and type(runtime.dialogs.choose) == "function"
        and type(runtime.dialogs.cancel) == "function"
        and type(runtime.dialogs.cancel_pending) == "function",
      "agent Dialog source is invalid")
  end
  if runtime.applet ~= nil then
    assert(type(runtime.applet) == "table"
        and type(runtime.applet.destroy) == "function",
      "agent Applet is invalid")
  end
  if runtime.auth ~= nil then
    assert(type(runtime.auth) == "table"
        and type(runtime.auth.resolve) == "function"
        and type(runtime.auth.login) == "function"
        and type(runtime.auth.logout) == "function",
      "agent authentication manager is invalid")
  end
  for _, field in ipairs({ "id", "profile_id", "label" }) do
    assert(runtime[field] == nil
        or type(runtime[field]) == "string" and runtime[field] ~= "",
      "agent " .. field .. " must be a non-empty string")
  end
  if runtime.initial_model ~= nil then
    assert(type(runtime.initial_model) == "table"
        and type(runtime.initial_model.provider) == "string"
        and runtime.initial_model.provider ~= ""
        and type(runtime.initial_model.model) == "string"
        and runtime.initial_model.model ~= "",
      "agent initial_model must identify a provider and model")
  end
  if runtime.host_effects ~= nil then
    assert(type(runtime.host_effects) == "table"
        and type(runtime.host_effects.refresh_file) == "function"
        and type(runtime.host_effects.on_exit) == "function",
      "agent host effects are invalid")
  end
  for _, field in ipairs({ "interaction", "compaction_run" }) do
    assert(runtime[field] == nil or type(runtime[field]) == "function",
      "agent " .. field .. " must be a function")
  end
  if runtime.session ~= nil then
    assert(type(runtime.session) == "table",
      "agent Session is invalid")
    for _, method in ipairs({
      "id", "identity", "append", "append_compaction", "messages",
      "context_messages", "entries", "entry", "leaf_id", "path",
      "state", "move_to", "snapshot", "metadata",
    }) do
      assert(type(runtime.session[method]) == "function",
        "agent Session must implement " .. method)
    end
  end
  assert(runtime.workspace == nil
      or type(runtime.workspace) == "string" and runtime.workspace ~= "",
    "agent workspace must be a non-empty string")
  assert(runtime.restore_session_selection == nil
      or type(runtime.restore_session_selection) == "boolean",
    "agent restore_session_selection must be boolean")
  assert(runtime.commit_workspace_preference == nil
      or type(runtime.commit_workspace_preference) == "boolean",
    "agent commit_workspace_preference must be boolean")
  local owns_presenter = runtime.presenter == nil
  local owns_dialogs = runtime.dialogs == nil
  local workspace_trust = runtime.workspace_trust
  local presenter = runtime.presenter or require("neoagent.presenter").new()
  local host_effects = runtime.host_effects or require("applet").host_effects
  options = util.copy(options)
  local settings_name = runtime.profile_id or options.name or "default"
  local session_metadata = runtime.session and runtime.session:metadata()
    or nil
  assert(session_metadata == nil or type(session_metadata) == "table"
      and (next(session_metadata) == nil
        or not util.is_list(session_metadata)),
    "agent Session metadata is invalid")
  local session_workspace = session_metadata and session_metadata.cwd or nil
  assert(session_workspace == nil or type(session_workspace) == "string"
      and session_workspace ~= "",
    "agent Session workspace is invalid")
  local fs = require("neoagent.fs")
  if session_workspace then session_workspace = fs.canonical(session_workspace) end
  local workspace_root = fs.canonical(
    runtime.workspace or session_workspace or vim.fn.getcwd())
  assert(not session_workspace or session_workspace == workspace_root,
    "agent Workspace must match the Session Workspace")
  local initial_session = runtime.session
  if not initial_session then
    local Session = require("neoagent.session")
    local session_err
    if options.persistence.enabled then
      local store = require("neoagent.storage").new({
        directory = options.persistence.directory,
        cwd = workspace_root,
      })
      initial_session, session_err = Session.new({ store = store })
    else
      initial_session, session_err = Session.new()
    end
    if not initial_session then error(session_err, 0) end
  end
  next_id = next_id + 1
  local agent_id = runtime.id or "agent-" .. next_id
  local profile_id = runtime.profile_id
  local agent_label = runtime.label or options.name or agent_id
  local agent = { _neoagent_agent = true }
  local state = {
    applet = runtime.applet,
    dialogs = runtime.dialogs,
    session = initial_session,
    session_id = initial_session:identity(),
    request_selection = nil,
    workspace = nil,
    workspace_settings = nil,
    workspace_model_pending = runtime.commit_workspace_preference == true
      or runtime.session == nil,
    session_selection_pending = runtime.commit_workspace_preference == true
      or runtime.session == nil,
    run = nil,
    live_usage = nil,
    provider_status = nil,
    inference_stats = nil,
    provider_runtimes = runtime.runtimes or {},
    provider_id = nil,
    provider_unsubscribes = {},
    provider_usage_release = nil,
    presentation_runs = {},
    destroy_runtimes = runtime.destroy_runtimes,
    pending_events = {},
    publication_revision = 0,
    steering = {},
    last_result = nil,
    listeners = {},
    next_listener_id = 0,
    activity_listeners = {},
    next_activity_listener_id = 0,
    attention = {},
    last_activity = nil,
    run_id = 0,
    status = "idle",
    destroyed = false,
    pending_warning = options._sandbox_warning,
    toolset = {
      tools = options._tools_supplied and util.copy(options.tools)
        or require("neoagent.tools").coding({
          shell_timeout = options.shell_timeout,
        }),
      execute_tool = options.execute_tool,
      system_prompt = options._sandbox_system_prompt,
    },
  }
  local auth_manager = runtime.auth
  if not auth_manager then
    auth_manager = require("neoagent.auth").configured(options)
  end
  state.request_selection = RequestSelection.new({
    config = options,
    auth = auth_manager,
    runtimes = state.provider_runtimes,
    initial_model = runtime.initial_model,
  })

  local function trust_cwd()
    return state.workspace and state.workspace.root or vim.fn.getcwd()
  end

  local function require_workspace_trust(cwd)
    if not workspace_trust then return true end
    local trusted, err = workspace_trust:check(cwd or trust_cwd())
    if not trusted then error(err, 0) end
    return true
  end

  local function report(message, level)
    return presenter:notify({
      message = message,
      level = level or vim.log.levels.INFO,
    })
  end


  local function notify(message, level)
    return report("neoagent: " .. message, level)
  end

  state.dialogs = state.dialogs or require("neoagent.dialog").new({
    report = function(message, level) report(message, level) end,
  })

  local function track_presentation(run, callback)
    local token = {}
    local tracked = async.run(function()
      return run:await()
    end, {
      error_kind = "presentation",
      on_done = function(result)
        state.presentation_runs[token] = nil
        callback(result)
      end,
    })
    state.presentation_runs[token] = tracked
    return tracked
  end

  local function present_value(kind, request, callback)
    local run = presenter[kind](presenter, request)
    local function completed(result)
      if state.destroyed then return end
      if result.ok then
        callback(result.value)
      elseif result.error.kind ~= "cancelled" then
        notify(result.error.message, vim.log.levels.ERROR)
      end
    end
    if run:is_done() then
      completed(run:result())
      return run
    end
    return track_presentation(run, completed)
  end

  local function present_model_choices(choices, callback)
    local models = require("neoagent.models")
    local function items(values)
      return vim.tbl_map(function(value)
        return { id = value, label = value, value = value }
      end, values)
    end
    local run, update = presenter:select({
      prompt = "Select model:",
      items = items(choices),
    })
    local unsubscribe
    local function completed(result)
      if unsubscribe then unsubscribe() unsubscribe = nil end
      if state.destroyed then return end
      if result.ok then
        callback(result.value)
      elseif result.error.kind ~= "cancelled" then
        notify(result.error.message, vim.log.levels.ERROR)
      end
    end
    if run:is_done() then
      completed(run:result())
      return run
    end
    local tracked = track_presentation(run, completed)
    if type(update) == "function" then
      unsubscribe = models.subscribe_available(
        options, auth_manager, state.provider_runtimes,
        function(updated, err)
          if err then
            notify(err.message, vim.log.levels.ERROR)
            return
          end
          local ok, changed, update_err = pcall(update, items(updated))
          if not ok then
            notify("model selector update failed: " .. tostring(changed),
              vim.log.levels.ERROR)
          elseif changed == nil and update_err then
            notify("model selector update failed: "
              .. util.normalize_error(update_err, "presentation").message,
              vim.log.levels.ERROR)
          end
        end)
    end
    return tracked
  end

  local function configured()
    return options
  end

  local bind_provider
  local provider_event

  local function model_service()
    local selected = state.request_selection:model_selection()
    local runtime = selected and state.provider_runtimes[selected.provider]
      or nil
    return runtime and runtime.service or nil
  end

  local function unbind_provider()
    for _, unsubscribe in ipairs(state.provider_unsubscribes) do
      local ok, err = pcall(unsubscribe)
      if not ok then
        notify("provider unsubscribe failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
    state.provider_unsubscribes = {}
    state.provider_id = nil
  end

  local function activity_snapshot()
    local attention = state.attention.dialog or state.attention.presentation
    if attention then
      return {
        state = "waiting",
        detail = attention.label,
        attention = util.copy(attention),
      }
    end
    local working = state.status ~= "idle"
      or state.run ~= nil
    if working then
      return {
        state = "working",
        detail = state.provider_status or state.status,
        attention = false,
      }
    end
    return { state = "idle", attention = false }
  end

  local function publish_activity()
    local value = activity_snapshot()
    if state.last_activity and vim.deep_equal(state.last_activity, value) then
      return false
    end
    state.last_activity = util.copy(value)
    for _, listener in pairs(state.activity_listeners) do
      local ok, err = pcall(listener, util.copy(value))
      if not ok then
        notify("agent activity listener failed: " .. tostring(err),
          vim.log.levels.ERROR)
      end
    end
    return true
  end

  local function publish(update)
    state.publication_revision = state.publication_revision + 1
    local publication = util.copy(update)
    publication.revision = state.publication_revision
    for _, listener in pairs(state.listeners) do
      local ok, err = pcall(listener, util.copy(publication))
      if not ok then notify("agent listener failed: " .. tostring(err), vim.log.levels.ERROR) end
    end
    publish_activity()
  end

  local function model_label()
    return state.request_selection:label()
  end

  local function preference_defaults()
    local options = configured()
    return {
      default_model = options.default_model,
      default_thinking_level = options.default_thinking_level,
      ui_position = options.ui.position,
    }
  end

  local function preferences()
    return state.request_selection:preferences()
  end

  local function scoped_workspace_settings(settings, warn)
    local accepted, issues = workspace_preferences.scope(
      settings, preference_defaults(), settings_name)
    if warn then
      local path = state.workspace_settings:metadata().settings_path
      local warning = workspace_preferences.warning(issues, path)
      if warning then notify(warning, vim.log.levels.WARN) end
    end
    return accepted
  end

  local function workspace_patch(patch)
    return workspace_preferences.patch(settings_name, patch)
  end

  local function save_workspace_settings(patch)
    local persistence = configured().persistence
    if not state.workspace_settings or not persistence.workspace_settings then return true end
    local saved, err = state.workspace_settings:update(workspace_patch(patch))
    if not saved then return nil, err end
    state.request_selection:set_workspace_preferences(
      scoped_workspace_settings(saved, false))
    return true
  end

  local function activate_workspace(cwd)
    local root = require("neoagent.fs").canonical(cwd)
    if state.workspace then
      assert(state.workspace.root == root, "Agent Workspace is immutable")
      return
    end
    state.workspace = require("neoagent.workspace").new({ root = root, cwd = root })
    state.workspace_settings = nil
    state.request_selection:set_workspace_preferences({})
    state.request_selection:clear()
    state.live_usage, state.provider_status, state.inference_stats = nil, nil, nil
    unbind_provider()
    local options = configured().persistence
    if not options.enabled then return end
    state.workspace_settings = require("neoagent.workspace_settings").new({
      directory = options.directory,
      root = root,
    })
    if not options.workspace_settings then return end
    local settings, settings_err = state.workspace_settings:load()
    if not settings then
      local path = state.workspace_settings:metadata().settings_path
      notify(settings_err.message
        .. (settings_err.detail and ": " .. settings_err.detail or "")
        .. "; the file may be outdated, update or delete " .. path,
      vim.log.levels.WARN)
      return
    end
    state.request_selection:set_workspace_preferences(
      scoped_workspace_settings(settings, true))
  end

  local function ensure_session()
    return state.session
  end

  local function transcript_messages(session)
    return session_lifecycle.transcript_messages(session)
  end

  local function sync_tools()
    if not state.session_id then return end
    local messages = state.session and state.session:messages() or {}
    local hook_context = { session_id = state.session_id }
    for _, tool in ipairs(state.toolset.tools) do
      if type(tool.on_messages) == "function" then
        local ok, err = pcall(
          tool.on_messages, util.copy(messages), hook_context)
        if not ok then
          notify("tool " .. tostring(tool.name)
            .. " failed to read the session: " .. tostring(err),
            vim.log.levels.ERROR)
        end
      end
    end
  end

  local function publish_messages(messages)
    sync_tools()
    publish({ type = "messages", messages = messages })
  end

  local function commit_model_preference()
    state.session_selection_pending = false
    if not state.workspace_model_pending then return true end
    local selected = state.request_selection:model_selection()
    if not selected then
      return nil, util.error("model", "No model is selected")
    end
    local overrides = state.request_selection:workspace_preferences()
    local level = state.request_selection:thinking_level()
    local same_thinking = overrides.default_thinking_level == level
    if RequestSelection.same_model(
        overrides.default_model, selected) and same_thinking then
      state.workspace_model_pending = false
      return true
    end
    local saved, err = save_workspace_settings({
      default_model = selected,
      default_thinking_level = level,
    })
    if not saved then return nil, err end
    state.workspace_model_pending = false
    return true
  end

  local function first_available_model()
    local selected, err = require("neoagent.models").first_available(
      options, auth_manager, state.provider_runtimes)
    if err then error(err, 0) end
    return selected
  end

  local function configured_catalog_pending(selected)
    local configured_default = preference_defaults().default_model
    if not RequestSelection.same_model(selected, configured_default) then
      return false
    end
    local runtime = state.provider_runtimes[selected.provider]
    return type(runtime) == "table"
      and type(runtime.definition) == "table"
      and type(runtime.definition.catalog) == "table"
      and type(runtime.definition.catalog.discover) == "function"
      and runtime.catalog:snapshot().models[selected.model] == nil
  end

  local function ensure_model()
    require_workspace_trust()
    if state.request_selection:model() then
      return state.request_selection:model()
    end
    if not state.workspace then activate_workspace(workspace_root) end
    local selected = state.request_selection:candidate()
    if not selected then selected = first_available_model() end
    if not selected then error("No models are configured") end
    local model, resolve_err = state.request_selection:resolve(selected)
    if not model then
      local overrides = state.request_selection:workspace_preferences()
      local workspace_default = overrides.default_model
      local configured_default = preference_defaults().default_model
      local uses_workspace_default = workspace_default ~= nil
        and RequestSelection.same_model(selected, workspace_default)
      if uses_workspace_default then
        overrides.default_model = nil
        state.request_selection:set_workspace_preferences(overrides)
        local fallback_selection = configured_default
        if not fallback_selection
            or RequestSelection.same_model(
              workspace_default, fallback_selection) then
          fallback_selection = first_available_model()
        end
        local fallback_available = fallback_selection ~= nil
          and not RequestSelection.same_model(
            workspace_default, fallback_selection)
        if fallback_available then
          local fallback_model, fallback_err =
            state.request_selection:resolve(fallback_selection)
          if not fallback_model then error(fallback_err, 0) end
          selected, model = fallback_selection, fallback_model
        else
          notify("ignoring unavailable workspace model "
            .. selected.provider .. "/" .. selected.model, vim.log.levels.WARN)
          error("No models are configured")
        end
        notify("ignoring unavailable workspace model "
          .. workspace_default.provider .. "/" .. workspace_default.model,
          vim.log.levels.WARN)
      else
        error(resolve_err, 0)
      end
    end
    bind_provider(selected.provider)
    return model
  end

  local function system_prompt(value, tools)
    require_workspace_trust()
    local options = configured()
    local instructions_result = { files = {}, diagnostics = {} }
    if options.agent_instructions then
      instructions_result = require("neoagent.agent_instructions").discover({
        cwd = state.workspace.root,
        global_files = options.agent_instructions.global_files,
        project_filenames = options.agent_instructions.project_filenames,
      })
    end
    local has_read = false
    for _, tool in ipairs(tools) do
      if type(tool.capabilities) == "table" and tool.capabilities.read_files == true then
        has_read = true
        break
      end
    end
    local skills_result = options.skills and has_read and require("neoagent.skills").discover({
      cwd = state.workspace.root,
      global_dirs = options.skills.global_dirs,
      project_dirs = options.skills.project_dirs,
    }) or { skills = {}, diagnostics = {} }
    for _, diagnostic in ipairs(vim.list_extend(
        instructions_result.diagnostics, skills_result.diagnostics)) do
      notify(diagnostic.message .. ": " .. diagnostic.path, vim.log.levels.WARN)
    end
    local context = {
      session = state.session,
      model = state.request_selection:model(),
      workspace = state.workspace,
      prompt = value,
      tools = tools,
      agent_instructions = instructions_result.files,
      skills = skills_result.skills,
    }
    local prompt = options.system_prompt
    if type(prompt) == "function" then
      prompt = prompt(context)
    elseif prompt == nil then
      prompt = require("neoagent.system_prompt").default(context)
    end
    local composed = require("neoagent.system_prompt").compose(prompt, context)
    local guidance = state.toolset.system_prompt
    if type(guidance) == "string" and guidance ~= "" then
      composed = composed .. "\n\n" .. guidance
    end
    return composed
  end

  local function copy_toolset(value)
    assert(type(value) == "table" and not util.is_list(value),
      "toolset must be an object")
    assert(type(value.tools) == "table" and util.is_list(value.tools),
      "toolset.tools must be a list")
    assert(value.execute_tool == nil or type(value.execute_tool) == "function",
      "toolset.execute_tool must be a function")
    assert(value.system_prompt == nil or type(value.system_prompt) == "string",
      "toolset.system_prompt must be a string")
    return {
      tools = util.copy(value.tools),
      execute_tool = value.execute_tool,
      system_prompt = value.system_prompt,
    }
  end

  local function refresh_buffer(path)
    local absolute = state.workspace and state.workspace:resolve(path)
    if not absolute then return end
    local ok, result = pcall(host_effects.refresh_file, absolute)
    if not ok then
      notify("failed to refresh changed file: " .. tostring(result),
        vim.log.levels.ERROR)
      return
    end
    for _, name in ipairs(result.modified or {}) do
      notify("did not reload modified buffer " .. name, vim.log.levels.WARN)
    end
    for _, err in ipairs(result.failures or {}) do
      notify("failed to reload changed buffer: " .. tostring(err),
        vim.log.levels.ERROR)
    end
  end

  local function context()
    return {
      name = options.name or false,
      model = model_label(),
      thinking = state.request_selection:thinking_level() or false,
      workspace = state.workspace and state.workspace.root or nil,
      position = preferences().ui_position,
      state = state.status,
      context_usage = context_metrics.display(state.session,
        state.request_selection:model(), state.live_usage),
      provider_status = state.provider_status or false,
      inference_stats = state.inference_stats or false,
      steering = vim.tbl_map(function(message) return message.text end, state.steering),
    }
  end

  local function update_context()
    publish({ type = "context", context = context() })
  end

  bind_provider = function(provider_id)
    local runtime = provider_id and state.provider_runtimes[provider_id] or nil
    local service = runtime and runtime.service or nil
    local catalog = runtime and runtime.catalog or nil
    if not service or type(catalog) ~= "table"
        or type(catalog.subscribe) ~= "function" then
      unbind_provider()
      return
    end
    local validated, err = provider_service.validate(service)
    if not validated then
      notify("provider service for " .. provider_id .. " is invalid: "
        .. (err and err.message or "invalid Provider Service"),
        vim.log.levels.ERROR)
      unbind_provider()
      return
    end
    if state.provider_id == provider_id then
      return
    end
    unbind_provider()
    state.provider_id = provider_id
    local function changed()
      util.schedule(function()
        if state.destroyed or state.provider_id ~= provider_id then return end
        local selected = state.request_selection:model_selection()
        if not state.request_selection:model() and selected
            and selected.provider == provider_id
            and catalog:snapshot().models[selected.model] ~= nil then
          local resolved, resolve_err = pcall(ensure_model)
          if not resolved then
            resolve_err = util.normalize_error(resolve_err, "model")
            notify("could not resolve " .. selected.provider .. "/"
              .. selected.model .. ": " .. resolve_err.message,
              vim.log.levels.ERROR)
          end
        end
        update_context()
      end)
    end
    local catalog_ok, catalog_unsubscribe = pcall(
      catalog.subscribe, catalog, changed)
    if not catalog_ok then
      notify("model catalog subscription failed: "
        .. tostring(catalog_unsubscribe), vim.log.levels.ERROR)
    elseif type(catalog_unsubscribe) == "function" then
      state.provider_unsubscribes[#state.provider_unsubscribes + 1] =
        catalog_unsubscribe
    end
    if type(service.subscribe) == "function" then
      local ok, unsubscribe = pcall(service.subscribe, service, changed)
      if not ok then
        notify("provider subscription failed: " .. tostring(unsubscribe),
          vim.log.levels.ERROR)
      elseif type(unsubscribe) == "function" then
        state.provider_unsubscribes[#state.provider_unsubscribes + 1] =
          unsubscribe
      end
    end
    update_context()
  end

  provider_event = function(event)
    local service = model_service()
    if service and type(service.on_event) == "function" then
      pcall(service.on_event, service, util.copy(event))
    end
  end

  local sessions = session_lifecycle.new({
    state = state,
    workspace = workspace_root,
    restore_selection = runtime.restore_session_selection == true,
    notify = notify,
    publish_messages = publish_messages,
    update_context = update_context,
    require_workspace_trust = require_workspace_trust,
    activate_workspace = activate_workspace,
    ensure_model = ensure_model,
    preferences = preferences,
    request_selection = state.request_selection,
    bind_provider = bind_provider,
  })
  local initialized, initialize_err = sessions.initialize()
  if not initialized then error(initialize_err, 0) end

  local runs = require("neoagent.agent.run_lifecycle").new({
    state = state,
    config = options,
    notify = notify,
    publish = publish,
    publish_messages = publish_messages,
    update_context = update_context,
    sync_tools = sync_tools,
    transcript_messages = transcript_messages,
    require_workspace_trust = require_workspace_trust,
    ensure_session = ensure_session,
    ensure_model = ensure_model,
    commit_model_preference = commit_model_preference,
    copy_toolset = copy_toolset,
    system_prompt = system_prompt,
    refresh_buffer = refresh_buffer,
    provider_event = provider_event,
    interaction = runtime.interaction,
    compaction_run = runtime.compaction_run,
    acquire_provider = function()
      local service = model_service()
      if not service then return function() end end
      local release, err = provider_service.acquire(service)
      if not release then error(err, 0) end
      return release
    end,
  })

  function agent:prepare()
    local ok, err = pcall(function()
      if state.pending_warning then
        local warning = state.pending_warning
        state.pending_warning = nil
        report(warning, vim.log.levels.WARN)
      end
      if not state.workspace then activate_workspace(workspace_root) end
      if workspace_trust then
        local trusted = workspace_trust:is_trusted(state.workspace.root)
        if not trusted then
          workspace_trust:request(state.workspace.root)
          update_context()
          return
        end
      end
      local selected = state.request_selection:candidate()
      if selected then
        if configured_catalog_pending(selected) then
          state.request_selection:stage(
            selected, configured().default_thinking_level)
          bind_provider(selected.provider)
        else
          ensure_model()
        end
      elseif first_available_model() then
        ensure_model()
      end
      update_context()
    end)
    if not ok then
      err = util.normalize_error(err, "agent")
      notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    return true
  end

  function agent:send(text)
    return runs.send(text)
  end

  function agent:steer(text)
    return runs.steer(text)
  end

  function agent:dequeue_steering()
    return runs.dequeue_steering()
  end

  function agent:compact(instructions)
    return runs.compact(instructions)
  end

  function agent:stop()
    return runs.stop()
  end

  function agent:branch(entry_id)
    return sessions.branch(entry_id)
  end
  function agent:select_branch(on_selected)
    if not state.session then notify("no active session") return nil end
    local entries = state.session:entries()
    local current = state.session:leaf_id()
    local choices = {}
    for _, entry in ipairs(entries) do
      if entry.type == "message" or entry.type == "compaction" then
        choices[#choices + 1] = {
          id = entry.id,
          label = session_lifecycle.entry_label(entry, current),
        }
      end
    end
    if #choices == 0 then notify("the active session has no entries") return nil end
    present_value("select", {
      prompt = "Branch",
      items = choices,
    }, function(entry_id)
      local moved = agent:branch(entry_id)
      if moved and on_selected then on_selected(entry_id) end
    end)
    return true
  end

  function agent:select_model(on_selected)
    local trusted, trust_err = pcall(require_workspace_trust)
    if not trusted then
      trust_err = util.normalize_error(trust_err, "workspace_trust")
      notify(trust_err.message, vim.log.levels.ERROR)
      return nil, trust_err
    end
    if state.run then notify("cannot change model while the agent is running", vim.log.levels.WARN) return nil end
    local choices, err = require("neoagent.models").available(
      options, auth_manager, state.provider_runtimes)
    if not choices then
      notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.ERROR)
      return nil
    end
    if #choices == 0 then notify("no models configured") return nil end
    present_model_choices(choices, function(choice)
      local provider_id, model_id = choice:match("^([^/]+)/(.+)$")
      if provider_id then
        local model = agent:set_model(provider_id, model_id)
        if model and on_selected then on_selected(model) end
      end
    end)
    return true
  end

  function agent:set_model(provider_id, model_id)
    if state.run then notify("cannot change model while the agent is running", vim.log.levels.WARN) return nil end
    local trusted, trust_err = pcall(require_workspace_trust)
    if not trusted then
      trust_err = util.normalize_error(trust_err, "workspace_trust")
      notify(trust_err.message, vim.log.levels.ERROR)
      return nil, trust_err
    end
    if not state.workspace then activate_workspace(workspace_root) end
    local model, model_err = state.request_selection:select(
      provider_id, model_id, configured().default_thinking_level)
    if not model then
      notify(model_err.message, vim.log.levels.ERROR)
      return nil, model_err
    end
    state.live_usage, state.provider_status, state.inference_stats = nil, nil, nil
    bind_provider(provider_id)
    update_context()
    return model
  end

  function agent:available_thinking_levels()
    local ok, model = pcall(ensure_model)
    if not ok then return nil, util.normalize_error(model, "model") end
    return state.request_selection:levels()
  end

  function agent:get_thinking_level()
    return state.request_selection:thinking_level()
  end

  function agent:set_thinking_level(level)
    if state.run then notify("cannot change thinking level while the agent is running", vim.log.levels.WARN) return nil end
    local selected, err = state.request_selection:set_thinking_level(level)
    if not selected then
      notify(err.message, err.message:match("not supported")
        and vim.log.levels.WARN or vim.log.levels.ERROR)
      return nil, err
    end
    update_context()
    return selected
  end

  function agent:cycle_thinking_level()
    if state.run then notify("cannot change thinking level while the agent is running", vim.log.levels.WARN) return nil end
    local ok, model = pcall(ensure_model)
    if not ok then notify(util.normalize_error(model, "model").message, vim.log.levels.ERROR) return nil end
    local level, err = state.request_selection:cycle_thinking_level()
    if not level then
      notify(err.message, vim.log.levels.WARN)
      return nil, err
    end
    update_context()
    notify("thinking level: " .. level)
    return level
  end

  function agent:set_ui_position(position)
    if not ui_positions[position] then return nil, util.error("ui", "invalid window position") end
    if not state.workspace then activate_workspace(workspace_root) end
    local saved, err = save_workspace_settings({ ui_position = position })
    if not saved then return nil, err end
    local overrides = state.request_selection:workspace_preferences()
    overrides.ui_position = position
    state.request_selection:set_workspace_preferences(overrides)
    update_context()
    return position
  end

  function agent:id() return agent_id end
  function agent:profile_id() return profile_id end
  function agent:label() return agent_label end
  function agent:applet() return state.applet end

  function agent:attach_applet(applet)
    assert(not state.destroyed, "Agent is destroyed")
    assert(type(applet) == "table"
        and type(applet.destroy) == "function",
      "agent Applet is invalid")
    assert(state.applet == nil or state.applet == applet,
      "Agent already owns an Applet")
    state.applet = applet
    return applet
  end

  function agent:detach_applet(applet)
    assert(not state.destroyed, "Agent is destroyed")
    assert(state.applet == applet,
      "Agent Applet is not owned by the caller")
    state.applet = nil
    return applet
  end

  function agent:set_attention(source, value)
    assert(source == "dialog" or source == "presentation",
      "attention source must be dialog or presentation")
    if value == nil or value == false then
      state.attention[source] = nil
    else
      assert(type(value) == "table"
          and (value.kind == "dialog" or value.kind == "input"
            or value.kind == "select" or value.kind == "notice")
          and type(value.label) == "string" and value.label ~= "",
        "Agent attention is invalid")
      state.attention[source] = {
        kind = value.kind,
        label = value.label:sub(1, 160),
      }
    end
    publish_activity()
    return activity_snapshot()
  end

  function agent:activity()
    return util.copy(activity_snapshot())
  end

  function agent:summary()
    return {
      id = agent_id,
      profile_id = profile_id,
      session_id = state.session:id(),
      label = agent_label,
      workspace = state.workspace and state.workspace.root or nil,
      model = model_label(),
      activity = activity_snapshot(),
    }
  end

  function agent:subscribe_activity(listener)
    assert(type(listener) == "function",
      "agent activity listener must be a function")
    state.next_activity_listener_id = state.next_activity_listener_id + 1
    local id = state.next_activity_listener_id
    state.activity_listeners[id] = listener
    local ok, err = pcall(listener, agent:activity())
    if not ok then
      state.activity_listeners[id] = nil
      error(err, 0)
    end
    local subscribed = true
    return function()
      if not subscribed then return end
      subscribed = false
      state.activity_listeners[id] = nil
    end
  end

  function agent:subscribe(listener)
    assert(type(listener) == "function", "agent listener must be a function")
    state.next_listener_id = state.next_listener_id + 1
    local id = state.next_listener_id
    state.listeners[id] = listener
    local subscribed = true
    return function()
      if not subscribed then return end
      subscribed = false
      state.listeners[id] = nil
    end
  end

  function agent:snapshot()
    local messages = state.session and transcript_messages(state.session) or {}
    sync_tools()
    return {
      revision = state.publication_revision,
      messages = messages,
      context = context(),
      events = util.copy(state.pending_events),
      result = util.copy(state.last_result),
    }
  end

  function agent:get_session() return state.session end
  function agent:get_model() return state.request_selection:model() end
  function agent:get_model_selection()
    return state.request_selection:model_selection()
  end
  function agent:get_workspace() return state.workspace end
  function agent:dialogs() return state.dialogs end

  function agent:get_toolset()
    return copy_toolset(state.toolset)
  end

  function agent:set_toolset(value)
    if state.run then
      local err = util.error("agent",
        "Cannot change tools while the agent is running")
      notify(err.message, vim.log.levels.WARN)
      return nil, err
    end
    local selected = copy_toolset(value)
    local previous = copy_toolset(state.toolset)
    state.toolset = selected
    if state.session then
      publish_messages(transcript_messages(state.session))
    end
    return previous
  end

  function agent:config() return util.copy(options) end
  function agent:presenter() return presenter end
  function agent:is_running() return state.run ~= nil end
  function agent:is_destroyed() return state.destroyed end

  function agent:destroy()
    if state.destroyed then return end
    state.destroyed = true
    state.run_id = state.run_id + 1
    if state.run then state.run:cancel() end
    for _, run in pairs(state.presentation_runs) do run:cancel() end
    if state.provider_usage_release then state.provider_usage_release() end
    unbind_provider()
    local destroy_runtimes = state.destroy_runtimes
    state.destroy_runtimes = nil
    if destroy_runtimes then pcall(destroy_runtimes) end
    state.run = nil
    state.presentation_runs = {}
    state.provider_usage_release = nil
    local applet = state.applet
    state.applet = nil
    if applet then pcall(applet.destroy, applet) end
    if owns_dialogs then
      pcall(state.dialogs.cancel_pending, state.dialogs,
        "Agent was destroyed", { presenter_unavailable = true })
    end
    if owns_presenter then pcall(presenter.destroy, presenter) end
    state.listeners = {}
    state.activity_listeners = {}
    state.attention = {}
    if state.release_exit then state.release_exit() end
  end

  state.release_exit = host_effects.on_exit(function() agent:destroy() end)

  return agent
end

function M.new(opts, runtime)
  local options = config.resolve(opts)
  local selected = {}
  for key, value in pairs(runtime or {}) do selected[key] = value end
  local destroy_runtimes
  if selected.runtimes == nil then
    local auth = selected.auth or require("neoagent.auth").configured(options)
    selected.auth = auth
    local function report(message, level)
      if selected.presenter then
        return selected.presenter:notify({ message = message, level = level })
      end
      return require("applet").Presenter.notify(message, level)
    end
    local runtimes, err = require("neoagent.provider_runtimes").compose(
      options, {
        auth = auth,
        store = require("neoagent.state_store").new({
          directory = vim.fn.stdpath("state") .. "/neoagent/model-catalog",
        }),
        report = report,
      })
    if not runtimes then error(err, 0) end
    selected.runtimes = runtimes
    local owned = runtimes
    destroy_runtimes = function()
      local current = owned
      owned = nil
      require("neoagent.provider_runtimes").destroy(current)
    end
    selected.destroy_runtimes = destroy_runtimes
  end
  local ok, agent = pcall(M.from_config, options, selected)
  if not ok then
    if destroy_runtimes then destroy_runtimes() end
    error(agent, 0)
  end
  return agent
end

return M
