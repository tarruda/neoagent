local model_catalog = require("neoagent.model_catalog")
local provider_auth = require("neoagent.provider_auth")
local provider_credentials = require("neoagent.provider_credentials")
local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")

local M = {}
local destroyed = setmetatable({}, { __mode = "k" })

local function bind_transport(transport, context)
  if type(transport) == "table"
      and type(transport.with_context) == "function" then
    return transport.with_context(context)
  end
  return transport
end

local function provider_projection(provider)
  local result = {}
  for _, key in ipairs({
    "api", "base_url", "auth", "auth_optional", "auth_scopes", "models",
    "service_opts",
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
    if type(service) == "table" and not services[service] then
      services[service] = true
      local validated = provider_service.validate(service)
      if validated then
        provider_service.retire(service, function()
          if type(service.destroy) == "function" then
            pcall(service.destroy, service)
          end
        end)
      elseif type(service.destroy) == "function" then
        pcall(service.destroy, service)
      end
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
  local provider_ids = vim.tbl_keys(configured.providers or {})
  table.sort(provider_ids)

  for _, provider_id in ipairs(provider_ids) do
    local provider = configured.providers[provider_id]
    local bound_service
    local model_transport = bind_transport(opts.transport, {
      provider = provider_id,
      origin = "model",
    })
    local credentials = provider_credentials.new({
      provider_id = provider_id,
      provider = provider,
      authentication = opts.auth,
      method = configured.auth and configured.auth.methods
          and configured.auth.methods[provider.auth] or nil,
    })
    local ok, catalog = pcall(model_catalog.new, {
      provider_id = provider_id,
      provider = provider,
      definition = provider.catalog,
      models = provider.models,
      store = opts.store,
      authentication = opts.auth,
      credentials = credentials,
      transport = bind_transport(opts.transport, {
        provider = provider_id,
        origin = "catalog",
      }),
      report = opts.report,
      now = opts.now,
      new_timer = opts.new_timer,
      acquire_use = function()
        if not bound_service then
          return { release = function() return true end }
        end
        return provider_service.acquire_use(bound_service)
      end,
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
      credentials = credentials,
      transport = model_transport,
      report = opts.report,
      bind_service = function(service) bound_service = service end,
    }
  end

  for _, provider_id in ipairs(provider_ids) do
    local runtime = runtimes[provider_id]
    local provider = runtime.definition
    local service = empty_service(provider_id)
    if type(provider.service) == "function" then
      local ok, value = pcall(provider.service, provider_projection(provider), {
        auth = opts.auth,
        catalog = runtime.catalog,
        transport = bind_transport(opts.transport, {
          provider = provider_id,
          origin = "provider-shell",
        }),
        provider_id = provider_id,
        report = opts.report,
        ambient_api_key = function()
          return runtime.credentials:ambient_api_key()
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
    runtime.bind_service(validated)
    runtime.bind_service = nil
  end

  local auth_groups = {}
  for _, provider_id in ipairs(provider_ids) do
    local runtime = runtimes[provider_id]
    runtime.auth_methods = {}
    for _, entry in ipairs(provider_auth.entries(runtime.definition)) do
      local method = entry.method
      if type(method) == "string" then
        auth_groups[method] = auth_groups[method] or {}
        auth_groups[method][#auth_groups[method] + 1] = runtime.service
        runtime.auth_methods[#runtime.auth_methods + 1] = method
      end
    end
  end
  for _, runtime in pairs(runtimes) do
    runtime.auth_services = {}
    for _, method in ipairs(runtime.auth_methods) do
      runtime.auth_services[method] = auth_groups[method]
    end
    runtime.auth_methods = nil
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
