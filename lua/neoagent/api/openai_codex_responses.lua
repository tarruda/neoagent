local async = require("neoagent.async")
local responses = require("neoagent.api.openai_responses")
local util = require("neoagent.util")

local M = {}

local REQUEST_MAX_RETRIES = 4
local STREAM_MAX_RETRIES = 5
local INITIAL_RETRY_DELAY_MS = 200
local MAX_RETRY_DELAY_MS = 60 * 1000

local function close_timer(timer)
  if timer and not timer:is_closing() then timer:close() end
end

local function delay(milliseconds)
  return async.await(function(done)
    local timer = vim.uv.new_timer()
    timer:start(math.max(1, milliseconds), 0, function()
      timer:stop()
      close_timer(timer)
      done.resolve(true)
    end)
    return function()
      timer:stop()
      close_timer(timer)
    end
  end)
end

local function window_label(minutes)
  return ({ [300] = "5h", [10080] = "weekly" })[minutes]
    or tostring(minutes) .. "m"
end

local function normalized_headers(headers)
  local result = {}
  for name, value in pairs(headers or {}) do result[name:lower()] = value end
  return result
end

local function finite_number(value)
  value = tonumber(value)
  if value == nil or value ~= value
      or value == math.huge or value == -math.huge then
    return nil
  end
  return value
end

local function safe_header_text(value, maximum)
  if type(value) ~= "string" then return nil end
  value = util.trim(value)
  if value == "" or #value > maximum
      or not util.is_valid_utf8(value)
      or value:find("[%z\1-\31\127]") then
    return nil
  end
  return value
end

local function header_boolean(value)
  if type(value) ~= "string" then return nil end
  value = value:lower()
  if value == "true" or value == "1" then return true end
  if value == "false" or value == "0" then return false end
  return nil
end

local function rate_limit_window(headers, prefix, name)
  local base = "x-" .. prefix .. "-" .. name .. "-"
  local used = finite_number(headers[base .. "used-percent"])
  if not used then return nil end
  local minutes = finite_number(headers[base .. "window-minutes"])
  if not minutes or minutes <= 0 then minutes = nil end
  local resets_at = finite_number(headers[base .. "reset-at"])
  if resets_at and resets_at <= 0 then resets_at = nil end
  if used == 0 and not minutes and not resets_at then return nil end
  local remaining = math.max(0, math.min(1, (100 - used) / 100))
  return {
    used_percent = used,
    remaining = remaining,
    window_minutes = minutes,
    resets_at = resets_at,
  }
end

