local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local util = require("neoagent.util")

local M = {}
local DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024
local DEFAULT_TIMEOUT_MS = 15 * 1000

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function safe_id(value)
  return type(value) == "string" and value ~= "" and #value <= 512
    and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

-- Howard Hinnant's civil-date conversion keeps UTC parsing independent from
-- the host timezone. OpenCode emits JavaScript Date.toISOString() values.
local function iso_timestamp(value)
  if type(value) ~= "string" then return nil end
  local year, month, day, hour, minute, second = value:match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.%d+Z$")
  if not year then
    year, month, day, hour, minute, second = value:match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  if not year or not month or month < 1 or month > 12
      or not day or day < 1 or day > 31
      or not hour or hour > 23 or not minute or minute > 59
      or not second or second > 60 then
    return nil
  end
  local adjusted_year = year - (month <= 2 and 1 or 0)
  local era = math.floor(adjusted_year / 400)
  local year_of_era = adjusted_year - era * 400
  local shifted_month = month + (month > 2 and -3 or 9)
  local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
    - math.floor(year_of_era / 100) + day_of_year
  local days = era * 146097 + day_of_era - 719468
  local timestamp = days * 86400 + hour * 3600 + minute * 60
    + math.min(second, 59)
  local roundtrip = os.date("!*t", timestamp)
  if not roundtrip or roundtrip.year ~= year or roundtrip.month ~= month
      or roundtrip.day ~= day or roundtrip.hour ~= hour
      or roundtrip.min ~= minute or roundtrip.sec ~= math.min(second, 59) then
    return nil
  end
  return timestamp
end

local function response_error(status, resource)
  if status == 401 then
    return "OpenCode Go " .. resource .. " requires a valid API key"
  end
  if status == 403 then
    return "OpenCode Go subscription is required"
  end
  if status == 429 then
    return "OpenCode Go " .. resource .. " request was rate limited"
  end
  return "OpenCode Go " .. resource .. " request failed (HTTP "
    .. tostring(status) .. ")"
end

local function bearer_from(headers)
  for name, value in pairs(headers or {}) do
    if type(name) == "string" and type(value) == "string" then
      local lower = name:lower()
      if lower == "authorization" then
        local key = value:match("^[Bb]earer%s+(.+)$")
        if key and util.trim(key) ~= "" then return util.trim(key) end
      elseif lower == "x-api-key" and util.trim(value) ~= "" then
        return util.trim(value)
      end
    end
  end
end

local function parse_usage(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.usage) ~= "table" or util.is_list(value.usage) then
    return nil
  end
  local result = {}
  for _, id in ipairs({ "rolling", "weekly", "monthly" }) do
    local source = value.usage[id]
    local percent = type(source) == "table" and source.percent or nil
    local status = type(source) == "table" and source.status or nil
    local resets_at = type(source) == "table"
      and iso_timestamp(source.resetsAt) or nil
    if not finite(percent) or percent < 0 or percent > 100
        or percent % 1 ~= 0
        or (status ~= "ok" and status ~= "rate-limited")
        or not resets_at then
      return nil
    end
    result[id] = {
      remaining = math.max(0, math.min(1, (100 - percent) / 100)),
      resets_at = resets_at,
      rate_limited = status == "rate-limited",
    }
  end
  return result
end

