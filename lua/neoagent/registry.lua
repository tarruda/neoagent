local util = require("neoagent.util")

local M = {}

local openai = require("neoagent.registry.openai")
local defaults = {
  openai = openai.openai,
  ["openai-codex"] = openai["openai-codex"],
  deepseek = require("neoagent.registry.deepseek"),
  zai = require("neoagent.registry.zai"),
  ["zai-coding-plan"] = require("neoagent.registry.zai_coding_plan"),
}

local function compose_models(base, user)
  if user == nil then return util.copy(base or {}) end
  if user == false then return {} end
  assert(type(user) == "table", "provider models must be a table or false")
  local result = util.copy(base or {})
  for id, model in pairs(user) do
    assert(type(id) == "string", "models must use string ids")
    if model == false then
      result[id] = nil
    else
      assert(type(model) == "table", "models must contain tables or false")
      result[id] = util.deep_merge(result[id], model)
    end
  end
  return result
end

function M.defaults()
  return util.copy(defaults)
end

function M.compose(user, include_defaults)
  assert(type(user) == "table", "providers must be a table")
  local result = include_defaults == false and {} or M.defaults()
  for id, provider in pairs(user) do
    assert(type(id) == "string", "providers must use string ids")
    if provider == false then
      result[id] = nil
    else
      assert(type(provider) == "table", "providers must contain tables or false")
      local base = result[id]
      local override = util.copy(provider)
      override.models = nil
      result[id] = util.deep_merge(base, override)
      result[id].models = compose_models(base and base.models, provider.models)
    end
  end
  return result
end

return M
