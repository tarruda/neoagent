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

function AgentApplet.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table",
    "Agent Applet UI config is required")
  assert(opts.context == nil
      or type(opts.context) == "table" and not util.is_list(opts.context),
    "Agent Applet context must be an object")

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
    pending_submission = nil,
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

  if opts.agent then self:bind(opts.agent) end
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

function AgentApplet:_context(value)
  value = self.agent_value and util.copy(value or {})
    or util.deep_merge(self.draft_context, value or {})
  value.name = self.display_label
  value.position = value.position or self.position
  value.model = value.model or "no model"
  value.state = value.state or "idle"
  if not self.agent_value then
    value.context_usage = value.context_usage or false
    value.provider_status = value.provider_status or false
    value.inference_stats = value.inference_stats or false
    value.steering = value.steering or {}
  end
  return value
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
  end
  snapshot.revision = update.revision

  local view = self.view_value
  if not view or view.destroyed then return end
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
  assert(type(snapshot.revision) == "number"
      and snapshot.revision >= 0 and snapshot.revision % 1 == 0,
    "Agent snapshot revision must be a non-negative integer")
  local current = self.agent_snapshot
  if current and (current.revision or 0) > snapshot.revision then
    snapshot = current
  end
  self.agent_snapshot = util.copy(snapshot)
  snapshot = self.agent_snapshot
  self:_select_workspace(snapshot.context.workspace)
  local view = self.view_value
  if not view or view.destroyed then return true end
  self:_sync_position(snapshot.context, view)
  view:set_messages(snapshot.messages)
  view:set_context(self:_context(snapshot.context))
  for _, event in ipairs(snapshot.events) do view:apply(event) end
  if snapshot.result then view:finish(snapshot.result) end
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

function AgentApplet:_reject_agent(agent, err)
  self.pending_submission = nil
  if self:_agent_or_nil() == agent then
    self:_owner_callback("on_reject", agent)
  end
  return nil, err
end

function AgentApplet:_accept_agent(agent)
  if self:_agent_or_nil() ~= agent or not self.binding_restore then return false end
  self.binding_restore = nil
  self:_owner_callback("on_accept", agent)
  return true
end

function AgentApplet:_submit(text)
  if util.trim(text) == "" then return nil end
  local agent, agent_err, created = self:_ensure_agent(text)
  if not agent then return nil, agent_err end
  local prepared, prepare_err = agent:prepare()
  if not prepared then
    if created then return self:_reject_agent(agent, prepare_err) end
    return nil, prepare_err
  end
  local run, err = agent:send(text)
  if run then
    self:_accept_agent(agent)
    self.pending_submission = nil
    self:_record_history(text)
  elseif err and err.kind == "workspace_trust" then
    self.pending_submission = text
  elseif created then
    return self:_reject_agent(agent, err)
  end
  return run, err
end

function AgentApplet:retry_submission()
  local text = self.pending_submission
  local agent = self:_agent_or_nil()
  if not text or not agent then return false end
  local prepared, prepare_err = agent:prepare()
  if not prepared then return nil, prepare_err end
  local run, err = agent:send(text)
  if not run then
    if not err or err.kind ~= "workspace_trust" then
      self.pending_submission = nil
    end
    return nil, err
  end
  self:_accept_agent(agent)
  self.pending_submission = nil
  self:_record_history(text)
  local view = self.view_value
  if view and not view.destroyed then
    if type(view.submission_accepted) == "function" then
      view:submission_accepted(text)
    elseif view:get_input() == text then
      view:set_input("")
    end
  end
  return run
end

function AgentApplet:pending_message()
  return self.pending_submission
end

