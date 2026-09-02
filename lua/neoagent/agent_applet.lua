local Applet = require("applet")
local async = require("neoagent.async")
local renderer_protocol = require("neoagent.ui.renderer")
local renderers = require("neoagent.ui.renderers")
local util = require("neoagent.util")

local M = {}
local AgentApplet = {}
AgentApplet.__index = AgentApplet

local positions = {
  auto = true,
  left = true,
  right = true,
  top = true,
  bottom = true,
  center = true,
}

local owner_callback_names = {
  on_bind = true,
  on_accept = true,
  on_reject = true,
  on_close = true,
  on_destroy = true,
  on_agents = true,
  on_cycle_thinking = true,
  on_select_model = true,
  on_resume_session = true,
  on_provider_shell = true,
}

local function validate_owner_callbacks(callbacks)
  assert(type(callbacks) == "table"
      and (next(callbacks) == nil or not util.is_list(callbacks)),
    "Agent Applet owner callbacks must be an object")
  for name, callback in pairs(callbacks) do
    assert(owner_callback_names[name],
      "Unknown Agent Applet owner callback: " .. tostring(name))
    assert(type(callback) == "function",
      "Agent Applet " .. name .. " must be a function")
  end
end

local function assert_agent(agent)
  assert(type(agent) == "table" and agent._neoagent_agent,
    "Agent Applet requires a Neoagent Agent")
end

local function presentation_attention(snapshot)
  local active = snapshot and snapshot.active
  if not active then return nil end
  return { kind = active.kind, label = active.prompt }
end

local function dialog_attention(snapshot)
  local active = snapshot and snapshot.active
  if not active then return nil end
  return { kind = "dialog", label = active.title }
end

local required_view_methods = {
  "open", "close", "is_open", "destroy", "get_input", "set_input",
  "set_messages", "set_context", "apply", "finish",
}

local function call_view(view, method, ...)
  local ok, value, err = pcall(view[method], view, ...)
  if not ok then return nil, util.normalize_error(value, "ui") end
  if value == false or (value == nil and err ~= nil) then
    return nil, util.normalize_error(err or (method .. " failed"), "ui")
  end
  return true, value
end

local function valid_snapshot(snapshot)
  return type(snapshot) == "table"
    and (next(snapshot) == nil or not util.is_list(snapshot))
    and type(snapshot.revision) == "number" and snapshot.revision >= 0
    and snapshot.revision % 1 == 0
    and type(snapshot.messages) == "table" and util.is_list(snapshot.messages)
    and type(snapshot.context) == "table"
    and (next(snapshot.context) == nil or not util.is_list(snapshot.context))
    and type(snapshot.events) == "table" and util.is_list(snapshot.events)
end

function AgentApplet.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table",
    "Agent Applet UI config is required")
  assert(opts.context == nil
      or type(opts.context) == "table" and not util.is_list(opts.context),
    "Agent Applet context must be an object")

  local owns_presenter = opts.presenter == nil
  local owns_dialogs = opts.dialogs == nil
  local presenter = opts.presenter or require("neoagent.presenter").new()
  local function report(message, level)
    return presenter:notify({ message = message, level = level })
  end
  local dialogs = opts.dialogs or require("neoagent.dialog").new({
    report = report,
  })
  local selected = opts.config.renderer or renderers.get(opts.config.style)
  renderer_protocol.assert(selected, "Agent Applet Renderer")

  local draft_context = util.copy(opts.context or {})
  local self = setmetatable({
    _neoagent_agent_applet = true,
    config = util.copy(opts.config),
    persistence = util.copy(opts.persistence),
    profile = opts.profile_id,
    display_label = opts.label or "Agent",
    presenter_source = presenter,
    dialog_source = dialogs,
    owns_presenter = owns_presenter,
    owns_dialogs = owns_dialogs,
    view_factory = opts.view,
    host = opts.host,
    owner_value = nil,
    owner_callbacks = nil,
    renderer = selected,
    transcript_style = opts.config.style,
    position = opts.config.position,
    draft_context = draft_context,
    agent_value = nil,
    agent_snapshot = nil,
    view_value = nil,
    agent_unsubscribe = nil,
    binding_restore = nil,
    presenter_unsubscribe = nil,
    dialog_unsubscribe = nil,
    presentation = nil,
    dialog = nil,
    workspace_root = draft_context.workspace,
    histories = {},
    history_stores = {},
    input_value = "",
    input_submission_id = nil,
    pending_submission = nil,
    submissions = {},
    destroyed = false,
  }, AgentApplet)

  self.dialog_unsubscribe = dialogs:subscribe(function(snapshot)
    self.dialog = snapshot.active and util.copy(snapshot) or nil
    self:_set_attention("dialog", dialog_attention(snapshot))
    local view = self.view_value
    if not self.destroyed and view and not view.destroyed then
      self:_set_view_dialog(view)
    end
  end)
  self.presenter_unsubscribe = presenter:attach({
    present = function(snapshot)
      if self.destroyed then error("Agent Applet is destroyed", 0) end
      self.presentation = snapshot.active and util.copy(snapshot) or nil
      self:_set_attention("presentation", presentation_attention(snapshot))
      local view = self.view_value
      if view and not view.destroyed then
        local presented, err = self:_set_view_presentation(view)
        if not presented then
          self.presentation = nil
          self:_set_attention("presentation", nil)
          error(err, 0)
        end
      end
      return true
    end,
    notify = function(message, level)
      local view = self.view_value
      if view and not view.destroyed and type(view.notify) == "function" then
        return view:notify(message, level)
      end
      return Applet.Presenter.notify(message, level)
    end,
    open_uri = function(uri)
      local view = self.view_value
      if view and not view.destroyed and type(view.open_uri) == "function" then
        return view:open_uri(uri)
      end
      return Applet.Presenter.open_uri(uri)
    end,
  })

  if opts.agent then
    local bound, err = pcall(self.bind, self, opts.agent)
    if not bound then
      self:destroy()
      error(err, 0)
    end
  end
  return self
