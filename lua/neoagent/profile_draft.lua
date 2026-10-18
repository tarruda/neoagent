local selection = require("neoagent.profiles.selection")
local util = require("neoagent.util")
local composition = require("neoagent.profiles.composition")
local config = require("neoagent.config")

local M = {}
---@alias Neoagent.ProfileDraftState 'draft'|'provisional'|'bound'|'destroyed'

---@class Neoagent.ProfileDraftOptions
---@field key string
---@field composition Neoagent.ProfileComposition
---@field workspace string
---@field applet Neoagent.AgentApplet
---@field auth? Neoagent.AuthManager
---@field runtimes? Neoagent.ProviderRuntimes
---@field profiles table<string, Neoagent.Profile>
---@field snapshot Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>
---@field policy Neoagent.DefaultProfile

---@class Neoagent.ProfileDraft
---@field key string
---@field profile Neoagent.Profile
---@field workspace string
---@field applet Neoagent.AgentApplet
---@field accepted Neoagent.ProfileComposition
---@field selection_context Neoagent.ProfileSelectionContext
---@field state_value Neoagent.ProfileDraftState
---@field composition_revision integer
---@field selection_revision integer
---@field model_picker? Neoagent.PresentationRun
local ProfileDraft = {}
ProfileDraft.__index = ProfileDraft

---@param opts Neoagent.ProfileDraftOptions
---@return Neoagent.ProfileDraft
function ProfileDraft.new(opts)
  assert(type(opts) == "table", "ProfileDraft options are required")
  assert(type(opts.key) == "string" and opts.key ~= "", "ProfileDraft key is required")
  local resolved = composition.copy(opts.composition)
  assert(type(resolved) == "table" and type(resolved.profile) == "table", "ProfileDraft composition is required")
  assert(type(opts.workspace) == "string" and opts.workspace ~= "", "ProfileDraft Workspace is required")
  assert(type(opts.applet) == "table", "ProfileDraft Agent Applet is required")
  assert(type(opts.profiles) == "table", "ProfileDraft registry is required")
  assert(type(opts.policy) == "string" or type(opts.policy) == "function", "ProfileDraft policy is required")
  local self = setmetatable({
    key = opts.key,
    profile = resolved.profile,
    workspace = opts.workspace,
    applet = opts.applet,
    accepted = resolved,
    selection_context = {
      profiles = opts.profiles,
      snapshot = assert(opts.snapshot),
      policy = opts.policy,
      auth = opts.auth,
      runtimes = opts.runtimes or {},
      workspace = opts.workspace,
    },
    state_value = "draft",
    composition_revision = 0,
    selection_revision = 0,
  }, ProfileDraft)
  selection.validate(resolved, self.selection_context)
  return self
end

---@return Neoagent.ProfileDraftState
function ProfileDraft:state()
  return self.state_value
end

---@return boolean
function ProfileDraft:is_active()
  return self.state_value == "draft"
end

---@return boolean
function ProfileDraft:is_automatic()
  return self.accepted.automatic
end

function ProfileDraft:cancel_model_picker()
  self.selection_revision = self.selection_revision + 1
  local picker = self.model_picker
  self.model_picker = nil
  if picker then
    picker:cancel()
  end
end

---@param key string
function ProfileDraft:pin(key)
  assert(self:is_active(), "ProfileDraft is not active")
  local accepted = self:snapshot()
  accepted.automatic = false
  self.key = key
  self:accept(accepted)
end

---@return boolean
function ProfileDraft:is_retained()
  return self.state_value == "draft" or self.state_value == "provisional"
end

---@return Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
function ProfileDraft:options()
  return config.copy(self.accepted.options)
end

---@return Neoagent.ProfileComposition
function ProfileDraft:snapshot()
  return composition.copy(self.accepted)
end

---@return Neoagent.ModelSelection?
function ProfileDraft:model_selection()
  return util.copy(self.accepted.config.default_model)
end

---@return string[]?
function ProfileDraft:model_apis()
  local explicit = not self:is_automatic() and self.profile.id or nil
  local profile = selection.constraint(self.selection_context, explicit)
  return profile and util.copy(profile.supported_apis) or nil
end

---@param provider string
---@param model string
---@param patch? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@return Neoagent.ProfileComposition?, Neoagent.Error?
function ProfileDraft:prepare_model(provider, model, patch)
  ---@type Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  local selected_patch = {}
  if patch then
    selected_patch = config.copy(patch)
  end
  selected_patch.default_model = { provider = provider, model = model }
  return self:prepare_update(selected_patch)
end

---@param patch Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@return Neoagent.ProfileComposition?, Neoagent.Error?
function ProfileDraft:prepare_update(patch)
  assert(self:is_active(), "ProfileDraft is not active")
  local prepared, candidate = pcall(selection.update, self.accepted, patch, self.selection_context)
  if not prepared then
    return nil, util.normalize_error(candidate, "profile")
  end
  return candidate
end

---@param candidate Neoagent.ProfileComposition
---@param selection_changed? boolean
function ProfileDraft:accept(candidate, selection_changed)
  assert(self:is_active(), "ProfileDraft is not active")
  local previous = self.accepted
  self.accepted = composition.copy(candidate)
  self.composition_revision = self.composition_revision + 1
  self.profile = candidate.profile
  if
    selection_changed
    or previous.profile ~= candidate.profile
    or previous.automatic ~= candidate.automatic
    or not vim.deep_equal(previous.config.default_model, candidate.config.default_model)
  then
    self:cancel_model_picker()
  end
end

---@return Neoagent.ThinkingLevel
function ProfileDraft:thinking_level()
  return self.accepted.config.default_thinking_level
end

---@return Neoagent.ThinkingLevel[]?, Neoagent.Error?
function ProfileDraft:thinking_levels()
  return selection.levels(self.accepted, self.selection_context)
end

---@return Neoagent.ProfileComposition?, Neoagent.Error?
function ProfileDraft:prepare_cycle()
  assert(self:is_active(), "ProfileDraft is not active")
  local prepared, candidate = pcall(selection.update, self.accepted, {}, self.selection_context, true)
  if not prepared then
    return nil, util.normalize_error(candidate, "profile")
  end
  return candidate
end

---@return Neoagent.ProfileDraft
function ProfileDraft:stage()
  assert(self.state_value == "draft", "ProfileDraft is not active")
  self.state_value = "provisional"
  self:cancel_model_picker()
  return self
end

---@return Neoagent.ProfileDraft
function ProfileDraft:restore()
  assert(self.state_value == "provisional", "ProfileDraft is not provisional")
  self.state_value = "draft"
  return self
end

---@return Neoagent.ProfileDraft
function ProfileDraft:bind()
  assert(self.state_value == "draft" or self.state_value == "provisional", "ProfileDraft cannot bind")
  self.state_value = "bound"
  self:cancel_model_picker()
  return self
end

function ProfileDraft:destroy()
  self.state_value = "destroyed"
  self:cancel_model_picker()
end

M.new = ProfileDraft.new

return M