function AgentApplet:_ensure_view()
  local view = self.view_value
  if view and not view.destroyed then return view end
  local factory = self.view_factory or require("neoagent.ui").new
  local view_config = util.copy(self.config)
  view_config.style = self.transcript_style
  view_config.renderer = self.renderer
  view = factory({
    config = view_config,
    host = self.host,
    on_submit = function(prompt) return self:_submit(prompt) end,
    on_stop = function()
      local agent = self:_agent_or_nil()
      return agent and agent:stop() or false
    end,
    on_dequeue_steering = function()
      local agent = self:_agent_or_nil()
      return agent and agent:dequeue_steering() or {}
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
  assert(type(view) == "table", "View factory must return a View")
  for _, method in ipairs({
    "open", "close", "is_open", "destroy", "get_input", "set_input",
    "set_messages", "set_context", "apply", "finish",
  }) do
    assert(type(view[method]) == "function", "View must implement " .. method)
  end
  self.view_value = view
  view:set_context(self:_context())
  if self.dialog then self:_set_view_dialog(view) end
  if self.presentation then
    local presented, err = self:_set_view_presentation(view)
    if not presented then
      self.presentation = nil
      self:_set_attention("presentation", nil)
      self.presenter_unsubscribe(
        "Presenter surface failed: " .. err.message)
    end
  end
  local hydrated, err = self:_hydrate()
  if not hydrated then
    view:destroy()
    self.view_value = nil
    error(err, 0)
  end
  return view
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
  local previous_label = self.display_label
  local previous_snapshot = self.agent_snapshot
  self.binding_restore = opts.provisional and {
    display_label = previous_label,
    agent_snapshot = previous_snapshot,
  } or nil
  self.agent_value = agent
  self.display_label = agent:label()
  self.agent_unsubscribe = agent:subscribe(function(update)
    self:_apply(update)
  end)
  local hydrated, err = self:_hydrate()
  if not hydrated then
    self.agent_unsubscribe()
    self.agent_unsubscribe = nil
    self.agent_value = nil
    self.agent_snapshot = previous_snapshot
    self.display_label = previous_label
    self.binding_restore = nil
    error(err, 0)
  end
  local attached, attach_err = pcall(
    agent.attach_applet, agent, self)
  if not attached then
    self.agent_unsubscribe()
    self.agent_unsubscribe = nil
    self.agent_value = nil
    self.agent_snapshot = previous_snapshot
    self.display_label = previous_label
    self.binding_restore = nil
    error(attach_err, 0)
  end
  self:_set_attention("dialog", dialog_attention(self.dialog))
  self:_set_attention("presentation", presentation_attention(self.presentation))
  return agent
end

function AgentApplet:unbind(agent)
  assert(not self.destroyed, "Agent Applet is destroyed")
  assert(self.agent_value == agent,
    "Agent Applet is not bound to the caller")
  pcall(agent.set_attention, agent, "dialog", nil)
  pcall(agent.set_attention, agent, "presentation", nil)
  if self.agent_unsubscribe then self.agent_unsubscribe() end
  self.agent_unsubscribe = nil
  agent:detach_applet(self)
  self.agent_value = nil
  local restore = self.binding_restore or {}
  self.agent_snapshot = restore.agent_snapshot
  self.display_label = restore.display_label or self.display_label
  self.binding_restore = nil
  local view = self.view_value
  if view and not view.destroyed then
    view:set_messages({})
    view:set_context(self:_context())
  end
  return agent
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
    if not prepared then return nil, err end
  end
  local ready, view = pcall(self._ensure_view, self)
  if not ready then return nil, util.normalize_error(view, "ui") end
  return view:open(opts.origin, {
    preserve_scroll = opts.preserve_scroll == true,
  })
end

function AgentApplet:close()
  local view = self.view_value
  if view and not view.destroyed then view:close() end
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
  return view and not view.destroyed and view:get_input() or ""
end

function AgentApplet:set_input(value)
  assert(type(value) == "string", "Agent Applet input must be a string")
  return self:_ensure_view():set_input(value)
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
  if self.agent_unsubscribe then self.agent_unsubscribe() end
  if self.dialog_unsubscribe then self.dialog_unsubscribe() end
  if self.presenter_unsubscribe then
    self.presenter_unsubscribe("Agent Applet was destroyed")
  end
  self.agent_unsubscribe = nil
  self.dialog_unsubscribe = nil
  self.presenter_unsubscribe = nil
  local view = self.view_value
  self.view_value = nil
  if view and not view.destroyed then view:destroy() end
  self.dialog_source:cancel_pending("Agent Applet was destroyed", {
    presenter_unavailable = true,
  })
  self.presenter_source:destroy()
  local owner = self.owner_value
  local on_destroy = self.owner_callbacks and self.owner_callbacks.on_destroy
  if on_destroy then pcall(on_destroy, self) end
  if self.owner_value == owner then
    self.owner_value = nil
    self.owner_callbacks = nil
  end
  local agent = self.agent_value
  self.agent_value = nil
  if agent and not agent:is_destroyed() then agent:destroy() end
end

M.new = AgentApplet.new
M.AgentApplet = AgentApplet

return M
