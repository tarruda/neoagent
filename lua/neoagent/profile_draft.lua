local RequestSelection = require("neoagent.request_selection")
local util = require("neoagent.util")

local M = {}
local ProfileDraft = {}
ProfileDraft.__index = ProfileDraft

function ProfileDraft.new(opts)
  assert(type(opts) == "table", "ProfileDraft options are required")
  assert(type(opts.key) == "string" and opts.key ~= "",
    "ProfileDraft key is required")
  assert(type(opts.profile) == "table" and type(opts.profile.id) == "string",
    "ProfileDraft Profile is required")
  assert(type(opts.workspace) == "string" and opts.workspace ~= "",
    "ProfileDraft Workspace is required")
  assert(type(opts.applet) == "table",
    "ProfileDraft Agent Applet is required")
  local options = util.copy(opts.options or {})
  local selection = RequestSelection.new({
    config = opts.profile.config,
    auth = opts.auth,
    runtimes = opts.runtimes,
    workspace = {
      default_model = options.default_model,
      default_thinking_level = options.default_thinking_level,
    },
  })
  local self = setmetatable({
    key = opts.key,
    profile = opts.profile,
    workspace = opts.workspace,
    applet = opts.applet,
    options_value = options,
    selection = selection,
    state_value = "draft",
  }, ProfileDraft)
  local selected = selection:candidate()
  if selected then
    selection:stage(selected, options.default_thinking_level
      or opts.profile.config.default_thinking_level)
  end
  return self
end

function ProfileDraft:state() return self.state_value end

function ProfileDraft:is_active()
  return self.state_value == "draft"
end

function ProfileDraft:options()
  local options = util.copy(self.options_value)
  local selected = self.selection:model_selection()
  if selected then options.default_model = selected end
  local level = self.selection:thinking_level()
  if level ~= nil then options.default_thinking_level = level end
  return options
end

function ProfileDraft:model_selection()
  return self.selection:model_selection()
end

function ProfileDraft:update(patch)
  assert(type(patch) == "table" and not util.is_list(patch),
    "Profile draft options must be an object")
  assert(self:is_active(), "ProfileDraft is not active")
  local selected_options = util.deep_merge(self.options_value, patch)
  if patch.default_model ~= nil then
    local selected = patch.default_model
    local model, err = self.selection:select(
      selected.provider, selected.model,
      patch.default_thinking_level)
    if not model then return nil, err end
  elseif patch.default_thinking_level ~= nil then
    local level, err = self.selection:set_thinking_level(
      patch.default_thinking_level)
    if not level then return nil, err end
  end
  self.options_value = selected_options
  return self:options()
end

function ProfileDraft:set_model(provider, model)
  assert(self:is_active(), "ProfileDraft is not active")
  local resolved, err = self.selection:select(provider, model)
  if not resolved then return nil, err end
  local snapshot = self.selection:snapshot()
  self.options_value.default_model = snapshot.model
  self.options_value.default_thinking_level = snapshot.thinking_level
  return snapshot.model
end

function ProfileDraft:thinking_level()
  return self.selection:thinking_level()
    or self.profile.config.default_thinking_level
end

function ProfileDraft:thinking_levels()
  return self.selection:levels()
end

function ProfileDraft:set_thinking_level(level)
  assert(self:is_active(), "ProfileDraft is not active")
  local selected, err = self.selection:set_thinking_level(level)
  if not selected then return nil, err end
  self.options_value.default_thinking_level = selected
  return selected
end

function ProfileDraft:cycle_thinking_level()
  assert(self:is_active(), "ProfileDraft is not active")
  local selected, err = self.selection:cycle_thinking_level()
  if not selected then return nil, err end
  self.options_value.default_thinking_level = selected
  return selected
end

function ProfileDraft:stage()
  assert(self.state_value == "draft", "ProfileDraft is not active")
  self.state_value = "provisional"
  return self
end

function ProfileDraft:restore()
  assert(self.state_value == "provisional",
    "ProfileDraft is not provisional")
  self.state_value = "draft"
  return self
end

function ProfileDraft:bind()
  assert(self.state_value == "draft"
      or self.state_value == "provisional",
    "ProfileDraft cannot bind")
  self.state_value = "bound"
  return self
end

function ProfileDraft:destroy()
  self.state_value = "destroyed"
end

M.new = ProfileDraft.new

return M
