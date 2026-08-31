local async = require("neoagent.async")
local client_module = require("neoagent.providers.deepseek.client")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}
local DEFAULT_BASE_URL = "https://api.deepseek.com"

local function validate_service_opts(value)
  value = value or {}
  assert(type(value) == "table"
      and (next(value) == nil or not util.is_list(value)),
    "deepseek service_opts must be an object")
  local allowed = { timeout_ms = true, max_response_bytes = true }
  for name, setting in pairs(value) do
    assert(allowed[name], "unknown deepseek service option: " .. tostring(name))
    assert(type(setting) == "number" and setting > 0
        and setting < math.huge and setting % 1 == 0,
      "deepseek service option " .. name .. " must be a positive integer")
  end
  return util.copy(value)
end

local function client(provider, resources)
  local service_opts = validate_service_opts(provider.service_opts)
  return client_module.new({
    base_url = (provider.base_url or DEFAULT_BASE_URL):gsub("/+$", ""),
    transport = resources.transport,
    timeout_ms = service_opts.timeout_ms,
    max_response_bytes = service_opts.max_response_bytes,
    ambient_api_key = resources.ambient_api_key,
  })
end

function M.discover_models(ctx)
  local selected = client(ctx.provider, {
    transport = ctx.transport,
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

local function amount(currency, value)
  return (currency == "USD" and "$" or "CN¥") .. value
end

function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  local provider_id = resources.provider_id or "deepseek"
  local base_url = (opts.base_url or DEFAULT_BASE_URL):gsub("/+$", "")
  local selected = client(opts, resources)
  local status
  local balance
  local destroyed = false

  local function blocks()
    local result = {}
    if status then result[#result + 1] = util.copy(status) end
    result[#result + 1] = {
      type = "field", label = "Endpoint", value = base_url,
    }
    if balance then
      for _, currency in ipairs(balance.currencies) do
        result[#result + 1] = {
          type = "list",
          title = currency.currency .. " balance",
          items = {
            { label = "Total", detail = amount(currency.currency, currency.total) },
            { label = "Topped up", detail = amount(currency.currency, currency.topped_up) },
            { label = "Granted", detail = amount(currency.currency, currency.granted) },
          },
        }
      end
    end
    return result
  end

  local dashboard = provider_state.new(
    { blocks = blocks() }, { report = resources.report })
  local function publish()
    if not destroyed then assert(dashboard:push({ blocks = blocks() })) end
  end
  local service = {
    id = provider_id,
    name = "DeepSeek",
    operations = {},
  }

  function service:state() return dashboard:state() end
  function service:subscribe(listener) return dashboard:subscribe(listener) end

  service.operations.refresh = {
    label = "Refresh balance",
    description = "Load current DeepSeek account balances",
    mutating = false,
    run = function(ctx)
      return async.run(function()
        ctx.interact.progress({
          id = "refresh",
          label = "Refresh balance",
          state = "running",
          message = "Loading DeepSeek balance",
        })
        local refreshed = selected:balance(ctx):await()
        if refreshed.ok == false then
          local err = refreshed.error
          if err and err.status == 403 then
            local detail = tostring(err.message or "permission denied")
            status = {
              type = "status",
              text = "DeepSeek balance reporting is unavailable for this API key: " .. detail,
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
        status = nil
        publish()
        return { ok = true }
      end, { error_kind = "provider" })
    end,
  }

  function service:destroy()
    if destroyed then return end
    destroyed = true
    dashboard:destroy()
  end

  return service
end

return M