local function rate_limit_details(headers)
  local normalized = normalized_headers(headers)
  local prefixes = {}
  for name in pairs(normalized) do
    local prefix = name:match("^x%-(.-)%-primary%-used%-percent$")
    if prefix and #prefix <= 128 and prefix:match("^[%w%-_]+$") then
      prefixes[prefix] = true
    end
  end
  if normalized["x-codex-secondary-used-percent"] ~= nil then
    prefixes.codex = true
  end

  local credits
  local has_credits = header_boolean(
    normalized["x-codex-credits-has-credits"])
  local unlimited = header_boolean(
    normalized["x-codex-credits-unlimited"])
  if has_credits ~= nil and unlimited ~= nil then
    credits = {
      has_credits = has_credits,
      unlimited = unlimited,
      balance = safe_header_text(
        normalized["x-codex-credits-balance"], 128),
    }
    prefixes.codex = true
  end

  local names = {}
  for prefix in pairs(prefixes) do names[#names + 1] = prefix end
  table.sort(names, function(left, right)
    if left == "codex" then return right ~= "codex" end
    if right == "codex" then return false end
    return left < right
  end)
  local limits = {}
  for _, prefix in ipairs(names) do
    if #limits >= 32 then break end
    local primary = rate_limit_window(normalized, prefix, "primary")
    local secondary = rate_limit_window(normalized, prefix, "secondary")
    if primary or secondary then
      limits[#limits + 1] = {
        id = prefix,
        name = safe_header_text(
          normalized["x-" .. prefix .. "-limit-name"], 128),
        primary = primary,
        secondary = secondary,
      }
    end
  end
  if #limits == 0 and not credits then return nil end
  return { source = "headers", limits = limits, credits = credits }
end

local function rate_limit_status(headers)
  local details = rate_limit_details(headers)
  local parts = {}
  local default
  for _, limit in ipairs(details and details.limits or {}) do
    if limit.id == "codex" then default = limit break end
  end
  for _, window in ipairs(default and {
    default.primary,
    default.secondary,
  } or {}) do
    if window and window.window_minutes then
      local remaining = window.remaining * 100
      local formatted = string.format("%.1f", remaining):gsub("%.0$", "")
      parts[#parts + 1] = string.format("%s %s%% left",
        window_label(window.window_minutes), formatted)
    end
  end
  return #parts > 0 and table.concat(parts, " · ") or nil, details
end

local function base_url(value)
  local normalized = value:gsub("/+$", "")
  if normalized:sub(-10) == "/responses" then normalized = normalized:sub(1, -11) end
  if normalized:sub(-6) ~= "/codex" then normalized = normalized .. "/codex" end
  return normalized
end

local function decoded_detail(detail)
  if type(detail) == "table" then return detail end
  if type(detail) ~= "string" or detail == "" then return nil end
  local ok, value = pcall(vim.json.decode, detail)
  return ok and type(value) == "table" and value or nil
end

local function error_fields(value)
  if type(value) ~= "table" then return nil, nil end
  local nested = type(value.error) == "table" and value.error or nil
  local response = type(value.response) == "table" and value.response or nil
  local response_error = response and type(response.error) == "table" and response.error or nil
  local code = type(value.code) == "string" and value.code
    or nested and type(nested.code) == "string" and nested.code
    or response_error and type(response_error.code) == "string" and response_error.code
  local message = type(value.message) == "string" and value.message
    or nested and type(nested.message) == "string" and nested.message
    or response_error and type(response_error.message) == "string" and response_error.message
  return code, message
end

local function terminal_error(code, message)
  local text = ((code or "") .. " " .. (message or "")):lower()
  for _, pattern in ipairs({
    "context_length", "context window", "context_window", "maximum context",
    "too many tokens", "invalid_prompt", "invalid request", "invalid_request",
    "bio_policy", "cyber_policy", "content_policy", "insufficient_quota",
    "quota exceeded", "usage limit", "usage_limit", "usage_not_included",
    "available balance", "out of budget", "billing", "cancelled", "canceled",
  }) do
    if text:find(pattern, 1, true) then return true end
  end
  return false
end

local function response_context(err)
  local response = type(err.response) == "table" and err.response or {}
  local status = tonumber(response.status)
  local headers = normalized_headers(response.headers)
  return status, headers
end

local function retry_after(headers)
  local milliseconds = tonumber(headers["retry-after-ms"])
  if milliseconds then return math.max(0, math.min(MAX_RETRY_DELAY_MS, milliseconds)) end
  local seconds = tonumber(headers["retry-after"])
  if seconds then return math.max(0, math.min(MAX_RETRY_DELAY_MS, seconds * 1000)) end
end

local function message_retry_after(code, message)
  if code ~= "rate_limit_exceeded" or type(message) ~= "string" then return nil end
  local amount, unit = message:lower():match("try again in%s+([%d%.]+)%s*([%a]+)")
  amount = tonumber(amount)
  if not amount then return nil end
  local milliseconds
  if unit == "ms" then
    milliseconds = amount
  elseif unit == "s" or unit:sub(1, 6) == "second" then
    milliseconds = amount * 1000
  end
  return milliseconds and math.max(0, math.min(MAX_RETRY_DELAY_MS, milliseconds)) or nil
end

local function enrich_error(value)
  local err = util.normalize_error(value, "model")
  local status, headers = response_context(err)
  local code, message = error_fields(decoded_detail(err.detail))
  if code then err.code = code end
  if message then
    err.message = status and ("HTTP " .. tostring(status) .. ": " .. message) or message
  end
  err.status = status
  err.request_id = headers["x-request-id"] or headers["x-oai-request-id"]
  err.cf_ray = headers["cf-ray"]
  err.authorization_error = headers["x-openai-authorization-error"]
  local provider_status, provider_status_details = rate_limit_status(headers)
  if provider_status then err.provider_status = provider_status end
  if provider_status_details then
    err.provider_status_details = provider_status_details
  end
  err.retry_after_ms = retry_after(headers) or message_retry_after(err.code, err.message)
  if err.kind == "cancelled" or terminal_error(err.code, err.message) then
    err.retryable = false
  elseif status then
    err.retryable = status == 429 or status == 500 or status == 502
      or status == 503 or status == 504 or status == 200
  else
    err.retryable = err.kind == "transport" or err.kind == "protocol" or err.kind == "model"
  end
  if err.retryable then err.stream_max_retries = STREAM_MAX_RETRIES end
  return err
end

local function retry_delay(err, attempt)
  return err.retry_after_ms
    or math.min(MAX_RETRY_DELAY_MS, INITIAL_RETRY_DELAY_MS * (2 ^ attempt))
end

local function emit_diagnostic(self, call_opts, event_type, err, attempt, max_attempts, delay_ms)
  if not self._on_diagnostic then return end
  local value = {
    type = event_type,
    timestamp = util.now_ms(),
    api = self.api,
    provider = self.provider,
    model = self.id,
    request_attempt = attempt,
    request_max_attempts = max_attempts,
    stream_attempt = (tonumber(call_opts.retry_attempt) or 0) + 1,
    kind = err.kind,
    message = err.message,
    code = err.code,
    status = err.status,
    retryable = err.retryable == true,
    retry_after_ms = delay_ms,
    request_id = err.request_id,
    cf_ray = err.cf_ray,
    authorization_error = err.authorization_error,
    exit_code = err.exit_code,
  }
  pcall(self._on_diagnostic, value)
end

local function wrap_stream(model, opts)
  local base_stream = model.stream
  model._request_max_retries = opts.request_max_retries == nil
      and REQUEST_MAX_RETRIES or opts.request_max_retries
  assert(type(model._request_max_retries) == "number" and model._request_max_retries >= 0
    and model._request_max_retries % 1 == 0, "request_max_retries must be a non-negative integer")
  model._sleep = opts.sleep or delay
  model._on_diagnostic = opts.on_diagnostic

  function model:stream(call_opts)
    call_opts = call_opts or {}
    return async.run(function(run)
      local reconnecting = false
      local ok, outcome = pcall(function()
        local max_retries = self._request_max_retries
        for attempt = 0, max_retries do
          local call = util.copy(call_opts)
          call.on_event = function(event) run:emit(event) end
          call.on_done = nil
          local result = base_stream(self, call):await()
          if result.ok then return result end

          local err = enrich_error(result.error)
          result.error = err
          if result.message then result.message.errorMessage = err.message end
          if err.kind == "cancelled" then return result end

          local should_retry = err.retryable
            and result.message == nil and attempt < max_retries
          local wait = should_retry and retry_delay(err, attempt) or nil
          emit_diagnostic(self, call_opts,
            should_retry and "request_retry" or "request_failed",
            err, attempt + 1, max_retries + 1, wait)
          if not should_retry then return result end

          reconnecting = true
          run:emit({
            type = "provider_status",
            text = string.format(
              "Reconnecting… %d/%d", attempt + 1, max_retries),
            reconnecting = true,
          })
          self._sleep(wait)
        end
      end)
      if reconnecting then
        run:emit({ type = "provider_status", reconnecting = false })
      end
      if not ok then error(outcome, 0) end
      return outcome
    end, {
      on_event = call_opts.on_event,
      on_done = call_opts.on_done,
      error_kind = "model",
    })
  end
end

function M.new(opts)
  opts = util.copy(opts or {})
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "base_url is required")
  opts.base_url = base_url(opts.base_url)
  opts.profile = "codex"
  opts.response_status = rate_limit_status
  local model = responses.new(opts)
  model.api = "openai-codex-responses"
  wrap_stream(model, opts)
  return model
end

M.rate_limit_status = rate_limit_status

return M
