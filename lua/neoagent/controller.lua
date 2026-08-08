local config = require("neoagent.config")
local context_metrics = require("neoagent.controller.context")
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
    live_usage = nil,
    provider_status = nil,
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

  local function ensure_model()
    require_workspace_trust()
    if state.model then
      local seeded, seed_err = seed_store()
      if not seeded then error(seed_err, 0) end
      return state.model
    end
    if not state.workspace then activate_workspace(vim.fn.getcwd()) end
    local selected = preferences().default_model
    if selected then
      state.model = require("neoagent.models").resolve(selected.provider, selected.model, options, auth_manager)
      state.model_selection = util.copy(selected)
    else
      state.model = require("neoagent.models").resolve(nil, nil, options, auth_manager)
      state.model_selection = { provider = state.model.provider, model = state.model.id }
    end
    state.thinking_level = thinking_level(state.model, state.thinking_level)
    local seeded, seed_err = seed_store()
    if not seeded then error(seed_err, 0) end
    return state.model
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
      steering = vim.tbl_map(function(message) return message.text end, state.steering),
    }
  end

  local function update_context()
    publish({ type = "context", context = context() })
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
      if preferences().default_model then ensure_model() end
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
      prompt = "Neoagent branch",
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
      prompt = "Fork Neoagent session from",
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
      prompt = "Resume Neoagent session:",
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
    local choices, err = require("neoagent.models").available(options, auth_manager)
    if not choices then
      notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.ERROR)
      return nil
    end
    if #choices == 0 then notify("no models configured") return nil end
    vim.ui.select(choices, { prompt = "Select Neoagent model:" }, function(choice)
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
    local ok, model = pcall(require("neoagent.models").resolve, provider_id, model_id, options, auth_manager)
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
        if value and value ~= "" then done.resolve(value) else done.reject(util.error("auth", "Login cancelled")) end
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
        prompt = "Select Neoagent login:",
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
        prompt = "Select Neoagent credential to remove:",
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

  function controller:destroy()
    if state.destroyed then return end
    state.destroyed = true
    state.run_id = state.run_id + 1
    if state.run then state.run:cancel() end
    if state.login_run then state.login_run:cancel() end
    if state.logout_run then state.logout_run:cancel() end
    state.run, state.login_run, state.logout_run = nil, nil, nil
    state.listeners = {}
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end

  state.augroup = vim.api.nvim_create_augroup("NeoagentLifecycle" .. next_id, { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.augroup,
    callback = function()
      if state.run then state.run:cancel() end
      if state.login_run then state.login_run:cancel() end
      if state.logout_run then state.logout_run:cancel() end
    end,
  })

  return controller
end

function M.new(opts, runtime)
  return M.from_config(config.resolve(opts), runtime)
end

return M
