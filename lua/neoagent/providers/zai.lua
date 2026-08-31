local async = require("neoagent.async")
local client_module = require("neoagent.providers.zai.client")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}
local DEFAULT_BASE_URL = "https://api.z.ai/api/paas/v4"

local function validate_service_opts(value)
  value = value or {}
  assert(type(value) == "table"
      and (next(value) == nil or not util.is_list(value)),
    "zai service_opts must be an object")
  local allowed = {
    timeout_ms = "number",
    max_response_bytes = "number",
    management_url = "string",
  }
  for name, setting in pairs(value) do
    local kind = allowed[name]
    assert(kind, "unknown zai service option: " .. tostring(name))
    if kind == "number" then
      assert(type(setting) == "number" and setting > 0
          and setting < math.huge and setting % 1 == 0,
        "zai service option " .. name .. " must be a positive integer")
    else
      assert(type(setting) == "string" and setting ~= "",
        "zai service option management_url must be a non-empty string")
    end
  end
  return util.copy(value)
end

local function origin(url)
  return url:match("^(https?://[^/]+)") or url
end

local function level(remaining)
  if remaining <= 0 then return "error" end
  if remaining <= 0.2 then return "warn" end
  return "success"
end

local function grouped(value)
  local digits = tostring(math.floor(value))
  while true do
    local next_value, count = digits:gsub("^(%d+)(%d%d%d)", "%1,%2")
    digits = next_value
    if count == 0 then return digits end
  end
end

local function money(value, currency)
  if currency == "USD" then return string.format("$%.2f", value) end
  if currency then return string.format("%s %.2f", currency, value) end
  return string.format("%.2f", value)
end

local function unavailable(resource, err)
  return "Z.AI " .. resource .. " reporting is unavailable for this API key: "
    .. tostring(err.message or "permission denied")
end

function M.discover_models(ctx)
  local service_opts = validate_service_opts(ctx.provider.service_opts)
  local selected = client_module.new({
    management_url = (ctx.provider.base_url or DEFAULT_BASE_URL)
      :gsub("/+$", ""),
    transport = ctx.transport,
    timeout_ms = service_opts.timeout_ms,
    max_response_bytes = service_opts.max_response_bytes,
    ambient_api_key = ctx.resolve_api_key,
  })
  return async.run(function()
    local result = selected:models({ resolve_auth = ctx.resolve_auth }):await()
    if result.ok == false then error(result.error, 0) end
    local models = {}
    for _, id in ipairs(result.models) do models[#models + 1] = { id = id } end
    return { ok = true, models = models }
  end, { error_kind = "provider" })
end

function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  local provider_id = resources.provider_id or "zai"
  local plan = provider_id == "zai-coding-plan"
  local name = plan and "Z.AI Plan" or "Z.AI API"
  local base_url = (opts.base_url or DEFAULT_BASE_URL):gsub("/+$", "")
  local service_opts = validate_service_opts(opts.service_opts)
  local management_url = (service_opts.management_url or origin(base_url))
    :gsub("/+$", "")
  local client = client_module.new({
    management_url = management_url,
    transport = resources.transport,
    timeout_ms = service_opts.timeout_ms,
    max_response_bytes = service_opts.max_response_bytes,
    ambient_api_key = resources.ambient_api_key,
  })
  local status
  local quota
  local balance
  local destroyed = false

  local function blocks()
    local result = {}
    if status then result[#result + 1] = util.copy(status) end
    result[#result + 1] = {
      type = "field", label = "Endpoint", value = base_url,
    }
    if balance then
      result[#result + 1] = {
        type = "field", label = "Available balance",
        value = money(balance.available, balance.currency),
      }
      result[#result + 1] = {
        type = "field", label = "Total balance",
        value = money(balance.total, balance.currency),
      }
    end
    if quota and quota.plan then
      result[#result + 1] = {
        type = "field", label = "Plan", value = quota.plan,
      }
    end
    for _, limit in ipairs(quota and quota.limits or {}) do
      local resource = limit.type == "TOKENS_LIMIT" and "token"
        or limit.type == "CREDIT_LIMIT" and "credit" or "MCP"
      local detail
      if limit.current ~= nil then
        detail = grouped(limit.current) .. " of " .. grouped(limit.maximum)
          .. (resource == "MCP" and " uses consumed"
            or (" " .. resource .. "s consumed"))
      end
      result[#result + 1] = {
        type = "limit",
        label = limit.window .. " " .. resource .. " limit",
        remaining = limit.remaining,
        resets_at = limit.resets_at,
        detail = detail,
        level = level(limit.remaining),
      }
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
    id = provider_id,
    name = name,
    operations = {},
  }

  function service:state()
    return dashboard:state()
  end

  function service:subscribe(listener)
    return dashboard:subscribe(listener)
  end

  if plan then
    service.operations.refresh = {
      label = "Refresh quotas",
      description = "Load current plan quotas",
      mutating = false,
      run = function(ctx)
        return async.run(function()
          ctx.interact.progress({
            id = "refresh", label = "Refresh quotas", state = "running",
            message = "Loading Z.AI Plan quotas",
          })
          local refreshed = client:quota(ctx):await()
          if refreshed.ok == false then
            local err = refreshed.error
            if err and (err.status == 401 or err.status == 403) then
              status = {
                type = "status",
                text = unavailable("quota", err),
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
          quota = refreshed.quota
          status = nil
          publish()
          return { ok = true }
        end, { error_kind = "provider" })
      end,
    }
  else
    service.operations.refresh = {
      label = "Refresh balance",
      description = "Load current Z.AI API balance",
      mutating = false,
      run = function(ctx)
        return async.run(function()
          ctx.interact.progress({
            id = "refresh", label = "Refresh balance", state = "running",
            message = "Loading Z.AI API balance",
          })
          local refreshed = client:balance(ctx):await()
          if refreshed.ok == false then
            local err = refreshed.error
            if err and (err.status == 401 or err.status == 403
                or err.status == 404) then
              status = {
                type = "status",
                text = unavailable("balance", err),
                level = "warn",
              }
              publish()
              return { ok = true }
            end
            status = {
              type = "status",
              text = "Balance refresh failed: " .. tostring(
                err and err.message or "unknown error"),
              level = "error",
            }
            publish()
            error(err, 0)
          end
          balance = refreshed.balance
          if balance.available > 0 then
            status = nil
          else
            status = {
              type = "status",
              text = "Z.AI API balance is exhausted",
              level = "error",
            }
          end
          publish()
          return { ok = true }
        end, { error_kind = "provider" })
      end,
    }
  end

  function service:destroy()
    if destroyed then return end
    destroyed = true
    dashboard:destroy()
  end

  return service
end

return M
