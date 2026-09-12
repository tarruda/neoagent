local async = require("neoagent.async")
local client_module = require("neoagent.providers.anthropic.client")
local provider_http = require("neoagent.providers.http")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}
local DEFAULT_BASE_URL = "https://api.anthropic.com/v1"

---@param provider Neoagent.ProviderServiceConfig
---@param resources Neoagent.ProviderServiceResources
---@return Neoagent.AnthropicClient
local function client(provider, resources)
  local service_opts = provider_http.service_options(provider.service_opts, "anthropic")
  return client_module.new({
    name = "Anthropic API",
    environment = "ANTHROPIC_API_KEY",
    base_url = (provider.base_url or DEFAULT_BASE_URL):gsub("/+$", ""),
    transport = resources.transport,
    timeout_ms = service_opts.timeout_ms,
    max_response_bytes = service_opts.max_response_bytes,
    ambient_api_key = resources.ambient_api_key,
    ambient_headers = function(key)
      return { ["x-api-key"] = key }
    end,
    now = resources.now,
  })
end

---@param ctx Neoagent.CatalogDiscoveryContext<Neoagent.ProviderServiceConfig>
---@return Neoagent.Run<Neoagent.CatalogDiscoveryResult<Neoagent.AnthropicCatalogModel>, nil>
function M.discover_models(ctx)
  local selected = client(ctx.provider, {
    transport = ctx.transport,
    ambient_api_key = ctx.resolve_api_key,
  })
  return async.run(function()
    local result = selected:models({ resolve_auth = ctx.resolve_auth }):await()
    if result.ok == false then
      error(result.error, 0)
    end
    return { ok = true, models = util.copy(result.models) }
  end, { error_kind = "provider" })
end

---@param value number
---@return string
local function grouped(value)
  local digits = tostring(math.floor(value))
  while true do
    local next_value, count = digits:gsub("^(%d+)(%d%d%d)", "%1,%2")
    digits = next_value
    if count == 0 then
      return digits
    end
  end
end

---@param entry Neoagent.AnthropicOrganizationCost
---@return string
local function currency(entry)
  if entry.currency == "USD" then
    return string.format("$%.2f", entry.value)
  end
  return string.format("%.2f %s", entry.value, entry.currency)
end

---@param opts? Neoagent.ProviderServiceConfig
---@param resources? Neoagent.ProviderServiceResources
---@return Neoagent.ProviderService
function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  local provider_id = resources.provider_id or "anthropic"
  local base_url = (opts.base_url or DEFAULT_BASE_URL):gsub("/+$", "")
  local selected = client(opts, resources)
  ---@type Neoagent.ProviderStatusBlock?
  local status
  ---@type Neoagent.AnthropicOrganizationSuccess?
  local report
  local destroyed = false

  ---@return Neoagent.ProviderBlock[]
  local function blocks()
    ---@type Neoagent.ProviderBlock[]
    local result = {}
    if status then
      result[#result + 1] = util.copy(status)
    end
    result[#result + 1] = {
      type = "field",
      label = "Endpoint",
      value = base_url,
    }
    if report then
      for _, cost in ipairs(report.costs) do
        result[#result + 1] = {
          type = "field",
          label = "30-day cost",
          value = currency(cost),
        }
      end
      result[#result + 1] = {
        type = "list",
        title = "30-day token usage",
        items = {
          { label = "Uncached input", detail = grouped(report.usage.uncached_input_tokens) },
          { label = "Cache reads", detail = grouped(report.usage.cache_read_input_tokens) },
          { label = "Cache writes", detail = grouped(report.usage.cache_creation_input_tokens) },
          { label = "Output", detail = grouped(report.usage.output_tokens) },
        },
      }
    end
    return result
  end

  local dashboard = provider_state.new({ blocks = blocks() }, { report = resources.report })
  local function publish()
    if not destroyed then
      assert(dashboard:push({ blocks = blocks() }))
    end
  end
  ---@class Neoagent.AnthropicService: Neoagent.ProviderService
  local service = {
    id = provider_id,
    name = "Anthropic API",
    operations = {},
  }

  function service:state()
    return dashboard:state()
  end
  function service:subscribe(listener)
    return dashboard:subscribe(listener)
  end

  service.operations.refresh = {
    label = "Refresh organization data",
    description = "Load 30-day organization usage and costs",
    mutating = false,
    run = function(ctx)
      return async.run(function()
        ctx.interact.progress({
          id = "refresh",
          label = "Refresh organization data",
          state = "running",
          message = "Loading Anthropic organization usage and costs",
        })
        local refreshed = selected:organization(ctx):await()
        if refreshed.ok == false then
          local err = refreshed.error
          local status_code = err and rawget(err, "status")
          if status_code == 401 or status_code == 403 then
            local detail = tostring(err.message or "permission denied")
            status = {
              type = "status",
              text = "Anthropic organization reporting is unavailable for this API key: " .. detail,
              level = "warn",
            }
            publish()
            return { ok = true }
          end
          status = {
            type = "status",
            text = "Organization refresh failed: " .. tostring(err and err.message or "unknown error"),
            level = "error",
          }
          publish()
          error(err, 0)
        end
        report = refreshed
        status = nil
        publish()
        return { ok = true }
      end, { error_kind = "provider" })
    end,
  }

  function service:destroy()
    if destroyed then
      return
    end
    destroyed = true
    dashboard:destroy()
  end

  return service
end

return M