end

function AgentApplet:claim(owner, callbacks)
  assert(not self.destroyed, "Agent Applet is destroyed")
  assert(type(owner) == "table", "Agent Applet owner must be a table")
  validate_owner_callbacks(callbacks)
  assert(self.owner_value == nil or self.owner_value == owner,
    "Agent Applet already has an owner")
  if self.owner_value == owner then return self end
  self.owner_value = owner
  self.owner_callbacks = util.copy(callbacks)
  return self
end

function AgentApplet:release(owner)
  assert(self.owner_value == owner,
    "Agent Applet is not owned by the caller")
  self.owner_value = nil
  self.owner_callbacks = nil
  return self
end

function AgentApplet:owner() return self.owner_value end

function AgentApplet:_owner_callback(name, ...)
  local callback = self.owner_callbacks and self.owner_callbacks[name]
  if not callback then return false end
  return callback(self, ...) or false
end

function AgentApplet:_notify(message, level)
  return self.presenter_source:notify({
    message = "neoagent: " .. message,
    level = level or vim.log.levels.INFO,
  })
end

function AgentApplet:_set_view_presentation(view)
  if type(view.set_presentation) ~= "function" then
    if not self.presentation then return true end
    return nil, util.error("ui",
      "the active View does not support semantic presentations")
  end
  local ok, shown, err = pcall(
    view.set_presentation, view, self.presentation)
  if ok and shown ~= false and err == nil then return true end
  return nil, util.normalize_error(ok and err or shown, "ui")
end

function AgentApplet:_set_view_dialog(view)
  if type(view.set_dialog) ~= "function" then
    if not self.dialog then return true end
    local err = util.error("ui", "the active View does not support dialogs")
    self.dialog_source:cancel_pending(err.message, {
      presenter_unavailable = true,
    })
    return nil, err
  end
  local ok, shown, err = pcall(view.set_dialog, view, self.dialog)
  if ok and shown ~= false and err == nil then return true end
  local failure = util.normalize_error(ok and err or shown, "ui")
  local unavailable = { presenter_unavailable = true }
  self.dialog_source:cancel_pending(
    "Dialog presentation failed: " .. failure.message, unavailable)
  return nil, failure
end

function AgentApplet:_set_attention(source, value)
  local agent = self.agent_value
  if agent and not agent:is_destroyed() then
    agent:set_attention(source, value)
  end
end

function AgentApplet:_history_store(root)
  local persistence = self.persistence
  if not persistence or not persistence.enabled then return nil end
  if not self.history_stores[root] then
    self.history_stores[root] = require("neoagent.input_history").new({
      directory = persistence.directory,
      root = root,
    })
  end
  return self.history_stores[root]
end

function AgentApplet:_load_history(root, refresh)
  if not root then return {} end
  if self.histories[root] and not refresh then return self.histories[root] end
  local store = self:_history_store(root)
  if not store then
    self.histories[root] = self.histories[root] or {}
    return self.histories[root]
  end
  local history, err = store:load()
  if not history then
    self:_notify(err.message .. (err.detail and ": " .. err.detail or ""),
      vim.log.levels.WARN)
    self.histories[root] = self.histories[root] or {}
    return self.histories[root]
  end
  self.histories[root] = history
  return history
end

function AgentApplet:_select_workspace(root)
  local changed = self.workspace_root ~= root
  self.workspace_root = root
  self:_load_history(root)
  return changed
end

function AgentApplet:_record_history(text)
  local root = self.workspace_root
  text = util.trim(text)
  if not root or text == "" then return true end
  local store = self:_history_store(root)
  if not store then
    local history = self:_load_history(root)
    if history[1] ~= text then
      table.insert(history, 1, text)
      if #history > 100 then table.remove(history) end
    end
    return true
  end
  local history, err = store:add(text)
  if not history then
    self:_notify("input history was not saved: " .. err.message,
      vim.log.levels.WARN)
    return nil, err
  end
  self.histories[root] = history
  return true
