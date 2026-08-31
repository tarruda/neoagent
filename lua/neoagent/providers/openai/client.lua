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

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function count(value)
  return finite(value) and value >= 0 and value % 1 == 0
end

local function parse_models(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.data) ~= "table" or not util.is_list(value.data)
      or #value.data > 5000 then
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

local function page(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.has_more) ~= "boolean"
      or type(value.data) ~= "table" or not util.is_list(value.data)
      or #value.data > 31 then
    return nil
  end
  return value
end

local function parse_usage(value)
  value = page(value)
  if not value or value.has_more then return nil, value and "incomplete" or "invalid" end
  local result = {
    requests = 0,
    input_tokens = 0,
    cached_input_tokens = 0,
    output_tokens = 0,
  }
  for _, bucket in ipairs(value.data) do
    if type(bucket) ~= "table" or util.is_list(bucket)
        or type(bucket.results) ~= "table" or not util.is_list(bucket.results)
        or #bucket.results > 1000 then
      return nil, "invalid"
    end
    for _, entry in ipairs(bucket.results) do
      local requests = type(entry) == "table" and entry.num_model_requests or nil
      local input = type(entry) == "table" and entry.input_tokens or nil
      local cached = type(entry) == "table"
        and (entry.input_cached_tokens or 0) or nil
      local output = type(entry) == "table" and entry.output_tokens or nil
      if not count(requests) or not count(input)
          or not count(cached) or not count(output) then
        return nil, "invalid"
      end
      result.requests = result.requests + requests
      result.input_tokens = result.input_tokens + input
      result.cached_input_tokens = result.cached_input_tokens + cached
      result.output_tokens = result.output_tokens + output
    end
  end
  return result
end

local function parse_costs(value)
  value = page(value)
  if not value or value.has_more then return nil, value and "incomplete" or "invalid" end
  local totals = {}
  for _, bucket in ipairs(value.data) do
    if type(bucket) ~= "table" or util.is_list(bucket)
        or type(bucket.results) ~= "table" or not util.is_list(bucket.results)
        or #bucket.results > 1000 then
      return nil, "invalid"
    end
    for _, entry in ipairs(bucket.results) do
      local amount = type(entry) == "table" and entry.amount or nil
      local currency = type(amount) == "table" and amount.currency or nil
      local number = type(amount) == "table" and amount.value or nil
      if type(currency) ~= "string" or currency == "" or #currency > 16
          or not currency:match("^[a-z]+$")
          or not finite(number) or number < 0 then
        return nil, "invalid"
      end
      totals[currency] = (totals[currency] or 0) + number
    end
  end
  local result = {}
  for currency, value_number in pairs(totals) do
    result[#result + 1] = { currency = currency, value = value_number }
  end
  table.sort(result, function(left, right) return left.currency < right.currency end)
  return result
end

local function status_message(status, resource)
  if status == 401 then
    return "OpenAI " .. resource .. " requires a valid API key"
  end
  if status == 403 then
    return "OpenAI API key does not permit " .. resource
  end
  if status == 429 then
    return "OpenAI " .. resource .. " request was rate limited"
  end
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.base_url) == "string" and opts.base_url ~= "",
    "OpenAI base_url is required")
  local ambient_api_key = opts.ambient_api_key or function()
    return vim.env.OPENAI_API_KEY
  end
  local now = opts.now or os.time
  assert(type(now) == "function", "OpenAI now must be a function")
  local request = http.new({
    name = "OpenAI",
    base_url = opts.base_url,
    transport = opts.transport,
    timeout_ms = opts.timeout_ms,
    max_response_bytes = opts.max_response_bytes,
    status_message = status_message,
  })
  local client = {}

  function client:models(ctx)
    return async.run(function()
      local resolved = auth_headers.resolve(ctx, {
        name = "OpenAI",
        environment = "OPENAI_API_KEY",
        ambient_api_key = ambient_api_key,
        missing_message = "Connect OpenAI or set OPENAI_API_KEY to load models",
      }):await()
      if resolved.ok == false then error(resolved.error, 0) end
      resolved.headers.Accept = "application/json"
      local fetched = request:get("/models", "model catalog",
        resolved.headers):await()
      if fetched.ok == false then error(fetched.error, 0) end
      local models = parse_models(fetched.value)
      if not models then
        error(util.error("provider",
          "OpenAI returned an invalid model catalog"), 0)
      end
      return { ok = true, models = models }
    end, { error_kind = "provider" })
  end

  function client:organization(ctx)
    return async.run(function()
      local resolved = auth_headers.resolve(ctx, {
        name = "OpenAI organization reporting",
        environment = "OPENAI_API_KEY",
        ambient_api_key = ambient_api_key,
        missing_message = "Connect OpenAI or set OPENAI_API_KEY to query organization usage and costs",
      }):await()
      if resolved.ok == false then error(resolved.error, 0) end
      resolved.headers.Accept = "application/json"
      local end_time = math.floor(now())
      local start_time = end_time - 30 * 86400
      local query = "?start_time=" .. tostring(start_time)
        .. "&end_time=" .. tostring(end_time)
        .. "&bucket_width=1d&limit=31"
      local usage_response = request:get(
        "/organization/usage/completions" .. query,
        "organization usage", resolved.headers):await()
      if usage_response.ok == false then error(usage_response.error, 0) end
      local usage, usage_error = parse_usage(usage_response.value)
      if not usage then
        error(util.error("provider", "OpenAI returned " .. usage_error
          .. " usage data"), 0)
      end
      local cost_response = request:get(
        "/organization/costs" .. query,
        "organization costs", resolved.headers):await()
      if cost_response.ok == false then error(cost_response.error, 0) end
      local costs, costs_error = parse_costs(cost_response.value)
      if not costs then
        error(util.error("provider",
          "OpenAI returned " .. costs_error .. " cost data"), 0)
      end
      return {
        ok = true,
        start_time = start_time,
        end_time = end_time,
        usage = usage,
        costs = costs,
      }
    end, { error_kind = "provider" })
  end

  return client
end

return M
