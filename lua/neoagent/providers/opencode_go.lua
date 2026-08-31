local async = require("neoagent.async")
local client_module = require("neoagent.providers.opencode_go.client")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}
local DEFAULT_BASE_URL = "https://opencode.ai/zen/go/v1"

local windows = {
  { id = "rolling", label = "5-hour limit", dollars = 12 },
  { id = "weekly", label = "Weekly limit", dollars = 30 },
  { id = "monthly", label = "Monthly limit", dollars = 60 },
}

local function validate_service_opts(value)
  value = value or {}
  assert(type(value) == "table"
      and (next(value) == nil or not util.is_list(value)),
    "opencode-go service_opts must be an object")
  local allowed = { timeout_ms = true, max_response_bytes = true }
  for name, setting in pairs(value) do
    assert(allowed[name],
      "unknown opencode-go service option: " .. tostring(name))
    assert(type(setting) == "number" and setting > 0
        and setting < math.huge and setting % 1 == 0,
      "opencode-go service option " .. name .. " must be a positive integer")
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
    local resolved = ctx.resolve_auth():await()
    if resolved.ok == false then error(resolved.error, 0) end
    if resolved.configured ~= true then
      local ok, key = pcall(ctx.resolve_api_key)
      if not ok then
        error(util.error("auth",
          "Failed to resolve OPENCODE_API_KEY", key), 0)
      end
      if type(key) ~= "string" or util.trim(key) == "" then
        error(util.error("auth",
          "Connect OpenCode Go or set OPENCODE_API_KEY to load models"), 0)
      end
    end
    local result = selected:models():await()
    if result.ok == false then error(result.error, 0) end
    local models = {}
    for _, id in ipairs(result.models) do models[#models + 1] = { id = id } end
    return { ok = true, models = models }
  end, { error_kind = "provider" })
end

local function limit_level(window)
  if window.rate_limited or window.remaining <= 0 then return "error" end
  if window.remaining <= 0.2 then return "warn" end
  return "success"
end

function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  local base_url = (opts.base_url or DEFAULT_BASE_URL):gsub("/+$", "")
  local selected = client(opts, resources)
  local status
  local usage
  local destroyed = false

  local function blocks()
    local result = {}
    if status then result[#result + 1] = util.copy(status) end
    result[#result + 1] = {
      type = "field", label = "Endpoint", value = base_url,
    }
    result[#result + 1] = {
      type = "field", label = "Quota scope",
      value = "Shared across all Go models",
    }
    if usage then
      for _, definition in ipairs(windows) do
        local window = usage[definition.id]
        result[#result + 1] = {
          type = "limit",
          label = definition.label,
          remaining = window.remaining,
          resets_at = window.resets_at,
          detail = string.format("≈ $%.2f of $%d allowance remaining",
            definition.dollars * window.remaining, definition.dollars),
          level = limit_level(window),
        }
      end
    end
    return result
  end

  local report = resources.report or function() end
  local dashboard = provider_state.new({ blocks = blocks() }, { report = report })
  local function publish()
    if destroyed then return end
    local ok, err = dashboard:push({ blocks = blocks() })
    if not ok then
      report("neoagent OpenCode Go dashboard failed: "
        .. tostring(err and err.message or err), vim.log.levels.ERROR)
    end
  end
  local service = {
    id = resources.provider_id or "opencode-go",
    name = "OpenCode Go",
    operations = {},
  }

  function service:state() return dashboard:state() end
  function service:subscribe(listener) return dashboard:subscribe(listener) end

  service.operations.refresh = {
    label = "Refresh usage",
    description = "Load shared 5-hour, weekly, and monthly Go quotas",
    mutating = false,
    run = function(ctx)
      return async.run(function()
        ctx.interact.progress({
          id = "refresh",
          label = "Refresh usage",
          state = "running",
          message = "Loading OpenCode Go usage",
        })
        local refreshed = selected:usage(ctx):await()
        if refreshed.ok == false then
          status = {
            type = "status",
            text = "Usage refresh failed: " .. tostring(
              refreshed.error and refreshed.error.message or "unknown error"),
            level = "error",
          }
          publish()
          error(refreshed.error, 0)
        end
        usage = refreshed.usage
        local exhausted = false
        for _, definition in ipairs(windows) do
          if usage[definition.id].rate_limited then exhausted = true break end
        end
        status = exhausted and {
          type = "status",
          text = "A Go usage window is exhausted",
          level = "error",
        } or nil
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
