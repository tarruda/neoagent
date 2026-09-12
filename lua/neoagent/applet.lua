local async = require("neoagent.async")
local AgentApplet = require("neoagent.agent_applet")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.AgentAdoptionOptions
---@field owned? boolean
---@field ui? Neoagent.UIConfigInput
---@field view? fun(options: Neoagent.ViewOptions): Neoagent.View
---@field host? Neoagent.ViewHostFactory
---@field metadata? Neoagent.ProfileAgentResources

---@class Neoagent.AgentAdoption: Neoagent.AgentAdoptionOptions
---@field agent Neoagent.Agent
---@field applet? Neoagent.AgentApplet

---@class Neoagent.AppletOptions
---@field profiles? Neoagent.Profile[]
---@field default_profile? string
---@field resources? Neoagent.ProfileResources
---@field provider_shell? Neoagent.ProviderShell
---@field agents? (Neoagent.Agent|Neoagent.AgentAdoption)[]
---@field active? Neoagent.Agent|integer

---@class Neoagent.AppletFromAgentsOptions
---@field agents Neoagent.Agent[]
---@field active? Neoagent.Agent|integer
---@field ui? Neoagent.UIConfigInput
---@field _view? fun(options: Neoagent.ViewOptions): Neoagent.View
---@field host? Neoagent.ViewHostFactory
---@field provider_shell? Neoagent.ProviderShell

---@class Neoagent.AgentConstructionOptions
---@field workspace? string
---@field restore_session_selection? boolean
---@field commit_workspace_preference? boolean
---@field apply_draft_position? boolean
---@field provisional? boolean

---@class Neoagent.DraftRegistrationRollback
---@field draft Neoagent.ProfileDraft
---@field label_count? integer
---@field reserved_label_count integer
---@field foreground? Neoagent.AgentApplet
---@field foreground_id? string
---@field selected? Neoagent.AgentApplet
---@field last_id? string

---@class Neoagent.AgentRecord
---@field id string
---@field agent Neoagent.Agent
---@field applet Neoagent.AgentApplet
---@field owned boolean
---@field metadata Neoagent.ProfileAgentResources
---@field session_id string
---@field activity? Neoagent.AgentActivitySnapshot
---@field activity_unsubscribe? fun()
---@field draft_rollback? Neoagent.DraftRegistrationRollback

---@class Neoagent.PublishedSessionError: Neoagent.Error
---@field session_created true
---@field session_path string
---@field agent_id? string

---@class Neoagent.ProfileSessionChoice: Neoagent.ListedProfileSession
---@field current boolean
---@field label string

---@class Neoagent.AgentDeriveOptions
---@field kind 'copy'|'fork'
---@field source_profile_id? string
---@field entry_id? string
---@field position? 'before'|'at'
---@field input? string

---@class Neoagent.SessionDerivation
---@field ok true
---@field agent Neoagent.Agent
---@field input? string

---@class Neoagent.NeoagentApplet
---@field _neoagent_applet true
---@field profiles_by_id table<string, Neoagent.Profile>
---@field profile_order Neoagent.Profile[]
---@field default_profile? string
---@field resources? Neoagent.ProfileResources
---@field provider_shell_value? Neoagent.ProviderShell
---@field agent_order Neoagent.Agent[]
---@field agents_by_id table<string, Neoagent.Agent>
---@field records table<string, Neoagent.AgentRecord>
---@field drafts_by_key table<string, Neoagent.ProfileDraft>
---@field drafts_by_applet table<Neoagent.AgentApplet, Neoagent.ProfileDraft>
---@field session_claims table<string, string>
---@field label_counts table<string, integer>
---@field foreground? Neoagent.AgentApplet
---@field foreground_id? string
---@field selected? Neoagent.AgentApplet
---@field last_id? string
---@field switcher_value? Neoagent.AgentSwitcher
---@field destroyed boolean
---@field derivations table<Neoagent.Run<Neoagent.SessionDerivation, unknown>, boolean>
local NeoagentApplet = {}
NeoagentApplet.__index = NeoagentApplet

local next_agent_id = 0

---@param agent unknown
---@return Neoagent.Agent
local function assert_agent(agent)
  assert(type(agent) == "table" and agent._neoagent_agent, "Neoagent Applet requires Neoagent Agents")
  return agent --[[@as Neoagent.Agent]]
end

