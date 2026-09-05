local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local util = require("neoagent.util")

local M = {}

local DEFAULT_GATEWAY_URL =
  "https://bailian-singapore-cs.alibabacloud.com"
local DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024
local DEFAULT_TIMEOUT_MS = 15 * 1000
local REGION = "ap-southeast-1"
local ACTION = "IntlBroadScopeAspnGateway"
local PRODUCT = "sfm_bailian"
local USAGE_API =
  "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"

local function encode_fields(fields)
  local names = vim.tbl_keys(fields)
  table.sort(names)
  local result = {}
  for _, name in ipairs(names) do
    result[#result + 1] = vim.uri_encode(name, "rfc2396") .. "="
      .. vim.uri_encode(tostring(fields[name]), "rfc2396")
  end
  return table.concat(result, "&")
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function timestamp(value)
  if not finite(value) or value <= 0 then return nil end
  if value > 100000000000 then value = value / 1000 end
  value = math.floor(value)
  return value > 0 and value or nil
end

local function window(value, percentage_name, reset_name)
  local percentage = value[percentage_name]
  local reset = value[reset_name]
  if percentage == nil and reset == nil then return nil end
  if percentage ~= nil and (not finite(percentage)
      or percentage < 0 or percentage > 1) then
    return false
  end
  local resets_at = reset ~= nil and timestamp(reset) or nil
  if reset ~= nil and not resets_at then return false end
  local result = {}
  if percentage ~= nil then result.used = percentage end
  if resets_at then result.resets_at = resets_at end
  return result
end

local function unwrap(value)
  local data = type(value.data) == "table" and value.data or nil
  if not data then return value end
  local data_v2 = type(data.DataV2) == "table" and data.DataV2 or nil
  if data_v2 then
    local inner = type(data_v2.data) == "table" and data_v2.data or nil
    return inner and type(inner.data) == "table" and inner.data
      or inner or data_v2
  end
  return type(data.data) == "table" and data.data or data
end

local function parse_usage(value)
  if type(value) ~= "table" or util.is_list(value) then return nil end
  value = unwrap(value)
  if type(value) ~= "table" or util.is_list(value) then return nil end
  local five_hour = window(value,
    "per5HourPercentage", "per5HourResetTime")
  local seven_day = window(value,
    "per1WeekPercentage", "per1WeekResetTime")
  if five_hour == false or seven_day == false then return nil end
  local result = {}
  if five_hour then result.five_hour = five_hour end
  if seven_day then result.seven_day = seven_day end
  return result
end

local function authorization(resolved)
  if type(resolved) ~= "table" or resolved.ok == false then
    error(type(resolved) == "table" and resolved.error
      or util.error("auth", "Alibaba Cloud authorization failed"), 0)
  end
  if not resolved.configured then
    error(util.error("auth",
      "Log in to the Alibaba Cloud dashboard through the Provider Shell "
        .. "to load quotas"), 0)
  end
  local headers = type(resolved.request_opts) == "table"
    and resolved.request_opts.headers or nil
  for name, value in pairs(headers or {}) do
    if type(name) == "string" and name:lower() == "authorization"
        and type(value) == "string"
        and value:match("^[Bb]earer%s+%S") then
      return value
    end
  end
  error(util.error("auth",
    "Alibaba Cloud dashboard authorization returned no bearer token"), 0)
end

function M.new(opts)
  opts = opts or {}
  local transport = opts.transport or curl
  assert(type(transport) == "table" and type(transport.fetch) == "function",
    "Alibaba Token Plan transport requires fetch")
  local gateway_url = (opts.gateway_url or DEFAULT_GATEWAY_URL):gsub("/+$", "")
  assert(gateway_url:match("^https?://[^/]+"),
    "Alibaba Token Plan gateway_url must be an HTTP origin")
  local maximum = opts.max_response_bytes or DEFAULT_MAX_RESPONSE_BYTES
  assert(type(maximum) == "number" and maximum >= 1024
      and maximum % 1 == 0,
    "Alibaba Token Plan max_response_bytes must be an integer of at least 1024")
  local timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS
  assert(type(timeout_ms) == "number" and timeout_ms > 0
      and timeout_ms < math.huge,
    "Alibaba Token Plan timeout_ms must be positive and finite")
  local client = {}

  function client:usage(ctx)
    assert(type(ctx) == "table" and type(ctx.resolve_auth) == "function",
      "Alibaba Token Plan usage requires auth resolution")
    return async.run(function()
      local bearer = authorization(ctx.resolve_auth("dashboard"):await())
      local params = util.json_encode({
        Api = USAGE_API,
        Data = {
          cornerstoneParam = {
            console = "ONE_CONSOLE",
            consoleSite = "BAILIAN_ALIYUN",
            productCode = "p_efm",
            protocol = "V2",
            switchUserType = 3,
          },
        },
        V = "1.0",
      })
      local fetched = transport.fetch({ request = {
        url = gateway_url .. "/cli/api.json?action=" .. ACTION
          .. "&product=" .. PRODUCT .. "&api="
          .. vim.uri_encode(USAGE_API, "rfc2396"),
        method = "POST",
        headers = {
          Accept = "*/*",
          Authorization = bearer,
          ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        body = encode_fields({ params = params, region = REGION }),
        timeout_ms = timeout_ms,
        max_response_bytes = maximum,
      } }):await()
      if fetched.ok == false then
        error(util.normalize_error(fetched.error, "provider"), 0)
      end
      local status = tonumber(fetched.status)
      if not status then
        error(util.error("provider",
          "Alibaba Cloud quota response has no HTTP status"), 0)
      end
      if status < 200 or status >= 300 then
        local err = util.error("provider",
          "Alibaba Cloud quota request failed (HTTP "
            .. tostring(status) .. ")")
        err.status = status
        error(err, 0)
      end
      local body = fetched.body
      if type(body) ~= "string" then
        error(util.error("provider",
          "Alibaba Cloud quota response body must be text"), 0)
      end
      if #body > maximum then
        error(util.error("provider",
          "Alibaba Cloud quota response exceeds "
            .. tostring(maximum) .. " bytes"), 0)
      end
      local decoded, value = pcall(vim.json.decode, body)
      if not decoded or type(value) ~= "table" then
        error(util.error("provider",
          "Alibaba Cloud quota response contains invalid JSON"), 0)
      end
      local envelope = type(value.data) == "table" and value.data or nil
      if envelope and envelope.success == false
          and envelope.errorCode ~= nil then
        local code = tostring(envelope.errorCode)
        if code:find("NotLogined", 1, true) then
          error(util.error("auth",
            "Alibaba Cloud dashboard authorization expired"), 0)
        end
        error(util.error("provider",
          "Alibaba Cloud console gateway rejected the quota request"), 0)
      end
      local usage = parse_usage(value)
      if not usage then
        error(util.error("provider",
          "Alibaba Cloud returned invalid usage data"), 0)
      end
      return { ok = true, usage = usage }
    end, { error_kind = "provider" })
  end

  return client
end

return M