end

function AgentApplet:_context_for(value, bound, label)
  value = bound and util.copy(value or {})
    or util.deep_merge(self.draft_context, value or {})
  value.name = label or self.display_label
  value.position = value.position or self.position
  value.model = value.model or "no model"
  value.state = value.state or "idle"
  if not bound then
    value.context_usage = value.context_usage or false
    value.provider_status = value.provider_status or false
    value.inference_stats = value.inference_stats or false
    value.steering = value.steering or {}
  end
  return value
end

function AgentApplet:_context(value)
  return self:_context_for(value, self.agent_value ~= nil)
end

function AgentApplet:_capture_input(view)
  if not view or type(view.get_input) ~= "function" then
    return self.input_value
  end
  local ok, value = pcall(view.get_input, view)
  if ok and type(value) == "string" then
    if value ~= self.input_value then self.input_submission_id = nil end
    self.input_value = value
  end
  return self.input_value
end

function AgentApplet:_restore_input(value)
  local view = self.view_value
  local current = self:_capture_input(view)
  if current ~= "" and current ~= value then return current end
  self.input_value = value
  if view and not view.destroyed then
    local restored, err = call_view(view, "set_input", value)
    if not restored then self:_notify(err.message, vim.log.levels.ERROR) end
  end
  return value
end

function AgentApplet:_hydrate_view(view, snapshot, label)
  assert(valid_snapshot(snapshot), "Agent snapshot is invalid")
  local context = self:_context_for(snapshot.context, true, label)
  local applied, err
  if positions[snapshot.context.position]
      and type(view.set_position) == "function" then
    applied, err = call_view(
      view, "set_position", snapshot.context.position)
    if not applied then return nil, err end
  end
  applied, err = call_view(view, "set_messages", util.copy(snapshot.messages))
  if not applied then return nil, err end
  applied, err = call_view(view, "set_context", context)
  if not applied then return nil, err end
  for _, event in ipairs(snapshot.events) do
    applied, err = call_view(view, "apply", util.copy(event))
    if not applied then return nil, err end
  end
  if snapshot.result then
    applied, err = call_view(view, "finish", util.copy(snapshot.result))
    if not applied then return nil, err end
  end
  return {
    snapshot = util.copy(snapshot),
    workspace = snapshot.context.workspace,
    position = positions[snapshot.context.position]
      and snapshot.context.position or nil,
  }
end

function AgentApplet:set_draft_context(patch)
  assert(type(patch) == "table" and not util.is_list(patch),
    "Agent Applet draft context must be an object")
  if self:_agent_or_nil() then
    return nil, util.error("agent",
      "A bound Agent owns the Applet context")
  end
  self.draft_context = util.deep_merge(self.draft_context, patch)
  if patch.workspace ~= nil then self:_select_workspace(patch.workspace) end
  local context = self:_context()
  local view = self.view_value
  if view and not view.destroyed then view:set_context(context) end
  return util.copy(context)
end

function AgentApplet:_sync_position(context, view)
  local position = context and context.position
  if not positions[position] or position == self.position then return false end
  self.position = position
  if view and not view.destroyed and type(view.set_position) == "function" then
    view:set_position(position)
  end
  return true
end

