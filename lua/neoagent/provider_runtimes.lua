local model_catalog = require("neoagent.model_catalog")
local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")

local M = {}
local destroyed = setmetatable({}, { __mode = "k" })

local function provider_projection(provider)
  local result = {}
  for _, key in ipairs({
    "api", "base_url", "auth", "auth_optional", "models", "service_opts",
  }) do
    if provider[key] ~= nil then result[key] = util.copy(provider[key]) end
  end
  return result
end

local function empty_service(provider_id)
  return {
    id = provider_id,
    name = provider_id,
    operations = {},
    state = function() return false end,
  }
end

local function destroy_values(runtimes, candidate)
  local services = {}
  for _, runtime in pairs(runtimes) do
    if runtime.catalog then pcall(runtime.catalog.destroy, runtime.catalog) end
    local service = runtime.service
    if type(service) == "table" and type(service.destroy) == "function"
        and not services[service] then
      services[service] = true
      pcall(service.destroy, service)
    end
  end
  if type(candidate) == "table" and type(candidate.destroy) == "function"
      and not services[candidate] then
    pcall(candidate.destroy, candidate)
  end
end

function M.compose(configured, opts)
  assert(type(configured) == "table" and not util.is_list(configured),
    "provider runtime configuration must be an object")
  opts = opts or {}
  assert(type(opts) == "table"
      and (next(opts) == nil or not util.is_list(opts)),
    "provider runtime options must be an object")
  assert(opts.report == nil or type(opts.report) == "function",
    "provider runtime report must be a function")
  local runtimes = {}

  for provider_id, provider in pairs(configured.providers or {}) do
    local ok, catalog = pcall(model_catalog.new, {
      provider_id = provider_id,
      provider = provider,
      definition = provider.catalog,
      models = provider.models,
      store = opts.store,
      authentication = opts.auth,
      transport = opts.transport,
      report = opts.report,
      now = opts.now,
      new_timer = opts.new_timer,
    })
    if not ok then
      destroy_values(runtimes)
      return nil, util.error("provider",
        "Failed to construct model catalog for " .. provider_id, catalog)
    end
    runtimes[provider_id] = {
      id = provider_id,
      definition = provider,
      catalog = catalog,
      report = opts.report,
    }
  end

  for provider_id, runtime in pairs(runtimes) do
    local provider = runtime.definition
    local service = empty_service(provider_id)
    if type(provider.service) == "function" then
      local ok, value = pcall(provider.service, provider_projection(provider), {
        auth = opts.auth,
        catalog = runtime.catalog,
        transport = opts.transport,
        provider_id = provider_id,
        report = opts.report,
        ambient_api_key = function()
          local source = provider.api_key
          return type(source) == "function" and source() or source
        end,
      })
      if not ok then
        destroy_values(runtimes)
        return nil, util.error("provider",
          "Failed to construct provider service for " .. provider_id, value)
      end
      service = value
    end
    local validated, validate_err = provider_service.validate(service)
    if not validated then
      destroy_values(runtimes, service)
      return nil, validate_err
    end
    if validated.id ~= provider_id then
      destroy_values(runtimes, validated)
      return nil, util.error("provider",
        "Provider Service id for " .. provider_id .. " returned "
          .. tostring(validated.id))
    end
    runtime.service = validated
  end

  if opts.startup ~= false then
    for _, runtime in pairs(runtimes) do runtime.catalog:start() end
  end
  return runtimes
end

function M.destroy(runtimes)
  if type(runtimes) ~= "table" then return end
  if destroyed[runtimes] then return false end
  destroyed[runtimes] = true
  destroy_values(runtimes)
  return true
end

return M
