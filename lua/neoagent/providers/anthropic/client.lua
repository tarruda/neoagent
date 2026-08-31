local async = require("neoagent.async")
local auth_headers = require("neoagent.providers.auth_headers")
local http = require("neoagent.providers.http")
local util = require("neoagent.util")

local M = {}
local MODEL_PAGE_LIMIT = 1000
local MAX_MODEL_PAGES = 32

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

local function absent(value)
  return value == nil or value == vim.NIL
end

local function safe_name(value)
  return type(value) == "string" and value ~= "" and #value <= 256
    and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

local function capability(value)
  if absent(value) then return nil, true end
  if type(value) ~= "table" or util.is_list(value)
      or type(value.supported) ~= "boolean" then
    return nil, false
  end
  return value.supported, true
end

local function model_entry(entry)
  if type(entry) ~= "table" or util.is_list(entry)
      or not safe_id(entry.id)
      or entry.type ~= nil and entry.type ~= "model" then
    return nil
  end
  local result = { id = entry.id }
  if entry.display_name ~= nil then
    if not safe_name(entry.display_name) then return nil end
    result.name = entry.display_name
  end
  for source, target in pairs({
    max_input_tokens = "context_window",
    max_tokens = "max_output_tokens",
  }) do
    local value = entry[source]
    if not absent(value) then
      if not count(value) then return nil end
      if value > 0 then result[target] = value end
    end
  end
  local capabilities = entry.capabilities
  if absent(capabilities) then return result end
  if type(capabilities) ~= "table" or util.is_list(capabilities) then return nil end

  local image, image_ok = capability(capabilities.image_input)
  if not image_ok then return nil end
  if image ~= nil then
    result.input = image and { "text", "image" } or { "text" }
  end

  local thinking = capabilities.thinking
  if not absent(thinking) then
    local thinking_supported, thinking_ok = capability(thinking)
    if not thinking_ok then return nil end
    if not thinking_supported then
      result.thinking_type = false
    else
      local adaptive, enabled
      if not absent(thinking.types) then
        if type(thinking.types) ~= "table" or util.is_list(thinking.types) then
          return nil
        end
        local adaptive_ok, enabled_ok
        adaptive, adaptive_ok = capability(thinking.types.adaptive)
        enabled, enabled_ok = capability(thinking.types.enabled)
        if not adaptive_ok or not enabled_ok then return nil end
      end
      result.thinking_type = adaptive and "adaptive"
        or enabled and "enabled" or nil
    end
  end

  local effort = capabilities.effort
  if not absent(effort) then
    local effort_supported, effort_ok = capability(effort)
    if not effort_ok then return nil end
    if effort_supported then
      local levels = {}
      for _, level in ipairs({ "low", "medium", "high", "xhigh", "max" }) do
        local supported, supported_ok = capability(effort[level])
        if not supported_ok then return nil end
        if supported then levels[#levels + 1] = level end
      end
      if #levels > 0 then result.reasoning_levels = levels end
    end
  end
  return result
end

local function parse_model_page(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.has_more) ~= "boolean"
      or type(value.data) ~= "table" or not util.is_list(value.data)
      or #value.data > MODEL_PAGE_LIMIT
      or not absent(value.first_id) and not safe_id(value.first_id)
      or not absent(value.last_id) and not safe_id(value.last_id) then
    return nil, nil, "invalid"
  end
  if value.has_more and (#value.data == 0 or not safe_id(value.last_id)) then
    return nil, nil, "incomplete"
  end
  local result = {}
  for _, entry in ipairs(value.data) do
    local model = model_entry(entry)
    if not model then return nil, nil, "invalid" end
    result[#result + 1] = model
  end
  return result, value.has_more and value.last_id or nil
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
  local total = {
    uncached_input_tokens = 0,
    cache_read_input_tokens = 0,
    cache_creation_input_tokens = 0,
    output_tokens = 0,
  }
  for _, bucket in ipairs(value.data) do
    if type(bucket) ~= "table" or util.is_list(bucket)
        or type(bucket.results) ~= "table" or not util.is_list(bucket.results)
        or #bucket.results > 1000 then
      return nil, "invalid"
    end
    for _, entry in ipairs(bucket.results) do
      local creation = type(entry) == "table" and entry.cache_creation or nil
      local uncached = type(entry) == "table" and entry.uncached_input_tokens or nil
      local reads = type(entry) == "table" and entry.cache_read_input_tokens or nil
      local five = type(creation) == "table"
        and creation.ephemeral_5m_input_tokens or nil
      local hour = type(creation) == "table"
        and creation.ephemeral_1h_input_tokens or nil
      local output = type(entry) == "table" and entry.output_tokens or nil
      if not count(uncached) or not count(reads) or not count(five)
          or not count(hour) or not count(output) then
        return nil, "invalid"
      end
      total.uncached_input_tokens = total.uncached_input_tokens + uncached
      total.cache_read_input_tokens = total.cache_read_input_tokens + reads
      local created = five + hour
      total.cache_creation_input_tokens = total.cache_creation_input_tokens + created
      total.output_tokens = total.output_tokens + output
    end
  end
  return total
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
      local currency = type(entry) == "table" and entry.currency or nil
      local number = type(amount) == "string" and tonumber(amount) or nil
      if type(currency) ~= "string" or currency == "" or #currency > 16
          or not currency:match("^[A-Z]+$")
          or not finite(number) or number < 0 then
        return nil, "invalid"
      end
      totals[currency] = (totals[currency] or 0) + number / 100
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
    return "Anthropic " .. resource .. " requires a valid API key"
  end
  if status == 403 then
    return "Anthropic API key does not permit " .. resource
  end
  if status == 429 then
    return "Anthropic " .. resource .. " request was rate limited"
  end
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.base_url) == "string" and opts.base_url ~= "",
    "Anthropic base_url is required")
  local name = opts.name or "Anthropic"
  local environment = opts.environment or "ANTHROPIC_API_KEY"
  local ambient_api_key = opts.ambient_api_key or function()
    return vim.env[environment]
  end
  local ambient_headers = opts.ambient_headers or function(key)
    return { ["x-api-key"] = key }
  end
  local now = opts.now or os.time
  assert(type(now) == "function", "Anthropic now must be a function")
  local request = http.new({
    name = "Anthropic",
    base_url = opts.base_url,
    transport = opts.transport,
    timeout_ms = opts.timeout_ms,
    max_response_bytes = opts.max_response_bytes,
    status_message = status_message,
  })
  local client = {}

  local function versioned(headers)
    headers.Accept = "application/json"
    headers["anthropic-version"] = "2023-06-01"
    return headers
  end

  function client:models(ctx)
    return async.run(function()
      local resolved = auth_headers.resolve(ctx, {
        name = name,
        environment = environment,
        ambient_api_key = ambient_api_key,
        ambient_headers = ambient_headers,
        missing_message = "Connect " .. name .. " or set " .. environment
          .. " to load models",
      }):await()
      if resolved.ok == false then error(resolved.error, 0) end
      local headers = versioned(resolved.headers)
      local models, seen, cursors = {}, {}, {}
      local cursor
      for _ = 1, MAX_MODEL_PAGES do
        local path = "/models?limit=" .. tostring(MODEL_PAGE_LIMIT)
        if cursor then path = path .. "&after_id=" .. vim.uri_encode(cursor) end
        local fetched = request:get(path, "model catalog", headers):await()
        if fetched.ok == false then error(fetched.error, 0) end
        local entries, next_cursor, reason = parse_model_page(fetched.value)
        if not entries then
          error(util.error("provider",
            "Anthropic returned an " .. reason .. " model catalog"), 0)
        end
        for _, model in ipairs(entries) do
          if seen[model.id] then
            error(util.error("provider",
              "Anthropic returned an invalid model catalog"), 0)
          end
          seen[model.id] = true
          models[#models + 1] = model
        end
        if not next_cursor then
          table.sort(models, function(left, right) return left.id < right.id end)
          return { ok = true, models = models }
        end
        if cursors[next_cursor] then
          error(util.error("provider",
            "Anthropic returned an incomplete model catalog"), 0)
        end
        cursors[next_cursor] = true
        cursor = next_cursor
      end
      error(util.error("provider",
        "Anthropic returned an incomplete model catalog"), 0)
    end, { error_kind = "provider" })
  end

  function client:organization(ctx)
    return async.run(function()
      local resolved = auth_headers.resolve(ctx, {
        name = "Anthropic organization reporting",
        environment = environment,
        ambient_api_key = ambient_api_key,
        ambient_headers = ambient_headers,
        missing_message = "Connect " .. name .. " or set " .. environment
          .. " to query organization usage and costs",
      }):await()
      if resolved.ok == false then error(resolved.error, 0) end
      local end_seconds = math.floor(now())
      local start_seconds = end_seconds - 30 * 86400
      local starting_at = os.date("!%Y-%m-%dT%H:%M:%SZ", start_seconds)
      local ending_at = os.date("!%Y-%m-%dT%H:%M:%SZ", end_seconds)
      local query = "?starting_at=" .. vim.uri_encode(starting_at)
        .. "&ending_at=" .. vim.uri_encode(ending_at)
        .. "&bucket_width=1d&limit=31"
      local headers = versioned(resolved.headers)
      local usage_response = request:get(
        "/organizations/usage_report/messages" .. query,
        "organization usage", headers):await()
      if usage_response.ok == false then error(usage_response.error, 0) end
      local usage, usage_error = parse_usage(usage_response.value)
      if not usage then
        error(util.error("provider", "Anthropic returned " .. usage_error
          .. " usage data"), 0)
      end
      local cost_response = request:get(
        "/organizations/cost_report" .. query,
        "organization costs", headers):await()
      if cost_response.ok == false then error(cost_response.error, 0) end
      local costs, costs_error = parse_costs(cost_response.value)
      if not costs then
        error(util.error("provider",
          "Anthropic returned " .. costs_error .. " cost data"), 0)
      end
      return {
        ok = true,
        start_time = start_seconds,
        end_time = end_seconds,
        usage = usage,
        costs = costs,
      }
    end, { error_kind = "provider" })
  end

  return client
end

return M
