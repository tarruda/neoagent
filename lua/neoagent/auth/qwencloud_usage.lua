local async = require("neoagent.async")
local http_client = require("neoagent.transport.http")
local pkce = require("neoagent.auth.pkce")
local util = require("neoagent.util")

local M = {}
local AUTH_ORIGIN = "https://t.qwencloud.com"
local ACCOUNT_ORIGIN = "https://account.qwencloud.com"
local REQUEST_TIMEOUT_MS = 30000
local LOGIN_TIMEOUT_MS = 15 * 60 * 1000
local MAX_RESPONSE_BYTES = 64 * 1024
local TOKEN_PLACEHOLDERS = {
  ["[redacted]"] = true,
  ["<redacted>"] = true,
  redacted = true,
  ["<omitted>"] = true,
  omitted = true,
}

---@class Neoagent.QwenCloudUsageAuthOptions
---@field transport? Neoagent.ByteBackend
---@field sleep? async fun(milliseconds: integer)
---@field clock? fun(): number Monotonic milliseconds.

---@return string
local function client_id()
  ---@type integer[]
  local bytes = { string.byte(assert(vim.uv.random(16)), 1, 16) }
  bytes[7] = bit.bor(bit.band(assert(bytes[7]), 0x0f), 0x40)
  bytes[9] = bit.bor(bit.band(assert(bytes[9]), 0x3f), 0x80)
  return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", unpack(bytes))
end

---@param value unknown
---@return TypeGuard<string>
function M.valid_access_token(value)
  -- QwenCloud tokens are opaque. Accept punctuation while keeping whitespace
  -- and control bytes out of the Authorization header.
  return type(value) == "string"
    and #value <= 16384
    and value:match("^[!-~]+$") ~= nil
    and not TOKEN_PLACEHOLDERS[value:lower()]
    and not value:match("^%*+$")
end

---@param value unknown
---@return TypeGuard<integer>
local function positive_seconds(value)
  return type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
end

---@param value unknown
---@return TypeGuard<string>
local function verification_url(value)
  if type(value) ~= "string" or #value > 8192 or value:find("[%z\1-\32\127\\]") then
    return false
  end
  local origin = value:match("^(https://[^/?#]+)")
  return origin == ACCOUNT_ORIGIN or origin == AUTH_ORIGIN
end

---@param message string
---@return never
local function fail(message)
  error(util.error("auth", "QwenCloud browser login " .. message), 0)
end

---@param response Neoagent.HttpSuccess
---@return boolean
local function http_success(response)
  local status = response.status or 0
  return status >= 200 and status < 300
end

---@param value unknown
---@return TypeGuard<Neoagent.JsonObject>
local function object(value)
  return type(value) == "table" and not util.is_list(value)
end

---@param response Neoagent.HttpSuccess
---@return Neoagent.JsonObject?
local function data(response)
  local body = response.body
  if http_success(response) and object(body) and body.Success == true and object(body.Data) then
    return body.Data
  end
end

---@param response Neoagent.HttpSuccess
---@return string?
local function poll_error(response)
  local body = response.body
  local code = object(body) and (body.error or body.Code) or nil
  if code == "authorization_pending" or code == "slow_down" or code == "access_denied" or code == "expired_token" then
    return code
  end
end

