local async = require("neoagent.async")
local auth_headers = require("neoagent.providers.auth_headers")
local http = require("neoagent.providers.http")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.ZaiClientOptions
---@field management_url string
---@field ambient_api_key? fun(): string?
---@field transport? Neoagent.ByteBackend
---@field timeout_ms? number
---@field max_response_bytes? integer

---@class Neoagent.ZaiBalance
---@field total number
---@field available number
---@field currency? string

---@class Neoagent.ZaiQuotaLimit
---@field type "TIME_LIMIT"|"TOKENS_LIMIT"|"CREDIT_LIMIT"
---@field remaining number
---@field window string
---@field resets_at? integer
---@field current? number
---@field maximum? number

---@class Neoagent.ZaiOrderedLimit
---@field order number
---@field limit Neoagent.ZaiQuotaLimit

---@class Neoagent.ZaiQuota
---@field plan? string
---@field limits Neoagent.ZaiQuotaLimit[]

---@class Neoagent.ZaiModelsSuccess
---@field ok true
---@field models string[]

---@class Neoagent.ZaiBalanceSuccess
---@field ok true
---@field balance Neoagent.ZaiBalance

---@class Neoagent.ZaiQuotaSuccess
---@field ok true
---@field quota Neoagent.ZaiQuota

---@param value unknown
---@return TypeGuard<number>
local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

---@param value unknown
---@param maximum integer
---@return TypeGuard<string>
local function safe_text(value, maximum)
  return type(value) == "string" and value ~= "" and #value <= maximum
    and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

