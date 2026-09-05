local thinking = require("neoagent.thinking")
local model_contract = require("neoagent.model")
local util = require("neoagent.util")

local M = {}
local RequestSelection = {}
RequestSelection.__index = RequestSelection

local function valid_model(value)
  return type(value) == "table"
    and type(value.provider) == "string" and value.provider ~= ""
    and type(value.model) == "string" and value.model ~= ""
end

local function same_model(left, right)
  return valid_model(left) and valid_model(right)
    and left.provider == right.provider and left.model == right.model
end

local function valid_selection(value)
  return type(value) == "table"
    and valid_model(value.model)
    and (value.thinking_level == nil
      or thinking.is_level(value.thinking_level))
end

function RequestSelection.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table",
    "RequestSelection configuration is required")
  assert(opts.initial_selection == nil
      or valid_selection(opts.initial_selection),
    "RequestSelection initial_selection must contain a model and optional thinking level")
  assert(opts.http_context == nil or type(opts.http_context) == "table"
      or type(opts.http_context) == "function",
    "RequestSelection HTTP context must be a table or function")
  local self = setmetatable({
    config = opts.config,
    auth = opts.auth,
    runtimes = opts.runtimes or {},
    http_context = type(opts.http_context) == "function"
      and opts.http_context or util.copy(opts.http_context or {}),
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

function RequestSelection:preferences()
  return util.deep_merge(self.defaults, self.workspace)
end

function RequestSelection:workspace_preferences()
  return util.copy(self.workspace)
end

function RequestSelection:set_workspace_preferences(value)
  assert(type(value) == "table"
      and (next(value) == nil or not util.is_list(value)),
    "RequestSelection workspace preferences must be an object")
  self.workspace = util.copy(value)
  return self:workspace_preferences()
end

function RequestSelection:clear(discard_initial)
  self.selected = nil
  self.model_value = nil
  self.thinking_value = nil
  if discard_initial then self.initial = nil end
end

function RequestSelection:candidate()
  return util.copy(self.selected or self.initial and self.initial.model
    or self:preferences().default_model)
end

function RequestSelection:model()
  return self.model_value
end

function RequestSelection:model_selection()
  return util.copy(self.selected)
end

function RequestSelection:thinking_level()
  return self.thinking_value
end

function RequestSelection:label()
  local selected = self.selected
  return selected and selected.provider .. "/" .. selected.model
    or "no model"
end

function RequestSelection:bind(selected, model, preferred)
  assert(valid_model(selected),
    "RequestSelection model must identify a provider and model")
  model = model_contract.assert(model, "RequestSelection resolved Model")
  local selected_value = util.copy(selected)
  local thinking_value = thinking.clamp(model,
    preferred or self.thinking_value
      or self:preferences().default_thinking_level)
  self.selected = selected_value
  self.model_value = model
  self.initial = nil
  self.thinking_value = thinking_value
  return model
end

function RequestSelection:stage(selected, preferred)
  assert(valid_model(selected),
    "RequestSelection model must identify a provider and model")
  self.selected = util.copy(selected)
  self.model_value = nil
  self.initial = nil
  if preferred ~= nil then self.thinking_value = preferred end
  return self:model_selection()
end

function RequestSelection:resolve(selected, preferred)
  selected = selected or self:candidate()
  if not selected then
    return nil, util.error("model", "No default_model is configured")
  end
  local ok, model = pcall(function()
    local http_context = self.http_context
    if type(http_context) == "function" then http_context = http_context() end
    local resolved = require("neoagent.models").resolve(
      selected.provider, selected.model, self.config, self.auth,
      self.runtimes, http_context)
    return self:bind(selected, resolved, preferred)
  end)
  if not ok then return nil, util.normalize_error(model, "model") end
  return model
end

function RequestSelection:select(provider, model, preferred)
  assert(type(provider) == "string" and provider ~= "",
    "provider id must be a non-empty string")
  assert(type(model) == "string" and model ~= "",
    "model id must be a non-empty string")
  return self:resolve({ provider = provider, model = model }, preferred)
end

function RequestSelection:levels()
  local model, err = self.model_value, nil
  if not model then model, err = self:resolve() end
  if not model then return nil, err end
  return thinking.levels(model)
end

function RequestSelection:set_thinking_level(level)
  if not thinking.is_level(level) then
    return nil, util.error("model",
      "unknown thinking level: " .. tostring(level))
  end
  local levels, err = self:levels()
  if not levels then return nil, err end
  if not vim.tbl_contains(levels, level) then
    return nil, util.error("model", "thinking level " .. level
      .. " is not supported by " .. self:label())
  end
  self.thinking_value = level
  return level
end

function RequestSelection:cycle_thinking_level()
  local model, err = self.model_value, nil
  if not model then model, err = self:resolve() end
  if not model then return nil, err end
  local level = thinking.next(model, self.thinking_value)
  if not level then
    return nil, util.error("model",
      "current model does not support thinking")
  end
  return self:set_thinking_level(level)
end

function RequestSelection:snapshot(opts)
  opts = opts or {}
  assert(type(opts) == "table"
      and (next(opts) == nil or not util.is_list(opts)),
    "RequestSelection snapshot options must be an object")
  assert(opts.persisted == nil or type(opts.persisted) == "boolean",
    "RequestSelection snapshot persisted must be a boolean")
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