function AgentApplet:_apply(update)
  local snapshot = self.agent_snapshot or {
    revision = 0,
    messages = {},
    context = {},
    events = {},
    result = nil,
  }
  assert(type(update.revision) == "number"
      and update.revision >= 1 and update.revision % 1 == 0,
    "Agent publication revision must be a positive integer")
  if update.revision <= (snapshot.revision or 0) then return false end
  self.agent_snapshot = snapshot
  if update.type == "context" then
    snapshot.context = util.copy(update.context)
  elseif update.type == "messages" then
    snapshot.messages = util.copy(update.messages)
    snapshot.events = {}
    snapshot.result = nil
  elseif update.type == "event" then
    if update.event.type == "message_end" then
      snapshot.events = {}
    elseif update.event.type ~= "usage"
        and update.event.type ~= "provider_status"
        and update.event.type ~= "inference_stats" then
      snapshot.events[#snapshot.events + 1] = util.copy(update.event)
    end
  elseif update.type == "finish" then
    snapshot.result = util.copy(update.result)
  elseif update.type == "submission_accepted" then
    self:_submission_accepted(update)
  end
  snapshot.revision = update.revision

  local view = self.view_value
  if not view or view.destroyed then
    if update.type == "finish" then self:_finish_submissions(update.result) end
    return
  end
  if update.type == "context" then
    self:_sync_position(update.context, view)
    if self:_select_workspace(update.context.workspace) then
      view:set_input(view:get_input())
    end
    view:set_context(self:_context(update.context))
  elseif update.type == "messages" then
    view:set_messages(update.messages)
  elseif update.type == "event" then
    if update.event.type ~= "inference_stats" then view:apply(update.event) end
  elseif update.type == "finish" then
    view:finish(update.result)
    self:_finish_submissions(update.result)
  end
end

function AgentApplet:_hydrate(snapshot)
  local agent = self.agent_value
  if not agent then return true end
  if not snapshot then
    local ok, value = pcall(agent.snapshot, agent)
    if not ok then return nil, util.normalize_error(value, "agent") end
    snapshot = value
  end
  assert(valid_snapshot(snapshot), "Agent snapshot is invalid")
  local current = self.agent_snapshot
  if current and (current.revision or 0) > snapshot.revision then
    snapshot = current
  end
  local view = self.view_value
  local hydrated
  if view and not view.destroyed then
    local err
    hydrated, err = self:_hydrate_view(view, snapshot, self.display_label)
    if not hydrated then return nil, err end
  else
    hydrated = {
      snapshot = util.copy(snapshot),
      workspace = snapshot.context.workspace,
      position = positions[snapshot.context.position]
        and snapshot.context.position or nil,
    }
  end
  self.agent_snapshot = hydrated.snapshot
  self:_select_workspace(hydrated.workspace)
  if hydrated.position then self.position = hydrated.position end
  return true
end

function AgentApplet:_agent_or_nil()
  local agent = self.agent_value
  if agent and not agent:is_destroyed() then return agent end
end

function AgentApplet:_ensure_agent(value)
  local agent = self:_agent_or_nil()
  local created = false
  if not agent then
    local on_bind = self.owner_callbacks and self.owner_callbacks.on_bind
    if not on_bind then
      return nil, util.error("agent", "No Agent is bound")
    end
    local bound, err = on_bind(self, value)
    if not bound then return nil, err end
    agent = self:_agent_or_nil()
    if not agent then
      return nil, util.error("agent",
        "Agent construction did not bind the Applet")
    end
    created = true
  end
  return agent, nil, created
end

function AgentApplet:_reject_agent(agent, err, text)
  text = text or self.pending_submission
  self.pending_submission = nil
  self.input_submission_id = nil
  self.submissions = {}
  if self:_agent_or_nil() == agent then
    self:_owner_callback("on_reject", agent)
  end
  if text then self:_restore_input(text) end
  return nil, err
end

function AgentApplet:_queue_submission(
    agent, text, created, submission_id, kind)
  assert(type(submission_id) == "number" and submission_id >= 1
      and submission_id % 1 == 0,
    "Agent submission id must be a positive integer")
  assert(kind == "turn" or kind == "steering",
    "Agent submission kind is invalid")
  local submission = {
    id = submission_id,
    agent = agent,
    text = text,
    created = created == true,
    kind = kind,
  }
  self.submissions[#self.submissions + 1] = submission
  self.input_submission_id = submission_id
  return submission
end

function AgentApplet:_clear_submission_input(submission)
  if submission.kind ~= "steering"
      or self.input_submission_id ~= submission.id then
    return false
  end
  local view = self.view_value
  local current = self:_capture_input(view)
  if current ~= submission.text then return false end
  if view and not view.destroyed then
    local cleared, err = call_view(view, "set_input", "")
    if not cleared then
      self:_notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
  end
  self.input_value = ""
  submission.input_cleared = true
  return true
end

function AgentApplet:_submission(id)
  for index, submission in ipairs(self.submissions) do
    if submission.id == id then return submission, index end
  end
end

function AgentApplet:_forget_submissions(ids)
  local selected = {}
  for _, id in ipairs(ids or {}) do selected[id] = true end
  local retained = {}
  for _, submission in ipairs(self.submissions) do
    if not selected[submission.id] then retained[#retained + 1] = submission end
  end
  self.submissions = retained
  if selected[self.input_submission_id] then self.input_submission_id = nil end
end

function AgentApplet:_submission_accepted(update)
  local selected, index = self:_submission(update.submission_id)
  if not selected or selected.agent ~= self:_agent_or_nil() then return false end
  table.remove(self.submissions, index)
  if selected.created then self:_accept_agent(selected.agent) end
  self.pending_submission = nil
  self:_record_history(selected.text)
  local view = self.view_value
  local current = self:_capture_input(view)
  if self.input_submission_id == selected.id then
    self.input_submission_id = nil
    if current == selected.text then self.input_value = "" end
  end
  if view and not view.destroyed then
    if type(view.submission_accepted) == "function" then
      local accepted, err = call_view(
        view, "submission_accepted", selected.text)
      if not accepted then self:_notify(err.message, vim.log.levels.ERROR) end
    elseif current == selected.text then
      local cleared, err = call_view(view, "set_input", "")
      if not cleared then self:_notify(err.message, vim.log.levels.ERROR) end
    end
  end
  return true
end

function AgentApplet:_finish_submissions(result)
  local retained = {}
  local rejected
  local restore
  for _, submission in ipairs(self.submissions) do
    if submission.created and not rejected then
      rejected = submission
    elseif submission.kind == "steering" then
      retained[#retained + 1] = submission
      if not result.ok and submission.input_cleared
          and self.input_submission_id == submission.id then
        restore = submission
      end
    end
  end
  self.submissions = retained
  if restore and self:_restore_input(restore.text) == restore.text then
    restore.input_cleared = false
  end
  if rejected then
    self:_reject_agent(rejected.agent, result.error, rejected.text)
  end
end

function AgentApplet:_accept_agent(agent)
  if self:_agent_or_nil() ~= agent or not self.binding_restore then return false end
  self.binding_restore = nil
  self:_owner_callback("on_accept", agent)
  return true
end

function AgentApplet:_attempt_submission(text)
  if util.trim(text) == "" then return nil end
  local agent, agent_err, created = self:_ensure_agent(text)
  if not agent then
    self:_restore_input(text)
    return nil, agent_err
  end
  self:_restore_input(text)
  local provisional = created or self.binding_restore ~= nil
  local prepared, prepare_err = agent:prepare()
  if not prepared then
    if prepare_err and prepare_err.kind == "workspace_trust"
        and prepare_err.pending == true then
      self.pending_submission = text
      return nil, prepare_err
    end
    if provisional then
      return self:_reject_agent(agent, prepare_err, text)
    end
    return nil, prepare_err
  end
  local represented = self.input_submission_id and self:_submission(
    self.input_submission_id) or nil
  if represented and represented.agent == agent
      and represented.kind == "steering" then
    if agent:is_running() then return true end
    local resumed, resume_err = agent:resubmit_steering(represented.id)
    if resumed then
      self:_clear_submission_input(represented)
      return resumed, resume_err
    end
    if not resume_err or resume_err.kind ~= "steering" then
      return nil, resume_err
    end
    self:_forget_submissions({ represented.id })
  end
  local run, err, submission_id, kind = agent:send(text)
  if run then
    self.pending_submission = nil
    local submission = self:_queue_submission(
      agent, text, provisional, submission_id, kind)
    self:_clear_submission_input(submission)
  elseif err and err.kind == "workspace_trust" and err.pending == true then
    self.pending_submission = text
  else
    self.pending_submission = nil
    if provisional then return self:_reject_agent(agent, err, text) end
  end
  return run, err
end

function AgentApplet:_submit(text)
  return self:_attempt_submission(text)
end

function AgentApplet:retry_submission()
  local text = self.pending_submission
  if not text or not self:_agent_or_nil() then return false end
  return self:_attempt_submission(text)
end

function AgentApplet:trust_submission_result(result)
  local text = self.pending_submission
  local agent = self:_agent_or_nil()
  if not text or not agent then return false end
  if result.ok then return self:retry_submission() end
  self.pending_submission = nil
  if self.binding_restore then
    return self:_reject_agent(agent, result.error, text)
  end
  return nil, result.error
end

function AgentApplet:pending_message()
  return self.pending_submission
end

function AgentApplet:_dequeue_steering()
  local agent = self:_agent_or_nil()
  if not agent then return {} end
  local view = self.view_value
  local current = self:_capture_input(view)
  local messages, ids = agent:dequeue_steering()
  local represented = self.input_submission_id and self:_submission(
    self.input_submission_id) or nil
  if represented and current == represented.text then
    self.input_value = ""
    if view and not view.destroyed then pcall(view.set_input, view, "") end
  end
  self:_forget_submissions(ids)
  return messages
end

function AgentApplet:_ensure_view()
  local view = self.view_value
  if view and not view.destroyed then return view end
  self:_capture_input(view)
  local factory = self.view_factory or require("neoagent.ui").new
  local view_config = util.copy(self.config)
  view_config.style = self.transcript_style
  view_config.renderer = self.renderer
  local candidate
  local built, staged = pcall(function()
    candidate = factory({
    config = view_config,
    host = self.host,
    on_submit = function(prompt) return self:_submit(prompt) end,
    on_stop = function()
      local agent = self:_agent_or_nil()
      return agent and agent:stop() or false
    end,
    on_dequeue_steering = function()
      return self:_dequeue_steering()
    end,
    on_input_history = function() return self:input_history() end,
    on_select_history = function() return self:select_input_history() end,
    on_cycle_thinking = function()
      local agent = self:_agent_or_nil()
      if agent then return agent:cycle_thinking_level() end
      return self:_owner_callback("on_cycle_thinking")
    end,
    on_agents = function()
      return self:_owner_callback("on_agents")
    end,
    on_select_model = function()
      local agent = self:_agent_or_nil()
      if agent then return agent:select_model() end
      return self:_owner_callback("on_select_model")
    end,
    on_resume_session = function()
      return self:_owner_callback("on_resume_session")
    end,
    resolve_tool = function(name)
      local agent = self:_agent_or_nil()
      if not agent then return end
      for _, tool in ipairs(agent:get_toolset().tools) do
        if tool.name == name then return tool end
      end
    end,
    on_dialog_action = function(id, action, input)
      return self.dialog_source:choose(id, action, input)
    end,
    on_dialog_dismiss = function(id)
      return self.dialog_source:cancel(id, "dialog dismissed by user")
    end,
    on_provider_shell = function()
      return self:_owner_callback("on_provider_shell")
    end,
    on_help = function(request)
      return self.presenter_source:notice(request)
    end,
    on_presentation_resolve = function(id, value)
      return self.presenter_source:resolve(id, value)
    end,
    on_presentation_cancel = function(id)
      return self.presenter_source:cancel(id)
    end,
    on_close = function()
      if not self.destroyed then self:_owner_callback("on_close") end
    end,
    })
    assert(type(candidate) == "table", "View factory must return a View")
    for _, method in ipairs(required_view_methods) do
      assert(type(candidate[method]) == "function",
        "View must implement " .. method)
    end
    local applied, err = call_view(candidate, "set_input", self.input_value)
    if not applied then error(err, 0) end
    applied, err = call_view(candidate, "set_context",
      self:_context_for(nil, false))
    if not applied then error(err, 0) end
    if self.dialog then
      if type(candidate.set_dialog) ~= "function" then
        error(util.error("ui",
          "the active View does not support dialogs"), 0)
      end
      applied, err = call_view(
        candidate, "set_dialog", util.copy(self.dialog))
      if not applied then error(err, 0) end
    end
    if self.presentation then
      if type(candidate.set_presentation) ~= "function" then
        error(util.error("ui",
          "the active View does not support semantic presentations"), 0)
      end
      applied, err = call_view(
        candidate, "set_presentation", util.copy(self.presentation))
      if not applied then error(err, 0) end
    end
    local agent = self:_agent_or_nil()
    local hydrated
    if agent then
      local snapshot = self.agent_snapshot
      if not snapshot then
        local snapped, value = pcall(agent.snapshot, agent)
        if not snapped then error(value, 0) end
        snapshot = value
      end
      local label = type(agent.label) == "function"
        and agent:label() or self.display_label
      while true do
        hydrated, err = self:_hydrate_view(
          candidate, snapshot, label)
        if not hydrated then error(err, 0) end
        local newest = self.agent_snapshot
        if not newest or newest.revision <= snapshot.revision then break end
        snapshot = newest
      end
    end
    return { view = candidate, hydrated = hydrated }
  end)
  if not built then
    if candidate and type(candidate.destroy) == "function"
        and not candidate.destroyed then
      pcall(candidate.destroy, candidate)
    end
    self.view_value = nil
    error(util.normalize_error(staged, "ui").message, 0)
  end
  self.view_value = staged.view
  if staged.hydrated then
    self.agent_snapshot = staged.hydrated.snapshot
    self:_select_workspace(staged.hydrated.workspace)
    if staged.hydrated.position then
      self.position = staged.hydrated.position
    end
  end
  return staged.view
end

function AgentApplet:bind(agent, opts)
  assert(not self.destroyed, "Agent Applet is destroyed")
  assert_agent(agent)
  opts = opts or {}
  assert(type(opts) == "table"
      and (next(opts) == nil or not util.is_list(opts)),
    "Agent Applet bind options must be an object")
  assert(opts.provisional == nil or type(opts.provisional) == "boolean",
    "Agent Applet bind provisional must be boolean")
  assert(self.agent_value == nil or self.agent_value == agent,
    "Agent Applet is already bound")
  assert(agent:presenter() == self.presenter_source,
    "Agent and Applet must share one Presenter")
  assert(agent:dialogs() == self.dialog_source,
    "Agent and Applet must share one Dialog source")
  if self.agent_value == agent then return agent end
  local previous = {
    display_label = self.display_label,
    agent_snapshot = self.agent_snapshot,
    binding_restore = self.binding_restore,
    workspace_root = self.workspace_root,
    position = self.position,
  }
  local view = self.view_value
  self:_capture_input(view)
  local queued = {}
  local unsubscribe
  local attached = false
  local view_hydrated = false
  local committed = false
  local failed = false
  local function rollback(value)
    if failed then return util.normalize_error(value, "agent") end
    failed = true
    if unsubscribe then pcall(unsubscribe) end
    unsubscribe = nil
    if attached then pcall(agent.detach_applet, agent, self) end
    attached = false
    pcall(agent.set_attention, agent, "dialog", nil)
    pcall(agent.set_attention, agent, "presentation", nil)
    if view_hydrated and view and not view.destroyed then
      self:_capture_input(view)
      pcall(view.destroy, view)
      if self.view_value == view then self.view_value = nil end
    end
    self.agent_value = nil
    self.agent_unsubscribe = nil
    self.agent_snapshot = previous.agent_snapshot
    self.display_label = previous.display_label
    self.binding_restore = previous.binding_restore
    self.workspace_root = previous.workspace_root
    self.position = previous.position
    return util.normalize_error(value, "agent")
  end

  local ok, failure = pcall(function()
    unsubscribe = agent:subscribe(function(update)
      if failed then return end
      if committed then self:_apply(update)
      else queued[#queued + 1] = util.copy(update) end
    end)
    assert(type(unsubscribe) == "function",
      "Agent subscription must return an unsubscribe function")
    local snapped, snapshot = pcall(agent.snapshot, agent)
    if not snapped then error(snapshot, 0) end
    assert(valid_snapshot(snapshot), "Agent snapshot is invalid")
    if previous.agent_snapshot
        and previous.agent_snapshot.revision > snapshot.revision then
      snapshot = previous.agent_snapshot
    end
    local hydrated = {
      snapshot = util.copy(snapshot),
      workspace = snapshot.context.workspace,
      position = positions[snapshot.context.position]
        and snapshot.context.position or nil,
    }
    if view and not view.destroyed then
      view_hydrated = true
      local err
      hydrated, err = self:_hydrate_view(view, snapshot, agent:label())
      if not hydrated then error(err, 0) end
    end
    local called, owned, attach_err = pcall(
      agent.attach_applet, agent, self)
    if not called or owned ~= self then
      error(called and attach_err or owned, 0)
    end
    attached = true
    local attentive, attention_err = pcall(
      agent.set_attention, agent, "dialog", dialog_attention(self.dialog))
    if not attentive then error(attention_err, 0) end
    attentive, attention_err = pcall(agent.set_attention, agent,
      "presentation", presentation_attention(self.presentation))
    if not attentive then error(attention_err, 0) end

    self.agent_value = agent
    self.display_label = agent:label()
    self.agent_snapshot = hydrated.snapshot
    self.agent_unsubscribe = unsubscribe
    self.binding_restore = opts.provisional and {
      display_label = previous.display_label,
      agent_snapshot = previous.agent_snapshot,
    } or nil
    self:_select_workspace(hydrated.workspace)
    if hydrated.position then self.position = hydrated.position end
    committed = true
    for _, update in ipairs(queued) do self:_apply(update) end
  end)
  if not ok then error(rollback(failure).message, 0) end
  return agent
end

function AgentApplet:unbind(agent)
  assert(not self.destroyed, "Agent Applet is destroyed")
  assert(self.agent_value == agent,
    "Agent Applet is not bound to the caller")
  pcall(agent.set_attention, agent, "dialog", nil)
  pcall(agent.set_attention, agent, "presentation", nil)
  local view = self.view_value
  self:_capture_input(view)
  if self.agent_unsubscribe then pcall(self.agent_unsubscribe) end
  self.agent_unsubscribe = nil
  local detached, detach_err = pcall(agent.detach_applet, agent, self)
  self.agent_value = nil
  self.submissions = {}
  self.input_submission_id = nil
  local restore = self.binding_restore or {}
  self.agent_snapshot = restore.agent_snapshot
  self.display_label = restore.display_label or self.display_label
  self.binding_restore = nil
  if view and not view.destroyed then
    local cleared, err = call_view(view, "set_messages", {})
    if cleared then
      cleared, err = call_view(view, "set_context", self:_context())
    end
    if not cleared then
      pcall(view.destroy, view)
      self.view_value = nil
      self:_notify(err.message, vim.log.levels.ERROR)
    end
  end
  if not detached then
    self:_notify(util.normalize_error(detach_err, "agent").message,
      vim.log.levels.ERROR)
  end
  return agent, detached and nil or util.normalize_error(detach_err, "agent")
end

function AgentApplet:agent() return self:_agent_or_nil() end
function AgentApplet:presenter() return self.presenter_source end
function AgentApplet:dialogs() return self.dialog_source end
function AgentApplet:view() return self.view_value end

function AgentApplet:open(opts)
  opts = opts or {}
  assert(type(opts) == "table",
    "Agent Applet open options must be a table")
  if self.destroyed then
    return nil, util.error("ui", "Agent Applet is destroyed")
  end
  local agent = self:_agent_or_nil()
  if agent then
    local prepared, err = agent:prepare()
    if not prepared and not (err and err.kind == "workspace_trust"
        and err.pending == true) then
      return nil, err
    end
  end
  local ready, view = pcall(self._ensure_view, self)
  if not ready then return nil, util.normalize_error(view, "ui") end
  return view:open(opts.origin, {
    preserve_scroll = opts.preserve_scroll == true,
  })
end

function AgentApplet:close()
  local view = self.view_value
  if view and not view.destroyed then
    self:_capture_input(view)
    view:close()
  end
end

function AgentApplet:toggle()
  if self:is_open() then self:close() return false end
  return self:open()
end

function AgentApplet:is_open()
  local view = self.view_value
  return view ~= nil and not view.destroyed and view:is_open()
end

function AgentApplet:is_destroyed() return self.destroyed end

function AgentApplet:focus_input()
  local view = self.view_value
  return view and type(view.focus_input) == "function"
    and view:focus_input() or false
end

function AgentApplet:focus_attention()
  local view = self.view_value
  if not view then return false end
  if self.presentation and self.presentation.active then
    local key = self.presentation.active.kind == "select"
      and "presentation-filter" or "presentation"
    local pane = type(view.pane) == "function" and view:pane(key) or nil
    return pane and pane:focus() or false
  end
  if self.dialog and self.dialog.active then
    local pane = type(view.pane) == "function" and view:pane("dialog") or nil
    if pane then return pane:focus() end
    return type(view.focus_transcript) == "function"
      and view:focus_transcript() or false
  end
  return type(view.focus_input) == "function" and view:focus_input() or false
end

function AgentApplet:get_input()
  local view = self.view_value
  return self:_capture_input(view)
end

function AgentApplet:set_input(value)
  assert(type(value) == "string", "Agent Applet input must be a string")
  if value ~= self.input_value then self.input_submission_id = nil end
  local view = self:_ensure_view()
  local set, result = call_view(view, "set_input", value)
  if not set then return nil, result end
  self.input_value = value
  return result == nil and value or result
end

function AgentApplet:send(value)
  assert(type(value) == "string", "Agent Applet message must be a string")
  return self:_submit(value)
end

function AgentApplet:input_history()
  local persistent = self.persistence and self.persistence.enabled == true
  return util.copy(self:_load_history(self.workspace_root, persistent))
end

function AgentApplet:select_input_history()
  local history = self:input_history()
  if #history == 0 then
    self:_notify("no input history found for the current workspace")
    return nil
  end
  local items = {}
  for index, item in ipairs(history) do
    items[#items + 1] = {
      id = "history-" .. index,
      label = util.trim(item:gsub("[%c%s]+", " ")),
      value = item,
      fallback = item,
    }
  end
  local selection = self.presenter_source:select({
    prompt = "Select input history:",
    items = items,
  })
  async.run(function() return selection:await() end, {
    error_kind = "presentation",
    on_done = function(result)
      if self.destroyed or not result.ok then return end
      self:set_input(result.value)
      if self:is_open() then self:focus_input() end
    end,
  })
  return true
end

function AgentApplet:set_position(position)
  if not positions[position] then
    return nil, util.error("ui", "invalid window position")
  end
  self.position = position
  local agent = self:_agent_or_nil()
  local saved, err = position
  if agent then saved, err = agent:set_ui_position(position) end
  local view = self.view_value
  if view and not view.destroyed and type(view.set_position) == "function" then
    view:set_position(position)
  end
  if not saved then
    self:_notify("window position changed but workspace settings were not saved: "
      .. err.message, vim.log.levels.WARN)
  end
  return position, err
end

function AgentApplet:set_renderer(renderer)
  local selected, err = renderer_protocol.validate(renderer)
  if not selected then return nil, err end
  local view = self.view_value
  if view and not view.destroyed then
    if type(view.set_renderer) ~= "function" then
      return nil, util.error("ui", "the active View does not support Renderers")
    end
    local installed, install_err = view:set_renderer(selected)
    if not installed then return nil, install_err end
  end
  self.renderer = selected
  return selected
end

function AgentApplet:set_transcript_style(style)
  local renderer = renderers.get(style)
  if not renderer then return nil, util.error("ui", "invalid transcript style") end
  local selected, err = self:set_renderer(renderer)
  if not selected then return nil, err end
  self.transcript_style = style
  local view = self.view_value
  if view and not view.destroyed then view.config.style = style end
  return style
end

function AgentApplet:destroy()
  if self.destroyed then return end
  self.destroyed = true
  self:_set_attention("dialog", nil)
  self:_set_attention("presentation", nil)
  if self.agent_unsubscribe then pcall(self.agent_unsubscribe) end
  if self.dialog_unsubscribe then pcall(self.dialog_unsubscribe) end
  if self.presenter_unsubscribe then
    pcall(self.presenter_unsubscribe,
      self.owns_presenter and "Agent Applet was destroyed" or nil)
  end
  self.agent_unsubscribe = nil
  self.dialog_unsubscribe = nil
  self.presenter_unsubscribe = nil
  local view = self.view_value
  self:_capture_input(view)
  self.view_value = nil
  if view and not view.destroyed then pcall(view.destroy, view) end
  if self.owns_dialogs then
    pcall(self.dialog_source.cancel_pending, self.dialog_source,
      "Agent Applet was destroyed", { presenter_unavailable = true })
  end
  if self.owns_presenter then
    pcall(self.presenter_source.destroy, self.presenter_source)
  end
  local owner = self.owner_value
  local on_destroy = self.owner_callbacks and self.owner_callbacks.on_destroy
  if on_destroy then pcall(on_destroy, self) end
  if self.owner_value == owner then
    self.owner_value = nil
    self.owner_callbacks = nil
  end
  local agent = self.agent_value
  self.agent_value = nil
  self.submissions = {}
  self.input_submission_id = nil
  if agent and not agent:is_destroyed() then pcall(agent.destroy, agent) end
end

M.new = AgentApplet.new
M.AgentApplet = AgentApplet

return M
