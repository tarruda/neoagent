local config = require("neoagent.config")
local util = require("neoagent.util")

local M = {}

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
  view = nil,
  run = nil,
  login_run = nil,
  run_id = 0,
  status = "idle",
}

local function notify(message, level)
  vim.notify("neoagent: " .. message, level or vim.log.levels.INFO)
end

local function configured()
  return config.get()
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
  return accepted
end

local function activate_workspace(cwd)
  local root = require("neoagent.fs").canonical(cwd)
  if state.workspace and state.workspace.root == root then return end
  state.workspace = require("neoagent.workspace").new({ root = root, cwd = root })
  state.workspace_settings, state.workspace_overrides = nil, {}
  state.model, state.model_selection, state.thinking_level = nil, nil, nil
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
    state.model = require("neoagent.models").resolve(selected.provider, selected.model)
    state.model_selection = util.copy(selected)
  else
    state.model = require("neoagent.models").resolve()
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

local function update_context()
  if state.view then
    state.view:set_context({
      model = model_label(),
      thinking = state.thinking_level or false,
      workspace = state.workspace and state.workspace.root or nil,
      state = state.status,
    })
  end
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
        if state.view then state.view:apply(event) end
        if event.type == "tool_end" and not event.message.isError
            and (event.call.name == "write_file" or event.call.name == "edit_file") then
          refresh_buffer(event.call.arguments.path)
        end
      end,
      on_done = function(done)
        if run_id ~= state.run_id then return end
        state.run = nil
        state.status = "idle"
        update_context()
        if state.view then state.view:finish(done) end
      end,
    })
    assert(type(run) == "table" and type(run.cancel) == "function", "interaction must return a Run")
    state.run = run
    state.status = "running"
    if state.view then
      state.view:set_messages(state.session:messages())
      state.view:set_input("")
    end
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

local function ensure_view()
  if state.view and not state.view.destroyed then return state.view end
  local options = configured()
  state.view = require("neoagent.ui").new({
    config = options.ui,
    on_submit = submit,
    on_stop = M.stop,
    on_cycle_thinking = M.cycle_thinking_level,
  })
  if state.session then state.view:set_messages(state.session:messages()) end
  update_context()
  return state.view
end

function M.setup(opts)
  if state.run then error("Cannot reconfigure neoagent while a run is active") end
  if state.view then state.view:destroy() end
  state.session, state.model, state.model_selection, state.thinking_level = nil, nil, nil, nil
  state.workspace, state.view = nil, nil
  state.workspace_settings, state.workspace_overrides = nil, {}
  state.store, state.store_seeded = nil, false
  state.status = "idle"
  return config.setup(opts)
end

function M.open()
  local ok, opened, open_err = pcall(function()
    ensure_session()
    if preferences().default_model then ensure_model() end
    local view = ensure_view()
    update_context()
    return view:open()
  end)
  if not ok then notify(util.normalize_error(opened, "ui").message, vim.log.levels.ERROR) return nil, opened end
  return opened, open_err
end

function M.close()
  if state.view then state.view:close() end
end

function M.toggle()
  local view = ensure_view()
  if view:is_open() then M.close() else return M.open() end
end

function M.send(text)
  return submit(text)
end

function M.stop()
  if not state.run then return false end
  state.status = "stopping"
  update_context()
  state.run:cancel()
  return true
end

function M.new_session()
  if state.run then notify("cannot create a session while the agent is running", vim.log.levels.WARN) return nil end
  local cwd = vim.fn.getcwd()
  local root = require("neoagent.fs").canonical(cwd)
  if state.workspace and state.workspace.root == root then
    state.model, state.model_selection, state.thinking_level = nil, nil, nil
  end
  local session, err = make_session(cwd)
  if not session then notify(err.message, vim.log.levels.ERROR) return nil, err end
  state.session = session
  if state.view then
    state.view:set_messages({})
    update_context()
  end
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
  local stored = store:state()
  local workspace_default = preferences().default_model
  local candidates = {}
  if stored.model then candidates[#candidates + 1] = stored.model end
  if workspace_default and (not stored.model or workspace_default.provider ~= stored.model.provider
      or workspace_default.model ~= stored.model.model) then
    candidates[#candidates + 1] = workspace_default
  end
  for _, selected in ipairs(candidates) do
    local ok, model = pcall(require("neoagent.models").resolve, selected.provider, selected.model)
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
  if state.view then
    state.view:set_messages(session:messages())
    update_context()
  end
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

function M.resume(path)
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
    if choice and M.resume(choice) then M.open() end
  end)
  return true
end

function M.select_model()
  if state.run then notify("cannot change model while the agent is running", vim.log.levels.WARN) return nil end
  local choices, err = require("neoagent.models").available()
  if not choices then
    notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.ERROR)
    return nil
  end
  if #choices == 0 then notify("no models configured") return nil end
  vim.ui.select(choices, { prompt = "Select Neoagent model:" }, function(choice)
    if not choice then return end
    local provider_id, model_id = choice:match("^([^/]+)/(.+)$")
    if provider_id and M.set_model(provider_id, model_id) then M.open() end
  end)
  return true
end

local function save_workspace_settings(patch)
  local options = configured().persistence
  if not state.workspace_settings or not options.workspace_settings then return true end
  local saved, err = state.workspace_settings:update(patch)
  if not saved then return nil, err end
  state.workspace_overrides = usable_workspace_settings(saved, false)
  return true
end

function M.set_model(provider_id, model_id)
  if state.run then notify("cannot change model while the agent is running", vim.log.levels.WARN) return nil end
  if not state.workspace then activate_workspace(vim.fn.getcwd()) end
  local ok, model = pcall(require("neoagent.models").resolve, provider_id, model_id)
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
  update_context()
  return model
end

function M.available_thinking_levels()
  local ok, model = pcall(ensure_model)
  if not ok then return nil, util.normalize_error(model, "model") end
  return require("neoagent.thinking").levels(model)
end

function M.get_thinking_level()
  return state.thinking_level
end

function M.set_thinking_level(level)
  if state.run then notify("cannot change thinking level while the agent is running", vim.log.levels.WARN) return nil end
  if not require("neoagent.thinking").is_level(level) then
    notify("unknown thinking level: " .. tostring(level), vim.log.levels.ERROR)
    return nil
  end
  local levels, err = M.available_thinking_levels()
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

function M.cycle_thinking_level()
  if state.run then notify("cannot change thinking level while the agent is running", vim.log.levels.WARN) return nil end
  local ok, model = pcall(ensure_model)
  if not ok then notify(util.normalize_error(model, "model").message, vim.log.levels.ERROR) return nil end
  local level = require("neoagent.thinking").next(model, state.thinking_level)
  if not level then notify("current model does not support thinking", vim.log.levels.WARN) return nil end
  level = M.set_thinking_level(level)
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

function M.login(method_id)
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
    }, function(choice) if choice then M.login(choice.id) end end)
    return true
  end
  if not methods[method_id] then notify("unknown login method: " .. method_id, vim.log.levels.ERROR) return nil end
  local run = require("neoagent.auth").configured():login(method_id, {
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

function M.cancel_login()
  if not state.login_run then return false end
  state.login_run:cancel()
  return true
end

function M.get_session() return state.session end
function M.get_model() return state.model end
function M._state() return state end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("NeoagentLifecycle", { clear = true }),
  callback = function()
    if state.run then state.run:cancel() end
    if state.login_run then state.login_run:cancel() end
  end,
})

return M
