local util = require("neoagent.util")
local no_source_options = require("neoagent.model_catalog.source").no_options

local M = {}

local openai = require("neoagent.registry.openai")
local defaults = {
  openai = openai.openai,
  ["openai-codex"] = openai["openai-codex"],
  deepseek = require("neoagent.registry.deepseek"),
  ["alibaba-token-plan"] = require("neoagent.registry.alibaba_token_plan"),
  zai = require("neoagent.registry.zai"),
  ["zai-coding-plan"] = require("neoagent.registry.zai_coding_plan"),
  anthropic = require("neoagent.registry.anthropic"),
  ["opencode-go"] = require("neoagent.registry.opencode_go"),
  ["llama.cpp"] = {
    api = "openai-completions",
    base_url = "http://127.0.0.1:8080/v1",
    auth = "llama",
    auth_optional = true,
    request_opts = { body = {
      return_progress = true,
      timings_per_token = true,
    } },
    catalog = {
      source_id = "llama-cpp-models",
      source_revision = 1,
      source_options = no_source_options,
      account_scoped = true,
      ttl_ms = 5 * 60 * 1000,
      seed = {},
      discover = require("neoagent.providers.llama.catalog").discover,
      transform_model = require("neoagent.providers.llama.catalog").transform,
    },
    models = {},
    service = require("neoagent.providers.llama").new,
  },
}

local function compose_models(base, user)
  if user == nil then return util.copy(base or {}) end
  assert(type(user) == "table"
      and (next(user) == nil or not util.is_list(user)),
    "provider models must be a keyed table")
  local result = util.copy(base or {})
  for id, model in pairs(user) do
    assert(type(id) == "string", "models must use string ids")
    if model == false then
      result[id] = false
    else
      assert(type(model) == "table", "models must contain tables or false")
      result[id] = util.deep_merge(result[id], model)
    end
  end
  return result
end

local function assert_transform(value)
  assert(value == nil or type(value) == "function",
    "provider catalog transform_model must be a function")
  return value
end

local function transformed(transform, model, ctx)
  if not transform then return util.copy(model) end
  local result = transform(util.copy(model), util.copy(ctx))
  if result == false then return false end
  assert(type(result) == "table" and not util.is_list(result),
    "provider catalog transform_model must return a model or false")
  return util.copy(result)
end

local function compose_transform(base, user)
  base = assert_transform(base)
  user = assert_transform(user)
  if not base then return user end
  if not user then return base end
  return function(model, ctx)
    local current = transformed(base, model, ctx)
    if current == false then return false end
    return transformed(user, current, ctx)
  end
end

local function compose_catalog(base, user)
  base = base or {}
  user = user or {}
  assert(type(base) == "table"
      and (next(base) == nil or not util.is_list(base)),
    "provider catalog must be an object")
  assert(type(user) == "table"
      and (next(user) == nil or not util.is_list(user)),
    "provider catalog must be an object")
  if user.discover ~= nil and user.discover ~= base.discover then
    assert(type(user.source_id) == "string" and user.source_id ~= ""
        and user.source_revision ~= nil,
      "a configured catalog discover callback requires source_id and source_revision")
  end
  if user.source_id ~= nil or user.source_revision ~= nil then
    assert(user.source_id ~= nil and user.source_revision ~= nil,
      "catalog source_id and source_revision must be configured together")
  end
  local base_values = util.copy(base)
  local user_values = util.copy(user)
  base_values.transform_model = nil
  user_values.transform_model = nil
  local result = util.deep_merge(base_values, user_values)
  result.transform_model = compose_transform(
    base.transform_model, user.transform_model)
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
      local base = result[id] or {}
      local override = util.copy(provider)
      override.models = nil
      override.catalog = nil
      result[id] = util.deep_merge(base, override)
      result[id].models = compose_models(base.models, provider.models)
      result[id].catalog = compose_catalog(base.catalog, provider.catalog)
    end
  end
  return result
end

return M
