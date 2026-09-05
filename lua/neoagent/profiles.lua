local Agent = require("neoagent.agent")
local AgentApplet = require("neoagent.agent_applet")
local provider_runtimes = require("neoagent.provider_runtimes")
local util = require("neoagent.util")
local workspace_preferences = require("neoagent.workspace_preferences")

local M = {}

local function configured_toolset(configured)
  return {
    tools = configured._tools_supplied and util.copy(configured.tools)
      or require("neoagent.tools").coding({
        shell_timeout = configured.shell_timeout,
      }),
    execute_tool = configured.execute_tool,
  }
end

local function trust_protected(configured, toolset)
  return #toolset.tools > 0
    or configured.agent_instructions ~= false
      and #configured.agent_instructions.project_filenames > 0
    or configured.skills ~= false
      and #configured.skills.project_dirs > 0
end

local function catalog_store()
  return require("neoagent.state_store").new({
    directory = vim.fn.stdpath("state") .. "/neoagent/provider/state",
  })
end

local function preference_defaults(configured)
  return {
    default_model = configured.default_model,
    default_thinking_level = configured.default_thinking_level,
    ui_position = configured.ui.position,
  }
end

local function draft_options(configured, profile_id, presenter, workspace)
  local persistence = configured.persistence
  if not persistence.enabled or not persistence.workspace_settings then
    return {}
  end
  local store = require("neoagent.workspace_settings").new({
    directory = persistence.directory,
    root = workspace,
  })
  local settings, err = store:load()
  local path = store:metadata().settings_path
  if not settings then
    presenter:notify({
      message = "neoagent: " .. err.message
        .. (err.detail and ": " .. err.detail or "")
        .. "; the file may be outdated, update or delete " .. path,
      level = vim.log.levels.WARN,
    })
    return {}
  end
  local selected, issues = workspace_preferences.scope(
    settings, preference_defaults(configured), profile_id)
  local warning = workspace_preferences.warning(issues, path)
  if warning then
    presenter:notify({
      message = "neoagent: " .. warning,
      level = vim.log.levels.WARN,
    })
  end
  local options = {}
  if selected.default_model ~= nil then
    options.default_model = selected.default_model
  end
  if selected.default_thinking_level ~= nil then
    options.default_thinking_level = selected.default_thinking_level
  end
  if selected.ui_position ~= nil then
    options.ui = { position = selected.ui_position }
  end
  return options
end

local function applet_factory(
    configured, profile_id, profile_label, auth, runtimes)
  return function(context)
    local presenter = require("neoagent.presenter").new()
    local built, applet, options = pcall(function()
      local workspace = require("neoagent.fs").canonical(context.workspace)
      local draft = draft_options(
        configured, profile_id, presenter, workspace)
      local selected_model = draft.default_model or configured.default_model
      if not selected_model then
        local fallback, err = require("neoagent.models").first_available(
          configured, auth, runtimes)
        if err then
          presenter:notify({
            message = "neoagent: " .. err.message
              .. (err.detail and ": " .. err.detail or ""),
            level = vim.log.levels.ERROR,
          })
        elseif fallback then
          selected_model = fallback
          draft.default_model = util.copy(fallback)
        end
      end
      local selected_thinking = draft.default_thinking_level
      if selected_thinking == nil then
        selected_thinking = configured.default_thinking_level
      end
      local model_label = "no model"
      if selected_model then
        model_label = selected_model.provider .. "/" .. selected_model.model
      end
      local value = AgentApplet.new({
        config = util.deep_merge(
          util.deep_merge(configured.ui, draft.ui or {}), context.ui or {}),
        persistence = configured.persistence,
        context = {
          model = model_label,
          thinking = selected_thinking or false,
          workspace = workspace,
          state = "idle",
        },
        profile_id = profile_id,
        label = context.label or profile_label,
        presenter = presenter,
        view = configured._view,
      })
      return value, draft
    end)
    if not built then
      presenter:destroy()
      error(applet, 0)
    end
    return applet, options
  end
end

local function agent_options(configured, context)
  local selected = util.copy(configured)
  for key, value in pairs(context.options or {}) do
    if key == "ui" or key == "sandbox" then
      selected[key] = util.deep_merge(selected[key], value)
    else
      selected[key] = util.copy(value)
    end
  end
  local selection = context.initial_selection
  if selection then
    selected.default_model = util.copy(selection.model)
    selected.default_thinking_level = selection.thinking_level
  end
  return selected
end

local function make_chat(configured, auth, runtimes, runtime)
  local chat = util.copy(configured)
  chat.name = "Chat"
  chat.sandbox.enabled = false
  chat.tools = {}
  chat._tools_supplied = true
  chat.system_prompt = ""
  chat.agent_instructions = false
  chat.skills = false
  return {
    id = "chat",
    label = "Chat",
    config = chat,
    create_applet = applet_factory(
      chat, "chat", "Chat", auth, runtimes),
    create_agent = function(context)
      local selected = agent_options(chat, context)
      return Agent.from_config(selected, {
        id = context.id,
        profile_id = "chat",
        label = context.label,
        initial_selection = context.initial_selection,
        session = context.session,
        workspace = context.workspace,
        restore_session_selection = context.restore_session_selection,
        commit_workspace_preference = context.commit_workspace_preference,
        runtimes = runtimes,
        auth = auth,
        presenter = context.applet:presenter(),
        dialogs = context.applet:dialogs(),
        interaction = runtime.interaction,
        compaction_run = runtime.compaction_run,
      })
    end,
  }
