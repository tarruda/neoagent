local util = require("neoagent.util")

local M = {}

---@class Neoagent.ModelRuleContext
---@field provider_id? string
---@field source_model? Neoagent.DiscoveredModel

---@alias Neoagent.ModelTransform fun(model: Neoagent.ModelConfigInput, ctx?: Neoagent.ModelRuleContext): Neoagent.ModelConfigInput|false

---@class Neoagent.ModelRule
---@field match string|fun(model: Neoagent.ModelConfigInput, ctx?: Neoagent.ModelRuleContext): boolean
---@field defaults? Neoagent.ModelConfigInput
---@field set? Neoagent.ModelConfigInput
---@field apply? Neoagent.ModelTransform

---@param target table<unknown, unknown>
---@param defaults? table<unknown, unknown>
---@return table<unknown, unknown>
local function merge_defaults(target, defaults)
  for key, value in pairs(defaults or {}) do
    if target[key] == nil then
      target[key] = util.copy(value)
    elseif type(target[key]) == "table" and type(value) == "table"
        and not util.is_list(target[key]) and not util.is_list(value) then
      merge_defaults(target[key], value)
    end
  end
  return target
end

---@param target table<unknown, unknown>
---@param values? table<unknown, unknown>
---@return table<unknown, unknown>
local function merge_set(target, values)
  for key, value in pairs(values or {}) do
    if value == false then
      target[key] = nil
    elseif type(value) == "table" and type(target[key]) == "table"
        and not util.is_list(value) and not util.is_list(target[key]) then
      merge_set(target[key], value)
    else
      target[key] = util.copy(value)
    end
  end
  return target
end

---@param rule Neoagent.ModelRule
---@param model Neoagent.ModelConfigInput
---@param ctx? Neoagent.ModelRuleContext
---@return boolean
local function matches(rule, model, ctx)
  if type(rule.match) == "string" then
    local id = model.id
    assert(type(id) == "string", "model rule input must contain an id")
    return id:match(rule.match) ~= nil
  end
  return rule.match(model, ctx) == true
end

---@param definitions Neoagent.ModelRule[]
---@return Neoagent.ModelTransform
function M.compile(definitions)
  assert(util.is_list(definitions), "model rules must be a list")
  local rules = util.copy(definitions)
  for index, rule in ipairs(rules) do
    assert(type(rule) == "table" and not util.is_list(rule),
      "model rule " .. index .. " must be an object")
    assert(type(rule.match) == "string" or type(rule.match) == "function",
      "model rule " .. index .. " match must be a Lua pattern or function")
    assert(rule.defaults == nil or type(rule.defaults) == "table"
        and not util.is_list(rule.defaults),
      "model rule " .. index .. " defaults must be an object")
    assert(rule.set == nil or type(rule.set) == "table"
        and not util.is_list(rule.set),
      "model rule " .. index .. " set must be an object")
    assert(rule.apply == nil or type(rule.apply) == "function",
      "model rule " .. index .. " apply must be a function")
  end
  ---@param model Neoagent.ModelConfigInput
  ---@param ctx? Neoagent.ModelRuleContext
  ---@return Neoagent.ModelConfigInput|false
  return function(model, ctx)
    assert(type(model) == "table" and type(model.id) == "string",
      "model rule input must contain an id")
    ---@type Neoagent.ModelConfigInput
    local current = util.copy(model)
    for _, rule in ipairs(rules) do
      if matches(rule, current, ctx) then
        merge_defaults(current, rule.defaults)
        merge_set(current, rule.set)
        if rule.apply then
          local transformed = rule.apply(current, ctx)
          if transformed == false then return false end
          assert(type(transformed) == "table" and not util.is_list(transformed),
            "model rule apply must return a model or false")
          current = transformed
        end
      end
    end
    return current
  end
end

M.defaults = merge_defaults
M.set = merge_set

return M
