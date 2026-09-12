local async = require("neoagent.async")
local model_contract = require("neoagent.model")
local responses = require("neoagent.api.openai_responses")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.CodexQuotaWindow: Neoagent.JsonObject
---@field used_percent number
---@field remaining number
---@field window_minutes? number
---@field resets_at? number

---@class Neoagent.CodexQuota: Neoagent.JsonObject
---@field id string
---@field name? string
---@field primary? Neoagent.CodexQuotaWindow
---@field secondary? Neoagent.CodexQuotaWindow

---@class Neoagent.CodexCredits: Neoagent.JsonObject
---@field has_credits boolean
---@field unlimited boolean
---@field balance? string

---@class Neoagent.CodexQuotaDetails: Neoagent.JsonObject
---@field source "headers"
---@field limits Neoagent.CodexQuota[]
---@field credits? Neoagent.CodexCredits

---@class Neoagent.CodexError: Neoagent.HttpError
---@field code? string
---@field status? number
---@field request_id? string
---@field cf_ray? string
---@field authorization_error? string
---@field provider_status? string
---@field provider_status_details? Neoagent.CodexQuotaDetails
---@field retry_after_ms? number
---@field retryable? boolean
---@field stream_max_retries? integer

---@class Neoagent.CodexRequestDiagnostic
---@field type "request_retry"|"request_failed"
---@field timestamp integer
---@field api string
---@field provider string
---@field model string
---@field request_attempt integer
---@field request_max_attempts integer
---@field stream_attempt integer
---@field kind string
---@field message string
---@field code? string
---@field status? number
---@field retryable boolean
---@field retry_after_ms? number
---@field request_id? string
---@field cf_ray? string
---@field authorization_error? boolean
---@field exit_code? integer

---@class Neoagent.CodexOptions: Neoagent.ResponsesOptions
---@field request_max_retries? integer
---@field sleep? fun(milliseconds: number)
---@field on_diagnostic? fun(event: Neoagent.CodexRequestDiagnostic)

---@class Neoagent.CodexModel: Neoagent.ResponsesModel
---@field _request_max_retries integer
---@field _sleep fun(milliseconds: number)
---@field _on_diagnostic? fun(event: Neoagent.CodexRequestDiagnostic)

local REQUEST_MAX_RETRIES = 4
local STREAM_MAX_RETRIES = 5
local INITIAL_RETRY_DELAY_MS = 200
local MAX_RETRY_DELAY_MS = 60 * 1000

-- Error envelopes may echo prompts or credentials in any string field.
-- Diagnostics retain only this locally defined error-code vocabulary.
local diagnostic_codes = {
  invalid_request = true,
  invalid_request_error = true,
  context_length_exceeded = true,
  internal_server_error = true,
  server_error = true,
  rate_limit_exceeded = true,
  insufficient_quota = true,
  usage_limit_reached = true,
  upstream_error = true,
}

---@param timer? uv.uv_timer_t
local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:close()
  end
end

