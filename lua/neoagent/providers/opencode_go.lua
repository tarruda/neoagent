local async = require("neoagent.async")
local client_module = require("neoagent.providers.opencode_go.client")
local provider_catalog = require("neoagent.provider_catalog")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}
local DEFAULT_BASE_URL = "https://opencode.ai/zen/go/v1"

local response_models = {
  ["gpt-5.6-luna"] = true,
  ["grok-4.5"] = true,
  ["muse-spark-1.2-contributor"] = true,
}

local message_models = {
  ["minimax-m3"] = true,
  ["minimax-m2.7"] = true,
  ["minimax-m2.5"] = true,
  ["qwen3.8-max"] = true,
  ["qwen3.7-max"] = true,
  ["qwen3.7-plus"] = true,
  ["qwen3.6-plus"] = true,
  ["qwen3.5-plus"] = true,
}

local estimates = {
  ["grok-4.5"] = { 120, 300, 600 },
  ["gpt-5.6-luna"] = { 2050, 5100, 10250 },
  ["glm-5.3"] = { 220, 540, 1080 },
  ["glm-5.2"] = { 880, 2150, 4300 },
  ["glm-5.1"] = { 880, 2150, 4300 },
  ["kimi-k3"] = { 110, 250, 490 },
  ["kimi-k2.7-code"] = { 1350, 3380, 6750 },
  ["kimi-k2.6"] = { 1150, 2880, 5750 },
  ["mimo-v2.5"] = { 30100, 75200, 150400 },
  ["mimo-v2.5-pro"] = { 3250, 8150, 16300 },
  ["minimax-m3"] = { 3200, 8000, 16000 },
  ["minimax-m2.7"] = { 3400, 8500, 17000 },
  ["muse-spark-1.2-contributor"] = { 45300, 113300, 226600 },
  ["qwen3.8-max"] = { 160, 400, 810 },
  ["qwen3.7-max"] = { 340, 840, 1690 },
  ["qwen3.7-plus"] = { 4300, 10800, 21600 },
  ["qwen3.6-plus"] = { 3300, 8200, 16300 },
  ["deepseek-v4-pro"] = { 1050, 2600, 5200 },
  ["deepseek-v4-flash"] = { 7600, 18900, 37800 },
  ["hy3"] = { 4300, 10750, 21500 },
}

local windows = {
  { id = "rolling", label = "5-hour limit", short = "5-hour", dollars = 12 },
  { id = "weekly", label = "Weekly limit", short = "Weekly", dollars = 30 },
  { id = "monthly", label = "Monthly limit", short = "Monthly", dollars = 60 },
}

local function route_for(id)
  if response_models[id] then return "openai-responses" end
  if message_models[id] then return "anthropic-messages" end
  return "openai-completions"
end

local function model_entries(ids)
  local result = {}
  for _, id in ipairs(ids or {}) do
    local entry = { id = id, input = { "text" } }
    local api = route_for(id)
    if api ~= "openai-completions" then entry.api = api end
    result[#result + 1] = entry
  end
  table.sort(result, function(left, right) return left.id < right.id end)
  return result
end

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
        and setting % 1 == 0,
      "opencode-go service option " .. name
        .. " must be a positive integer")
  end
  return util.copy(value)
end

local function validate_catalog_cache(value)
  if value == false then return false end
  value = value or {}
  assert(type(value) == "table"
      and (next(value) == nil or not util.is_list(value)),
    "opencode-go catalog_cache must be false or an object")
  for name in pairs(value) do
    assert(name == "ttl_ms",
      "unknown opencode-go catalog cache option: " .. tostring(name))
  end
  local ttl = value.ttl_ms
  assert(ttl == nil or type(ttl) == "number" and ttl >= 0
      and ttl % 1 == 0,
    "opencode-go catalog_cache.ttl_ms must be a non-negative integer")
  return util.copy(value)
end

local function cached_ids(value)
  if type(value) ~= "table" or util.is_list(value)
      or value.version ~= 1 or type(value.checked_at) ~= "number"
      or value.checked_at ~= value.checked_at or value.checked_at < 0
      or value.checked_at == math.huge
      or type(value.models) ~= "table" or not util.is_list(value.models)
      or #value.models > 100 then
    return nil
  end
  local ids, seen = {}, {}
  for _, id in ipairs(value.models) do
    if type(id) ~= "string" or id == "" or #id > 512
        or not util.is_valid_utf8(id)
        or id:find("[%z\1-\31\127]") or seen[id] then
      return nil
    end
    seen[id] = true
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

local function count_models(configured, discovered)
  local ids = {}
  for id, model in pairs(configured or {}) do
    if type(model) == "table" then ids[id] = true end
  end
  for _, model in ipairs(discovered or {}) do ids[model.id] = true end
  return vim.tbl_count(ids)
end

local function limit_level(window)
  if window.rate_limited or window.remaining <= 0 then return "error" end
  if window.remaining <= 0.2 then return "warn" end
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

