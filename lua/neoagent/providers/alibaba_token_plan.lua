local async = require("neoagent.async")
local client_module = require("neoagent.providers.alibaba_token_plan.client")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}
local DEFAULT_BASE_URL =
  "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"

function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  assert(opts.service_opts == nil or type(opts.service_opts) == "table"
      and next(opts.service_opts) == nil,
    "alibaba-token-plan does not support service_opts")
  local base_url = (opts.base_url or DEFAULT_BASE_URL):gsub("/+$", "")
  local client = resources.client or client_module.new({
    transport = resources.transport,
  })
  assert(type(client) == "table" and type(client.usage) == "function",
    "Alibaba Token Plan client requires usage")
  local status
  local usage
  local destroyed = false

  local function level(remaining)
    if remaining <= 0 then return "error" end
    if remaining <= 0.2 then return "warn" end
    return "success"
  end

  local function quota_block(id, label, absent)
    local value = usage and usage[id] or nil
    if not value or value.used == nil then
      return { type = "field", label = label, value = absent }
    end
    local remaining = math.max(0, math.min(1, 1 - value.used))
    return {
      type = "limit",
      label = label,
      remaining = remaining,
      resets_at = value.resets_at,
      level = level(remaining),
    }
  end

  local function blocks()
    local result = {}
    if status then result[#result + 1] = util.copy(status) end
    result[#result + 1] = {
      type = "field", label = "Plan", value = "Token Plan Personal",
    }
    result[#result + 1] = {
      type = "field", label = "Endpoint", value = base_url,
    }
    if usage then
      result[#result + 1] = quota_block(
        "five_hour", "5-hour quota", "No limit reported")
      result[#result + 1] = quota_block(
        "seven_day", "7-day quota", "No usage reported")
    end
    return result
  end

  local dashboard = provider_state.new(
    { blocks = blocks() }, { report = resources.report })

  local function publish()
    if destroyed then return end
    assert(dashboard:push({ blocks = blocks() }))
  end

  local service = {
    id = resources.provider_id or "alibaba-token-plan",
    name = "Alibaba Cloud Token Plan Personal",
    operations = {
      refresh = {
        label = "Refresh quotas",
        description = "Load current Token Plan quota usage",
        mutating = false,
        auth_scope = "dashboard",
        run = function(ctx)
          return async.run(function()
            ctx.interact.progress({
              id = "refresh",
              label = "Refresh quotas",
              state = "running",
              message = "Loading Alibaba Cloud Token Plan quotas",
            })
            local refreshed = client:usage(ctx):await()
            if refreshed.ok == false then
              local err = refreshed.error
              if err and (err.kind == "auth" or err.status == 401
                  or err.status == 403) then
                status = {
                  type = "status",
                  text = "Alibaba Cloud quota reporting requires current "
                    .. "dashboard authorization. Log in through the Provider "
                    .. "Shell.",
                  level = "warn",
                }
                publish()
                return { ok = true }
              end
              status = {
                type = "status",
                text = "Quota refresh failed: " .. tostring(
                  err and err.message or "unknown error"),
                level = "error",
              }
              publish()
              error(err, 0)
            end
            usage = refreshed.usage
            status = nil
            publish()
            return { ok = true }
          end, { error_kind = "provider" })
        end,
      },
    },
  }

  function service:state()
    return dashboard:state()
  end

  function service:subscribe(listener)
    return dashboard:subscribe(listener)
  end

  function service:destroy()
    if destroyed then return end
    destroyed = true
    dashboard:destroy()
  end

  return service
end

return M
