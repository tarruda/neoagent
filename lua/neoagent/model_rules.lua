local util = require("neoagent.util")

local M = {}

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

local function matches(rule, model, ctx)
  if type(rule.match) == "string" then
    return model.id:match(rule.match) ~= nil
  end
  return rule.match(model, ctx) == true
end

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
  return function(model, ctx)
    assert(type(model) == "table" and type(model.id) == "string",
      "model rule input must contain an id")
    local current = util.copy(model)
    for _, rule in ipairs(rules) do
      if matches(rule, current, ctx) then
        merge_defaults(current, rule.defaults)
        merge_set(current, rule.set)
        if rule.apply then
          current = rule.apply(current, ctx)
          if current == false then return false end
          assert(type(current) == "table" and not util.is_list(current),
            "model rule apply must return a model or false")
        end
      end
    end
    return current
  end
end

M.defaults = merge_defaults
M.set = merge_set

return M
