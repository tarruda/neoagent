local thinking = require("neoagent.thinking")
local model_contract = require("neoagent.model")
local util = require("neoagent.util")

local M = {}
---@alias Neoagent.SelectionConfig Neoagent.ModelResolutionConfig & {default_thinking_level: Neoagent.ThinkingLevel, ui?: {position?: Neoagent.UiPosition}}
---@alias Neoagent.SelectionIdentity Neoagent.RequestIdentity|(fun(): Neoagent.RequestIdentity?)

---@class Neoagent.InitialSelection
---@field model Neoagent.ModelSelection
---@field thinking_level? Neoagent.ThinkingLevel

---@class Neoagent.CurrentSelection: Neoagent.SelectionState
---@field thinking_level? Neoagent.ThinkingLevel

---@class Neoagent.SelectionSnapshot: Neoagent.RequestStateInput
---@field model? Neoagent.ModelSelection
---@field thinking_level? Neoagent.ThinkingLevel|vim.NIL

---@class Neoagent.RequestSelectionOptions
---@field required_api? string
---@field config Neoagent.SelectionConfig
---@field auth? Neoagent.AuthManager
---@field runtimes? Neoagent.ProviderRuntimes
---@field request_context? Neoagent.SelectionIdentity
---@field checkpoint_identity? fun(): Neoagent.NativeContextIdentity?, Neoagent.Error?
---@field workspace? Neoagent.WorkspacePreferences
---@field initial_selection? Neoagent.InitialSelection

---@class Neoagent.RequestSelection
---@field required_api? string
---@field config Neoagent.SelectionConfig
---@field auth? Neoagent.AuthManager
---@field runtimes Neoagent.ProviderRuntimes
---@field request_context Neoagent.SelectionIdentity
---@field checkpoint_identity? fun(): Neoagent.NativeContextIdentity?, Neoagent.Error?
---@field defaults Neoagent.WorkspacePreferences
---@field workspace Neoagent.WorkspacePreferences
---@field initial? Neoagent.InitialSelection
---@field selected? Neoagent.ModelSelection
---@field model_value? Neoagent.Model
---@field thinking_value? Neoagent.ThinkingLevel
local RequestSelection = {}
RequestSelection.__index = RequestSelection

---@param value unknown
---@return TypeGuard<Neoagent.ModelSelection>
local function valid_model(value)
  return type(value) == "table"
    and type(value.provider) == "string"
    and value.provider ~= ""
    and type(value.model) == "string"
    and value.model ~= ""
end

---@param left unknown
---@param right unknown
---@return boolean
local function same_model(left, right)
  return valid_model(left) and valid_model(right) and left.provider == right.provider and left.model == right.model
end

---@param value unknown
---@return TypeGuard<Neoagent.InitialSelection>
local function valid_selection(value)
  return type(value) == "table"
    and valid_model(value.model)
    and (value.thinking_level == nil or thinking.is_level(value.thinking_level) == true)
end

---@param self Neoagent.RequestSelection
---@param selected Neoagent.ModelSelection
---@return Neoagent.ThinkingLevel?
local function initial_thinking(self, selected)
  local initial = self.initial
  if initial and same_model(initial.model, selected) then
    return initial.thinking_level
  end
end

---@param runtimes Neoagent.ProviderRuntimes
---@param selected Neoagent.ModelSelection
---@param required_api? string
---@return boolean?
function M.api_compatible(runtimes, selected, required_api)
  if not required_api then
    return true
  end
  local runtime = runtimes[selected.provider]
  local model = runtime and runtime.catalog:snapshot().models[selected.model]
  if not model then
    return nil
  end
  return (model.api or runtime.definition.api) == required_api
end

