local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")

local M = {}

local function cleanup(services, candidate)
  local destroyed = {}
  for _, service in pairs(services) do
    if type(service) == "table" and type(service.destroy) == "function"
        and not destroyed[service] then
      destroyed[service] = true
      pcall(service.destroy, service)
    end
  end
  if type(candidate) == "table" and type(candidate.destroy) == "function"
      and not destroyed[candidate] then
    pcall(candidate.destroy, candidate)
  end
end

local function projection(provider)
  local result = {}
  if type(provider.api) == "string" then result.api = provider.api end
  if type(provider.base_url) == "string" then
    result.base_url = provider.base_url
  end
  if type(provider.auth) == "string" then result.auth = provider.auth end
  if type(provider.auth_optional) == "boolean" then
    result.auth_optional = provider.auth_optional
  end
  if type(provider.models) == "table" then
    result.models = util.copy(provider.models)
  end
  if type(provider.service_opts) == "table" then
    result.service_opts = util.copy(provider.service_opts)
  end
  if provider.catalog_cache == false then
    result.catalog_cache = false
  elseif type(provider.catalog_cache) == "table" then
    result.catalog_cache = util.copy(provider.catalog_cache)
  end
  return result
end

function M.compose(configured, opts)
  assert(type(configured) == "table" and not util.is_list(configured),
    "provider services configuration must be an object")
  opts = opts or {}
  assert(type(opts) == "table"
      and (next(opts) == nil or not util.is_list(opts)),
    "provider services options must be an object")
  local result = {}
  for provider_id, provider in pairs(configured.providers or {}) do
    if provider ~= false and type(provider) == "table"
        and type(provider.service) == "function" then
      local ok, value = pcall(provider.service,
        projection(provider), {
          auth = opts.auth,
          store = opts.store,
          transport = opts.transport,
          provider_id = provider_id,
          explicit = type(opts.explicit) == "table"
            and opts.explicit[provider_id] ~= nil,
          default_model = opts.default_model,
          startup = opts.startup,
        })
      if not ok then
        cleanup(result)
        return nil, util.error("provider",
          "Failed to construct provider service for " .. provider_id, value)
      end
      local service, err = provider_service.validate(value)
      if not service then
        cleanup(result, value)
        return nil, err
      end
      if service.id ~= provider_id then
        cleanup(result, service)
        return nil, util.error("provider",
          "Provider Service id for " .. provider_id .. " returned "
            .. tostring(service.id))
      end
      result[provider_id] = service
    end
  end
  return result
end

function M.destroy(services)
  if type(services) ~= "table" then return end
  for _, service in pairs(services) do
    if type(service) == "table" and type(service.destroy) == "function" then
      pcall(service.destroy, service)
    end
  end
end

return M
