local util = require("neoagent.util")

local M = {}

local openai = require("neoagent.registry.openai")
local defaults = {
  openai = openai.openai,
  ["openai-codex"] = openai["openai-codex"],
  deepseek = require("neoagent.registry.deepseek"),
  zai = require("neoagent.registry.zai"),
  ["zai-coding-plan"] = require("neoagent.registry.zai_coding_plan"),
  anthropic = require("neoagent.registry.anthropic"),
  ["anthropic-plan"] = require("neoagent.registry.anthropic_plan"),
  ["opencode-go"] = require("neoagent.registry.opencode_go"),
  ["llama.cpp"] = {
    api = "openai-completions",
    base_url = "http://127.0.0.1:8080/v1",
    auth = "llama",
    auth_optional = true,
    catalog_cache = { ttl_ms = 60 * 1000 },
    models = {},
    service = require("neoagent.providers.llama").new,
  },
}

local function compose_models(base, user)
  local removals = {}
  if user == nil then return util.copy(base or {}), removals end
  if user == false then return {}, removals end
  assert(type(user) == "table", "provider models must be a table or false")
  local result = util.copy(base or {})
  for id, model in pairs(user) do
    assert(type(id) == "string", "models must use string ids")
    if model == false then
      result[id] = nil
      removals[id] = true
    else
      assert(type(model) == "table", "models must contain tables or false")
      result[id] = util.deep_merge(result[id], model)
    end
  end
  return result, removals
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
      local models, removals = compose_models(base and base.models, provider.models)
      result[id].models = models
      for _, source in ipairs({
        base and base._model_removals or {},
        override._model_removals or {},
      }) do
        for model_id in pairs(source) do removals[model_id] = true end
      end
      if next(removals) then result[id]._model_removals = removals end
    end
  end
  return result
end

return M