local function parse_models(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.data) ~= "table" or not util.is_list(value.data) then
    return nil
  end
  local result, seen = {}, {}
  for _, source in ipairs(value.data) do
    local id = type(source) == "table" and source.id or nil
    if not safe_id(id) or seen[id] then return nil end
    seen[id] = true
    result[#result + 1] = id
  end
  table.sort(result)
  return result
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.base_url) == "string" and opts.base_url ~= "",
    "OpenCode Go base_url is required")
  local transport = opts.transport or curl
  assert(type(transport) == "table" and type(transport.fetch) == "function",
    "OpenCode Go transport requires fetch")
  local maximum = opts.max_response_bytes or DEFAULT_MAX_RESPONSE_BYTES
  assert(type(maximum) == "number" and maximum >= 1024
      and maximum % 1 == 0,
    "OpenCode Go max_response_bytes must be an integer of at least 1024")
  local timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS
  assert(type(timeout_ms) == "number" and timeout_ms > 0,
    "OpenCode Go timeout_ms must be positive")
  local base_url = opts.base_url:gsub("/+$", "")
  local ambient_api_key = opts.ambient_api_key
    or function() return vim.env.OPENCODE_API_KEY end
  assert(type(ambient_api_key) == "function",
    "OpenCode Go ambient_api_key must be a function")
  local client = {}

  local function request(path, resource, headers)
    return async.run(function()
      local fetched = transport.fetch({ request = {
        url = base_url .. path,
        method = "GET",
        headers = headers,
        timeout_ms = timeout_ms,
        max_response_bytes = maximum,
      } }):await()
      if fetched.ok == false then
        error(util.normalize_error(fetched.error, "provider"), 0)
      end
      local status = tonumber(fetched.status)
      if not status then
        error(util.error("provider",
          "OpenCode Go " .. resource .. " response has no HTTP status"), 0)
      end
      if status < 200 or status >= 300 then
        local err = util.error("provider", response_error(status, resource))
        err.status = status
        error(err, 0)
      end
      local body = fetched.body
      if type(body) ~= "string" then
        error(util.error("provider",
          "OpenCode Go " .. resource .. " response body must be text"), 0)
      end
      if #body > maximum then
        error(util.error("provider",
          "OpenCode Go " .. resource .. " response exceeds "
            .. tostring(maximum) .. " bytes"), 0)
      end
      local ok, decoded = pcall(vim.json.decode, body)
      if not ok or type(decoded) ~= "table" then
        error(util.error("provider",
          "OpenCode Go " .. resource .. " response contains invalid JSON"), 0)
      end
      return { ok = true, value = decoded }
    end, { error_kind = "provider" })
  end

  function client:usage(ctx)
    assert(type(ctx) == "table" and type(ctx.resolve_auth) == "function",
      "OpenCode Go usage requires auth resolution")
    return async.run(function()
      local resolved = ctx.resolve_auth():await()
      if resolved.ok == false then error(resolved.error, 0) end
      local key
      if resolved.configured then
        key = bearer_from(type(resolved.request_opts) == "table"
          and resolved.request_opts.headers or nil)
      else
        local ok, value = pcall(ambient_api_key)
        if not ok then
          error(util.error("provider",
            "Failed to resolve OPENCODE_API_KEY", value), 0)
        end
        if type(value) == "string" and util.trim(value) ~= "" then
          key = util.trim(value)
        end
      end
      if not key then
        error(util.error("provider",
          "Connect OpenCode Go or set OPENCODE_API_KEY to load usage"), 0)
      end
      local fetched = request("/usage", "usage", {
        Accept = "application/json",
        Authorization = "Bearer " .. key,
      }):await()
      if fetched.ok == false then error(fetched.error, 0) end
      local decoded = fetched.value
      local usage = parse_usage(decoded)
      if not usage then
        error(util.error("provider",
          "OpenCode Go returned invalid usage data"), 0)
      end
      return { ok = true, usage = usage }
    end, { error_kind = "provider" })
  end

  function client:models()
    return async.run(function()
      local fetched = request("/models", "model catalog", {
        Accept = "application/json",
      }):await()
      if fetched.ok == false then error(fetched.error, 0) end
      local decoded = fetched.value
      local models = parse_models(decoded)
      if not models then
        error(util.error("provider",
          "OpenCode Go returned an invalid model catalog"), 0)
      end
      return { ok = true, models = models }
    end, { error_kind = "provider" })
  end

  return client
end

M.iso_timestamp = iso_timestamp

return M
