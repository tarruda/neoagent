local config = require("neoagent.config")
local async = require("neoagent.async")
local context_metrics = require("neoagent.controller.context")
local provider_service = require("neoagent.provider_service")
local provider_state = require("neoagent.provider_state")
local session_lifecycle = require("neoagent.controller.session_lifecycle")
local session_choices = require("neoagent.controller.session_choices")
local util = require("neoagent.util")

local M = {}
local next_id = 0
local ui_positions = { auto = true, left = true, right = true, top = true, bottom = true, center = true }

function M.from_config(options, runtime)
  assert(type(options) == "table", "controller configuration is required")
  runtime = runtime or {}
  assert(type(runtime) == "table",
    "controller runtime must be an object")
  if runtime.workspace_trust ~= nil then
    assert(type(runtime.workspace_trust) == "table"
        and type(runtime.workspace_trust.is_trusted) == "function"
        and type(runtime.workspace_trust.check) == "function",
      "controller workspace trust policy is invalid")
  end
  if runtime.providers ~= nil then
    assert(type(runtime.providers) == "table"
        and (next(runtime.providers) == nil or not util.is_list(runtime.providers)),
      "controller provider services must be a keyed table")
  end
  if runtime.destroy_providers ~= nil then
    assert(type(runtime.destroy_providers) == "function",
      "controller provider cleanup must be a function")
  end
  local workspace_trust = runtime.workspace_trust
  options = util.copy(options)
  local settings_name = options.name or "default"
  next_id = next_id + 1
  local controller = { _neoagent_controller = true }
  local state = {
    session = nil,
    session_id = nil,
    model = nil,
    model_selection = nil,
    thinking_level = nil,
    workspace = nil,
    workspace_settings = nil,
    workspace_overrides = {},
    store = nil,
    store_seeded = false,
    run = nil,
    login_run = nil,
    logout_run = nil,
    catalog_runs = {},
    live_usage = nil,
    provider_status = nil,
    provider_services = runtime.providers or {},
    provider_id = nil,
    provider_unsubscribe = nil,
    provider_run = nil,
    provider_run_id = 0,
    provider_operation = nil,
    provider_usage_release = nil,
    destroy_providers = runtime.destroy_providers,
    pending_events = {},
    steering = {},
    last_result = nil,
    listeners = {},
    next_listener_id = 0,
    run_id = 0,
    status = "idle",
    destroyed = false,
    toolset = {
      tools = options._tools_supplied and util.copy(options.tools)
        or require("neoagent.tools").coding({
          shell_timeout = options.shell_timeout,
        }),
      execute_tool = options.execute_tool,
      system_prompt = options._sandbox_system_prompt,
    },
  }
  local function activate_session(session)
    state.session = session
    state.session_id = {}
  end
  local auth_manager = require("neoagent.auth").configured(options)

  local function trust_cwd()
    return state.workspace and state.workspace.root or vim.fn.getcwd()
  end

  local function require_workspace_trust(cwd)
    if not workspace_trust then return true end
    local trusted, err = workspace_trust:check(cwd or trust_cwd())
    if not trusted then error(err, 0) end
    return true
  end

  local function notify(message, level)
    vim.notify("neoagent: " .. message, level or vim.log.levels.INFO)
  end

  local function configured()
    return options
  end

  local bind_provider
  local provider_context
  local provider_interact
  local provider_event

  local function bound_service()
    local provider_id = state.provider_id
    return provider_id and state.provider_services[provider_id] or nil
  end

  local function model_service()
    local selected = state.model_selection
    return selected and state.provider_services[selected.provider] or nil
  end

  local function unbind_provider()
    -- A provider operation belongs to the bound provider; replacing the
    -- binding cancels the active Run and invalidates its completion so it
    -- can never paint state onto a newer provider console.
    state.provider_run_id = state.provider_run_id + 1
    if state.provider_run then
      state.provider_run:cancel()
      state.provider_run = nil
    end
    if state.provider_unsubscribe then
      local ok, err = pcall(state.provider_unsubscribe)
      if not ok then
        notify("provider unsubscribe failed: " .. tostring(err), vim.log.levels.ERROR)
      end
      state.provider_unsubscribe = nil
    end
    state.provider_id = nil
    state.provider_operation = nil
  end

  local function publish(update)
    for _, listener in pairs(state.listeners) do
      local ok, err = pcall(listener, update)
      if not ok then notify("controller listener failed: " .. tostring(err), vim.log.levels.ERROR) end
    end
  end

  local function model_label()
    local selected = state.model_selection
    return selected and (selected.provider .. "/" .. selected.model) or "no model"
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
    return util.deep_merge(preference_defaults(), state.workspace_overrides)
  end

  local function thinking_level(model, preferred)
    return require("neoagent.thinking").clamp(model, preferred or preferences().default_thinking_level)
  end

  local function scoped_workspace_settings(settings, warn)
    local accepted = { ui_position = settings.ui_position }
    local controllers = settings.controllers
    if controllers ~= nil and (type(controllers) ~= "table" or util.is_list(controllers)) then
      if warn then notify("ignoring invalid workspace controllers", vim.log.levels.WARN) end
      controllers = nil
    end
    local scoped = controllers and controllers[settings_name]
    if scoped ~= nil and (type(scoped) ~= "table" or util.is_list(scoped)) then
      if warn then
        notify("ignoring invalid workspace settings for " .. settings_name, vim.log.levels.WARN)
      end
      scoped = nil
    end
    scoped = scoped or {}
    accepted.default_model = scoped.default_model
    accepted.default_thinking_level = scoped.default_thinking_level
    if accepted.default_model == nil then accepted.default_model = settings.default_model end
    if accepted.default_thinking_level == nil then
      accepted.default_thinking_level = settings.default_thinking_level
    end
    local merged = util.deep_merge(preference_defaults(), accepted)
    if merged.default_model ~= nil and (type(merged.default_model) ~= "table"
        or type(merged.default_model.provider) ~= "string" or type(merged.default_model.model) ~= "string") then
      if warn then notify("ignoring invalid workspace default_model", vim.log.levels.WARN) end
      accepted.default_model = nil
    end
    if not require("neoagent.thinking").is_level(merged.default_thinking_level) then
      if warn then notify("ignoring invalid workspace default_thinking_level", vim.log.levels.WARN) end
      accepted.default_thinking_level = nil
    end
    if not ui_positions[merged.ui_position] then
      if warn then notify("ignoring invalid workspace ui_position", vim.log.levels.WARN) end
      accepted.ui_position = nil
    end
    return accepted
  end

  local function workspace_patch(patch)
    local result = {}
    if patch.ui_position ~= nil then result.ui_position = patch.ui_position end
    local scoped = {}
    if patch.default_model ~= nil then scoped.default_model = patch.default_model end
    if patch.default_thinking_level ~= nil then
      scoped.default_thinking_level = patch.default_thinking_level
    end
    if next(scoped) ~= nil then result.controllers = { [settings_name] = scoped } end
    return result
  end

  local function save_workspace_settings(patch)
    local persistence = configured().persistence
    if not state.workspace_settings or not persistence.workspace_settings then return true end
    local saved, err = state.workspace_settings:update(workspace_patch(patch))
    if not saved then return nil, err end
    state.workspace_overrides = scoped_workspace_settings(saved, false)
    return true
  end

  local function activate_workspace(cwd)
    local root = require("neoagent.fs").canonical(cwd)
    if state.workspace and state.workspace.root == root then return end
    state.workspace = require("neoagent.workspace").new({ root = root, cwd = root })
    state.workspace_settings, state.workspace_overrides = nil, {}
    state.model, state.model_selection, state.thinking_level = nil, nil, nil
    state.live_usage, state.provider_status = nil, nil
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
      notify(settings_err.message .. (settings_err.detail and ": " .. settings_err.detail or ""),
        vim.log.levels.WARN)
      return
    end
    state.workspace_overrides = scoped_workspace_settings(settings, true)
  end

  local function seed_store()
    if not state.store or state.store_seeded or not state.model then return true end
    local selected = state.model_selection or { provider = state.model.provider, model = state.model.id }
    local ok, err = state.store:append_model_change(selected.provider, selected.model)
    if not ok then return nil, err end
    if state.thinking_level then
      ok, err = state.store:append_thinking_level_change(state.thinking_level)
      if not ok then return nil, err end
    end
    state.store_seeded = true
    return true
  end

  local sessions
  local function ensure_session()
    if state.session then return state.session end
    local cwd = vim.fn.getcwd()
    local session, err = sessions.make(cwd)
    if not session then error(err, 0) end
    activate_session(session)
    return session
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

  local function same_model(left, right)
    return type(left) == "table" and type(right) == "table"
      and left.provider == right.provider and left.model == right.model
  end

  local function ensure_model()
    require_workspace_trust()
    if state.model then
      local seeded, seed_err = seed_store()
      if not seeded then error(seed_err, 0) end
      return state.model
    end
    if not state.workspace then activate_workspace(vim.fn.getcwd()) end
    local selected = preferences().default_model
    if not selected then error("No default_model is configured") end
    local ok, model = pcall(require("neoagent.models").resolve,
      selected.provider, selected.model, options, auth_manager, state.provider_services)
    if not ok then
      local workspace_default = state.workspace_overrides.default_model
      local configured_default = preference_defaults().default_model
      if workspace_default and same_model(selected, workspace_default) then
        state.workspace_overrides.default_model = nil
        if configured_default and not same_model(workspace_default, configured_default) then
          local fallback_ok, fallback = pcall(require("neoagent.models").resolve,
            configured_default.provider, configured_default.model, options,
            auth_manager, state.provider_services)
          if not fallback_ok then error(fallback, 0) end
          selected, model, ok = configured_default, fallback, true
        else
          notify("ignoring unavailable workspace model "
            .. selected.provider .. "/" .. selected.model, vim.log.levels.WARN)
          return nil
        end
        notify("ignoring unavailable workspace model "
          .. workspace_default.provider .. "/" .. workspace_default.model,
          vim.log.levels.WARN)
      else
        error(model, 0)
      end
    end
    state.model = model
    state.model_selection = util.copy(selected)
    state.thinking_level = thinking_level(state.model, state.thinking_level)
    bind_provider(state.model_selection.provider)
    local seeded, seed_err = seed_store()
    if not seeded then error(seed_err, 0) end
    return state.model
  end

  local function dynamic_model_pending(selected)
    if type(selected) ~= "table" then return false end
    local provider = options.providers[selected.provider]
    local service = state.provider_services[selected.provider]
    if type(provider) ~= "table" or type(service) ~= "table"
        or type(service.refresh_catalog) ~= "function" then
      return false
    end
    if type(provider.models) == "table"
        and type(provider.models[selected.model]) == "table" then
      return false
    end
    if type(service.get_models) == "function" then
      local ok, discovered = pcall(service.get_models, service)
      if ok and type(discovered) == "table" then
        for _, model in ipairs(discovered) do
          if type(model) == "table" and model.id == selected.model then
            return false
          end
        end
      end
    end
    return true
  end

  local function system_prompt(value, tools)
    require_workspace_trust()
    local options = configured()
    local agents_result = options.agents and require("neoagent.agents").discover({
      cwd = state.workspace.root,
      global_files = options.agents.global_files,
      project_filenames = options.agents.project_filenames,
    }) or { files = {}, diagnostics = {} }
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
    for _, diagnostic in ipairs(vim.list_extend(agents_result.diagnostics, skills_result.diagnostics)) do
      notify(diagnostic.message .. ": " .. diagnostic.path, vim.log.levels.WARN)
    end
    local context = {
      session = state.session,
      model = state.model,
      workspace = state.workspace,
      prompt = value,
      tools = tools,
      agents = agents_result.files,
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
    local canonical = vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buffer) then
        local name = vim.api.nvim_buf_get_name(buffer)
        if name ~= "" and (vim.uv.fs_realpath(name) or vim.fs.normalize(name)) == canonical then
          if vim.bo[buffer].modified then
            notify("did not reload modified buffer " .. name, vim.log.levels.WARN)
          else
            vim.api.nvim_buf_call(buffer, function() vim.cmd("silent checktime") end)
          end
        end
      end
    end
  end

  local function context()
    return {
      name = options.name or false,
      model = model_label(),
      thinking = state.thinking_level or false,
      workspace = state.workspace and state.workspace.root or nil,
      position = preferences().ui_position,
      state = state.status,
      context_usage = context_metrics.display(state.session, state.model, state.live_usage),
      provider_status = state.provider_status or false,
      provider = provider_context(),
      steering = vim.tbl_map(function(message) return message.text end, state.steering),
    }
  end

  local function update_context()
    publish({ type = "context", context = context() })
  end

  local function safe_state(service)
    local ok, value = pcall(service.state, service)
    if not ok then
      notify("provider state failed: " .. tostring(value), vim.log.levels.ERROR)
      return nil
    end
    if value == false then return false end
    local normalized, err = provider_state.normalize(value)
    if not normalized then
      notify("provider state is invalid: " .. (err and err.message or "invalid value"),
        vim.log.levels.ERROR)
      return nil
    end
    return normalized
  end

  provider_context = function()
    local service = bound_service()
    local provider_id = service and service.id
      or state.model_selection and state.model_selection.provider or nil
    if not provider_id then return false end
    if not service then
      return {
        id = provider_id,
        name = provider_id,
        state = false,
        operations = {},
      }
    end
    local snapshot = safe_state(service)
    if snapshot == nil then
      snapshot = {
        blocks = { {
          type = "status",
          text = "Provider state is unavailable",
          level = "error",
        } },
      }
    end
    local operations = provider_service.operations(service)
    for _, operation in ipairs(operations) do
      operation.enabled = provider_service.operation_enabled(
        service, service.operations[operation.id])
    end
    if snapshot ~= false and state.provider_operation then
      snapshot = util.copy(snapshot)
      snapshot.operation = util.copy(state.provider_operation)
    end
    return {
      id = service.id,
      name = service.name,
      state = snapshot,
      operations = operations,
    }
  end

  bind_provider = function(provider_id)
    local service = provider_id and state.provider_services[provider_id] or nil
    if not service then
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
    if state.provider_id == provider_id and state.provider_unsubscribe then
      return
    end
    unbind_provider()
    state.provider_id = provider_id
    if type(service.subscribe) == "function" then
      local ok, unsubscribe = pcall(service.subscribe, service, function()
        util.schedule(function()
          if state.destroyed then return end
          local selected = state.model_selection
          if not state.model and selected
              and selected.provider == service.id
              and not dynamic_model_pending(selected) then
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
      end)
      if not ok then
        notify("provider subscription failed: " .. tostring(unsubscribe),
          vim.log.levels.ERROR)
        state.provider_id = nil
        return
      end
      if type(unsubscribe) == "function" then
        state.provider_unsubscribe = unsubscribe
      end
    end
    update_context()
  end

  local function formatted_item(item)
    local label = type(item.label) == "string" and item.label ~= "" and item.label or item.id
    local description = type(item.description) == "string" and item.description or ""
    description = util.trim(description)
    if description ~= "" then return label .. " · " .. description end
    return label
  end

  provider_interact = function()
    local function select(options, done)
      local items = type(options) == "table" and options.items or nil
      if type(items) ~= "table" or not util.is_list(items) or #items == 0 then
        done.reject(util.error("provider", "Select requires items"))
        return nil
      end
      for _, item in ipairs(items) do
        if type(item) ~= "table" or type(item.id) ~= "string" or item.id == "" then
          done.reject(util.error("provider", "Select items require string ids"))
          return nil
        end
      end
      local active = true
      local ok, err = pcall(vim.ui.select, items, {
        prompt = type(options) == "table" and type(options.prompt) == "string"
          and options.prompt or "Select",
        format_item = formatted_item,
      }, function(choice)
        if not active then return end
        active = false
        if choice == nil then
          done.reject(util.error("cancelled", "Selection cancelled"))
        else
          done.resolve(choice.id)
        end
      end)
      if not ok then
        done.reject(util.normalize_error(err, "provider"))
        return nil
      end
      return function() active = false end
    end

    local function input(options, done)
      local prompt = type(options) == "table" and type(options.prompt) == "string"
        and options.prompt or "Input"
      local default = type(options) == "table" and type(options.default) == "string"
        and options.default or ""
      local active = true
      local ok, err = pcall(vim.ui.input, {
        prompt = prompt .. " ",
        default = default,
      }, function(value)
        if not active then return end
        active = false
        if value == nil or value == "" then
          done.reject(util.error("cancelled", "Input cancelled"))
        else
          done.resolve(value)
        end
      end)
      if not ok then
        done.reject(util.normalize_error(err, "provider"))
        return nil
      end
      return function() active = false end
    end

    local function confirm(options, done)
      local prompt = type(options) == "table" and type(options.prompt) == "string"
        and options.prompt or "Confirm"
      local items = {
        { id = "yes", label = "Yes" },
        { id = "no", label = "No" },
      }
      local active = true
      local ok, err = pcall(vim.ui.select, items, {
        prompt = prompt,
        format_item = function(item) return item.label end,
      }, function(choice)
        if not active then return end
        active = false
        if choice == nil then
          done.reject(util.error("cancelled", "Confirmation cancelled"))
        else
          done.resolve(choice.id == "yes")
        end
      end)
      if not ok then
        done.reject(util.normalize_error(err, "provider"))
        return nil
      end
      return function() active = false end
    end

    local function progress(snapshot)
      local ok, normalized = pcall(provider_state.normalize_operation, snapshot)
      if not ok or not normalized then
        notify("provider progress is invalid: " .. tostring(normalized),
          vim.log.levels.ERROR)
        return
      end
      state.provider_operation = normalized
      update_context()
    end

    return {
      select = select,
      input = input,
      confirm = confirm,
      progress = progress,
      notify = function(message, level)
        notify(type(message) == "string" and message or tostring(message), level)
      end,
    }
  end

  provider_event = function(event)
    local service = model_service()
    if service and type(service.on_event) == "function" then
      pcall(service.on_event, service, util.copy(event))
    end
  end

  sessions = session_lifecycle.new({
    state = state,
    config = options,
    auth_manager = auth_manager,
    notify = notify,
    publish_messages = publish_messages,
    update_context = update_context,
    require_workspace_trust = require_workspace_trust,
    activate_workspace = activate_workspace,
    activate_session = activate_session,
    seed_store = seed_store,
    ensure_model = ensure_model,
    preferences = preferences,
    thinking_level = thinking_level,
    providers = state.provider_services,
    bind_provider = bind_provider,
  })

  local runs = require("neoagent.controller.run_lifecycle").new({
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
    copy_toolset = copy_toolset,
    system_prompt = system_prompt,
    refresh_buffer = refresh_buffer,
    provider_event = provider_event,
    acquire_provider = function()
      local service = model_service()
      if not service then return function() end end
      local release, err = provider_service.acquire(service)
      if not release then error(err, 0) end
      return release
    end,
  })

  function controller:prepare()
    local ok, err = pcall(function()
      if not state.workspace then activate_workspace(vim.fn.getcwd()) end
      if workspace_trust then
        local trusted = workspace_trust:is_trusted(state.workspace.root)
        if not trusted then
          update_context()
          return
        end
      end
      local selected = preferences().default_model
      if selected and dynamic_model_pending(selected) then
        state.model_selection = util.copy(selected)
        bind_provider(selected.provider)
      elseif selected then
        ensure_model()
      end
      update_context()
    end)
    if not ok then
      err = util.normalize_error(err, "controller")
      notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    return true
  end

  function controller:send(text)
    return runs.send(text)
  end

  function controller:steer(text)
    return runs.steer(text)
  end

  function controller:dequeue_steering()
    return runs.dequeue_steering()
  end

  function controller:compact(instructions)
    return runs.compact(instructions)
  end

  function controller:stop()
    return runs.stop()
  end

  function controller:new_session()
    return sessions.new_session()
  end

  function controller:branch(entry_id, summary)
    return sessions.branch(entry_id, summary)
  end
  function controller:select_branch(on_selected)
    if not state.session then notify("no active session") return nil end
    local entries = state.session:entries()
    local current = state.session:leaf_id()
    local choices = {}
    for _, entry in ipairs(entries) do
      if entry.type == "message" or entry.type == "custom_message"
          or entry.type == "branch_summary" or entry.type == "compaction" then
        choices[#choices + 1] = {
          id = entry.id,
          label = session_lifecycle.entry_label(entry, current),
        }
      end
    end
    if #choices == 0 then notify("the active session has no entries") return nil end
    vim.ui.select(choices, {
      prompt = "Branch",
      format_item = function(item) return item.label end,
    }, function(choice)
      if not choice then return end
      local moved = controller:branch(choice.id)
      if moved and on_selected then on_selected(choice.id) end
    end)
    return true
  end

  function controller:fork(entry_id, position)
    return sessions.fork(entry_id, position)
  end
  function controller:select_fork(on_selected)
    if not state.session then notify("no active session") return nil end
    local choices = {}
    for _, entry in ipairs(state.session:entries()) do
      if entry.type == "message" and entry.message.role == "user" then
        choices[#choices + 1] = {
          id = entry.id,
          label = session_lifecycle.entry_label(entry),
        }
      end
    end
    if #choices == 0 then notify("the active session has no user messages") return nil end
    vim.ui.select(choices, {
      prompt = "Fork session from",
      format_item = function(item) return item.label end,
    }, function(choice)
      if not choice then return end
      local forked, selected_text = controller:fork(choice.id, "before")
      if forked and on_selected then on_selected(forked, selected_text) end
    end)
    return true
  end

  function controller:resume(path, on_resumed)
    if state.run then notify("cannot resume while the agent is running", vim.log.levels.WARN) return nil end
    if path and path ~= "" then return sessions.resume(vim.fn.fnamemodify(path, ":p")) end
    local options = configured().persistence
    local sessions = require("neoagent.storage").list_sessions(options.directory, vim.fn.getcwd())
    if #sessions == 0 then notify("no sessions found for the current directory") return nil end
    local metadata = state.session and state.session:metadata()
    local current_path = metadata and metadata.path
    local choices = session_choices.build(sessions, current_path)
    vim.ui.select(choices, {
      prompt = "Resume session:",
      format_item = function(item) return item.label end,
    }, function(choice)
      if choice then
        local session = controller:resume(choice.path)
        if session and on_resumed then on_resumed(session) end
      end
    end)
    return true
  end

  function controller:select_model(on_selected)
    local trusted, trust_err = pcall(require_workspace_trust)
    if not trusted then
      trust_err = util.normalize_error(trust_err, "workspace_trust")
      notify(trust_err.message, vim.log.levels.ERROR)
      return nil, trust_err
    end
    if state.run then notify("cannot change model while the agent is running", vim.log.levels.WARN) return nil end
    local choices, err = require("neoagent.models").available(options, auth_manager, state.provider_services)
    if not choices then
      notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.ERROR)
      return nil
    end
    if #choices == 0 then notify("no models configured") return nil end
    vim.ui.select(choices, { prompt = "Select model:" }, function(choice)
      if not choice then return end
      local provider_id, model_id = choice:match("^([^/]+)/(.+)$")
      if provider_id then
        local model = controller:set_model(provider_id, model_id)
        if model and on_selected then on_selected(model) end
      end
    end)
    return true
  end

  function controller:set_model(provider_id, model_id)
    if state.run then notify("cannot change model while the agent is running", vim.log.levels.WARN) return nil end
    local trusted, trust_err = pcall(require_workspace_trust)
    if not trusted then
      trust_err = util.normalize_error(trust_err, "workspace_trust")
      notify(trust_err.message, vim.log.levels.ERROR)
      return nil, trust_err
    end
    if not state.workspace then activate_workspace(vim.fn.getcwd()) end
    local ok, model = pcall(require("neoagent.models").resolve, provider_id, model_id, options, auth_manager, state.provider_services)
    if not ok then notify(tostring(model), vim.log.levels.ERROR) return nil, model end
    local next_thinking = thinking_level(model, configured().default_thinking_level)
    if state.store then
      local recorded, record_err = state.store:append_model_change(provider_id, model_id)
      if not recorded then notify(record_err.message, vim.log.levels.ERROR) return nil, record_err end
      if next_thinking then
        recorded, record_err = state.store:append_thinking_level_change(next_thinking)
        if not recorded then notify(record_err.message, vim.log.levels.ERROR) return nil, record_err end
      end
      state.store_seeded = true
    end
    local saved, save_err = save_workspace_settings({
      default_model = { provider = provider_id, model = model_id },
      default_thinking_level = next_thinking,
    })
    if not saved and not state.store then
      notify(save_err.message, vim.log.levels.ERROR)
      return nil, save_err
    elseif not saved then
      notify("model changed for this session but workspace settings were not saved: " .. save_err.message,
        vim.log.levels.WARN)
    end
    state.model = model
    state.model_selection = { provider = provider_id, model = model_id }
    state.thinking_level = next_thinking
    state.live_usage, state.provider_status = nil, nil
    bind_provider(provider_id)
    update_context()
    return model
  end

  function controller:available_thinking_levels()
    local ok, model = pcall(ensure_model)
    if not ok then return nil, util.normalize_error(model, "model") end
    return require("neoagent.thinking").levels(model)
  end

  function controller:get_thinking_level()
    return state.thinking_level
  end

  function controller:set_thinking_level(level)
    if state.run then notify("cannot change thinking level while the agent is running", vim.log.levels.WARN) return nil end
    if not require("neoagent.thinking").is_level(level) then
      notify("unknown thinking level: " .. tostring(level), vim.log.levels.ERROR)
      return nil
    end
    local levels, err = self:available_thinking_levels()
    if not levels then notify(err.message, vim.log.levels.ERROR) return nil, err end
    if not vim.tbl_contains(levels, level) then
      notify("thinking level " .. level .. " is not supported by " .. model_label(), vim.log.levels.WARN)
      return nil
    end
    if state.store then
      local recorded, record_err = state.store:append_thinking_level_change(level)
      if not recorded then notify(record_err.message, vim.log.levels.ERROR) return nil, record_err end
    end
    local saved, save_err = save_workspace_settings({ default_thinking_level = level })
    if not saved and not state.store then
      notify(save_err.message, vim.log.levels.ERROR)
      return nil, save_err
    elseif not saved then
      notify("thinking changed for this session but workspace settings were not saved: " .. save_err.message,
        vim.log.levels.WARN)
    end
    state.store_seeded = state.store and true or state.store_seeded
    state.thinking_level = level
    update_context()
    return level
  end

  function controller:cycle_thinking_level()
    if state.run then notify("cannot change thinking level while the agent is running", vim.log.levels.WARN) return nil end
    local ok, model = pcall(ensure_model)
    if not ok then notify(util.normalize_error(model, "model").message, vim.log.levels.ERROR) return nil end
    local level = require("neoagent.thinking").next(model, state.thinking_level)
    if not level then notify("current model does not support thinking", vim.log.levels.WARN) return nil end
    level = self:set_thinking_level(level)
    if not level then return nil end
    notify("thinking level: " .. level)
    return level
  end

  local function login_prompt(prompt, done)
    if prompt.type == "select" then
      vim.ui.select(prompt.options, {
        prompt = prompt.message,
        format_item = function(item) return item.label end,
      }, function(choice)
        if choice then done.resolve(choice.id) else done.reject(util.error("auth", "Login cancelled")) end
      end)
    elseif prompt.type == "secret" then
      local active = true
      vim.schedule(function()
        if not active then return end
        local ok, value = pcall(vim.fn.inputsecret, prompt.message .. " ")
        if not active then return end
        if ok and value ~= "" then
          done.resolve(value)
        else
          done.reject(util.error("auth", "Login cancelled"))
        end
      end)
      return function() active = false end
    elseif prompt.type == "text" or prompt.type == "manual_code" then
      vim.ui.input({ prompt = prompt.message .. " ", default = "" }, function(value)
        if value ~= nil then done.resolve(value) else done.reject(util.error("auth", "Login cancelled")) end
      end)
    else
      done.reject(util.error("auth", "Unsupported login prompt: " .. tostring(prompt.type)))
    end
  end

  local function login_event(event)
    if event.type == "auth_url" then
      notify((event.instructions or "Open this URL to authenticate:") .. "\n" .. event.url)
      pcall(vim.ui.open, event.url)
    elseif event.type == "device_code" then
      notify("Open " .. event.verificationUri .. " and enter code " .. event.userCode)
      pcall(vim.ui.open, event.verificationUri)
    elseif event.message then
      notify(event.message)
    end
  end

  local function refresh_login_catalogs(method_id)
    for provider_id, service in pairs(state.provider_services) do
      local provider = configured().providers[provider_id]
      if provider and provider.auth == method_id
          and type(service.refresh_catalog) == "function" then
        local started, run = pcall(service.refresh_catalog, service, {
          allow_network = true,
          force = true,
        })
        if not started or type(run) ~= "table"
            or type(run.await) ~= "function" then
          notify("failed to refresh " .. provider_id .. " catalog after login",
            vim.log.levels.ERROR)
        else
          local token = {}
          local owned
          owned = async.run(function()
            local result = run:await()
            if result.ok == false then error(result.error, 0) end
            return result
          end, {
            on_done = function(result)
              state.catalog_runs[token] = nil
              if not result.ok and result.error.kind ~= "cancelled"
                  and not state.destroyed then
                notify("failed to refresh " .. provider_id
                  .. " catalog: " .. result.error.message,
                  vim.log.levels.ERROR)
              end
            end,
            error_kind = "provider",
          })
          state.catalog_runs[token] = owned
        end
      end
    end
  end

  function controller:login(method_id)
    if state.login_run or state.logout_run then
      notify("an authentication operation is already active", vim.log.levels.WARN)
      return nil
    end
    local methods = configured().auth.methods
    if method_id == nil or method_id == "" then
      local choices = {}
      for id, method in pairs(methods) do choices[#choices + 1] = { id = id, label = method.name } end
      table.sort(choices, function(a, b) return a.label < b.label end)
      if #choices == 0 then notify("no login methods configured") return nil end
      vim.ui.select(choices, {
        prompt = "Select login:",
        format_item = function(item) return item.label end,
      }, function(choice) if choice then controller:login(choice.id) end end)
      return true
    end
    if not methods[method_id] then notify("unknown login method: " .. method_id, vim.log.levels.ERROR) return nil end
    local run = auth_manager:login(method_id, {
      prompt = login_prompt,
      notify = login_event,
      on_done = function(result)
        state.login_run = nil
        if result.ok then
          refresh_login_catalogs(method_id)
          notify("logged in with " .. methods[method_id].name .. "; credentials saved to " .. configured().auth.path)
        elseif result.error.kind ~= "cancelled" then
          notify(result.error.message, vim.log.levels.ERROR)
        end
      end,
    })
    state.login_run = run
    return run
  end

  function controller:cancel_login()
    if not state.login_run then return false end
    state.login_run:cancel()
    return true
  end

  function controller:logout(method_id)
    if state.login_run or state.logout_run then
      notify("an authentication operation is already active", vim.log.levels.WARN)
      return nil
    end
    local credentials, err = auth_manager:list_credentials()
    if not credentials then notify(err.message, vim.log.levels.ERROR) return nil end
    if method_id == nil or method_id == "" then
      if #credentials == 0 then
        notify("no stored credentials to remove; environment API keys are unchanged")
        return nil
      end
      vim.ui.select(credentials, {
        prompt = "Select credential to remove:",
        format_item = function(item)
          local kind = item.type == "api_key" and "API key" or item.type == "oauth" and "OAuth" or "invalid"
          return item.name .. " (" .. kind .. ")"
        end,
      }, function(choice) if choice then controller:logout(choice.id) end end)
      return true
    end
    local selected
    for _, credential in ipairs(credentials) do
      if credential.id == method_id then selected = credential break end
    end
    if not selected then
      notify("no stored credential for " .. method_id, vim.log.levels.WARN)
      return nil
    end
    local run = auth_manager:logout(method_id, {
      on_done = function(result)
        state.logout_run = nil
        if result.ok then
          if selected.type == "api_key" then
            notify("removed stored " .. selected.name .. "; environment API keys are unchanged")
          else
            notify("logged out of " .. selected.name)
          end
        elseif result.error.kind ~= "cancelled" then
          notify(result.error.message, vim.log.levels.ERROR)
        end
      end,
    })
    state.logout_run = run
    return run
  end

  function controller:provider_operations()
    local service = bound_service()
    if not service then
      return state.model_selection and state.model_selection.provider and {} or nil
    end
    local operations = provider_service.operations(service)
    for _, operation in ipairs(operations) do
      operation.enabled = provider_service.operation_enabled(
        service, service.operations[operation.id])
    end
    return operations
  end

  function controller:provider_completion(operation_id, arg_lead, args)
    local service = bound_service()
    local descriptor = service and service.operations[operation_id] or nil
    if not descriptor or type(descriptor.complete) ~= "function" then return {} end
    local ok, values = pcall(descriptor.complete, arg_lead or "", args or "")
    if not ok or type(values) ~= "table" or not util.is_list(values) then
      return {}
    end
    local result = {}
    for _, value in ipairs(values) do
      if type(value) == "string" and value ~= "" and #value <= 512
          and util.is_valid_utf8(value)
          and not value:find("[%z\1-\31\127]")
          and (arg_lead == "" or vim.startswith(value, arg_lead)) then
        result[#result + 1] = value
      end
    end
    table.sort(result)
    return result
  end

  function controller:console_providers()
    local result = {}
    for provider_id, service in pairs(state.provider_services) do
      local ok, validated = pcall(provider_service.validate, service)
      if ok and validated ~= nil then
        result[#result + 1] = { id = provider_id, name = validated.name }
      end
    end
    table.sort(result, function(left, right)
      if left.name == right.name then return left.id < right.id end
      return left.name < right.name
    end)
    return result
  end

  function controller:bind_provider(provider_id)
    if state.destroyed then
      return nil, util.error("controller", "Controller is destroyed")
    end
    local service = state.provider_services[provider_id]
    local ok, validated = pcall(provider_service.validate, service)
    if not ok or not validated then
      return nil, util.error("provider",
        "provider service for " .. tostring(provider_id) .. " is invalid")
    end
    bind_provider(provider_id)
    return true
  end

  function controller:select_console_provider(on_selected)
    local providers = self:console_providers()
    if #providers == 0 then return nil end
    if #providers == 1 then
      local bound, err = self:bind_provider(providers[1].id)
      if not bound then notify(err.message, vim.log.levels.ERROR) return nil end
      if on_selected then on_selected() end
      return true
    end
    vim.ui.select(providers, {
      prompt = "Select provider console:",
      format_item = function(item) return item.name end,
    }, function(choice)
      if not choice then return end
      local bound, err = self:bind_provider(choice.id)
      if not bound then notify(err.message, vim.log.levels.ERROR) return end
      if on_selected then on_selected() end
    end)
    return true
  end

  function controller:provider_info()
    return util.copy(provider_context())
  end

  function controller:provider_service_bound()
    return bound_service() ~= nil
  end

  local function open_provider_artifact(artifact)
    if artifact == nil then return end
    if type(artifact) ~= "table" or util.is_list(artifact)
        or artifact.kind ~= "document"
        or type(artifact.name) ~= "string" or artifact.name == ""
        or #artifact.name > 128 or not util.is_valid_utf8(artifact.name)
        or type(artifact.filetype) ~= "string"
        or not artifact.filetype:match("^[%w_.+-]*$")
        or #artifact.filetype > 64
        or type(artifact.content) ~= "string"
        or #artifact.content > 1024 * 1024
        or not util.is_valid_utf8(artifact.content) then
      notify("provider operation returned an invalid document artifact",
        vim.log.levels.ERROR)
      return
    end
    local ok, err = pcall(function()
      vim.cmd("tabnew")
      vim.bo.filetype = artifact.filetype
      vim.bo.bufhidden = "wipe"
      vim.bo.swapfile = false
      pcall(vim.api.nvim_buf_set_name, 0, artifact.name)
      vim.api.nvim_buf_set_lines(0, 0, -1, false,
        vim.split(artifact.content, "\n", { plain = true, trimempty = true }))
      vim.bo.modified = false
    end)
    if not ok then
      notify("failed to open provider document: " .. tostring(err),
        vim.log.levels.ERROR)
    end
  end

  function controller:provider_operation(operation_id, args)
    local service = bound_service()
    if not service then
      notify("the active provider has no operations", vim.log.levels.WARN)
      return nil
    end
    if state.provider_run or provider_service.busy(service) then
      notify("a provider operation is already active", vim.log.levels.WARN)
      return nil
    end
    local descriptor = service.operations[operation_id]
    if not descriptor then
      local err = util.error("provider", "Unknown provider operation: " .. tostring(operation_id))
      notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    local provider = configured().providers[state.provider_id]
    local run_id = state.provider_run_id + 1
    state.provider_run_id = run_id
    state.provider_operation = {
      id = operation_id,
      label = descriptor.label,
      state = "running",
      message = descriptor.label,
    }
    update_context()
    local run, err = provider_service.run(service, operation_id, {
      args = args or "",
      model = state.model_selection and util.copy(state.model_selection) or nil,
      agent_running = state.run ~= nil,
      auth = auth_manager,
      auth_method = provider and provider.auth or nil,
      optional_auth = provider
        and (provider.auth_optional == true or provider.api_key ~= nil) or false,
      provider = provider,
      interact = provider_interact(),
      on_done = function(result)
        if run_id ~= state.provider_run_id then return end
        state.provider_run = nil
        local operation = state.provider_operation and util.copy(state.provider_operation)
          or { id = operation_id, label = descriptor.label }
        if result.ok then
          operation.state = "succeeded"
          open_provider_artifact(result.artifact)
        elseif type(result.error) == "table" and result.error.kind == "cancelled" then
          operation.state = "cancelled"
        else
          operation.state = "failed"
          operation.detail = type(result.error) == "table" and result.error.message or nil
        end
        state.provider_operation = operation
        update_context()
      end,
    })
    if not run then
      state.provider_operation = nil
      update_context()
      if err then notify(err.message, vim.log.levels.ERROR) end
      return nil, err
    end
    state.provider_run = run
    return run
  end

  function controller:cancel_provider()
    if not state.provider_run then return false end
    state.provider_run:cancel()
    return true
  end

  function controller:set_ui_position(position)
    if not ui_positions[position] then return nil, util.error("ui", "invalid window position") end
    if not state.workspace then activate_workspace(vim.fn.getcwd()) end
    local saved, err = save_workspace_settings({ ui_position = position })
    if not saved then return nil, err end
    state.workspace_overrides.ui_position = position
    update_context()
    return position
  end

  function controller:subscribe(listener)
    assert(type(listener) == "function", "controller listener must be a function")
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

  function controller:snapshot()
    local messages = state.session and transcript_messages(state.session) or {}
    sync_tools()
    return {
      messages = messages,
      context = context(),
      events = util.copy(state.pending_events),
      result = util.copy(state.last_result),
    }
  end

  function controller:get_session() return state.session end
  function controller:get_model() return state.model end
  function controller:get_workspace() return state.workspace end
  function controller:is_authenticating()
    return state.login_run ~= nil or state.logout_run ~= nil
  end

  function controller:get_toolset()
    return copy_toolset(state.toolset)
  end

  function controller:set_toolset(value)
    if state.run then
      local err = util.error("controller",
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

  function controller:config() return util.copy(options) end
  function controller:is_running() return state.run ~= nil end
  function controller:is_destroyed() return state.destroyed end

  function controller:destroy()
    if state.destroyed then return end
    state.destroyed = true
    state.run_id = state.run_id + 1
    state.provider_run_id = state.provider_run_id + 1
    if state.run then state.run:cancel() end
    if state.login_run then state.login_run:cancel() end
    if state.logout_run then state.logout_run:cancel() end
    if state.provider_run then state.provider_run:cancel() end
    for _, run in pairs(state.catalog_runs) do run:cancel() end
    if state.provider_usage_release then state.provider_usage_release() end
    unbind_provider()
    local destroy_providers = state.destroy_providers
    state.destroy_providers = nil
    if destroy_providers then pcall(destroy_providers) end
    state.run, state.login_run, state.logout_run = nil, nil, nil
    state.provider_run = nil
    state.catalog_runs = {}
    state.provider_usage_release = nil
    state.listeners = {}
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end

  state.augroup = vim.api.nvim_create_augroup("NeoagentLifecycle" .. next_id, { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.augroup,
    callback = function() controller:destroy() end,
  })

  return controller
end

function M.new(opts, runtime)
  return M.from_config(config.resolve(opts), runtime)
end

return M
