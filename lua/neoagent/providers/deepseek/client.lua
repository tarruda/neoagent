local async = require("neoagent.async")
local auth_headers = require("neoagent.providers.auth_headers")
local http = require("neoagent.providers.http")
local util = require("neoagent.util")

local M = {}

local function safe_id(value)
  return type(value) == "string" and value ~= "" and #value <= 512
    and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

local function safe_amount(value)
  return type(value) == "string" and #value <= 64
    and value:match("^%d+%.?%d*$") ~= nil
end

local function parse_models(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.data) ~= "table" or not util.is_list(value.data)
      or #value.data > 100 then
    return nil
  end
  local result, seen = {}, {}
  for _, entry in ipairs(value.data) do
    local id = type(entry) == "table" and entry.id or nil
    if not safe_id(id) or seen[id] then return nil end
    seen[id] = true
    result[#result + 1] = id
  end
  table.sort(result)
  return result
end

local function parse_balance(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.is_available) ~= "boolean"
      or type(value.balance_infos) ~= "table"
      or not util.is_list(value.balance_infos)
      or #value.balance_infos == 0 or #value.balance_infos > 8 then
    return nil
  end
  local currencies, seen = {}, {}
  for _, entry in ipairs(value.balance_infos) do
    if type(entry) ~= "table" or util.is_list(entry)
        or (entry.currency ~= "CNY" and entry.currency ~= "USD")
        or seen[entry.currency]
        or not safe_amount(entry.total_balance)
        or not safe_amount(entry.granted_balance)
        or not safe_amount(entry.topped_up_balance) then
      return nil
    end
    seen[entry.currency] = true
    currencies[#currencies + 1] = {
      currency = entry.currency,
      total = entry.total_balance,
      granted = entry.granted_balance,
      topped_up = entry.topped_up_balance,
    }
  end
  table.sort(currencies, function(left, right)
    return left.currency < right.currency
  end)
  return { is_available = value.is_available, currencies = currencies }
end

local function status_message(status, resource)
  if status == 401 then
    return "DeepSeek " .. resource .. " requires a valid API key"
  end
  if status == 402 then return "DeepSeek account balance is exhausted" end
  if status == 429 then
    return "DeepSeek " .. resource .. " request was rate limited"
  end
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.base_url) == "string" and opts.base_url ~= "",
    "DeepSeek base_url is required")
  local ambient_api_key = opts.ambient_api_key or function()
    return vim.env.DEEPSEEK_API_KEY
  end
  local request = http.new({
    name = "DeepSeek",
    base_url = opts.base_url,
    transport = opts.transport,
    timeout_ms = opts.timeout_ms,
    max_response_bytes = opts.max_response_bytes,
    status_message = status_message,
  })
  local client = {}

  local function headers(ctx)
    return auth_headers.resolve(ctx, {
      name = "DeepSeek",
      environment = "DEEPSEEK_API_KEY",
      ambient_api_key = ambient_api_key,
      missing_message = "Connect DeepSeek or set DEEPSEEK_API_KEY to load account data",
    })
  end

  function client:models(ctx)
    return async.run(function()
      local resolved = headers(ctx):await()
      if resolved.ok == false then error(resolved.error, 0) end
      resolved.headers.Accept = "application/json"
      local fetched = request:get("/models", "model catalog",
        resolved.headers):await()
      if fetched.ok == false then error(fetched.error, 0) end
      local models = parse_models(fetched.value)
      if not models then
        error(util.error("provider",
          "DeepSeek returned an invalid model catalog"), 0)
      end
      return { ok = true, models = models }
    end, { error_kind = "provider" })
  end

  function client:balance(ctx)
    return async.run(function()
      local resolved = headers(ctx):await()
      if resolved.ok == false then error(resolved.error, 0) end
      resolved.headers.Accept = "application/json"
      local fetched = request:get("/user/balance", "balance",
        resolved.headers):await()
      if fetched.ok == false then error(fetched.error, 0) end
      local balance = parse_balance(fetched.value)
      if not balance then
        error(util.error("provider",
          "DeepSeek returned invalid balance data"), 0)
      end
      return { ok = true, balance = balance }
    end, { error_kind = "provider" })
  end

  return client
end

return M
