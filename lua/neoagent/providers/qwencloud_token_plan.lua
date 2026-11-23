local async = require("neoagent.async")
local provider_auth = require("neoagent.provider_auth")
local provider_http = require("neoagent.providers.http")
local provider_state = require("neoagent.provider_state")
local usage_module = require("neoagent.providers.qwencloud_token_plan.usage")
local util = require("neoagent.util")

local M = { base_url = "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1" }

---@class Neoagent.QwenCloudServiceConfig: Neoagent.ProviderServiceConfig, Neoagent.ProviderAuthConfig

---@class Neoagent.QwenCloudServiceResources: Neoagent.ProviderServiceResources
---@field auth? Neoagent.AuthManager

---@param opts? Neoagent.QwenCloudServiceConfig
---@param resources? Neoagent.QwenCloudServiceResources
---@return Neoagent.ProviderService
function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  local service_opts = provider_http.service_options(opts.service_opts, "qwencloud-token-plan")
  local base_url = (opts.base_url or M.base_url):gsub("/+$", "")
  local method = provider_auth.for_scope(opts, "usage")
  local auth = resources.auth
  local quota = method
      and usage_module.new({
        transport = resources.transport,
        timeout_ms = service_opts.timeout_ms,
        max_response_bytes = service_opts.max_response_bytes,
      })
    or nil
  local destroyed = false
  local revision = 0
  ---@type Neoagent.QwenCloudUsage?
  local usage
  ---@type Neoagent.ProviderStatusBlock?
  local status

  ---@return Neoagent.QwenCloudUsage?
  local function visible_usage()
    if usage and method and auth and auth:credential_status(method) ~= "stored" then
      return nil
    end
    return usage
  end

  ---@param balance? Neoagent.QwenCloudUsage
  ---@return Neoagent.ProviderState
  local function state(balance)
    ---@type Neoagent.ProviderBlock[]
    local blocks = { { type = "field", label = "Endpoint", value = base_url } }
    if status then
      blocks[#blocks + 1] = util.copy(status)
    end
    if balance then
      local window = balance.window
      if window then
        local remaining = window.remaining
        local amounts = window.amounts
        blocks[#blocks + 1] = { type = "field", label = "Plan", value = window.plan }
        blocks[#blocks + 1] = {
          type = "limit",
          label = window.cycle == "weekly" and "Weekly Credits" or "Monthly Credits",
          remaining = remaining,
          resets_at = window.resets_at,
          detail = amounts and ("%.15g of %.15g Credits remaining"):format(amounts.remaining, amounts.total) or nil,
          level = remaining == 0 and "error" or remaining <= 0.2 and "warn" or "success",
        }
      elseif not status then
        blocks[#blocks + 1] = { type = "status", text = "No active QwenCloud Token Plan", level = "muted" }
      end
      if balance.addon == nil then
        blocks[#blocks + 1] = { type = "status", text = "Add-on Credits unavailable", level = "warn" }
      elseif balance.addon > 0 then
        blocks[#blocks + 1] = {
          type = "field",
          label = "Add-on Credits remaining",
          value = ("%.15g"):format(balance.addon),
        }
      end
    end
    return { blocks = blocks }
  end

  local dashboard = provider_state.new(state(), { report = resources.report })
  local function publish()
    assert(dashboard:push(state(visible_usage())))
  end
  local unsubscribe = method
      and auth
      and auth:subscribe(method, function()
        revision = revision + 1
        usage, status = nil, nil
        publish()
      end)
    or nil

  ---@type Neoagent.ProviderService
  local service = {
    id = resources.provider_id or "qwencloud-token-plan",
    name = "QwenCloud Token Plan",
    operations = {},
    state = function()
      if usage and not visible_usage() then
        return state()
      end
      return dashboard:state()
    end,
  }

  if quota then
    service.operations.refresh = {
      label = "Refresh quotas",
      description = "Load the Token Plan credit window and add-on Credits",
      mutating = false,
      auth_scope = "usage",
      run = function(ctx)
        return async.run(function()
          revision = revision + 1
          local started = revision
          ctx.interact.progress({
            id = "refresh",
            label = "Refresh quotas",
            state = "running",
            message = "Loading QwenCloud Token Plan quotas",
          })
          local result = quota:fetch(ctx):await()
          if destroyed or revision ~= started then
            error(util.error("cancelled", "QwenCloud quota refresh was superseded"), 0)
          end
          if not result.ok then
            local err = result.error
            if err.kind ~= "cancelled" then
              if err.kind == "auth" then
                usage = nil
              end
              status = {
                type = "status",
                text = "Quota refresh failed: " .. err.message,
                level = err.kind == "auth" and "warn" or "error",
              }
              publish()
            end
            error(err, 0)
          end
          usage, status = result.usage, nil
          publish()
          return { ok = true }
        end, { error_kind = "provider" })
      end,
    }
  end

  function service:subscribe(listener)
    return dashboard:subscribe(listener)
  end

  function service:destroy()
    if destroyed then
      return
    end
    destroyed = true
    if unsubscribe then
      unsubscribe()
    end
    usage, status = nil, nil
    dashboard:destroy()
  end

  return service
end

return M