---@async
---@param milliseconds number
local function delay(milliseconds)
  return async.await(function(done)
    local timer = assert(vim.uv.new_timer())
    timer:start(math.max(1, math.floor(milliseconds)), 0, function()
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

---@param minutes number
---@return string
local function window_label(minutes)
  return ({ [300] = "5h", [10080] = "weekly" })[minutes] or tostring(minutes) .. "m"
end

---@generic T
---@param headers? table<string, T>
---@return table<string, T>
local function normalized_headers(headers)
  ---@type table<string, T>
  local result = {}
  for name, value in pairs(headers or {}) do
    result[name:lower()] = value
  end
  return result
end

---@param value unknown
---@return number?
local function finite_number(value)
  value = tonumber(value)
  if value == nil or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  return value
end

---@param value unknown
---@param maximum integer
---@return string?
local function safe_header_text(value, maximum)
  if type(value) ~= "string" then
    return nil
  end
  value = util.trim(value)
  if value == "" or #value > maximum or not util.is_valid_utf8(value) or value:find("[%z\1-\31\127]") then
    return nil
  end
  return value
end

---@param value unknown
---@return boolean?
local function header_boolean(value)
  if type(value) ~= "string" then
    return nil
  end
  value = value:lower()
  if value == "true" or value == "1" then
    return true
  end
  if value == "false" or value == "0" then
    return false
  end
  return nil
end

---@param headers table<string, string>
---@param prefix string
---@param name string
---@return Neoagent.CodexQuotaWindow?
local function rate_limit_window(headers, prefix, name)
  local base = "x-" .. prefix .. "-" .. name .. "-"
  local used = finite_number(headers[base .. "used-percent"])
  if not used then
    return nil
  end
  local minutes = finite_number(headers[base .. "window-minutes"])
  if not minutes or minutes <= 0 then
    minutes = nil
  end
  local resets_at = finite_number(headers[base .. "reset-at"])
  if resets_at and resets_at <= 0 then
    resets_at = nil
  end
  if used == 0 and not minutes and not resets_at then
    return nil
  end
  local remaining = math.max(0, math.min(1, (100 - used) / 100))
  return {
    used_percent = used,
    remaining = remaining,
    window_minutes = minutes,
    resets_at = resets_at,
  }
end

---@param headers table<string, string>
---@return Neoagent.CodexCredits?
local function rate_limit_credits(headers)
  local has_credits = header_boolean(headers["x-codex-credits-has-credits"])
  local unlimited = header_boolean(headers["x-codex-credits-unlimited"])
  if has_credits == nil or unlimited == nil then
    return nil
  end
  return {
    has_credits = has_credits,
    unlimited = unlimited,
    balance = safe_header_text(headers["x-codex-credits-balance"], 128),
  }
end

---@param headers? table<string, string>
---@return Neoagent.CodexQuotaDetails?
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

  local credits = rate_limit_credits(normalized)
  if credits then
    prefixes.codex = true
  end

  local names = {}
  for prefix in pairs(prefixes) do
    names[#names + 1] = prefix
  end
  table.sort(names, function(left, right)
    if left == "codex" then
      return right ~= "codex"
    end
    if right == "codex" then
      return false
    end
    return left < right
  end)
  ---@type Neoagent.CodexQuota[]
  local limits = {}
  for _, prefix in ipairs(names) do
    if #limits >= 32 then
      break
    end
    local primary = rate_limit_window(normalized, prefix, "primary")
    local secondary = rate_limit_window(normalized, prefix, "secondary")
    if primary or secondary then
      limits[#limits + 1] = {
        id = prefix,
        name = safe_header_text(normalized["x-" .. prefix .. "-limit-name"], 128),
        primary = primary,
        secondary = secondary,
      }
    end
  end
  if #limits == 0 and not credits then
    return nil
  end
  return { source = "headers", limits = limits, credits = credits }
end

---@param headers? table<string, string>
---@return string?, Neoagent.CodexQuotaDetails?
local function rate_limit_status(headers)
  local details = rate_limit_details(headers)
  local parts = {}
  ---@type Neoagent.CodexQuota?
  local default
  for _, limit in ipairs(details and details.limits or {}) do
    if limit.id == "codex" then
      default = limit
      break
    end
  end
  for _, name in ipairs({ "primary", "secondary" }) do
    local window = default and default[name]
    if window and window.window_minutes then
      local remaining = window.remaining * 100
      local formatted = string.format("%.1f", remaining):gsub("%.0$", "")
      parts[#parts + 1] = string.format("%s %s%% left", window_label(window.window_minutes), formatted)
    end
  end
  return #parts > 0 and table.concat(parts, " · ") or nil, details
end

---@param value string
---@return string
local function base_url(value)
  local normalized = value:gsub("/+$", "")
  if normalized:sub(-10) == "/responses" then
    normalized = normalized:sub(1, -11)
  end
  if normalized:sub(-6) ~= "/codex" then
    normalized = normalized .. "/codex"
  end
  return normalized
end

---@param detail unknown
---@return table<string, unknown>?
local function decoded_detail(detail)
  if type(detail) == "table" then
    return detail
  end
  if type(detail) ~= "string" or detail == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, detail)
  return ok and type(value) == "table" and value or nil
end

---@param value unknown
---@return string?, string?
local function error_fields(value)
  if type(value) ~= "table" then
    return nil, nil
  end
  local nested = type(value.error) == "table" and value.error or nil
  local response = type(value.response) == "table" and value.response or nil
  local response_error = response and type(response.error) == "table" and response.error or nil
  local code = type(value.code) == "string" and value.code
    or nested and type(nested.code) == "string" and nested.code
    or response_error and type(response_error.code) == "string" and response_error.code
  local message = type(value.message) == "string" and value.message
    or nested and type(nested.message) == "string" and nested.message
    or response_error and type(response_error.message) == "string" and response_error.message
  return code or nil, message or nil
end

---@param code? string
---@param message? string
---@return boolean
local function terminal_error(code, message)
  local text = ((code or "") .. " " .. (message or "")):lower()
  for _, pattern in ipairs({
    "context_length",
    "context window",
    "context_window",
    "maximum context",
    "too many tokens",
    "invalid_prompt",
    "invalid request",
    "invalid_request",
    "bio_policy",
    "cyber_policy",
    "content_policy",
    "insufficient_quota",
    "quota exceeded",
    "usage limit",
    "usage_limit",
    "usage_not_included",
    "available balance",
    "out of budget",
    "billing",
    "cancelled",
    "canceled",
  }) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

---@param err Neoagent.HttpError
---@return number?, table<string, string>
local function response_context(err)
  local response = type(err.response) == "table" and err.response or {}
  local status = tonumber(response.status)
  local headers = normalized_headers(response.headers)
  return status, headers
end

---@param headers table<string, string>
---@return number?
local function retry_after(headers)
  local milliseconds = tonumber(headers["retry-after-ms"])
  if milliseconds then
    return math.max(0, math.min(MAX_RETRY_DELAY_MS, milliseconds))
  end
  local seconds = tonumber(headers["retry-after"])
  if seconds then
    return math.max(0, math.min(MAX_RETRY_DELAY_MS, seconds * 1000))
  end
end

---@param code? string
---@param message? string
---@return number?
local function message_retry_after(code, message)
  if code ~= "rate_limit_exceeded" or type(message) ~= "string" then
    return nil
  end
  local amount_text, unit = message:lower():match("try again in%s+([%d%.]+)%s*([%a]+)")
  local amount = tonumber(amount_text)
  if not amount or not unit then
    return nil
  end
  local milliseconds
  if unit == "ms" then
    milliseconds = amount
  elseif unit == "s" or unit:sub(1, 6) == "second" then
    milliseconds = amount * 1000
  end
  return milliseconds and math.max(0, math.min(MAX_RETRY_DELAY_MS, milliseconds)) or nil
end

---@param value unknown
---@return Neoagent.CodexError
local function enrich_error(value)
  ---@type Neoagent.CodexError
  local err = util.normalize_error(value, "model")
  local status, headers = response_context(err)
  local code, message = error_fields(decoded_detail(err.detail))
  if code then
    err.code = code
  end
  if message then
    err.message = status and ("HTTP " .. tostring(status) .. ": " .. message) or message
  end
  err.status = status
  err.request_id = headers["x-request-id"] or headers["x-oai-request-id"]
  err.cf_ray = headers["cf-ray"]
  err.authorization_error = headers["x-openai-authorization-error"]
  local provider_status, provider_status_details = rate_limit_status(headers)
  if provider_status then
    err.provider_status = provider_status
  end
  if provider_status_details then
    err.provider_status_details = provider_status_details
  end
  err.retry_after_ms = retry_after(headers) or message_retry_after(err.code, err.message)
  if err.kind == "cancelled" or terminal_error(err.code, err.message) then
    err.retryable = false
  elseif status then
    err.retryable = status == 429 or status == 500 or status == 502 or status == 503 or status == 504 or status == 200
  else
    err.retryable = err.kind == "transport" or err.kind == "protocol" or err.kind == "model"
  end
  if err.retryable then
    err.stream_max_retries = STREAM_MAX_RETRIES
  end
  return err
end

---@param err Neoagent.CodexError
---@param attempt integer
---@return number
local function retry_delay(err, attempt)
  return err.retry_after_ms or math.min(MAX_RETRY_DELAY_MS, INITIAL_RETRY_DELAY_MS * (2 ^ attempt))
end

---@param self Neoagent.CodexModel
---@param call_opts Neoagent.StreamOptions
---@param event_type "request_retry"|"request_failed"
---@param err Neoagent.CodexError
---@param attempt integer
---@param max_attempts integer
---@param delay_ms? number
local function emit_diagnostic(self, call_opts, event_type, err, attempt, max_attempts, delay_ms)
  if not self._on_diagnostic then
    return
  end
  local value = {
    type = event_type,
    timestamp = util.now_ms(),
    api = self.api,
    provider = self.provider,
    model = self.id,
    request_attempt = attempt,
    request_max_attempts = max_attempts,
    stream_attempt = (call_opts.retry_attempt or 0) + 1,
    kind = err.kind,
    message = err.status and ("HTTP " .. err.status .. " request failed") or "Model request failed",
    code = diagnostic_codes[err.code] and err.code or nil,
    status = err.status,
    retryable = err.retryable == true,
    retry_after_ms = delay_ms,
    request_id = err.request_id,
    cf_ray = err.cf_ray,
    authorization_error = err.authorization_error ~= nil or nil,
    exit_code = err.exit_code,
  }
  pcall(self._on_diagnostic, value)
end

---@param model Neoagent.ResponsesModel
---@param opts Neoagent.CodexOptions
---@return Neoagent.CodexModel
local function wrap_stream(model, opts)
  local base_stream = model.stream
  ---@cast model Neoagent.CodexModel
  model._request_max_retries = opts.request_max_retries == nil and REQUEST_MAX_RETRIES or opts.request_max_retries
  assert(
    type(model._request_max_retries) == "number"
      and model._request_max_retries >= 0
      and model._request_max_retries % 1 == 0,
    "request_max_retries must be a non-negative integer"
  )
  model._sleep = opts.sleep or delay
  model._on_diagnostic = opts.on_diagnostic

  ---@param self Neoagent.CodexModel
  ---@param call_opts Neoagent.StreamOptions
  ---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
  function model.stream(self, call_opts)
    call_opts = call_opts or {}
    return async.run(
      ---@param run Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
      ---@return Neoagent.ModelResult
      function(run)
        local reconnecting = false
        local ok, outcome = pcall(function()
          local max_retries = self._request_max_retries
          local attempt = 0
          while true do
            local call = util.copy(call_opts)
            call.on_event = function(event)
              run:emit(event)
            end
            call.on_done = nil
            local result = base_stream(self, call):await()
            if result.ok then
              return result
            end

            local err = enrich_error(result.error)
            result.error = err
            if result.message then
              result.message.errorMessage = err.message
            end
            if err.kind == "cancelled" then
              return result
            end

            local should_retry = err.retryable and result.message == nil and attempt < max_retries
            if not should_retry then
              emit_diagnostic(self, call_opts, "request_failed", err, attempt + 1, max_retries + 1)
              return result
            end
            local wait = retry_delay(err, attempt)
            emit_diagnostic(self, call_opts, "request_retry", err, attempt + 1, max_retries + 1, wait)
            reconnecting = true
            run:emit({
              type = "provider_status",
              text = string.format("Reconnecting… %d/%d", attempt + 1, max_retries),
              reconnecting = true,
            })
            self._sleep(wait)
            attempt = attempt + 1
          end
        end)
        if reconnecting then
          run:emit({ type = "provider_status", reconnecting = false })
        end
        if not ok then
          error(outcome, 0)
        end
        return outcome
      end,
      {
        on_event = call_opts.on_event,
        on_done = call_opts.on_done,
        error_kind = "model",
      }
    )
  end
  return model
end

---@param opts Neoagent.CodexOptions
---@return Neoagent.CodexModel
function M.new(opts)
  opts = util.copy(opts or {})
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "base_url is required")
  opts.base_url = base_url(opts.base_url)
  opts.profile = "codex"
  opts.response_status = rate_limit_status
  local model = responses.new(opts)
  model.api = "openai-codex-responses"
  local wrapped = wrap_stream(model, opts)
  model_contract.assert(wrapped, "OpenAI Codex Responses constructor")
  return wrapped
end

M.rate_limit_status = rate_limit_status

return M