---@param value Neoagent.JsonValue
---@return string[]?
local function parse_models(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.data) ~= "table" or not util.is_list(value.data)
      or #value.data > 100 then
    return nil
  end
  local result, seen = {}, {}
  for _, entry in ipairs(value.data) do
    local id = type(entry) == "table" and entry.id or nil
    if not safe_text(id, 512) or seen[id] then return nil end
    seen[id] = true
    result[#result + 1] = id
  end
  table.sort(result)
  return result
end

---@param value unknown
---@return integer?
local function reset_time(value)
  if not finite(value) or value <= 0 then return nil end
  if value > 100000000000 then value = value / 1000 end
  value = math.floor(value)
  if value <= 0 then return nil end
  return value
end

---@param value unknown
---@return number?
local function amount(value)
  if type(value) == "string" and value:match("^%d+%.?%d*$") then
    value = tonumber(value)
  end
  if not finite(value) or value < 0 then return nil end
  return value
end

---@param value Neoagent.JsonValue
---@return Neoagent.ZaiBalance?
local function parse_balance(value)
  if type(value) ~= "table" or util.is_list(value) then return nil end
  local data = value.data
  if type(data) ~= "table" or util.is_list(data) then return nil end
  local available = amount(data.available_balance)
  local total = amount(data.total_balance) or available
  local currency = data.currency
  if available == nil or total == nil
      or currency ~= nil and not safe_text(currency, 16) then
    return nil
  end
  return {
    total = total,
    available = available,
    currency = currency,
  }
end

---@param source Neoagent.JsonObject|Neoagent.JsonArray
---@param kind string
---@return string?, number?
---@return_overload string, number
---@return_overload nil
local function window(source, kind)
  local unit, count = source.unit, source.number
  if unit == nil and count == nil then
    return kind == "TIME_LIMIT" and "Monthly" or "5-hour", 0
  end
  if not finite(unit) or unit % 1 ~= 0 or not finite(count)
      or count <= 0 or count % 1 ~= 0 or count > 10000 then
    return nil
  end
  if unit == 3 then
    return tostring(count) .. "-hour", count * 60
  end
  if unit == 4 then
    return count == 1 and "Daily" or (tostring(count) .. "-day"),
      count * 24 * 60
  end
  if unit == 5 then
    return count == 1 and "Monthly" or (tostring(count) .. "-month"),
      count * 30 * 24 * 60
  end
  if unit == 6 then return "Weekly", 7 * 24 * 60 end
  return "Quota", math.huge
end

---@param source Neoagent.JsonValue
---@return Neoagent.ZaiOrderedLimit|false|nil
local function parse_limit(source)
  if type(source) ~= "table" or util.is_list(source) then return false end
  local kind = source.type
  if kind ~= "TOKENS_LIMIT" and kind ~= "CREDIT_LIMIT"
      and kind ~= "TIME_LIMIT" then
    return nil
  end
  local percentage = source.percentage
  if percentage ~= nil and (not finite(percentage)
      or percentage < 0 or percentage > 100) then
    return false
  end
  local current = source.currentValue ~= nil and amount(source.currentValue)
    or nil
  local maximum = source.usage ~= nil and amount(source.usage) or nil
  local remaining_count = source.remaining ~= nil and amount(source.remaining)
    or nil
  if source.currentValue ~= nil and current == nil
      or source.usage ~= nil and maximum == nil
      or source.remaining ~= nil and remaining_count == nil then
    return false
  end
  if current ~= nil or maximum ~= nil or remaining_count ~= nil then
    if maximum == nil or maximum <= 0
        or current == nil and remaining_count == nil
        or current ~= nil and current > maximum
        or remaining_count ~= nil and remaining_count > maximum then
      return false
    end
    if current == nil then
      -- A validated count group includes current or remaining.
      ---@cast remaining_count number
      current = math.max(0, maximum - remaining_count)
    end
  end
  if percentage == nil then
    if maximum == nil then return false end
    if remaining_count ~= nil then
      percentage = 100 * (1 - remaining_count / maximum)
    else
      -- A validated maximum has a supplied or derived current count.
      ---@cast current number
      percentage = 100 * current / maximum
    end
  end
  local window_name, order = window(source, kind)
  if not window_name then return false end
  ---@type Neoagent.ZaiQuotaLimit
  local entry = {
    type = kind,
    remaining = (100 - percentage) / 100,
    window = window_name,
  }
  if source.nextResetTime ~= nil then
    entry.resets_at = reset_time(source.nextResetTime)
    if not entry.resets_at then return false end
  end
  if current ~= nil then
    entry.current = current
    entry.maximum = maximum
  end
  return { order = order, limit = entry }
end

---@param value Neoagent.JsonValue
---@return Neoagent.ZaiQuota?
local function parse_quota(value)
  local data = type(value) == "table" and not util.is_list(value)
    and value.data or nil
  if type(data) ~= "table" or util.is_list(data)
      or type(data.limits) ~= "table" or not util.is_list(data.limits)
      or #data.limits == 0 or #data.limits > 32 then
    return nil
  end
  local plan_name, alternate_name, level = data.planName, data.plan_name, data.level
  local plan = plan_name or alternate_name or level
  if plan ~= nil and not safe_text(plan, 128) then return nil end
  ---@type Neoagent.ZaiOrderedLimit[]
  local ordered = {}
  for _, source in ipairs(data.limits) do
    local entry = parse_limit(source)
    if entry == false then return nil end
    if entry then ordered[#ordered + 1] = entry end
  end
  if #ordered == 0 then return nil end
  table.sort(ordered, function(left, right)
    local left_time = left.limit.type == "TIME_LIMIT"
    local right_time = right.limit.type == "TIME_LIMIT"
    if left_time ~= right_time then return not left_time end
    return left.order < right.order
  end)
  local limits = {}
  for _, entry in ipairs(ordered) do limits[#limits + 1] = entry.limit end
  return { plan = plan, limits = limits }
end

---@param status number
---@param resource string
---@return string?
local function status_message(status, resource)
  if status == 401 then
    return "Z.AI " .. resource .. " requires a valid API key"
  end
  if status == 403 then
    return "Z.AI API key does not permit " .. resource
  end
  if status == 429 then
    return "Z.AI " .. resource .. " request was rate limited"
  end
end

---@param headers table<string, unknown>
---@param bearer boolean
---@return table<string, unknown>?, Neoagent.Error?
local function authorization(headers, bearer)
  local key
  local result = {}
  for name, value in pairs(headers) do
    local lower = type(name) == "string" and name:lower() or ""
    if lower == "authorization" and type(value) == "string" then
      key = value:match("^[Bb]earer%s+(.+)$") or value
    elseif lower == "x-api-key" and type(value) == "string" then
      key = key or value
    else
      result[name] = value
    end
  end
  key = type(key) == "string" and util.trim(key) or ""
  if key == "" then
    return nil, util.error("provider",
      "Z.AI credentials returned no API key header")
  end
  result.Authorization = bearer and ("Bearer " .. key) or key
  result.Accept = "application/json"
  result["Accept-Language"] = "en-US,en"
  result["Content-Type"] = "application/json"
  return result
end

---@param opts Neoagent.ZaiClientOptions
---@return Neoagent.ZaiClient
function M.new(opts)
  opts = opts or {}
  assert(type(opts.management_url) == "string"
      and opts.management_url ~= "",
    "Z.AI management_url is required")
  local ambient_api_key = opts.ambient_api_key or function()
    return vim.env.ZAI_API_KEY
  end
  local request = http.new({
    name = "Z.AI",
    base_url = opts.management_url,
    transport = opts.transport,
    timeout_ms = opts.timeout_ms,
    max_response_bytes = opts.max_response_bytes,
    status_message = status_message,
  })
  ---@class Neoagent.ZaiClient
  local client = {}

  ---@param ctx Neoagent.ProviderAuthContext
  ---@return Neoagent.Run<Neoagent.ZaiModelsSuccess|Neoagent.AsyncFailure, nil>
  function client:models(ctx)
    return async.run(
    ---@return Neoagent.ZaiModelsSuccess
    function()
      local resolved = auth_headers.resolve(ctx, {
        name = "Z.AI",
        environment = "ZAI_API_KEY",
        ambient_api_key = ambient_api_key,
        missing_message = "Connect Z.AI or set ZAI_API_KEY to load models",
      }):await()
      if resolved.ok == false then error(resolved.error, 0) end
      local headers, header_error = authorization(resolved.headers, true)
      if not headers then error(header_error, 0) end
      local fetched = request:get("/models", "model catalog", headers):await()
      if fetched.ok == false then error(fetched.error, 0) end
      local models = parse_models(fetched.value)
      if not models then
        error(util.error("provider",
          "Z.AI returned an invalid model catalog"), 0)
      end
      return { ok = true, models = models }
    end, { error_kind = "provider" })
  end

  ---@param ctx Neoagent.ProviderAuthContext
  ---@return Neoagent.Run<Neoagent.ZaiBalanceSuccess|Neoagent.AsyncFailure, nil>
  function client:balance(ctx)
    return async.run(
    ---@return Neoagent.ZaiBalanceSuccess
    function()
      local resolved = auth_headers.resolve(ctx, {
        name = "Z.AI",
        environment = "ZAI_API_KEY",
        ambient_api_key = ambient_api_key,
        missing_message = "Connect Z.AI or set ZAI_API_KEY to query API balance",
      }):await()
      if resolved.ok == false then error(resolved.error, 0) end
      local headers, header_error = authorization(resolved.headers, true)
      if not headers then error(header_error, 0) end
      local fetched = request:get("/api/paas/v4/balance",
        "balance", headers):await()
      if fetched.ok == false then error(fetched.error, 0) end
      local balance = parse_balance(fetched.value)
      if not balance then
        error(util.error("provider", "Z.AI returned invalid balance data"), 0)
      end
      return { ok = true, balance = balance }
    end, { error_kind = "provider" })
  end

  ---@param ctx Neoagent.ProviderAuthContext
  ---@return Neoagent.Run<Neoagent.ZaiQuotaSuccess|Neoagent.AsyncFailure, nil>
  function client:quota(ctx)
    return async.run(
    ---@return Neoagent.ZaiQuotaSuccess
    function()
      local resolved = auth_headers.resolve(ctx, {
        name = "Z.AI Plan",
        environment = "ZAI_API_KEY",
        ambient_api_key = ambient_api_key,
        missing_message = "Connect Z.AI or set ZAI_API_KEY to query plan quotas",
      }):await()
      if resolved.ok == false then error(resolved.error, 0) end
      local headers, header_error = authorization(resolved.headers, false)
      if not headers then error(header_error, 0) end
      local fetched = request:get("/api/monitor/usage/quota/limit",
        "plan quota", headers):await()
      if fetched.ok == false then error(fetched.error, 0) end
      local quota = parse_quota(fetched.value)
      if not quota then
        error(util.error("provider", "Z.AI returned invalid quota data"), 0)
      end
      return { ok = true, quota = quota }
    end, { error_kind = "provider" })
  end

  return client
end

return M