function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  local base_url = (opts.base_url or DEFAULT_BASE_URL):gsub("/+$", "")
  local service_opts = validate_service_opts(opts.service_opts)
  local catalog_cache = validate_catalog_cache(opts.catalog_cache)
  local now = resources.now or util.now_ms
  local client = client_module.new({
    base_url = base_url,
    transport = resources.transport,
    timeout_ms = service_opts.timeout_ms,
    max_response_bytes = service_opts.max_response_bytes,
    ambient_api_key = resources.ambient_api_key,
  })
  local status = {
    type = "status",
    text = "Usage loads when this console opens",
    level = "muted",
  }
  local usage
  local selected_model
  local models = {}
  local destroyed = false
  local startup_run

  local function blocks(model_id)
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
    if model_id then
      result[#result + 1] = {
        type = "field", label = "Selected model", value = model_id,
      }
      local caps = estimates[model_id]
      if caps and usage then
        local items = {}
        for index, definition in ipairs(windows) do
          items[#items + 1] = {
            label = definition.short,
            detail = "~" .. grouped(caps[index]
              * usage[definition.id].remaining) .. " of "
              .. grouped(caps[index]) .. " typical requests",
          }
        end
        result[#result + 1] = {
          type = "list", title = "Selected-model estimate", items = items,
        }
      end
    end
    result[#result + 1] = {
      type = "field", label = "Models",
      value = tostring(count_models(opts.models, models)) .. " available",
    }
    return result
  end

  local dashboard = provider_state.new({ blocks = blocks() })

  local function publish()
    if destroyed then return end
    local ok, err = dashboard:push({ blocks = blocks(selected_model) })
    if not ok then
      vim.notify("neoagent OpenCode Go dashboard failed: "
        .. tostring(err and err.message or err), vim.log.levels.ERROR)
    end
  end

  local function set_models(ids)
    models = model_entries(ids)
    publish()
  end

  local service = {
    id = resources.provider_id or "opencode-go",
    name = "OpenCode Go",
    open_operation = "refresh",
    operations = {},
  }

  function service:state(ctx)
    if ctx ~= nil then
      local selected = type(ctx) == "table" and ctx.model or nil
      local model_id = type(selected) == "table"
        and selected.provider == service.id and selected.model or nil
      return { blocks = blocks(model_id) }
    end
    return dashboard:state()
  end

  function service:subscribe(listener)
    return dashboard:subscribe(listener)
  end

  function service:get_models()
    return util.copy(models)
  end

  function service:refresh_models(refresh_opts)
    refresh_opts = refresh_opts or {}
    return async.run(function()
      local ids = cached_ids(refresh_opts.stored)
      local checked_at = ids and refresh_opts.stored.checked_at or nil
      if refresh_opts.allow_network then
        local fetched = client:models():await()
        if fetched.ok == false then error(fetched.error, 0) end
        ids = fetched.models
        checked_at = now()
      end
      if not ids then
        error(util.error("provider",
          "OpenCode Go has no usable cached model catalog"), 0)
      end
      local publication = {
        update = function() set_models(ids) end,
        persist = {
          version = 1,
          checked_at = checked_at,
          models = util.copy(ids),
        },
      }
      local published = refresh_opts.publish(publication)
      return { ok = true, models = published and model_entries(ids) or self:get_models() }
    end, { error_kind = "provider" })
  end

  local catalog_options = { service = service, now = now }
  if catalog_cache ~= false then
    catalog_options.store = resources.store
    catalog_options.ttl_ms = catalog_cache.ttl_ms
  end
  local catalog = provider_catalog.new(catalog_options)

  function service:refresh_catalog(refresh_opts)
    refresh_opts = refresh_opts or {}
    return catalog:refresh({
      allow_network = refresh_opts.allow_network ~= false,
      force = refresh_opts.force == true,
      on_done = refresh_opts.on_done,
    })
  end

  service.operations.refresh = {
    label = "Refresh usage",
    description = "Load shared 5-hour, weekly, and monthly Go quotas",
    mutating = false,
    run = function(ctx)
      return async.run(function()
        ctx.interact.progress("Loading OpenCode Go usage")
        selected_model = ctx.model and ctx.model.model or selected_model
        local refreshed = client:usage(ctx):await()
        if refreshed.ok == false then
          local message = refreshed.error and refreshed.error.message
            or "unknown error"
          status = {
            type = "status",
            text = "Usage refresh failed: " .. message,
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

  service.operations.models = {
    label = "Refresh models",
    description = "Load the current OpenCode Go model catalog",
    mutating = false,
    run = function(ctx)
      return async.run(function()
        ctx.interact.progress("Loading OpenCode Go models")
        local refreshed = service:refresh_catalog({
          allow_network = true, force = true,
        }):await()
        if refreshed.ok == false then error(refreshed.error, 0) end
        return { ok = true }
      end, { error_kind = "provider" })
    end,
  }

  function service:destroy()
    if destroyed then return end
    destroyed = true
    if startup_run then startup_run:cancel() end
    startup_run = nil
    dashboard:destroy()
  end

  local provider_id = resources.provider_id or "opencode-go"
  local startup_fetch = resources.startup ~= false
    and (resources.explicit == true
      or type(resources.default_model) == "table"
        and resources.default_model.provider == provider_id)
  if startup_fetch then
    startup_run = service:refresh_catalog({
      allow_network = true,
      on_done = function(result)
        startup_run = nil
        if not result.ok and not destroyed then
          status = {
            type = "status",
            text = "Model catalog refresh failed: "
              .. tostring(result.error and result.error.message or "unknown error"),
            level = "warn",
          }
          publish()
        end
      end,
    })
  end

  return service
end

M.route_for = route_for
M.estimates = util.copy(estimates)

return M