---@param opts Neoagent.RequestSelectionOptions
---@return Neoagent.RequestSelection
function RequestSelection.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "RequestSelection configuration is required")
  assert(
    opts.initial_selection == nil or valid_selection(opts.initial_selection),
    "RequestSelection initial_selection must contain a model and optional thinking level"
  )
  assert(
    opts.request_context == nil or type(opts.request_context) == "table" or type(opts.request_context) == "function",
    "RequestSelection request_context must be a table or function"
  )
  assert(
    opts.checkpoint_identity == nil or type(opts.checkpoint_identity) == "function",
    "RequestSelection checkpoint_identity must be a function"
  )
  local self = setmetatable({
    config = opts.config,
    required_api = opts.required_api,
    auth = opts.auth,
    runtimes = opts.runtimes or {},
    request_context = type(opts.request_context) == "function" and opts.request_context
      or util.copy(opts.request_context or {}),
    checkpoint_identity = opts.checkpoint_identity,
    defaults = {
      default_model = util.copy(opts.config.default_model),
      default_thinking_level = opts.config.default_thinking_level,
      ui_position = opts.config.ui and opts.config.ui.position or nil,
    },
    workspace = util.copy(opts.workspace or {}),
    initial = util.copy(opts.initial_selection),
    selected = nil,
    model_value = nil,
    thinking_value = nil,
  }, RequestSelection)
  return self
end

---@return Neoagent.WorkspacePreferences
function RequestSelection:preferences()
  local preferences = util.deep_merge(self.defaults, self.workspace)
  ---@cast preferences Neoagent.WorkspacePreferences
  return preferences
end

---@return Neoagent.WorkspacePreferences
function RequestSelection:workspace_preferences()
  return util.copy(self.workspace)
end

---@param value Neoagent.WorkspacePreferences
---@return Neoagent.WorkspacePreferences
function RequestSelection:set_workspace_preferences(value)
  assert(
    type(value) == "table" and (next(value) == nil or not util.is_list(value)),
    "RequestSelection workspace preferences must be an object"
  )
  self.workspace = util.copy(value)
  return self:workspace_preferences()
end

---@param discard_initial? boolean
function RequestSelection:clear(discard_initial)
  self.selected = nil
  self.model_value = nil
  self.thinking_value = nil
  if discard_initial then
    self.initial = nil
  end
end

---@return Neoagent.ModelSelection?
function RequestSelection:candidate()
  return util.copy(self.selected or self.initial and self.initial.model or self:preferences().default_model)
end

---@return Neoagent.Model?
function RequestSelection:model()
  return self.model_value
end

---@return Neoagent.ModelSelection?
function RequestSelection:model_selection()
  return util.copy(self.selected)
end

---@return Neoagent.ThinkingLevel?
function RequestSelection:thinking_level()
  return self.thinking_value
end

---@return string
function RequestSelection:label()
  local selected = self.selected
  return selected and selected.provider .. "/" .. selected.model or "no model"
end

---@param selected Neoagent.ModelSelection
---@param model Neoagent.Model
---@param preferred? string
---@return Neoagent.Model
function RequestSelection:bind(selected, model, preferred)
  assert(valid_model(selected), "RequestSelection model must identify a provider and model")
  model = model_contract.assert(model, "RequestSelection resolved Model")
  if self.required_api and model.api ~= self.required_api then
    error(util.error("model", "Profile requires a Model using " .. self.required_api), 0)
  end
  if self.checkpoint_identity then
    local identity, identity_err = self.checkpoint_identity()
    if identity_err then
      error(util.normalize_error(identity_err, "session"), 0)
    end
    local compatible, compatibility_err = model_contract.compatible_context_identity(model, identity)
    if not compatible then
      error(compatibility_err, 0)
    end
  end
  local selected_value = util.copy(selected)
  local thinking_value =
    thinking.clamp(model, preferred or self.thinking_value or self:preferences().default_thinking_level)
  self.selected = selected_value
  self.model_value = model
  self.initial = nil
  self.thinking_value = thinking_value
  return model
end

---@param selected Neoagent.ModelSelection
---@param preferred? Neoagent.ThinkingLevel
---@return Neoagent.ModelSelection?, Neoagent.Error?
function RequestSelection:stage(selected, preferred)
  assert(valid_model(selected), "RequestSelection model must identify a provider and model")
  if M.api_compatible(self.runtimes, selected, self.required_api) == false then
    if self.model_value == nil and same_model(self.selected, selected) then
      self:clear(true)
    end
    return nil, util.error("model", "Profile requires a Model using " .. assert(self.required_api))
  end
  if preferred == nil then
    preferred = initial_thinking(self, selected)
  end
  if preferred == nil then
    preferred = self.thinking_value or self:preferences().default_thinking_level
  end
  self.selected = util.copy(selected)
  self.model_value = nil
  self.initial = nil
  if preferred ~= nil then
    self.thinking_value = preferred
  end
  return util.copy(selected)
