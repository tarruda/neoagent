local async = require("neoagent.async")
local AgentApplet = require("neoagent.agent_applet")
local util = require("neoagent.util")

local M = {}
local NeoagentApplet = {}
NeoagentApplet.__index = NeoagentApplet

local next_agent_id = 0

local function assert_agent(agent)
  assert(type(agent) == "table" and agent._neoagent_agent,
    "Neoagent Applet requires Neoagent Agents")
end

local function validate_profiles(profiles, default_profile)
  assert(type(profiles) == "table" and util.is_list(profiles),
    "Neoagent Applet Profiles must be a list")
  local result, order = {}, {}
  for _, profile in ipairs(profiles) do
    assert(type(profile) == "table" and not util.is_list(profile),
      "Neoagent Applet Profiles must be objects")
    assert(type(profile.id) == "string" and profile.id ~= "",
      "Profile id must be a non-empty string")
    assert(type(profile.label) == "string" and profile.label ~= "",
      "Profile label must be a non-empty string")
    assert(type(profile.create_applet) == "function",
      "Profile create_applet must be a function")
    assert(type(profile.create_agent) == "function",
      "Profile create_agent must be a function")
    assert(not result[profile.id], "Profile ids must be unique: " .. profile.id)
    result[profile.id] = profile
    order[#order + 1] = profile
  end
  if #profiles > 0 then
    assert(type(default_profile) == "string" and result[default_profile],
      "Neoagent Applet default Profile is invalid")
  end
  return result, order
end

local function create(opts)
  opts = opts or {}
  local profiles, profile_order = validate_profiles(
    opts.profiles or {}, opts.default_profile)
  local provider_shell_value = opts.provider_shell
  if provider_shell_value == nil and opts.resources then
    provider_shell_value = opts.resources.provider_shell
  end
  local self = setmetatable({
    _neoagent_applet = true,
    profiles_by_id = profiles,
    profile_order = profile_order,
    default_profile = opts.default_profile,
    resources = opts.resources,
    provider_shell_value = provider_shell_value,
    agent_order = {},
    agents_by_id = {},
    records = {},
    drafts_by_key = {},
    drafts_by_applet = setmetatable({}, { __mode = "k" }),
    session_claims = {},
    label_counts = {},
    foreground = nil,
    foreground_id = nil,
    selected = nil,
    last_id = nil,
    switcher_value = nil,
    destroyed = false,
  }, NeoagentApplet)
  for _, entry in ipairs(opts.agents or {}) do
    local explicit = type(entry) == "table"
      and rawget(entry, "agent") ~= nil
    local adopted, err = pcall(self._adopt, self,
      explicit and entry.agent or entry,
      explicit and entry.applet or nil, {
        owned = explicit and entry.owned == true,
      })
    if not adopted then
      self:destroy()
      error(err, 0)
    end
  end
  if opts.active then
    local agent = type(opts.active) == "number"
      and self.agent_order[opts.active] or opts.active
    if agent then
      local record = self.records[agent:id()]
      self.selected = record and record.applet or nil
      self.last_id = record and agent:id() or nil
    end
  elseif self.agent_order[1] then
    local agent = self.agent_order[1]
    self.selected = self.records[agent:id()].applet
    self.last_id = agent:id()
  end
  return self
end

function NeoagentApplet:_owner_callbacks(profile)
  return {
    on_bind = profile and function(value)
      return self:_bind_draft(profile, value)
    end or nil,
    on_accept = profile and function(value, agent)
      return self:_accept_draft_agent(profile, value, agent)
    end or nil,
    on_reject = profile and function(value, agent)
      return self:_reject_draft_agent(profile, value, agent)
    end or nil,
    on_close = function(value) self:_applet_closed(value) end,
    on_destroy = function(value) self:_applet_destroyed(value) end,
    on_agents = function() return self:show_agents() end,
    on_cycle_thinking = profile and function()
      return self:cycle_thinking_level()
    end or nil,
    on_select_model = profile and function(value)
      return self:_select_unbound_model(profile, value)
    end or nil,
    on_resume_session = profile and function(value)
      return self:_select_resume(value)
    end or nil,
    on_provider_shell = function()
      return self:toggle_provider_shell()
    end,
  }
end

function NeoagentApplet:_profile(id)
  local profile = self.profiles_by_id[id]
  if not profile then
    return nil, util.error("profile", "Unknown Profile: " .. tostring(id))
  end
  return profile
end

function NeoagentApplet:_next_label(profile)
  local count = (self.label_counts[profile.id] or 0) + 1
  return count == 1 and profile.label or profile.label .. " " .. count, count
end

function NeoagentApplet:_applet_closed(applet)
  if self.foreground ~= applet then return end
  local agent = applet:agent()
  if agent then self.last_id = agent:id() end
  self.foreground = nil
  self.foreground_id = nil
  if not agent and self.selected == applet then self.selected = nil end
end

function NeoagentApplet:_applet_destroyed(applet)
  if self.destroyed then return end
  for id, record in pairs(self.records) do
    if record.applet == applet then
      self:destroy_agent(id)
      return
    end
  end
  for key, draft in pairs(self.drafts_by_key) do
    if draft.applet == applet then
      self.drafts_by_key[key] = nil
      self.drafts_by_applet[applet] = nil
      draft:destroy()
      break
    end
  end
  if self.foreground == applet then
    self.foreground = nil
    self.foreground_id = nil
  end
  if self.selected == applet then self.selected = nil end
end

function NeoagentApplet:_draft(profile, workspace)
  workspace = require("neoagent.fs").canonical(
    workspace or vim.fn.getcwd())
  local key = profile.id .. "\0" .. workspace
  local current = self.drafts_by_key[key]
  if current and current:is_retained()
      and not current.applet:is_destroyed() then
    return current.applet
  end
  local called, applet, options = pcall(profile.create_applet, {
    profile = profile,
    label = profile.label,
    workspace = workspace,
  })
  if not called then return nil, util.normalize_error(applet, "profile") end
  local claimed = false
  local draft
  local function rollback(value)
    if draft then pcall(draft.destroy, draft) end
    if claimed then pcall(applet.release, applet, self) end
    if type(applet) == "table" and type(applet.destroy) == "function" then
      pcall(applet.destroy, applet)
    end
    return nil, util.normalize_error(value, "profile")
  end
  if type(applet) ~= "table" or not applet._neoagent_agent_applet then
    return rollback(applet == nil and options
      or "Profile create_applet must return an Agent Applet")
  end
  if options ~= nil and (type(options) ~= "table"
      or (next(options) ~= nil and util.is_list(options))) then
    return rollback("Profile draft options must be an object")
  end
  local owned, claimed_value, own_err = pcall(
    applet.claim, applet, self, self:_owner_callbacks(profile))
  if not owned or claimed_value ~= applet then
    return rollback(owned and own_err or claimed_value)
  end
  claimed = true
  local resources = self.resources or {}
  local constructed, value, draft_err = pcall(
    require("neoagent.profile_draft").new, {
      key = key,
      profile = profile,
      workspace = workspace,
      applet = applet,
      options = options,
      auth = resources.auth,
      runtimes = resources.runtimes,
    })
  if not constructed or type(value) ~= "table" then
    return rollback(constructed and draft_err or value)
  end
  draft = value
  self.drafts_by_key[key] = draft
  self.drafts_by_applet[applet] = draft
  return applet
end

function NeoagentApplet:_construction_error(applet, value)
  local err = util.normalize_error(value, "agent")
  pcall(function()
    applet:presenter():notify({
      message = "neoagent: " .. err.message,
      level = vim.log.levels.ERROR,
    })
  end)
  return nil, err
end

function NeoagentApplet:_construct_agent(
    profile, applet, session, opts)
  opts = opts or {}
  if self.destroyed then
    return nil, util.error("agent", "Neoagent Applet is destroyed")
  end
  local draft = self.drafts_by_applet[applet]
  local workspace = opts.workspace or draft and draft.workspace
  assert(type(workspace) == "string" and workspace ~= "",
    "Agent Workspace is required")
  next_agent_id = next_agent_id + 1
  local id = "neoagent-agent-" .. next_agent_id
  local label, label_count = self:_next_label(profile)
  local previous_label_count = self.label_counts[profile.id]
  local previous_foreground = self.foreground
  local previous_foreground_id = self.foreground_id
  local previous_selected = self.selected
  local previous_last_id = self.last_id
  local draft_options = draft and draft:options() or {}
  local ok, agent, metadata = pcall(profile.create_agent, {
    id = id,
    label = label,
    profile = profile,
    applet = applet,
    session = session,
    workspace = workspace,
    restore_session_selection = opts.restore_session_selection == true,
    commit_workspace_preference = opts.commit_workspace_preference == true,
    options = draft_options,
    resources = self.resources,
  })
  if not ok then return self:_construction_error(applet, agent) end
  local inspected, valid_agent = pcall(function()
    return type(agent) == "table" and agent._neoagent_agent
      and type(agent.id) == "function" and agent:id() == id
      and type(agent.profile_id) == "function"
      and agent:profile_id() == profile.id
      and type(agent.get_session) == "function"
      and agent:get_session() == session
  end)
  if not inspected or not valid_agent then
    if type(agent) == "table"
        and type(agent.destroy) == "function" then
      pcall(agent.destroy, agent)
    end
    local reason = not inspected and valid_agent or nil
    if reason == nil and agent == nil then reason = metadata end
    return self:_construction_error(applet,
      reason or "Profile returned an invalid Agent")
  end
  local prepared, record = pcall(
    self._prepare_record, self, agent, applet, {
      owned = true,
      metadata = metadata,
    })
  if not prepared then
    pcall(agent.destroy, agent)
    return self:_construction_error(applet, record)
  end
  local draft_position
  if opts.apply_draft_position and draft_options.ui then
    draft_position = draft_options.ui.position
  end
  if draft_position then
    local positioned, saved, save_err = pcall(agent.set_ui_position,
      agent, draft_position)
    if not positioned then
      pcall(record.activity_unsubscribe)
      pcall(agent.destroy, agent)
      return self:_construction_error(applet, saved)
    end
    if not saved and save_err then
      local warning = "neoagent: window position changed but workspace settings were not saved: " .. save_err.message
      pcall(function()
        applet:presenter():notify({
          message = warning, level = vim.log.levels.WARN,
        })
      end)
    end
  end
  local called, bound, bind_err = pcall(
    applet.bind, applet, agent, { provisional = opts.provisional == true })
  if not called or bound ~= agent then
    pcall(record.activity_unsubscribe)
    pcall(agent.destroy, agent)
    return self:_construction_error(applet,
      called and bind_err or bound)
  end
  local visible_ok, visible = pcall(applet.is_open, applet)
  if not visible_ok then
    pcall(record.activity_unsubscribe)
    pcall(applet.unbind, applet, agent)
    pcall(agent.destroy, agent)
    return self:_construction_error(applet, visible)
  end
  self:_commit_record(record)
  if draft then
    if opts.provisional then
      draft:stage()
      record.draft_rollback = {
        draft = draft,
        label_count = previous_label_count,
        reserved_label_count = label_count,
        foreground = previous_foreground,
        foreground_id = previous_foreground_id,
        selected = previous_selected,
        last_id = previous_last_id,
      }
    else
      draft:bind()
      self.drafts_by_key[draft.key] = nil
      self.drafts_by_applet[applet] = nil
    end
  end
  self.label_counts[profile.id] = label_count
  self.foreground = visible and applet or self.foreground
  self.foreground_id = visible and id or self.foreground_id
  self.selected = applet
  self.last_id = id
  return agent
end

function NeoagentApplet:_accept_draft_agent(profile, applet, agent)
  local record = self.records[agent:id()]
  local rollback = record and record.draft_rollback or nil
  local draft = rollback and rollback.draft or nil
  if not record or record.applet ~= applet or not draft
      or draft.profile ~= profile then
    return false
  end
  draft:bind()
  self.drafts_by_key[draft.key] = nil
  self.drafts_by_applet[applet] = nil
  record.draft_rollback = nil
  return true
end

function NeoagentApplet:_reject_draft_agent(profile, applet, agent)
  local record = self.records[agent:id()]
  local rollback = record and record.draft_rollback or nil
  local draft = rollback and rollback.draft or nil
  if not record or record.applet ~= applet or not draft
      or draft.profile ~= profile then
    return false
  end
  local id = agent:id()
  if record.activity_unsubscribe then pcall(record.activity_unsubscribe) end
  if self.session_claims[record.session_id] == id then
    self.session_claims[record.session_id] = nil
  end
  self.agents_by_id[id] = nil
  self.records[id] = nil
  for index, candidate in ipairs(self.agent_order) do
    if candidate == agent then table.remove(self.agent_order, index) break end
  end
  applet:unbind(agent)
  pcall(agent.destroy, agent)
  draft:restore()
  self.drafts_by_key[draft.key] = draft
  self.drafts_by_applet[applet] = draft
  if self.label_counts[profile.id] == rollback.reserved_label_count then
    self.label_counts[profile.id] = rollback.label_count
  end
  if self.foreground == applet and self.foreground_id == id then
    self.foreground = rollback.foreground
    self.foreground_id = rollback.foreground_id
  end
  if self.selected == applet then self.selected = rollback.selected end
  if self.last_id == id then self.last_id = rollback.last_id end
  self:_refresh_switcher()
  return true
end

function NeoagentApplet:_bind_draft(profile, applet)
  if self.destroyed then
    return nil, util.error("agent", "Neoagent Applet is destroyed")
  end
  local draft = self.drafts_by_applet[applet]
  if not draft or draft.profile ~= profile
      or self.drafts_by_key[draft.key] ~= draft
      or not draft:is_active() then
    return nil, util.error("agent", "Profile draft is not owned")
  end
  local called, session, err = pcall(
    require("neoagent.profile_sessions").new, {
    profile_id = profile.id,
    workspace = draft.workspace,
    persistence = profile.config.persistence,
  })
  if not called or not session then
    return self:_construction_error(applet, called and err or session)
  end
  return self:_construct_agent(profile, applet, session, {
    workspace = draft.workspace,
    commit_workspace_preference = true,
    apply_draft_position = true,
    provisional = true,
  })
end

function NeoagentApplet:_prepare_record(agent, applet, opts)
  opts = opts or {}
  assert_agent(agent)
  assert(type(applet) == "table"
      and applet._neoagent_agent_applet,
    "Agent registration requires an Agent Applet")
  local id = agent:id()
  assert(not self.agents_by_id[id], "Agent id is already registered")
  local session = agent:get_session()
  assert(type(session) == "table" and type(session.id) == "function",
    "Agent registration requires a Session")
  local session_id = session:id()
  assert(type(session_id) == "string" and session_id ~= "",
    "Agent Session id must be a non-empty string")
  assert(not self.session_claims[session_id],
    "Session is already owned by a live Agent: " .. session_id)
  local record = {
    agent = agent,
    applet = applet,
    owned = opts.owned == true,
    metadata = opts.metadata or {},
    session_id = session_id,
  }
  record.activity_unsubscribe = agent:subscribe_activity(function(activity)
    record.activity = util.copy(activity)
    self:_refresh_switcher()
  end)
  return record
end

function NeoagentApplet:_commit_record(record)
  local agent = record.agent
  local id = agent:id()
  self.agents_by_id[id] = agent
  self.agent_order[#self.agent_order + 1] = agent
  self.records[id] = record
  self.session_claims[record.session_id] = id
  return agent
end

function NeoagentApplet:_adopt(agent, applet, opts)
  assert_agent(agent)
  opts = opts or {}
  applet = applet or agent:applet()
  if not applet then
    local configured = agent:config()
    applet = AgentApplet.new({
      config = configured.ui,
      persistence = configured.persistence,
      profile_id = agent:profile_id(),
      label = agent:label(),
      presenter = agent:presenter(),
      dialogs = agent:dialogs(),
      agent = agent,
      view = configured._view,
    })
  elseif not applet:agent() then
    applet:bind(agent)
  end
  local record = self:_prepare_record(agent, applet, opts)
  local claimed, err = pcall(
    applet.claim, applet, self, self:_owner_callbacks())
  if not claimed then
    record.activity_unsubscribe()
    error(err, 0)
  end
  return self:_commit_record(record)
end

function NeoagentApplet:_activate(applet, agent)
  if self.destroyed then
    return nil, util.error("ui", "Neoagent Applet is destroyed")
  end
  if applet:is_destroyed() then
    return nil, util.error("ui", "Agent Applet is destroyed")
  end
  if self.switcher_value and self.switcher_value:is_open() then
    self.switcher_value:close()
  end
  if self.foreground == applet and applet:is_open() then
    applet:focus_attention()
    return agent or applet
  end
  local previous = self.foreground
  if previous and previous ~= applet and previous:is_open() then
    previous:close()
  end
  self.foreground = applet
  self.foreground_id = agent and agent:id() or nil
  self.selected = applet
  local opened, err = applet:open({
    preserve_scroll = previous ~= nil and previous ~= applet,
  })
  if not opened then
    self.foreground = nil
    self.foreground_id = nil
    if previous and previous ~= applet and not previous:is_destroyed() then
      local restored = previous:open({ preserve_scroll = true })
      if restored then
        self.foreground = previous
        local previous_agent = previous:agent()
        self.foreground_id = previous_agent and previous_agent:id() or nil
        self.selected = previous
      end
    end
    return nil, err
  end
  if agent then self.last_id = agent:id() end
  applet:focus_attention()
  return agent or applet
end

function NeoagentApplet:agents()
  return vim.list_slice(self.agent_order)
end

function NeoagentApplet:profile(id)
  return self.profiles_by_id[id]
end

function NeoagentApplet:record(value)
  local id = type(value) == "table" and value:id() or value
  return self.records[id]
end

function NeoagentApplet:active_agent()
  return self.foreground_id and self.agents_by_id[self.foreground_id] or nil
end

function NeoagentApplet:default_agent()
  local active = self:active_agent()
  if active then return active end
  return self.last_id and self.agents_by_id[self.last_id] or nil
end

function NeoagentApplet:target_agent()
  local applet = self.foreground or self.selected
  if applet then return applet:agent() end
  return self:default_agent()
end

function NeoagentApplet:foreground_applet() return self.foreground end
function NeoagentApplet:selected_applet()
  return self.foreground or self.selected
end

function NeoagentApplet:view()
  local applet = self.foreground or self.selected
  return applet and applet:view() or nil
end

function NeoagentApplet:presenter()
  local applet = self.foreground or self.selected
  if not applet and self.default_profile then
    local profile = assert(self:_profile(self.default_profile))
    applet = self:_draft(profile)
    if applet then self.selected = applet end
  end
  return applet and applet:presenter() or nil
end

function NeoagentApplet:open()
  if self.destroyed then
    return nil, util.error("ui", "Neoagent Applet is destroyed")
  end
  if self.foreground and self.foreground:is_open() then
    self.foreground:focus_attention()
    return true
  end
  local agent = self:target_agent()
  if agent then
    local opened, err = self:_activate(agent:applet(), agent)
    return opened and true or nil, err
  end
  if not self.default_profile then
    return nil, util.error("profile", "No default Profile is configured")
  end
  local opened, err = self:new(self.default_profile)
  return opened and true or nil, err
end

function NeoagentApplet:close()
  if self.switcher_value and self.switcher_value:is_open() then
    self.switcher_value:close()
    return true
  end
  local foreground = self.foreground
  if not foreground then return false end
  foreground:close()
  return true
end

function NeoagentApplet:toggle()
  if self.switcher_value and self.switcher_value:is_open() then
    self.switcher_value:close()
    return false
  end
  if self.foreground and self.foreground:is_open() then
    self:close()
    return false
  end
  return self:open()
end

function NeoagentApplet:is_open()
  return self.foreground ~= nil and self.foreground:is_open()
end

function NeoagentApplet:new(profile_id)
  local profile, err = self:_profile(profile_id or self.default_profile)
  if not profile then return nil, err end
  local applet
  applet, err = self:_draft(profile)
  if not applet then return nil, err end
  return self:_activate(applet, nil)
end

function NeoagentApplet:draft(profile_id, workspace)
  local profile, err = self:_profile(profile_id or self.default_profile)
  if not profile then return nil, err end
  return self:_draft(profile, workspace)
end

function NeoagentApplet:retained_draft(profile_id, workspace)
  local profile, err = self:_profile(profile_id or self.default_profile)
  if not profile then return nil, err end
  local root = require("neoagent.fs").canonical(
    workspace or vim.fn.getcwd())
  local draft = self.drafts_by_key[profile.id .. "\0" .. root]
  local applet = draft and draft.applet or nil
  if draft and draft:is_retained()
      and applet and not applet:is_destroyed() then
    return applet
  end
  return nil
end

function NeoagentApplet:get_draft_options(applet)
  applet = applet or self.foreground or self.selected
  local draft = applet and self.drafts_by_applet[applet]
  if not applet or applet:agent() or not draft
      or self.drafts_by_key[draft.key] ~= draft
      or not draft:is_active() then
    return nil, util.error("profile", "Profile draft is not owned")
  end
  return draft:options()
end

function NeoagentApplet:update_draft_options(patch, applet)
  assert(type(patch) == "table" and not util.is_list(patch),
    "Profile draft options must be an object")
  applet = applet or self.foreground or self.selected
  local draft = applet and self.drafts_by_applet[applet]
  if not draft or self.drafts_by_key[draft.key] ~= draft
      or not draft:is_active() then
    return nil, util.error("profile", "Profile draft is not owned")
  end
  return draft:update(patch)
end

function NeoagentApplet:select(value)
  local agent = value
  if type(value) == "number" then agent = self.agent_order[value] end
  if type(value) == "string" then agent = self.agents_by_id[value] end
  if type(agent) ~= "table" or not agent._neoagent_agent
      or self.agents_by_id[agent:id()] ~= agent then
    return nil, util.error("agent",
      "Agent is not owned by this Neoagent Applet")
  end
  local selected, err = self:_activate(agent:applet(), agent)
  if not selected then return nil, err end
  return agent
end

function NeoagentApplet:send(text)
  assert(type(text) == "string", "Neoagent message must be a string")
  local applet = self.foreground or self.selected
  if not applet then
    local agent = self:default_agent()
    applet = agent and agent:applet() or nil
  end
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
    self.selected = applet
  end
  return applet:send(text)
end

function NeoagentApplet:get_input()
  local applet = self.foreground or self.selected
  return applet and applet:get_input() or ""
end

function NeoagentApplet:set_input(value)
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
    self.selected = applet
  end
  return applet:set_input(value)
end

function NeoagentApplet:input_history()
  local applet = self.foreground or self.selected
  return applet and applet:input_history() or {}
end

function NeoagentApplet:set_position(position)
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local draft_err
    applet, draft_err = self:_draft(profile)
    if not applet then return nil, draft_err end
    self.selected = applet
  end
  local selected, err = applet:set_position(position)
  if selected and self.drafts_by_applet[applet] then
    self:update_draft_options({ ui = { position = position } }, applet)
  end
  return selected, err
end

function NeoagentApplet:set_renderer(renderer)
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
    self.selected = applet
  end
  return applet:set_renderer(renderer)
end

function NeoagentApplet:set_transcript_style(style)
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
    self.selected = applet
  end
  return applet:set_transcript_style(style)
end

function NeoagentApplet:_draft_selection_context(applet)
  local profile = assert(self:_profile(self.default_profile))
  local draft
  if applet then
    draft = self.drafts_by_applet[applet]
    if not draft or self.drafts_by_key[draft.key] ~= draft
        or not draft:is_active() then
      return nil, nil, util.error("profile", "Profile draft is not owned")
    end
    profile = draft.profile
  end
  return profile, draft
end

function NeoagentApplet:_report_draft_selection(applet, value)
  local err = util.normalize_error(value, "model")
  if applet then
    applet:presenter():notify({
      message = "neoagent: " .. err.message,
      level = vim.log.levels.ERROR,
    })
  end
  return nil, err
end

function NeoagentApplet:set_model(provider, model)
  assert(type(provider) == "string" and provider ~= "",
    "provider id must be a non-empty string")
  assert(type(model) == "string" and model ~= "",
    "model id must be a non-empty string")
  local agent = self:target_agent()
  if agent then return agent:set_model(provider, model) end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
    self.selected = applet
  end
  local profile, draft, context_err = self:_draft_selection_context(applet)
  if not profile then return self:_report_draft_selection(applet, context_err) end
  local selection, selection_err = draft:set_model(provider, model)
  if not selection then
    return self:_report_draft_selection(applet, selection_err)
  end
  applet:set_draft_context({ model = provider .. "/" .. model })
  applet:set_draft_context({
    thinking = draft:thinking_level() or false,
  })
  return selection
end

function NeoagentApplet:select_model()
  local agent = self:target_agent()
  if agent then return agent:select_model() end
  local applet = self.foreground or self.selected
  local profile = assert(self:_profile(self.default_profile))
  if not applet then
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
    self.selected = applet
  else
    local draft = self.drafts_by_applet[applet]
    profile = draft and draft.profile or profile
  end
  return self:_select_unbound_model(profile, applet)
end

function NeoagentApplet:get_thinking_level()
  local agent = self:target_agent()
  if agent then return agent:get_thinking_level() end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    return profile.config.default_thinking_level
  end
  local draft = self.drafts_by_applet[applet]
  return draft and draft:thinking_level() or nil
end

function NeoagentApplet:available_thinking_levels()
  local agent = self:target_agent()
  if agent then return agent:available_thinking_levels() end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
  end
  local _, draft, context_err = self:_draft_selection_context(applet)
  if not draft then return nil, context_err end
  return draft:thinking_levels()
end

function NeoagentApplet:set_thinking_level(level)
  local agent = self:target_agent()
  if agent then return agent:set_thinking_level(level) end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
    self.selected = applet
  end
  local _, draft, context_err = self:_draft_selection_context(applet)
  if not draft then return self:_report_draft_selection(applet, context_err) end
  local selected, selection_err = draft:set_thinking_level(level)
  if not selected then
    return self:_report_draft_selection(applet, selection_err)
  end
  applet:set_draft_context({ thinking = level })
  return selected
end

function NeoagentApplet:cycle_thinking_level()
  local agent = self:target_agent()
  if agent then return agent:cycle_thinking_level() end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
    self.selected = applet
  end
  local _, draft, context_err = self:_draft_selection_context(applet)
  if not draft then return self:_report_draft_selection(applet, context_err) end
  local selected, selection_err = draft:cycle_thinking_level()
  if not selected then
    return self:_report_draft_selection(applet, selection_err)
  end
  applet:set_draft_context({ thinking = selected })
  return selected
end

function NeoagentApplet:_provider_shell_provider()
  local applet = self.foreground or self.selected
  if not applet then return nil end
  local agent = applet:agent()
  if agent then
    local selected = agent:get_model_selection()
    if selected then return selected.provider end
    local configured = agent:config()
    local default = configured and configured.default_model or nil
    return default and default.provider or nil
  end
  local draft = self.drafts_by_applet[applet]
  local selected = draft and draft:model_selection() or nil
  return selected and selected.provider or nil
end

function NeoagentApplet:_align_provider_shell(shell)
  if type(shell.info) ~= "function" or type(shell.select) ~= "function" then
    return false
  end
  local provider_id = self:_provider_shell_provider()
  local current = shell:info()
  if provider_id and current and current.id ~= provider_id then
    shell:select(provider_id)
  end
  return true
end

function NeoagentApplet:toggle_provider_shell()
  local shell = self.provider_shell_value
  if not shell then
    return nil, util.error("provider",
      "This Neoagent Applet has no Provider Shell")
  end
  if shell:is_open() then
    shell:close()
    return false
  end
  self:_align_provider_shell(shell)
  return shell:open()
end

function NeoagentApplet:set_provider_shell(open)
  assert(type(open) == "boolean",
    "provider shell visibility must be boolean")
  if self.destroyed then
    return nil, util.error("ui", "Neoagent Applet is destroyed")
  end
  local shell = self.provider_shell_value
  if not shell then
    return nil, util.error("provider",
      "This Neoagent Applet has no Provider Shell")
  end
  if open then
    self:_align_provider_shell(shell)
    return shell:open()
  end
  shell:close()
  return true
end

function NeoagentApplet:provider_shell_open()
  local shell = self.provider_shell_value
  return shell and shell:is_open() or false
end

function NeoagentApplet:provider_shell()
  return self.provider_shell_value
end

function NeoagentApplet:_select_unbound_model(profile, applet)
  local resources = self.resources or {}
  local models = require("neoagent.models")
  local function items(values)
    return vim.tbl_map(function(value)
      return { id = value, label = value, value = value }
    end, values)
  end
  local choices, err = models.available(
    profile.config, resources.auth, resources.runtimes or {})
  if not choices then return self:_construction_error(applet, err) end
  if #choices == 0 then
    applet:presenter():notify({ message = "neoagent: no models configured" })
    return nil
  end
  local selection, update = applet:presenter():select({
    prompt = "Select model:",
    items = items(choices),
  })
  local unsubscribe
  if not selection:is_done() and type(update) == "function" then
    unsubscribe = models.subscribe_available(
      profile.config, resources.auth, resources.runtimes or {},
      function(updated, update_err)
        if self.destroyed or applet:agent() then return end
        if update_err then
          self:_report_draft_selection(applet, update_err)
          return
        end
        local ok, changed, presentation_err = pcall(update, items(updated))
        if not ok then
          self:_report_draft_selection(applet, changed)
        elseif changed == nil and presentation_err then
          self:_report_draft_selection(applet, presentation_err)
        end
      end)
  end
  async.run(function() return selection:await() end, {
    error_kind = "presentation",
    on_done = function(result)
      if unsubscribe then unsubscribe() unsubscribe = nil end
      if self.destroyed or not result.ok or applet:agent() then return end
      local provider, model = result.value:match("^([^/]+)/(.+)$")
      if not provider then return end
      local draft = self.drafts_by_applet[applet]
      local selected, selection_err = draft and draft:set_model(provider, model)
      if selected then
        applet:set_draft_context({
          model = provider .. "/" .. model,
          thinking = draft:thinking_level() or false,
        })
      elseif selection_err then
        self:_report_draft_selection(applet, selection_err)
      end
    end,
  })
  return true
end

function NeoagentApplet:_live_session_owner(session_id)
  local id = self.session_claims[session_id]
  local agent = id and self.agents_by_id[id] or nil
  if agent and not agent:is_destroyed() then return agent end
  if id then self.session_claims[session_id] = nil end
end

function NeoagentApplet:_resume_opened(opened)
  local session = opened.session
  local existing = self:_live_session_owner(session:id())
  if existing then return self:select(existing) end
  if not opened.profile_id then
    return nil, util.error("profile",
      "Session has no assigned Profile")
  end
  local profile = self.profiles_by_id[opened.profile_id]
  if not profile then
    return nil, util.error("profile",
      "Session Profile is unavailable: " .. opened.profile_id)
  end
  local applet, err = self:_draft(profile, opened.workspace)
  if not applet then return nil, err end
  local agent
  agent, err = self:_construct_agent(profile, applet, session, {
    workspace = opened.workspace,
    restore_session_selection = true,
  })
  if not agent then return nil, err end
  local selected, select_err = self:_activate(applet, agent)
  if not selected then return nil, select_err end
  return agent
end

function NeoagentApplet:_report_lifecycle_error(applet, value)
  local err = util.normalize_error(value, "profile")
  applet:presenter():notify({
    message = "neoagent: " .. err.message
      .. (err.detail and ": " .. err.detail or ""),
    level = vim.log.levels.ERROR,
  })
  return nil, err
end

function NeoagentApplet:_select_profile(applet, prompt,
    source_profile_id, callback)
  local profiles = {}
  if source_profile_id and self.profiles_by_id[source_profile_id] then
    profiles[#profiles + 1] = self.profiles_by_id[source_profile_id]
  end
  for _, profile in ipairs(self.profile_order) do
    if profile.id ~= source_profile_id then profiles[#profiles + 1] = profile end
  end
  if #profiles == 0 then
    return self:_report_lifecycle_error(applet,
      util.error("profile", "No Profiles are registered"))
  end
  local items = {}
  for _, profile in ipairs(profiles) do
    items[#items + 1] = {
      id = "profile:" .. profile.id,
      label = profile.label,
      value = profile.id,
      fallback = profile.id,
    }
  end
  local selection = applet:presenter():select({
    prompt = prompt,
    items = items,
  })
  async.run(function() return selection:await() end, {
    error_kind = "presentation",
    on_done = function(result)
      if self.destroyed or not result.ok then return end
      local ok, selected, err = pcall(callback, result.value)
      if not ok or not selected then
        self:_report_lifecycle_error(
          applet, ok and err or selected)
      end
    end,
  })
  return true
end

local function derived_open_error(session, value, agent)
  local err = util.normalize_error(value, "agent")
  local ok, metadata = pcall(session.metadata, session)
  local path = ok and type(metadata) == "table"
      and metadata.persisted == true and metadata.path or nil
  if type(path) ~= "string" or path == "" then return err end
  local detail = err.message
  if type(err.detail) == "string" and err.detail ~= "" then
    detail = detail .. ": " .. err.detail
  end
  local result = util.error(err.kind,
    "Created Session at " .. path .. "; Agent opening failed", detail)
  result.session_created = true
  result.session_path = path
  if agent and type(agent.id) == "function" then
    result.agent_id = agent:id()
  end
  return result
end

function NeoagentApplet:_open_published_session(
    session, profile, workspace, opts)
  local registered
  local ok, value = pcall(function()
    local applet, err = self:_draft(profile, workspace)
    if not applet then error(err, 0) end
    local agent
    agent, err = self:_construct_agent(profile, applet, session, opts)
    if not agent then error(err, 0) end
    registered = agent
    local selected
    selected, err = self:_activate(applet, agent)
    if not selected then error(err, 0) end
    return agent
  end)
  if ok then return value end
  return nil, derived_open_error(session, value, registered)
end

function NeoagentApplet:_derive(source_agent, target_profile_id, opts)
  opts = opts or {}
  local source = source_agent:get_session()
  if source_agent:is_running() then
    return nil, util.error("session",
      "Cannot derive a Session while its Agent is running")
  end
  local profile, err = self:_profile(target_profile_id)
  if not profile then return nil, err end
  local workspace = source_agent:get_workspace().root
  local source_profile_id = opts.source_profile_id
  if source_profile_id == nil then
    source_profile_id = source_agent:profile_id()
  end
  local session
  session, err = require("neoagent.profile_sessions").derive(source, {
    kind = opts.kind,
    source_profile_id = source_profile_id,
    target_profile_id = profile.id,
    workspace = workspace,
    persistence = profile.config.persistence,
    entry_id = opts.entry_id,
    position = opts.position,
  })
  if not session then return nil, err end
  local same_profile = source_agent:profile_id() == profile.id
  return self:_open_published_session(session, profile, workspace, {
    workspace = workspace,
    restore_session_selection = same_profile,
    commit_workspace_preference = not same_profile,
  })
end

function NeoagentApplet:_resume_choices()
  local root = require("neoagent.fs").canonical(vim.fn.getcwd())
  local seen_directories = {}
  local sessions = {}
  for _, profile in ipairs(self.profile_order) do
    local configured = profile.config.persistence
    if configured.enabled and not seen_directories[configured.directory] then
      seen_directories[configured.directory] = true
      for _, info in ipairs(
          require("neoagent.profile_sessions").list(configured, root)) do
        if info.profile_id and self.profiles_by_id[info.profile_id] then
          sessions[#sessions + 1] = info
        end
      end
    end
  end
  table.sort(sessions, function(left, right)
    if left.modified_at == right.modified_at then
      return left.path > right.path
    end
    return left.modified_at > right.modified_at
  end)
  local current_agent = self:active_agent()
  local current_metadata
  if current_agent then
    current_metadata = current_agent:get_session():metadata()
  end
  return require("neoagent.agent.session_choices").build(
    sessions, current_metadata and current_metadata.path or nil)
end

function NeoagentApplet:_select_resume(applet)
  applet = applet or self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then return nil, err end
    self.selected = applet
  end
  if not applet:is_open() then
    local activated, activate_err = self:_activate(
      applet, applet:agent())
    if not activated then return nil, activate_err end
  end
  local choices = self:_resume_choices()
  if #choices == 0 then
    applet:presenter():notify({
      message = "neoagent: no sessions found for the current directory",
    })
    return nil
  end
  local items = {}
  for index, choice in ipairs(choices) do
    local profile = assert(self.profiles_by_id[choice.profile_id])
    local selected = util.copy(choice)
    selected.label = choice.label .. "  ·  " .. profile.label
    items[#items + 1] = {
      id = "session-" .. index,
      label = selected.label,
      value = selected.path,
      fallback = selected,
    }
  end
  local selection = applet:presenter():select({
    prompt = "Resume session:",
    items = items,
  })
  async.run(function() return selection:await() end, {
    error_kind = "presentation",
    on_done = function(result)
      if self.destroyed or not result.ok then return end
      local opened, err = require("neoagent.profile_sessions")
        .open(result.value)
      if not opened then
        self:_report_lifecycle_error(applet, err)
        return
      end
      local resumed
      resumed, err = self:_resume_opened(opened)
      if not resumed then self:_report_lifecycle_error(applet, err) end
    end,
  })
  return true
end

function NeoagentApplet:resume(path)
  if not path or path == "" then return self:_select_resume() end
  local opened, err = require("neoagent.profile_sessions").open(
    vim.fn.fnamemodify(path, ":p"))
  if not opened then return nil, err end
  return self:_resume_opened(opened)
end

function NeoagentApplet:fork(entry_id, position)
  local source = self:target_agent()
  if not source then
    return nil, util.error("session", "Fork requires a bound Agent")
  end
  local selected_text
  if entry_id and (position == nil or position == "before") then
    local target = source:get_session():entry(entry_id)
    if target and target.type == "message"
        and target.message.role == "user" then
      local ok, text = pcall(util.text_content, target.message.content)
      if ok then selected_text = text end
    end
  end
  local agent, err = self:_derive(source, source:profile_id(), {
    kind = "fork",
    entry_id = entry_id,
    position = position,
  })
  if not agent then return nil, err end
  if selected_text then agent:applet():set_input(selected_text) end
  return agent, selected_text
end

function NeoagentApplet:select_fork()
  local source = self:target_agent()
  if not source then return nil end
  if source:is_running() then
    return nil, util.error("session",
      "Cannot fork while the Agent is running")
  end
  local choices = {}
  for _, entry in ipairs(source:get_session():entries()) do
    if entry.type == "message" and entry.message.role == "user" then
      choices[#choices + 1] = {
        id = entry.id,
        label = require("neoagent.agent.session_lifecycle")
          .entry_label(entry),
      }
    end
  end
  if #choices == 0 then
    source:presenter():notify({
      message = "neoagent: the active session has no user messages",
    })
    return nil
  end
  local selection = source:presenter():select({
    prompt = "Fork session from",
    items = choices,
  })
  async.run(function() return selection:await() end, {
    error_kind = "presentation",
    on_done = function(result)
      if self.destroyed or not result.ok then return end
      local forked, err = self:fork(result.value, "before")
      if not forked then
        self:_report_lifecycle_error(source:applet(), err)
      end
    end,
  })
  return true
end

function NeoagentApplet:copy_session()
  local applet = self.foreground
  local source = applet and applet:agent() or nil
  if not source then
    return nil, util.error("session",
      "Copy requires a visible bound Agent Applet")
  end
  if source:is_running() then
    return nil, util.error("session",
      "Cannot copy while the Agent is running")
  end
  local path, path_err = source:get_session():path()
  if not path then return nil, path_err end
  local has_user = false
  for _, entry in ipairs(path) do
    if entry.type == "message" and entry.message.role == "user" then
      has_user = true
      break
    end
  end
  if not has_user then
    return nil, util.error("session",
      "Copy requires an accepted user message on the active branch")
  end
  local snapshot, snapshot_err = source:get_session():snapshot()
  if not snapshot then return nil, snapshot_err end
  return self:_select_profile(applet, "Copy Session under Profile:",
    source:profile_id(), function(profile_id)
      if source:is_running() then
        return nil, util.error("session",
          "Cannot copy while the Agent is running")
      end
      local current, err = source:get_session():snapshot()
      if not current then return nil, err end
      if not vim.deep_equal(snapshot, current) then
        return nil, util.error("session",
          "Source Session changed while selecting a Profile")
      end
      return self:_derive(source, profile_id, { kind = "copy" })
    end)
end

function NeoagentApplet:_refresh_switcher()
  local switcher = self.switcher_value
  if switcher and switcher:is_open() then switcher:refresh() end
end

function NeoagentApplet:show_agents()
  if self.destroyed then
    return nil, util.error("ui", "Neoagent Applet is destroyed")
  end
  if not self.switcher_value then
    self.switcher_value = require("neoagent.ui.switcher").new({ owner = self })
  end
  return self.switcher_value:open()
end

function NeoagentApplet:destroy_agent(value)
  local agent = type(value) == "string" and self.agents_by_id[value] or value
  assert_agent(agent)
  local id = agent:id()
  local record = self.records[id]
  if not record then return false end
  local rollback = record.draft_rollback
  local draft = rollback and rollback.draft or nil
  if draft then
    if self.drafts_by_key[draft.key] == draft then
      self.drafts_by_key[draft.key] = nil
    end
    if self.drafts_by_applet[record.applet] == draft then
      self.drafts_by_applet[record.applet] = nil
    end
    draft:destroy()
    record.draft_rollback = nil
  end
  if record.activity_unsubscribe then record.activity_unsubscribe() end
  if self.session_claims[record.session_id] == id then
    self.session_claims[record.session_id] = nil
  end
  self.agents_by_id[id] = nil
  self.records[id] = nil
  for index, candidate in ipairs(self.agent_order) do
    if candidate == agent then table.remove(self.agent_order, index) break end
  end
  if self.foreground_id == id then
    self.foreground = nil
    self.foreground_id = nil
  end
  if self.last_id == id then self.last_id = nil end
  if self.selected == record.applet then self.selected = nil end
  record.applet:release(self)
  if record.owned then agent:destroy()
  else record.applet:close() end
  self:_refresh_switcher()
  return true
end

function NeoagentApplet:is_destroyed() return self.destroyed end

function NeoagentApplet:any_running()
  if self.provider_shell_value and self.provider_shell_value:is_active() then
    return true
  end
  for _, agent in ipairs(self.agent_order) do
    if agent:activity().state ~= "idle" then return true end
  end
  return false
end

function NeoagentApplet:destroy()
  if self.destroyed then return end
  self.destroyed = true
  if self.switcher_value then self.switcher_value:destroy() end
  self.switcher_value = nil
  for _, draft in pairs(self.drafts_by_key) do
    draft:destroy()
    if not draft.applet:agent() then
      draft.applet:release(self)
      draft.applet:destroy()
    end
  end
  self.drafts_by_key = {}
  self.drafts_by_applet = setmetatable({}, { __mode = "k" })
  local agents = vim.list_slice(self.agent_order)
  for _, agent in ipairs(agents) do
    local record = self.records[agent:id()]
    if record and record.activity_unsubscribe then
      record.activity_unsubscribe()
    end
    if record then record.applet:release(self) end
    if record and record.owned then agent:destroy()
    elseif record then record.applet:close() end
  end
  self.agent_order = {}
  self.agents_by_id = {}
  self.records = {}
  self.session_claims = {}
  self.foreground = nil
  self.foreground_id = nil
  self.selected = nil
  self.last_id = nil
  if self.resources and type(self.resources.destroy) == "function" then
    self.resources:destroy()
  end
end

function M._from_agents(opts)
  opts = opts or {}
  assert(type(opts.agents) == "table" and #opts.agents > 0,
    "Neoagent Applet requires Agents")
  local entries = {}
  for _, agent in ipairs(opts.agents) do
    assert_agent(agent)
    local applet = agent:applet()
    if not applet then
      local configured = agent:config()
      applet = AgentApplet.new({
        config = util.deep_merge(configured.ui, opts.ui or {}),
        persistence = configured.persistence,
        profile_id = agent:profile_id(),
        label = agent:label(),
        presenter = agent:presenter(),
        dialogs = agent:dialogs(),
        agent = agent,
        view = opts._view or configured._view,
        host = opts.host,
      })
    end
    entries[#entries + 1] = { agent = agent, applet = applet }
  end
  local result = create({
    profiles = {},
    agents = entries,
    active = opts.active,
    provider_shell = opts.provider_shell,
  })
  return result
end

M.new = create
M.NeoagentApplet = NeoagentApplet

return M