end

local function make_neo(configured, auth, runtimes, runtime)
  local neo = util.copy(configured)
  neo.name = neo.name or "Neo"
  return {
    id = "neo",
    label = neo.name,
    config = neo,
    create_applet = applet_factory(
      neo, "neo", neo.name, auth, runtimes),
    create_agent = function(context)
      local selected = agent_options(neo, context)
      local applet = context.applet
      local dialogs = applet:dialogs()
      local host_toolset = configured_toolset(selected)
      local composition = require("neoagent.sandbox.composition")
      local toolset, status, _, sandbox_runtime = composition.switchable(
        host_toolset, selected.sandbox, { dialogs = dialogs })
      local warning
      if selected.sandbox.enabled and not status.active then
        warning = composition.warning(context.label, status)
      end
      local trust
      if selected.workspace_trust and trust_protected(selected, host_toolset) then
        trust = require("neoagent.workspace_trust").new({
          path = selected.workspace_trust.path,
          dialogs = dialogs,
          sandbox_status = status,
          agent = context.label,
          notify = function(err)
            applet:presenter():notify({
              message = "neoagent: " .. err.message,
              level = vim.log.levels.ERROR,
            })
          end,
        })
      elseif warning then
        selected._sandbox_warning = warning
      end
      local agent = Agent.from_config(selected, {
        id = context.id,
        profile_id = "neo",
        label = context.label,
        initial_selection = context.initial_selection,
        session = context.session,
        workspace = context.workspace,
        restore_session_selection = context.restore_session_selection,
        commit_workspace_preference = context.commit_workspace_preference,
        workspace_trust = trust,
        runtimes = runtimes,
        auth = auth,
        presenter = applet:presenter(),
        dialogs = dialogs,
        interaction = runtime.interaction,
        compaction_run = runtime.compaction_run,
      })
      assert(agent:set_toolset(toolset))
      if trust then
        trust:attach({
          close = function() applet:close() end,
          on_result = function(result)
            if applet:is_destroyed() then return end
            if applet:pending_message() then
              applet:trust_submission_result(result)
              return
            end
            if not result.ok then return end
            local prepared, err = agent:prepare()
            if not prepared and err then
              applet:presenter():notify({
                message = "neoagent: " .. err.message,
                level = vim.log.levels.ERROR,
              })
            end
          end,
        })
      end
      return agent, {
        sandbox = {
          runtime = sandbox_runtime,
          status = util.copy(status),
          trust = trust,
        },
      }
    end,
  }
end

function M.bundled(configured, runtime)
  assert(type(configured) == "table",
    "Profile configuration is required")
  runtime = runtime or {}
  assert(type(runtime) == "table"
      and (next(runtime) == nil or not util.is_list(runtime)),
    "Profile runtime must be an object")
  local pending_reports = {}
  local report_target
  local function provider_report(message, level)
    if report_target then return report_target(message, level) end
    if #pending_reports < 64 then
      pending_reports[#pending_reports + 1] = { message, level }
    end
    return true
  end
  local transport = runtime.transport
  local recorder
  if configured.recording and configured.recording.enabled then
    local recording_err
    recorder, recording_err = require("neoagent.http_recording").new({
      config = configured.recording,
      report = provider_report,
    })
    if not recorder then error(recording_err, 0) end
    transport = recorder:transport(
      transport or require("neoagent.transport.curl"))
  end
  local auth = require("neoagent.auth").configured(configured, {
    transport = transport,
  })
  local runtimes, err = provider_runtimes.compose(configured, {
    auth = auth,
    store = runtime.store or catalog_store(),
    startup = runtime.startup,
    report = provider_report,
    transport = transport,
  })
  if not runtimes then
    if recorder then recorder:destroy() end
    error(err, 0)
  end
  local shell_ok, shell = pcall(require("neoagent.provider_shell").new, {
    config = configured,
    auth = auth,
    runtimes = runtimes,
    view = runtime.provider_view,
    host = runtime.provider_host,
  })
  if not shell_ok then
    provider_runtimes.destroy(runtimes)
    if recorder then recorder:destroy() end
    error(shell, 0)
  end
  report_target = function(message, level)
    return shell:report(message, level)
  end
  for _, entry in ipairs(pending_reports) do
    report_target(entry[1], entry[2])
  end
  pending_reports = {}
  local resources = {
    auth = auth,
    runtimes = runtimes,
    provider_shell = shell,
    recorder = recorder,
    destroyed = false,
  }
  function resources:destroy()
    if self.destroyed then return end
    self.destroyed = true
    self.provider_shell:destroy()
    provider_runtimes.destroy(self.runtimes)
    if self.recorder then self.recorder:destroy() end
  end
  return {
    make_neo(configured, auth, runtimes, runtime),
    make_chat(configured, auth, runtimes, runtime),
  }, "neo", resources
end

return M