end

---@param selected? Neoagent.ModelSelection
---@param preferred? string
---@return Neoagent.Model?, Neoagent.Error?
---@return_overload Neoagent.Model
---@return_overload nil, Neoagent.Error
function RequestSelection:resolve(selected, preferred)
  selected = selected or self:candidate()
  if not selected then
    return nil, util.error("model", "No default_model is configured")
  end
  if M.api_compatible(self.runtimes, selected, self.required_api) == false then
    if self.model_value == nil and same_model(self.selected, selected) then
      self:clear(true)
    end
    return nil, util.error("model", "Profile requires a Model using " .. assert(self.required_api))
  end
  if preferred == nil then
    preferred = initial_thinking(self, selected)
  end
  local ok, model = pcall(function()
    ---@type Neoagent.SelectionIdentity?
    local request_context = self.request_context
    if type(request_context) == "function" then
      request_context = request_context()
    end
    local resolved = require("neoagent.models").resolve(
      selected.provider,
      selected.model,
      self.config,
      self.auth,
      self.runtimes,
      request_context
    )
    return self:bind(selected, resolved, preferred)
  end)
  if not ok then
    return nil, util.normalize_error(model, "model")
  end
  return model
end

---@param provider string
---@param model string
---@param preferred? string
---@return Neoagent.Model?, Neoagent.Error?
function RequestSelection:select(provider, model, preferred)
  assert(type(provider) == "string" and provider ~= "", "provider id must be a non-empty string")
  assert(type(model) == "string" and model ~= "", "model id must be a non-empty string")
  return self:resolve({ provider = provider, model = model }, preferred)
end

---@return Neoagent.ThinkingLevel[]?, Neoagent.Error?
function RequestSelection:levels()
  local model, err = self.model_value, nil
  if not model then
    model, err = self:resolve()
  end
  if not model then
    return nil, err
  end
  return thinking.levels(model)
end

---@param level unknown
---@return Neoagent.ThinkingLevel?, Neoagent.Error?
function RequestSelection:set_thinking_level(level)
  if not thinking.is_level(level) then
    return nil, util.error("model", "unknown thinking level: " .. tostring(level))
  end
  local levels, err = self:levels()
  if not levels then
    return nil, err
  end
  if not vim.tbl_contains(levels, level) then
    return nil, util.error("model", "thinking level " .. level .. " is not supported by " .. self:label())
  end
  self.thinking_value = level
  return level
end

---@return Neoagent.ThinkingLevel?, Neoagent.Error?
function RequestSelection:cycle_thinking_level()
  local model, err = self.model_value, nil
  if not model then
    model, err = self:resolve()
  end
  if not model then
    return nil, err
  end
  local level = thinking.next(model, self.thinking_value)
  if not level then
    return nil, util.error("model", "current model does not support thinking")
  end
  return self:set_thinking_level(level)
end

---@overload fun(self: Neoagent.RequestSelection, opts?: {persisted?: false}): Neoagent.CurrentSelection
---@param opts? {persisted?: boolean}
---@return Neoagent.SelectionSnapshot
function RequestSelection:snapshot(opts)
  opts = opts or {}
  assert(
    type(opts) == "table" and (next(opts) == nil or not util.is_list(opts)),
    "RequestSelection snapshot options must be an object"
  )
  assert(
    opts.persisted == nil or type(opts.persisted) == "boolean",
    "RequestSelection snapshot persisted must be a boolean"
  )
  ---@type Neoagent.SelectionSnapshot
  local result = {
    model = self:model_selection(),
    thinking_level = self.thinking_value,
  }
  if opts.persisted and result.model and result.thinking_level == nil then
    result.thinking_level = vim.NIL
  end
  return result
end

M.new = RequestSelection.new
M.same_model = same_model

return M
