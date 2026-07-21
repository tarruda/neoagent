local config = require("neoagent.config")
local util = require("neoagent.util")

local M = {}
local next_id = 0
local ui_positions = { auto = true, left = true, right = true, top = true, bottom = true, center = true }

function M.from_config(options)
  assert(type(options) == "table", "controller configuration is required")
  options = util.copy(options)
  next_id = next_id + 1
  local controller = { _neoagent_controller = true }
  local state = {
    session = nil,
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
    live_usage = nil,
    provider_status = nil,
    pending_events = {},
    last_result = nil,
    listeners = {},
    next_listener_id = 0,
    run_id = 0,
    status = "idle",
    destroyed = false,
  }
  local auth_manager = require("neoagent.auth").configured(options)

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

  local function usage_tokens(usage)
    if type(usage) ~= "table" then return nil end
    if type(usage.totalTokens) == "number" and usage.totalTokens >= 0 then
      return usage.totalTokens
    end
    local total = 0
    for _, key in ipairs({ "input", "output", "cacheRead", "cacheWrite" }) do
      if type(usage[key]) == "number" then total = total + usage[key] end
    end
    return total
  end

  local function estimate_messages(messages, first)
    local characters = 0
    for index = first, #messages do
      local ok, encoded = pcall(vim.json.encode, messages[index])
      if ok then characters = characters + #encoded end
    end
    return math.ceil(characters / 4)
  end

  local function context_usage()
    local total = state.model and state.model.context_window
    if type(total) ~= "number" or total <= 0 or not state.session then return false end
    local messages = state.session:messages()
    local used
    if state.live_usage then
      used = state.live_usage.tokens
      used = used + estimate_messages(messages, state.live_usage.message_count + 1)
    else
      for index = #messages, 1, -1 do
        local message = messages[index]
        local tokens = message.role == "assistant" and usage_tokens(message.usage) or nil
        if tokens and message.stopReason ~= "aborted" and message.stopReason ~= "error" then
          used = tokens + estimate_messages(messages, index + 1)
          break
        end
      end
      used = used or estimate_messages(messages, 1)
    end
    return { used = used, total = total, percent = used / total * 100 }
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

  local function usable_workspace_settings(overrides, warn)
    local accepted = util.copy(overrides)
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

  local function save_workspace_settings(patch)
    local persistence = configured().persistence
    if not state.workspace_settings or not persistence.workspace_settings then return true end
    local saved, err = state.workspace_settings:update(patch)
    if not saved then return nil, err end
    state.workspace_overrides = usable_workspace_settings(saved, false)
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
    local merged, overrides_or_err = state.workspace_settings:merge(preference_defaults())
    if not merged then
      notify(overrides_or_err.message .. (overrides_or_err.detail and ": " .. overrides_or_err.detail or ""),
        vim.log.levels.WARN)
      return
    end
    state.workspace_overrides = usable_workspace_settings(overrides_or_err, true)
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

  local function make_session(cwd)
    local Session = require("neoagent.session")
    activate_workspace(cwd)
    local options = configured().persistence
    if options.enabled then
      state.store = require("neoagent.storage").new({ directory = options.directory, cwd = state.workspace.root })
      state.store_seeded = false
      local session, err = Session.new({ store = state.store })
      if not session then return nil, err end
      local seeded, seed_err = seed_store()
      if not seeded then return nil, seed_err end
      return session
    end
    state.store, state.store_seeded = nil, false
    return Session.new()
  end

  local function ensure_session()
    if state.session then return state.session end
    local cwd = vim.fn.getcwd()
    local session, err = make_session(cwd)
    if not session then error(err, 0) end
    state.session = session
    return session
  end

  local function ensure_model()
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
    local options = configured()
    local agents_result = options.agents and require("neoagent.agents").discover({
      cwd = state.workspace.root,
      global_files = options.agents.global_files,
      project_filenames = options.agents.project_filenames,
    }) or { files = {}, diagnostics = {} }
    local has_read = vim.tbl_contains(vim.tbl_map(function(tool) return tool.name end, tools), "read_file")
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
    return require("neoagent.system_prompt").compose(prompt, context)
  end

  local function tool_array()
    local options = configured()
    if options._tools_supplied then return options.tools end
    return require("neoagent.tools").coding()
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

  local function close_unmatched_calls()
    local messages = state.session:messages()
    local pending = {}
    local order = {}
    for _, message in ipairs(messages) do
      if message.role == "assistant" then
        for _, block in ipairs(message.content or {}) do
          if block.type == "toolCall" then
            pending[block.id] = block
            order[#order + 1] = block.id
          end
        end
      elseif message.role == "toolResult" then
        pending[message.toolCallId] = nil
      end
    end
    for _, id in ipairs(order) do
      local call = pending[id]
      if call then
        local ok, err = state.session:append({
          role = "toolResult",
          toolCallId = call.id,
          toolName = call.name,
          content = { { type = "text", text = "Tool execution was interrupted; side effects may already have occurred." } },
          isError = true,
          timestamp = util.now_ms(),
        })
        if not ok then return nil, err end
      end
    end
    return true
  end

  local function interaction(options)
    return require("neoagent.chat").run(options.session, options.prompt, {
      model = options.model,
      system_prompt = options.system_prompt,
      tools = options.tools,
      context = options.context,
      execute_tool = options.execute_tool,
      max_rounds = options.max_rounds,
      model_options = options.model_options,
      on_event = options.on_event,
      on_done = options.on_done,
    })
  end

  local function context()
    return {
      name = options.name or false,
      model = model_label(),
      thinking = state.thinking_level or false,
      workspace = state.workspace and state.workspace.root or nil,
      position = preferences().ui_position,
      state = state.status,
      context_usage = context_usage(),
      provider_status = state.provider_status or false,
    }
  end

  local function update_context()
    publish({ type = "context", context = context() })
  end

  local function submit(prompt)
    if util.trim(prompt) == "" then return nil end
    if state.status ~= "idle" then notify("the agent is busy", vim.log.levels.WARN) return nil end
    local ok, result = pcall(function()
      ensure_session()
      ensure_model()
      local closed, close_err = close_unmatched_calls()
      if not closed then error(close_err, 0) end
      local options = configured()
      local tools = tool_array()
      local run_id = state.run_id + 1
      state.run_id = run_id
      state.pending_events = {}
      state.last_result = nil
      local selected_interaction = options.interaction or interaction
      local run = selected_interaction({
        session = state.session,
        prompt = prompt,
        model = state.model,
        system_prompt = system_prompt(prompt, tools),
        tools = tools,
        workspace = state.workspace,
        context = { workspace = state.workspace },
        execute_tool = options.execute_tool,
        max_rounds = options.max_tool_rounds,
        thinking_level = state.thinking_level,
        model_options = {
          request_opts = require("neoagent.thinking").request_opts(state.model, state.thinking_level),
        },
        on_event = function(event)
          if run_id ~= state.run_id then return end
          if event.type == "usage" then
            state.live_usage = {
              tokens = usage_tokens(event.usage) or 0,
              message_count = #state.session:messages() + 1,
            }
            update_context()
          elseif event.type == "provider_status" then
            state.provider_status = type(event.text) == "string" and event.text or nil
            update_context()
          elseif event.type == "message_end" then
            update_context()
          end
          if event.type == "message_end" then
            state.pending_events = {}
          elseif event.type ~= "usage" and event.type ~= "provider_status" then
            state.pending_events[#state.pending_events + 1] = util.copy(event)
          end
          publish({ type = "event", event = event })
          if event.type == "tool_end" and not event.message.isError
              and (event.call.name == "write_file" or event.call.name == "edit_file") then
            refresh_buffer(event.call.arguments.path)
          end
        end,
        on_done = function(done)
          if run_id ~= state.run_id then return end
          state.run = nil
          state.status = "idle"
          state.live_usage = nil
          state.last_result = util.copy(done)
          update_context()
          publish({ type = "finish", result = done })
        end,
      })
      assert(type(run) == "table" and type(run.cancel) == "function", "interaction must return a Run")
      state.run = run
      state.status = "running"
      publish({ type = "messages", messages = state.session:messages() })
      update_context()
      return run
    end)
    if not ok then
      local err = util.normalize_error(result, "session")
      notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    return result
  end

  function controller:prepare()
    local ok, err = pcall(function()
      if not state.workspace then activate_workspace(vim.fn.getcwd()) end
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
    return submit(text)
  end

  function controller:stop()
    if not state.run then return false end
    state.status = "stopping"
    update_context()
    state.run:cancel()
    return true
  end

  function controller:new_session()
    if state.run then notify("cannot create a session while the agent is running", vim.log.levels.WARN) return nil end
    local cwd = vim.fn.getcwd()
    local root = require("neoagent.fs").canonical(cwd)
    if state.workspace and state.workspace.root == root then
      state.model, state.model_selection, state.thinking_level = nil, nil, nil
    end
    state.live_usage, state.provider_status = nil, nil
    state.pending_events, state.last_result = {}, nil
    local session, err = make_session(cwd)
    if not session then notify(err.message, vim.log.levels.ERROR) return nil, err end
    state.session = session
    publish({ type = "messages", messages = {} })
    update_context()
    return session
  end

  local function resume_path(path)
    local store, err = require("neoagent.storage").open(path)
    if not store then notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.ERROR) return nil, err end
    local cwd = store:metadata().cwd
    activate_workspace(cwd)
    local session
    session, err = require("neoagent.session").new({ store = store })
    if not session then notify(err.message, vim.log.levels.ERROR) return nil, err end
    state.session = session
    state.store, state.store_seeded = store, true
    state.model, state.model_selection, state.thinking_level = nil, nil, nil
    state.live_usage, state.provider_status = nil, nil
    state.pending_events, state.last_result = {}, nil
    local stored = store:state()
    local workspace_default = preferences().default_model
    local candidates = {}
    if stored.model then candidates[#candidates + 1] = stored.model end
    if workspace_default and (not stored.model or workspace_default.provider ~= stored.model.provider
        or workspace_default.model ~= stored.model.model) then
      candidates[#candidates + 1] = workspace_default
    end
    for _, selected in ipairs(candidates) do
      local ok, model = pcall(require("neoagent.models").resolve, selected.provider, selected.model,
        options, auth_manager)
      if ok then
        state.model = model
        state.model_selection = util.copy(selected)
        break
      else
        notify("could not restore model " .. tostring(selected.provider) .. "/" .. tostring(selected.model)
          .. ": " .. tostring(model), vim.log.levels.WARN)
      end
    end
    if state.model then
      state.thinking_level = thinking_level(state.model, stored.thinking_level)
    end
    publish({ type = "messages", messages = session:messages() })
    update_context()
    return session
  end

  local function session_preview(path)
    local store = require("neoagent.storage").open(path)
    if not store then return "(unreadable session)" end
    for _, message in ipairs(store:load()) do
      if message.role == "user" then
        local ok, text = pcall(util.text_content, message.content)
        text = ok and util.trim(text:gsub("[%c%s]+", " ")) or ""
        if text ~= "" then
          local limit = 80
          if vim.fn.strchars(text) > limit then return vim.fn.strcharpart(text, 0, limit) .. "…" end
          return text
        end
      end
    end
    return "(no user message)"
  end

  local function session_label(path, current_path)
    local name = vim.fn.fnamemodify(path, ":t")
    local year, month, day, hour, minute, second, id = name:match(
      "^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)_([^.]+)%.jsonl$"
    )
    local label = year and string.format("%s-%s-%s %s:%s:%s · %s", year, month, day, hour, minute, second, id:sub(1, 8))
      or name
    label = label .. " — " .. session_preview(path)
    return path == current_path and "● " .. label or label
  end

  function controller:resume(path, on_resumed)
    if state.run then notify("cannot resume while the agent is running", vim.log.levels.WARN) return nil end
    if path and path ~= "" then return resume_path(vim.fn.fnamemodify(path, ":p")) end
    local options = configured().persistence
    local paths = require("neoagent.storage").list(options.directory, vim.fn.getcwd())
    if #paths == 0 then notify("no sessions found for the current directory") return nil end
    local metadata = state.session and state.session:metadata()
    local current_path = metadata and metadata.path
    local labels = {}
    for _, path in ipairs(paths) do labels[path] = session_label(path, current_path) end
    vim.ui.select(paths, {
      prompt = "Resume Neoagent session:",
      format_item = function(item) return labels[item] end,
    }, function(choice)
      if choice then
        local session = controller:resume(choice)
        if session and on_resumed then on_resumed(session) end
      end
    end)
    return true
  end

  function controller:select_model(on_selected)
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
    if not state.workspace then activate_workspace(vim.fn.getcwd()) end
    local ok, model = pcall(require("neoagent.models").resolve, provider_id, model_id, options, auth_manager)
    if not ok then notify(tostring(model), vim.log.levels.ERROR) return nil, model end
    local next_thinking = thinking_level(model, state.thinking_level)
    if state.store then
      local recorded, record_err = state.store:append_model_change(provider_id, model_id)
      if not recorded then notify(record_err.message, vim.log.levels.ERROR) return nil, record_err end
      if not state.store_seeded and next_thinking then
        recorded, record_err = state.store:append_thinking_level_change(next_thinking)
        if not recorded then notify(record_err.message, vim.log.levels.ERROR) return nil, record_err end
      end
      state.store_seeded = true
    end
    local saved, save_err = save_workspace_settings({
      default_model = { provider = provider_id, model = model_id },
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
    else
      vim.ui.input({ prompt = prompt.message .. " ", default = "" }, function(value)
        if value and value ~= "" then done.resolve(value) else done.reject(util.error("auth", "Login cancelled")) end
      end)
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
    if state.login_run then notify("a login is already active", vim.log.levels.WARN) return nil end
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
    local messages = state.session and state.session:messages() or {}
    return {
      messages = messages,
      context = context(),
      events = util.copy(state.pending_events),
      result = util.copy(state.last_result),
    }
  end

  function controller:get_session() return state.session end
  function controller:get_model() return state.model end
  function controller:config() return util.copy(options) end
  function controller:is_running() return state.run ~= nil end
  function controller:_state() return state end

  function controller:destroy()
    if state.destroyed then return end
    state.destroyed = true
    state.run_id = state.run_id + 1
    if state.run then state.run:cancel() end
    if state.login_run then state.login_run:cancel() end
    state.run, state.login_run = nil, nil
    state.listeners = {}
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end

  state.augroup = vim.api.nvim_create_augroup("NeoagentLifecycle" .. next_id, { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.augroup,
    callback = function()
      if state.run then state.run:cancel() end
      if state.login_run then state.login_run:cancel() end
    end,
  })

  return controller
end

function M.new(opts)
  return M.from_config(config.resolve(opts))
end

return M