---@param profiles Neoagent.Profile[]
---@param default_profile string?
---@return table<string, Neoagent.Profile>, Neoagent.Profile[]
local function validate_profiles(profiles, default_profile)
  assert(type(profiles) == "table" and util.is_list(profiles), "Neoagent Applet Profiles must be a list")
  local result, order = {}, {}
  for _, profile in ipairs(profiles) do
    assert(type(profile) == "table" and not util.is_list(profile), "Neoagent Applet Profiles must be objects")
    assert(type(profile.id) == "string" and profile.id ~= "", "Profile id must be a non-empty string")
    assert(type(profile.label) == "string" and profile.label ~= "", "Profile label must be a non-empty string")
    assert(type(profile.create_applet) == "function", "Profile create_applet must be a function")
    assert(type(profile.create_agent) == "function", "Profile create_agent must be a function")
    assert(not result[profile.id], "Profile ids must be unique: " .. profile.id)
    result[profile.id] = profile
    order[#order + 1] = profile
  end
  if #profiles > 0 then
    assert(type(default_profile) == "string" and result[default_profile], "Neoagent Applet default Profile is invalid")
  end
  return result, order
end

---@param opts Neoagent.AppletOptions?
---@return Neoagent.NeoagentApplet
local function create(opts)
  opts = opts or {}
  local profiles, profile_order = validate_profiles(opts.profiles or {}, opts.default_profile)
  local provider_shell_value = opts.provider_shell
  if provider_shell_value == nil and opts.resources then
    provider_shell_value = opts.resources.provider_shell
  end
  ---@type Neoagent.NeoagentApplet
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
    derivations = {},
  }, NeoagentApplet)
  ---@type (fun())[]
  local adoption_rollbacks = {}
  for _, entry in ipairs(opts.agents or {}) do
    local explicit = type(entry) == "table" and rawget(entry, "agent") ~= nil
    local adopted, value, rollback = pcall(function()
      if explicit then
        ---@cast entry Neoagent.AgentAdoption
        return self:_adopt(entry.agent, entry.applet, {
          owned = entry.owned == true,
          ui = entry.ui,
          view = entry.view,
          host = entry.host,
        })
      end
      return self:_adopt(entry --[[@as Neoagent.Agent]], nil, { owned = false })
    end)
    if not adopted then
      for index = #adoption_rollbacks, 1, -1 do
        pcall(adoption_rollbacks[index])
      end
      if self.resources and type(self.resources.destroy) == "function" then
        pcall(self.resources.destroy, self.resources)
      end
      error(value, 0)
    end
    adoption_rollbacks[#adoption_rollbacks + 1] = rollback
  end
  if opts.active then
    local agent = opts.active
    if type(agent) == "number" then
      agent = assert(self.agent_order[agent], "Active Agent index is out of range")
    end
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

---@param profile Neoagent.Profile?
---@return Neoagent.AgentAppletCallbacks
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
    on_close = function(value)
      self:_applet_closed(value)
    end,
    on_destroy = function(value)
      self:_applet_destroyed(value)
    end,
    on_agents = function()
      return self:show_agents()
    end,
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

---@param id string?
---@return Neoagent.Profile?, Neoagent.Error?
function NeoagentApplet:_profile(id)
  local profile = self.profiles_by_id[id]
  if not profile then
    return nil, util.error("profile", "Unknown Profile: " .. tostring(id))
  end
  return profile
end

---@param profile Neoagent.Profile
---@return string, integer
function NeoagentApplet:_next_label(profile)
  local count = (self.label_counts[profile.id] or 0) + 1
  return count == 1 and profile.label or profile.label .. " " .. count, count
end

---@param applet Neoagent.AgentApplet
function NeoagentApplet:_applet_closed(applet)
  if self.foreground ~= applet then
    return
  end
  local agent = applet:agent()
  if agent then
    self.last_id = agent:id()
  end
  self.foreground = nil
  self.foreground_id = nil
  if not agent and self.selected == applet then
    self.selected = nil
  end
end

---@param applet Neoagent.AgentApplet
function NeoagentApplet:_applet_destroyed(applet)
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
  if self.selected == applet then
    self.selected = nil
  end
end

---@param profile Neoagent.Profile
---@param workspace string?
---@return Neoagent.AgentApplet?, Neoagent.Error?
function NeoagentApplet:_draft(profile, workspace)
  if self.destroyed then
    return nil, util.error("profile", "Neoagent Applet is destroyed")
  end
  workspace = require("neoagent.fs").canonical(workspace or vim.fn.getcwd())
  local key = profile.id .. "\0" .. workspace
  local current = self.drafts_by_key[key]
  if current and current:is_retained() and not current.applet:is_destroyed() then
    return current.applet
  end
  local called, applet, options = pcall(profile.create_applet, {
    profile = profile,
    label = profile.label,
    workspace = workspace,
  })
  if not called then
    return nil, util.normalize_error(applet, "profile")
  end
  local claimed = false
  local draft
  local function rollback(value)
    if draft then
      pcall(draft.destroy, draft)
    end
    if claimed then
      pcall(applet.release, applet, self)
    end
    if type(applet) == "table" and type(applet.destroy) == "function" then
      pcall(applet.destroy, applet)
    end
    return nil, util.normalize_error(value, "profile")
  end
  if type(applet) ~= "table" or not applet._neoagent_agent_applet then
    return rollback(applet == nil and options or "Profile create_applet must return an Agent Applet")
  end
  if options ~= nil and (type(options) ~= "table" or (next(options) ~= nil and util.is_list(options))) then
    return rollback("Profile draft options must be an object")
  end
  local owned, own_err = pcall(applet.claim, applet, self, self:_owner_callbacks(profile))
  if not owned then
    return rollback(own_err)
  end
  claimed = true
  local resources = self.resources or {}
  local constructed, value, draft_err = pcall(require("neoagent.profile_draft").new, {
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
  if self.destroyed then
    return rollback(util.error("profile", "Neoagent Applet was destroyed during draft creation"))
  end
  self.drafts_by_key[key] = draft
  self.drafts_by_applet[applet] = draft
  return applet
end

---@param applet Neoagent.AgentApplet
---@param value unknown
---@return nil, Neoagent.Error
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

---@param profile Neoagent.Profile
---@param applet Neoagent.AgentApplet
---@param session Neoagent.Session
---@param opts Neoagent.AgentConstructionOptions?
---@return Neoagent.Agent?, Neoagent.Error?
function NeoagentApplet:_construct_agent(profile, applet, session, opts)
  opts = opts or {}
  if self.destroyed then
    return nil, util.error("agent", "Neoagent Applet is destroyed")
  end
  local draft = self.drafts_by_applet[applet]
  local workspace = opts.workspace or draft and draft.workspace
  assert(type(workspace) == "string" and workspace ~= "", "Agent Workspace is required")
  next_agent_id = next_agent_id + 1
  local id = "neoagent-agent-" .. next_agent_id
  local label, label_count = self:_next_label(profile)
  local previous_label_count = self.label_counts[profile.id]
  local previous_foreground = self.foreground
  local previous_foreground_id = self.foreground_id
  local previous_selected = self.selected
  local previous_last_id = self.last_id
  local draft_snapshot = draft and draft:snapshot() or {
    options = {},
    initial_selection = nil,
  }
  local draft_options = draft_snapshot.options
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
    initial_selection = draft_snapshot.initial_selection,
    resources = self.resources,
  })
  if not ok then
    return self:_construction_error(applet, agent)
  end
  local inspected, valid_agent = pcall(function()
    return type(agent) == "table"
      and agent._neoagent_agent
      and type(agent.id) == "function"
      and agent:id() == id
      and type(agent.profile_id) == "function"
      and agent:profile_id() == profile.id
      and type(agent.get_session) == "function"
      and agent:get_session() == session
  end)
  if not inspected or not valid_agent then
    if type(agent) == "table" and type(agent.destroy) == "function" then
      pcall(agent.destroy, agent)
    end
    return self:_construction_error(applet, not inspected and valid_agent or "Profile returned an invalid Agent")
  end
  local prepared, record = pcall(self._prepare_record, self, agent, applet, {
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
    local positioned, saved, save_err = pcall(agent.set_ui_position, agent, draft_position)
    if not positioned then
      pcall((assert(record.activity_unsubscribe)))
      pcall(agent.destroy, agent)
      return self:_construction_error(applet, saved)
    end
    if not saved and save_err then
      local warning = "neoagent: window position changed but workspace settings were not saved: " .. save_err.message
      pcall(function()
        applet:presenter():notify({
          message = warning,
          level = vim.log.levels.WARN,
        })
      end)
    end
  end
  local called, bound, bind_err = pcall(applet.bind, applet, agent, { provisional = opts.provisional == true })
  if not called or bound ~= agent then
    pcall((assert(record.activity_unsubscribe)))
    pcall(agent.destroy, agent)
    return self:_construction_error(applet, called and bind_err or bound)
  end
  local visible_ok, visible = pcall(applet.is_open, applet)
  if not visible_ok then
    pcall((assert(record.activity_unsubscribe)))
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

---@param profile Neoagent.Profile
---@param applet Neoagent.AgentApplet
---@param agent Neoagent.Agent
---@return boolean
function NeoagentApplet:_accept_draft_agent(profile, applet, agent)
  local record = self.records[agent:id()]
  local rollback = record and record.draft_rollback or nil
  local draft = rollback and rollback.draft or nil
  if not record or record.applet ~= applet or not draft or draft.profile ~= profile then
    return false
  end
  draft:bind()
  self.drafts_by_key[draft.key] = nil
  self.drafts_by_applet[applet] = nil
  record.draft_rollback = nil
  return true
end

---@param profile Neoagent.Profile
---@param applet Neoagent.AgentApplet
---@param agent Neoagent.Agent
---@return boolean
function NeoagentApplet:_reject_draft_agent(profile, applet, agent)
  local record = self.records[agent:id()]
  local rollback = record and record.draft_rollback or nil
  local draft = rollback and rollback.draft or nil
  if not record or record.applet ~= applet or not draft or draft.profile ~= profile then
    return false
  end
  assert(rollback)
  local id = agent:id()
  if record.activity_unsubscribe then
    pcall((assert(record.activity_unsubscribe)))
  end
  if self.session_claims[record.session_id] == id then
    self.session_claims[record.session_id] = nil
  end
  self.agents_by_id[id] = nil
  self.records[id] = nil
  for index, candidate in ipairs(self.agent_order) do
    if candidate == agent then
      table.remove(self.agent_order, index)
      break
    end
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
  if self.selected == applet then
    self.selected = rollback.selected
  end
  if self.last_id == id then
    self.last_id = rollback.last_id
  end
  self:_refresh_switcher()
  return true
end

---@param profile Neoagent.Profile
---@param applet Neoagent.AgentApplet
---@return Neoagent.Agent?, Neoagent.Error?
function NeoagentApplet:_bind_draft(profile, applet)
  if self.destroyed then
    return nil, util.error("agent", "Neoagent Applet is destroyed")
  end
  local draft = self.drafts_by_applet[applet]
  if not draft or draft.profile ~= profile or self.drafts_by_key[draft.key] ~= draft or not draft:is_active() then
    return nil, util.error("agent", "Profile draft is not owned")
  end
  local called, session, err = pcall(require("neoagent.profile_sessions").new, {
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

---@param agent Neoagent.Agent
---@param applet Neoagent.AgentApplet
---@param opts? {owned?: boolean, metadata?: Neoagent.ProfileAgentResources}
---@return Neoagent.AgentRecord
function NeoagentApplet:_prepare_record(agent, applet, opts)
  opts = opts or {}
  assert_agent(agent)
  assert(type(applet) == "table" and applet._neoagent_agent_applet, "Agent registration requires an Agent Applet")
  local id = agent:id()
  assert(not self.agents_by_id[id], "Agent id is already registered")
  local session = agent:get_session()
  assert(type(session) == "table" and type(session.id) == "function", "Agent registration requires a Session")
  local session_id = session:id()
  assert(type(session_id) == "string" and session_id ~= "", "Agent Session id must be a non-empty string")
  assert(not self.session_claims[session_id], "Session is already owned by a live Agent: " .. session_id)
  ---@type Neoagent.AgentRecord
  local record = {
    id = id,
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

---@param record Neoagent.AgentRecord
---@return Neoagent.Agent
function NeoagentApplet:_commit_record(record)
  local agent = record.agent
  local id = record.id
  self.agents_by_id[id] = agent
  self.agent_order[#self.agent_order + 1] = agent
  self.records[id] = record
  self.session_claims[record.session_id] = id
  return agent
end

---@param agent Neoagent.Agent
---@param applet Neoagent.AgentApplet?
---@param opts Neoagent.AgentAdoptionOptions?
---@return Neoagent.Agent, fun()
function NeoagentApplet:_adopt(agent, applet, opts)
  assert_agent(agent)
  opts = opts or {}
  assert(
    type(opts) == "table" and (next(opts) == nil or not util.is_list(opts)),
    "Agent adoption options must be an object"
  )
  local created_applet = false
  local bound_here = false
  local record
  local claimed_here = false
  local committed = false

  local function remove_record()
    if not committed or not record then
      return
    end
    local id = record.id
    if self.session_claims[record.session_id] == id then
      self.session_claims[record.session_id] = nil
    end
    if self.agents_by_id[id] == agent then
      self.agents_by_id[id] = nil
    end
    if self.records[id] == record then
      self.records[id] = nil
    end
    for index, candidate in ipairs(self.agent_order) do
      if candidate == agent then
        table.remove(self.agent_order, index)
        break
      end
    end
    committed = false
  end

  local function rollback()
    remove_record()
    if claimed_here then
      pcall(assert(applet).release, applet, self)
    end
    claimed_here = false
    if record and record.activity_unsubscribe then
      pcall((assert(record.activity_unsubscribe)))
      record.activity_unsubscribe = nil
    end
    if bound_here then
      pcall(assert(applet).unbind, applet, agent)
    end
    bound_here = false
    if created_applet then
      pcall(assert(applet).destroy, applet)
    end
    created_applet = false
    return true
  end

  local ok, value = pcall(function()
    applet = applet or agent:applet()
    if not applet then
      local configured = agent:config()
      applet = AgentApplet.new({
        config = util.deep_merge(configured.ui, opts.ui or {}) --[[@as Neoagent.UIConfig]],
        persistence = configured.persistence,
        profile_id = agent:profile_id(),
        label = agent:label(),
        presenter = agent:presenter(),
        dialogs = agent:dialogs(),
        view = opts.view or configured._view,
        host = opts.host,
      })
      created_applet = true
    end
    assert(type(applet) == "table" and applet._neoagent_agent_applet, "Agent adoption requires an Agent Applet")
    local bound = applet:agent()
    if not bound then
      applet:bind(agent)
      bound_here = true
    else
      assert(bound == agent, "Agent Applet is bound to another Agent")
    end
    record = self:_prepare_record(agent, applet, opts)
    applet:claim(self, self:_owner_callbacks())
    claimed_here = true
    self:_commit_record(record)
    committed = true
    return agent
  end)
  if not ok then
    rollback()
    error(value, 0)
  end

  return value, rollback
end

---@param applet Neoagent.AgentApplet
---@param agent Neoagent.Agent?
---@return (Neoagent.Agent|Neoagent.AgentApplet)?, Neoagent.Error|Applet.Error?
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
  if agent then
    self.last_id = agent:id()
  end
  applet:focus_attention()
  return agent or applet
end

---@return Neoagent.Agent[]
function NeoagentApplet:agents()
  return vim.list_slice(self.agent_order)
end

---@param id string?
---@return Neoagent.Profile?
function NeoagentApplet:profile(id)
  return self.profiles_by_id[id]
end

---@param value Neoagent.Agent|string
---@return Neoagent.AgentRecord?
function NeoagentApplet:record(value)
  local id = type(value) == "table" and value:id() or value
  return self.records[id]
end

---@return Neoagent.Agent?
function NeoagentApplet:active_agent()
  return self.foreground_id and self.agents_by_id[self.foreground_id] or nil
end

---@return Neoagent.Agent?
function NeoagentApplet:default_agent()
  local active = self:active_agent()
  if active then
    return active
  end
  return self.last_id and self.agents_by_id[self.last_id] or nil
end

---@return Neoagent.Agent?
function NeoagentApplet:target_agent()
  local applet = self.foreground or self.selected
  if applet then
    return applet:agent()
  end
  return self:default_agent()
end

---@return Neoagent.AgentApplet?
function NeoagentApplet:foreground_applet()
  return self.foreground
end
---@return Neoagent.AgentApplet?
function NeoagentApplet:selected_applet()
  return self.foreground or self.selected
end

---@return Neoagent.View?
function NeoagentApplet:view()
  local applet = self.foreground or self.selected
  return applet and applet:view() or nil
end

---@return Neoagent.Presenter?
function NeoagentApplet:presenter()
  local applet = self.foreground or self.selected
  if not applet and self.default_profile then
    local profile = assert(self:_profile(self.default_profile))
    applet = self:_draft(profile)
    if applet then
      self.selected = applet
    end
  end
  return applet and applet:presenter() or nil
end

---@return true?, Neoagent.Error|Applet.Error?
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
    local opened, err = self:_activate(assert(agent:applet()), agent)
    return opened and true or nil, err
  end
  if not self.default_profile then
    return nil, util.error("profile", "No default Profile is configured")
  end
  local opened, err = self:new(self.default_profile)
  return opened and true or nil, err
end

---@return boolean
function NeoagentApplet:close()
  if self.switcher_value and self.switcher_value:is_open() then
    self.switcher_value:close()
    return true
  end
  local foreground = self.foreground
  if not foreground then
    return false
  end
  foreground:close()
  return true
end

---@return boolean?, Neoagent.Error|Applet.Error?
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

---@return boolean
function NeoagentApplet:is_open()
  return self.foreground ~= nil and self.foreground:is_open()
end

---@param profile_id string?
---@return (Neoagent.Agent|Neoagent.AgentApplet)?, Neoagent.Error|Applet.Error?
function NeoagentApplet:new(profile_id)
  local profile, err = self:_profile(profile_id or self.default_profile)
  if not profile then
    return nil, err
  end
  local applet
  applet, err = self:_draft(profile)
  if not applet then
    return nil, err
  end
  return self:_activate(applet, nil)
end

---@param profile_id string?
---@param workspace string?
---@return Neoagent.AgentApplet?, Neoagent.Error?
function NeoagentApplet:draft(profile_id, workspace)
  local profile, err = self:_profile(profile_id or self.default_profile)
  if not profile then
    return nil, err
  end
  return self:_draft(profile, workspace)
end

---@param profile_id string?
---@param workspace string?
---@return Neoagent.AgentApplet?, Neoagent.Error?
function NeoagentApplet:retained_draft(profile_id, workspace)
  local profile, err = self:_profile(profile_id or self.default_profile)
  if not profile then
    return nil, err
  end
  local root = require("neoagent.fs").canonical(workspace or vim.fn.getcwd())
  local draft = self.drafts_by_key[profile.id .. "\0" .. root]
  local applet = draft and draft.applet or nil
  if draft and draft:is_retained() and applet and not applet:is_destroyed() then
    return applet
  end
  return nil
end

---@param applet Neoagent.AgentApplet?
---@return Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>?, Neoagent.Error?
function NeoagentApplet:get_draft_options(applet)
  applet = applet or self.foreground or self.selected
  local draft = applet and self.drafts_by_applet[applet]
  if not applet or applet:agent() or not draft or self.drafts_by_key[draft.key] ~= draft or not draft:is_active() then
    return nil, util.error("profile", "Profile draft is not owned")
  end
  return draft:options()
end

---@param patch Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@param applet Neoagent.AgentApplet?
---@return Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>?, Neoagent.Error?
function NeoagentApplet:update_draft_options(patch, applet)
  assert(type(patch) == "table" and not util.is_list(patch), "Profile draft options must be an object")
  applet = applet or self.foreground or self.selected
  local draft = applet and self.drafts_by_applet[applet]
  if not draft or self.drafts_by_key[draft.key] ~= draft or not draft:is_active() then
    return nil, util.error("profile", "Profile draft is not owned")
  end
  return draft:update(patch)
end

---@param value Neoagent.Agent|string|integer
---@return Neoagent.Agent?, Neoagent.Error|Applet.Error?
function NeoagentApplet:select(value)
  ---@type Neoagent.Agent|string|integer|nil
  local agent = value
  if type(value) == "number" then
    agent = self.agent_order[value]
  end
  if type(value) == "string" then
    agent = self.agents_by_id[value]
  end
  if type(agent) ~= "table" or not agent._neoagent_agent or self.agents_by_id[agent:id()] ~= agent then
    return nil, util.error("agent", "Agent is not owned by this Neoagent Applet")
  end
  local selected, err = self:_activate(assert(agent:applet()), agent)
  if not selected then
    return nil, err
  end
  return agent
end

---@param text string
---@return Neoagent.AppletSubmissionResult, Neoagent.Error?
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
    if not applet then
      return nil, err
    end
    self.selected = applet
  end
  return applet:send(text)
end

---@return string
function NeoagentApplet:get_input()
  local applet = self.foreground or self.selected
  return applet and applet:get_input() or ""
end

---@param value string
---@return unknown, Neoagent.Error?
function NeoagentApplet:set_input(value)
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then
      return nil, err
    end
    self.selected = applet
  end
  return applet:set_input(value)
end

---@return string[]
function NeoagentApplet:input_history()
  local applet = self.foreground or self.selected
  return applet and applet:input_history() or {}
end

---@param position Neoagent.UiPosition
---@return Neoagent.UiPosition?, Neoagent.Error?
function NeoagentApplet:set_position(position)
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local draft_err
    applet, draft_err = self:_draft(profile)
    if not applet then
      return nil, draft_err
    end
    self.selected = applet
  end
  local selected, err = applet:set_position(position)
  if selected and self.drafts_by_applet[applet] then
    self:update_draft_options({ ui = { position = position } }, applet)
  end
  return selected, err
end

---@param renderer unknown
---@return Neoagent.Renderer<unknown>?, Neoagent.Error|Applet.Error?
function NeoagentApplet:set_renderer(renderer)
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then
      return nil, err
    end
    self.selected = applet
  end
  return applet:set_renderer(renderer)
end

---@param style 'codex'|'pi'
---@return ('codex'|'pi')?, Neoagent.Error|Applet.Error?
function NeoagentApplet:set_transcript_style(style)
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then
      return nil, err
    end
    self.selected = applet
  end
  return applet:set_transcript_style(style)
end

---@param applet Neoagent.AgentApplet
---@return Neoagent.ProfileDraft
function NeoagentApplet:_owned_draft(applet)
  local draft = assert(self.drafts_by_applet[applet], "Profile draft is not owned")
  assert(self.drafts_by_key[draft.key] == draft and draft:is_active(), "Profile draft is not active")
  return draft
end

---@param applet Neoagent.AgentApplet?
---@param value unknown
---@return nil, Neoagent.Error
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

---@param provider string
---@param model string
---@return (Neoagent.Model|Neoagent.ModelSelection)?, Neoagent.Error?
function NeoagentApplet:set_model(provider, model)
  assert(type(provider) == "string" and provider ~= "", "provider id must be a non-empty string")
  assert(type(model) == "string" and model ~= "", "model id must be a non-empty string")
  local agent = self:target_agent()
  if agent then
    return agent:set_model(provider, model)
  end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then
      return nil, err
    end
    self.selected = applet
  end
  local draft = self:_owned_draft(applet)
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

---@return true?, Neoagent.Error?
function NeoagentApplet:select_model()
  local agent = self:target_agent()
  if agent then
    return agent:select_model()
  end
  local applet = self.foreground or self.selected
  local profile = assert(self:_profile(self.default_profile))
  if not applet then
    local err
    applet, err = self:_draft(profile)
    if not applet then
      return nil, err
    end
    self.selected = applet
  else
    local draft = self.drafts_by_applet[applet]
    profile = draft and draft.profile or profile
  end
  return self:_select_unbound_model(profile, applet)
end

---@return Neoagent.ThinkingLevel?
function NeoagentApplet:get_thinking_level()
  local agent = self:target_agent()
  if agent then
    return agent:get_thinking_level()
  end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    return profile.config.default_thinking_level
  end
  local draft = self.drafts_by_applet[applet]
  return draft and draft:thinking_level() or nil
end

---@return Neoagent.ThinkingLevel[]?, Neoagent.Error?
function NeoagentApplet:available_thinking_levels()
  local agent = self:target_agent()
  if agent then
    return agent:available_thinking_levels()
  end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then
      return nil, err
    end
  end
  return self:_owned_draft(applet):thinking_levels()
end

---@param level Neoagent.ThinkingLevel
---@return Neoagent.ThinkingLevel?, Neoagent.Error?
function NeoagentApplet:set_thinking_level(level)
  local agent = self:target_agent()
  if agent then
    return agent:set_thinking_level(level)
  end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then
      return nil, err
    end
    self.selected = applet
  end
  local draft = self:_owned_draft(applet)
  local selected, selection_err = draft:set_thinking_level(level)
  if not selected then
    return self:_report_draft_selection(applet, selection_err)
  end
  applet:set_draft_context({ thinking = level })
  return selected
end

---@return Neoagent.ThinkingLevel?, Neoagent.Error?
function NeoagentApplet:cycle_thinking_level()
  local agent = self:target_agent()
  if agent then
    return agent:cycle_thinking_level()
  end
  local applet = self.foreground or self.selected
  if not applet then
    local profile = assert(self:_profile(self.default_profile))
    local err
    applet, err = self:_draft(profile)
    if not applet then
      return nil, err
    end
    self.selected = applet
  end
  local draft = self:_owned_draft(applet)
  local selected, selection_err = draft:cycle_thinking_level()
  if not selected then
    return self:_report_draft_selection(applet, selection_err)
  end
  applet:set_draft_context({ thinking = selected })
  return selected
end

---@return string?
function NeoagentApplet:_provider_shell_provider()
  local applet = self.foreground or self.selected
  if not applet then
    return nil
  end
  local agent = applet:agent()
  if agent then
    local selected = agent:get_model_selection()
    if selected then
      return selected.provider
    end
    local configured = agent:config()
    local default = configured and configured.default_model or nil
    return default and default.provider or nil
  end
  local draft = self.drafts_by_applet[applet]
  local selected = draft and draft:model_selection() or nil
  return selected and selected.provider or nil
end

---@param shell Neoagent.ProviderShell
function NeoagentApplet:_align_provider_shell(shell)
  local provider_id = self:_provider_shell_provider()
  local current = shell:info()
  if provider_id and current and current.id ~= provider_id then
    shell:select(provider_id)
  end
end

---@return boolean?, Neoagent.Error|Applet.Error?
function NeoagentApplet:toggle_provider_shell()
  local shell = self.provider_shell_value
  if not shell then
    return nil, util.error("provider", "This Neoagent Applet has no Provider Shell")
  end
  if shell:is_open() then
    shell:close()
    return false
  end
  self:_align_provider_shell(shell)
  return shell:open()
end

---@param open boolean
---@return true?, Neoagent.Error|Applet.Error?
function NeoagentApplet:set_provider_shell(open)
  assert(type(open) == "boolean", "provider shell visibility must be boolean")
  if self.destroyed then
    return nil, util.error("ui", "Neoagent Applet is destroyed")
  end
  local shell = self.provider_shell_value
  if not shell then
    return nil, util.error("provider", "This Neoagent Applet has no Provider Shell")
  end
  if open then
    self:_align_provider_shell(shell)
    return shell:open()
  end
  shell:close()
  return true
end

---@return boolean
function NeoagentApplet:provider_shell_open()
  local shell = self.provider_shell_value
  return shell and shell:is_open() or false
end

---@return Neoagent.ProviderShell?
function NeoagentApplet:provider_shell()
  return self.provider_shell_value
end

---@param profile Neoagent.Profile
---@param applet Neoagent.AgentApplet
---@return true?, Neoagent.Error?
function NeoagentApplet:_select_unbound_model(profile, applet)
  local resources = self.resources or {}
  local models = require("neoagent.models")
  local function items(values)
    return vim.tbl_map(function(value)
      return { id = value, label = value, value = value }
    end, values)
  end
  local choices, err = models.available(profile.config, resources.auth, resources.runtimes or {})
  if not choices then
    return self:_construction_error(applet, err)
  end
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
      profile.config,
      resources.auth,
      resources.runtimes or {},
      function(updated, update_err)
        if self.destroyed or applet:agent() then
          return
        end
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
      end
    )
  end
  async.run(function()
    return selection:await()
  end, {
    error_kind = "presentation",
    on_done = function(result)
      if unsubscribe then
        unsubscribe()
        unsubscribe = nil
      end
      if self.destroyed or not result.ok or applet:agent() then
        return
      end
      local provider, model = result.value:match("^([^/]+)/(.+)$")
      assert(provider and model, "available model selection must contain a provider and model")
      local draft = self:_owned_draft(applet)
      local selected, selection_err = draft:set_model(provider, model)
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

---@param session_id string
---@return Neoagent.Agent?
function NeoagentApplet:_live_session_owner(session_id)
  local id = self.session_claims[session_id]
  if not id then
    return nil
  end
  local agent = assert(self.agents_by_id[id], "Session claim must reference a registered Agent")
  assert(not agent:is_destroyed(), "Session claim must reference a live Agent")
  return agent
end

---@param opened Neoagent.OpenedProfileSession
---@return Neoagent.Agent?, Neoagent.Error|Applet.Error?
function NeoagentApplet:_resume_opened(opened)
  local session = opened.session
  local existing = self:_live_session_owner(session:id())
  if existing then
    return self:select(existing)
  end
  if not opened.profile_id then
    return nil, util.error("profile", "Session has no assigned Profile")
  end
  local profile = self.profiles_by_id[opened.profile_id]
  if not profile then
    return nil, util.error("profile", "Session Profile is unavailable: " .. opened.profile_id)
  end
  return self:_open_session(session, profile, opened.workspace, {
    workspace = opened.workspace,
    restore_session_selection = true,
  })
end

---@param applet Neoagent.AgentApplet
---@param value unknown
---@return nil, Neoagent.Error
function NeoagentApplet:_report_lifecycle_error(applet, value)
  local err = util.normalize_error(value, "profile")
  applet:presenter():notify({
    message = "neoagent: " .. err.message .. (err.detail and ": " .. err.detail or ""),
    level = vim.log.levels.ERROR,
  })
  return nil, err
end

---@param applet Neoagent.AgentApplet
---@param prompt string
---@param source_profile_id string?
---@param callback fun(profile_id: string): Neoagent.Run<Neoagent.SessionDerivation, unknown>?, Neoagent.Error?
---@return true?, Neoagent.Error?
function NeoagentApplet:_select_profile(applet, prompt, source_profile_id, callback)
  local profiles = {}
  if source_profile_id and self.profiles_by_id[source_profile_id] then
    profiles[#profiles + 1] = self.profiles_by_id[source_profile_id]
  end
  for _, profile in ipairs(self.profile_order) do
    if profile.id ~= source_profile_id then
      profiles[#profiles + 1] = profile
    end
  end
  if #profiles == 0 then
    return self:_report_lifecycle_error(applet, util.error("profile", "No Profiles are registered"))
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
  async.run(function()
    local result = selection:await()
    if not result.ok or self.destroyed then
      return result
    end
    assert(type(result.value) == "string", "Selected Profile id must be a string")
    local derivation, err = callback(result.value)
    if not derivation then
      error(err, 0)
    end
    return derivation:await()
  end, {
    error_kind = "presentation",
    on_done = function(result)
      if not self.destroyed and not result.ok and result.error.kind ~= "cancelled" then
        self:_report_lifecycle_error(applet, result.error)
      end
    end,
  })
  return true
end

---@param session Neoagent.Session
---@param value unknown
---@param agent Neoagent.Agent?
---@return Neoagent.Error
local function derived_open_error(session, value, agent)
  local err = util.normalize_error(value, "agent")
  local metadata = assert(session:metadata(), "derived Session metadata is required")
  if not metadata.persisted then
    return err
  end
  local path = assert(metadata.path, "persisted derived Session path is required")
  local detail = err.message
  if type(err.detail) == "string" and err.detail ~= "" then
    detail = detail .. ": " .. err.detail
  end
  local result = util.error(err.kind, "Created Session at " .. path .. "; Agent opening failed", detail) --[[@as Neoagent.PublishedSessionError]]
  result.session_created = true
  result.session_path = path
  if agent then
    result.agent_id = agent:id()
  end
  return result
end

---@param session Neoagent.Session
---@param profile Neoagent.Profile
---@param workspace string
---@param opts Neoagent.AgentConstructionOptions
---@return Neoagent.Agent?, Neoagent.Error|Applet.Error?
function NeoagentApplet:_open_session(session, profile, workspace, opts)
  local applet, err = self:_draft(profile, workspace)
  if not applet then
    return nil, err
  end
  local agent
  agent, err = self:_construct_agent(profile, applet, session, opts)
  if not agent then
    return nil, err
  end
  local selected, select_err = self:_activate(applet, agent)
  if not selected then
    return nil, select_err
  end
  return agent
end

---@param session Neoagent.Session
---@param profile Neoagent.Profile
---@param workspace string
---@param opts Neoagent.AgentConstructionOptions
---@return Neoagent.Agent?, Neoagent.Error?
function NeoagentApplet:_open_published_session(session, profile, workspace, opts)
  local ok, agent, err = pcall(self._open_session, self, session, profile, workspace, opts)
  if ok and agent then
    return agent
  end
  local failure = ok and err or agent
  return nil, derived_open_error(session, failure, self:_live_session_owner(session:id()))
end

---@param source_agent Neoagent.Agent
---@param target_profile_id string?
---@param opts Neoagent.AgentDeriveOptions
---@return Neoagent.Run<Neoagent.SessionDerivation, unknown>?, Neoagent.Error?
function NeoagentApplet:_derive(source_agent, target_profile_id, opts)
  opts = util.copy(opts or {})
  local source = source_agent:get_session()
  if source_agent:is_running() then
    return nil, util.error("session", "Cannot derive a Session while its Agent is running")
  end
  local profile, err = self:_profile(target_profile_id)
  if not profile then
    return nil, err
  end
  local workspace = assert(source_agent:get_workspace()).root
  local source_profile_id = opts.source_profile_id
  if source_profile_id == nil then
    source_profile_id = source_agent:profile_id()
  end
  local derive_options = {
    kind = opts.kind,
    source_profile_id = source_profile_id,
    target_profile_id = profile.id,
    workspace = workspace,
    persistence = util.copy(profile.config.persistence),
    entry_id = opts.entry_id,
    position = opts.position,
  }
  local same_profile = source_agent:profile_id() == profile.id
  local operation = async.run(function()
    local session, derive_err = require("neoagent.profile_sessions").derive(source, derive_options)
    if not session then
      error(derive_err, 0)
    end
    local agent, open_err = self:_open_published_session(session, profile, workspace, {
      workspace = workspace,
      restore_session_selection = same_profile,
      commit_workspace_preference = not same_profile,
    })
    if not agent then
      error(open_err, 0)
    end
    if opts.input then
      assert(agent:applet()):set_input(opts.input)
    end
    return { ok = true, agent = agent, input = opts.input }
  end, { error_kind = "session" })
  self.derivations[operation] = true
  operation:_listen(function()
    self.derivations[operation] = nil
  end)
  return operation
end

---@return Neoagent.ProfileSessionChoice[]
function NeoagentApplet:_resume_choices()
  local root = require("neoagent.fs").canonical(vim.fn.getcwd())
  local seen_directories = {}
  ---@type Neoagent.ListedProfileSession[]
  local sessions = {}
  for _, profile in ipairs(self.profile_order) do
    local configured = profile.config.persistence
    if configured.enabled and not seen_directories[configured.directory] then
      seen_directories[configured.directory] = true
      for _, info in ipairs(require("neoagent.profile_sessions").list(configured, root)) do
        if info.profile_id and self.profiles_by_id[info.profile_id] then
          sessions[#sessions + 1] = info
        end
      end
    end
  end
  local current_agent = self:active_agent()
  local current_metadata
  if current_agent then
    current_metadata = current_agent:get_session():metadata()
  end
  return require("neoagent.agent.session_choices").build(sessions, current_metadata and current_metadata.path or nil) --[[@as Neoagent.ProfileSessionChoice[] ]]
end

---@param applet Neoagent.AgentApplet?
---@return true?, Neoagent.Error|Applet.Error?
function NeoagentApplet:_select_resume(applet)
  applet = applet or self.foreground or self.selected
  if not applet then
    local selected, err = self:new(self.default_profile)
    if not selected then
      return nil, err
    end
    applet = assert(self.selected, "new conversation must select its Agent Applet")
  end
  if not applet:is_open() then
    local activated, activate_err = self:_activate(applet, applet:agent())
    if not activated then
      return nil, activate_err
    end
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
    ---@type Neoagent.Profile
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
  async.run(function()
    return selection:await()
  end, {
    error_kind = "presentation",
    on_done = function(result)
      if self.destroyed or not result.ok then
        return
      end
      local opened, err = require("neoagent.profile_sessions").open(result.value)
      if not opened then
        self:_report_lifecycle_error(applet, err)
        return
      end
      local resumed, resume_err = self:_resume_opened(opened)
      if not resumed then
        self:_report_lifecycle_error(applet, resume_err)
      end
    end,
  })
  return true
end

---@param path string?
---@return Neoagent.Agent|true|nil, Neoagent.Error|Applet.Error?
function NeoagentApplet:resume(path)
  if not path or path == "" then
    return self:_select_resume()
  end
  local opened, err = require("neoagent.profile_sessions").open(vim.fn.fnamemodify(path, ":p"))
  if not opened then
    return nil, err
  end
  return self:_resume_opened(opened)
end

---@param entry_id string?
---@param position 'before'|'at'?
---@return Neoagent.Run<Neoagent.SessionDerivation, unknown>?, Neoagent.Error?
function NeoagentApplet:fork(entry_id, position)
  local source = self:target_agent()
  if not source then
    return nil, util.error("session", "Fork requires a bound Agent")
  end
  local selected_text
  if entry_id and (position == nil or position == "before") then
    local target = source:get_session():entry(entry_id)
    if target and target.type == "message" then
      ---@cast target Neoagent.MessageEntry
      if target.message.role == "user" then
        local ok, text = pcall(util.text_content, target.message.content)
        if ok then
          selected_text = text
        end
      end
    end
  end
  return self:_derive(source, source:profile_id(), {
    kind = "fork",
    entry_id = entry_id,
    position = position,
    input = selected_text,
  })
end

---@return true?, Neoagent.Error?
function NeoagentApplet:select_fork()
  local source = self:target_agent()
  if not source then
    return nil
  end
  if source:is_running() then
    return nil, util.error("session", "Cannot fork while the Agent is running")
  end
  local choices = {}
  for _, entry in ipairs(source:get_session():entries()) do
    if entry.type == "message" and entry.message.role == "user" then
      choices[#choices + 1] = {
        id = entry.id,
        label = require("neoagent.agent.session_lifecycle").entry_label(entry),
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
  async.run(function()
    local result = selection:await()
    if not result.ok or self.destroyed then
      return result
    end
    local operation, err = self:fork(result.value, "before")
    if not operation then
      error(err, 0)
    end
    return operation:await()
  end, {
    error_kind = "presentation",
    on_done = function(result)
      if not self.destroyed and not result.ok and result.error.kind ~= "cancelled" then
        self:_report_lifecycle_error(assert(source:applet()), result.error)
      end
    end,
  })
  return true
end

---@return true?, Neoagent.Error?
function NeoagentApplet:copy_session()
  local applet = self.foreground
  local source = applet and applet:agent() or nil
  if not source then
    return nil, util.error("session", "Copy requires a visible bound Agent Applet")
  end
  if source:is_running() then
    return nil, util.error("session", "Cannot copy while the Agent is running")
  end
  local path, path_err = source:get_session():path()
  if not path then
    return nil, path_err
  end
  local has_user = false
  for _, entry in ipairs(path) do
    if entry.type == "message" and entry.message.role == "user" then
      has_user = true
      break
    end
  end
  if not has_user then
    return nil, util.error("session", "Copy requires an accepted user message on the active branch")
  end
  local snapshot, snapshot_err = source:get_session():snapshot()
  if not snapshot then
    return nil, snapshot_err
  end
  return self:_select_profile(assert(applet), "Copy Session under Profile:", source:profile_id(), function(profile_id)
    if source:is_running() then
      return nil, util.error("session", "Cannot copy while the Agent is running")
    end
    local current, err = source:get_session():snapshot()
    if not current then
      return nil, err
    end
    if not vim.deep_equal(snapshot, current) then
      return nil, util.error("session", "Source Session changed while selecting a Profile")
    end
    return self:_derive(source, profile_id, { kind = "copy" })
  end)
end

function NeoagentApplet:_refresh_switcher()
  local switcher = self.switcher_value
  if switcher and switcher:is_open() then
    switcher:refresh()
  end
end

---@return true?, Neoagent.Error|Applet.Error?
function NeoagentApplet:show_agents()
  if self.destroyed then
    return nil, util.error("ui", "Neoagent Applet is destroyed")
  end
  if not self.switcher_value then
    self.switcher_value = require("neoagent.ui.switcher").new({ owner = self })
  end
  return self.switcher_value:open()
end

---@param value Neoagent.Agent|string
---@return boolean
function NeoagentApplet:destroy_agent(value)
  local agent = assert_agent(type(value) == "string" and self.agents_by_id[value] or value)
  local id = agent:id()
  local record = self.records[id]
  if not record then
    return false
  end
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
  if record.activity_unsubscribe then
    record.activity_unsubscribe()
  end
  if self.session_claims[record.session_id] == id then
    self.session_claims[record.session_id] = nil
  end
  self.agents_by_id[id] = nil
  self.records[id] = nil
  for index, candidate in ipairs(self.agent_order) do
    if candidate == agent then
      table.remove(self.agent_order, index)
      break
    end
  end
  if self.foreground_id == id then
    self.foreground = nil
    self.foreground_id = nil
  end
  if self.last_id == id then
    self.last_id = nil
  end
  if self.selected == record.applet then
    self.selected = nil
  end
  record.applet:release(self)
  if record.owned then
    agent:destroy()
  else
    record.applet:close()
  end
  self:_refresh_switcher()
  return true
end

---@return boolean
function NeoagentApplet:is_destroyed()
  return self.destroyed
end

---@return boolean
function NeoagentApplet:any_running()
  if self.provider_shell_value and self.provider_shell_value:is_active() then
    return true
  end
  for _, agent in ipairs(self.agent_order) do
    if agent:activity().state ~= "idle" then
      return true
    end
  end
  return false
end

function NeoagentApplet:destroy()
  if self.destroyed then
    return
  end
  self.destroyed = true
  for operation in pairs(self.derivations) do
    operation:cancel()
  end
  if self.switcher_value then
    self.switcher_value:destroy()
  end
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
    if record then
      record.applet:release(self)
    end
    if record and record.owned then
      agent:destroy()
    elseif record then
      record.applet:close()
    end
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

---@param opts Neoagent.AppletFromAgentsOptions
---@return Neoagent.NeoagentApplet
function M._from_agents(opts)
  opts = opts or {}
  assert(type(opts.agents) == "table" and #opts.agents > 0, "Neoagent Applet requires Agents")
  local entries = {}
  for _, agent in ipairs(opts.agents) do
    assert_agent(agent)
    entries[#entries + 1] = {
      agent = agent,
      ui = opts.ui,
      view = opts._view,
      host = opts.host,
    }
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