---@param opts? Neoagent.QwenCloudUsageAuthOptions
---@return Neoagent.AuthMethod<Neoagent.OAuthCredential>
function M.new(opts)
  opts = opts or {}
  local http = http_client.new(opts.transport).with_context({ credential_response_body = true })
  local sleep = opts.sleep or async.sleep
  local clock = opts.clock or function()
    return vim.uv.hrtime() / 1e6
  end

  ---@async
  ---@param path string
  ---@param timeout_ms integer
  ---@return Neoagent.HttpSuccess
  local function post(path, timeout_ms)
    local response = http
      .fetch({
        request = {
          method = "POST",
          url = AUTH_ORIGIN .. path,
          private_input = true,
          headers = { Accept = "application/json", ["User-Agent"] = "neoagent" },
          timeout_ms = timeout_ms,
          max_response_bytes = MAX_RESPONSE_BYTES,
        },
      })
      :await()
    if not response.ok then
      if response.error.kind == "cancelled" then
        error(response.error, 0)
      end
      -- The URL and response can both contain device or access tokens.
      fail(response.error.kind == "protocol" and "returned an invalid response" or "request failed")
    end
    return response
  end

  ---@type Neoagent.AuthMethod<Neoagent.OAuthCredential>
  local method = {
    type = "oauth",
    name = "QwenCloud usage",
    login_label = "Log in for usage",
    logout_label = "Log out of usage",
    login = function(interaction)
      return async.run(function()
        local id = client_id()
        local verifier = pkce.random_urlsafe(32)
        local started = post(
          "/cli/device/code?client_id="
            .. id
            .. "&code_challenge="
            .. pkce.challenge(verifier)
            .. "&code_challenge_method=S256",
          REQUEST_TIMEOUT_MS
        )
        if not http_success(started) then
          fail("could not start (HTTP " .. tostring(started.status) .. ")")
        end
        local init = data(started)
        local token, url = init and init.Token, init and init.VerificationUrl
        local expires_in, interval = init and init.ExpiresIn, init and init.Interval
        if
          type(token) ~= "string"
          or token == ""
          or #token > 4096
          or token:find("[%z\1-\31\127]")
          or not verification_url(url)
          or not positive_seconds(expires_in)
          or not positive_seconds(interval)
        then
          fail("returned invalid device authorization data")
        end
        local deadline = clock() + math.min(LOGIN_TIMEOUT_MS, expires_in * 1000)
        local interval_ms = math.min(LOGIN_TIMEOUT_MS, interval * 1000)
        local path = "/cli/device/token?client_id="
          .. id
          .. "&token="
          .. vim.uri_encode(token, "rfc2396")
          .. "&code_verifier="
          .. verifier
        local function remaining_ms()
          local remaining = math.ceil(deadline - clock())
          if remaining <= 0 then
            fail("expired; start a new login")
          end
          return remaining
        end
        interaction.notify({
          type = "auth_url",
          url = url,
          instructions = "Authorize QwenCloud usage in your browser to finish.",
        })
        while true do
          sleep(math.min(interval_ms, remaining_ms()))
          local polled = post(path, math.min(REQUEST_TIMEOUT_MS, remaining_ms()))
          remaining_ms()
          local value = data(polled)
          local raw_status = value and value.Status
          local status = type(raw_status) == "string" and raw_status:lower() or poll_error(polled)
          if status == "complete" and value then
            local credential = value.Credentials
            local access = type(credential) == "table" and credential.AccessToken or nil
            local expires = type(credential) == "table" and util.parse_rfc3339_ms(credential.ExpireTime) or nil
            if not M.valid_access_token(access) or not expires or expires <= util.now_ms() then
              fail("returned an invalid or expired access token")
            end
            return { ok = true, credential = { type = "oauth", access = access, expires = expires } }
          elseif status == "access_denied" then
            fail("was denied")
          elseif status == "expired_token" then
            fail("expired; start a new login")
          elseif status == "slow_down" then
            interval_ms = interval_ms + 5000
          elseif status ~= "authorization_pending" then
            if not http_success(polled) then
              fail("poll failed (HTTP " .. tostring(polled.status) .. ")")
            end
            fail("returned an invalid device status")
          end
        end
      end, { error_kind = "auth" })
    end,
    validate_credential = function(credential)
      return M.valid_access_token(credential.access) and credential.expires > 0 and credential.expires < math.huge
    end,
    request_opts = function(credential, scope)
      if scope ~= "usage" then
        error(util.error("auth", "QwenCloud browser authorization is only for usage"), 0)
      end
      return { headers = { Authorization = "Bearer " .. credential.access } }
    end,
  }
  method._with_transport = function(transport)
    return M.new({ transport = transport, clock = opts.clock, sleep = opts.sleep })
  end
  return method
end

return M
