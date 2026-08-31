local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local util = require("neoagent.util")

local M = {}

local CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local AUTH_BASE_URL = "https://auth.openai.com"
local REDIRECT_URI = "http://localhost:1455/auth/callback"
local DEVICE_REDIRECT_URI = AUTH_BASE_URL .. "/deviceauth/callback"
local CLAIM = "https://api.openai.com/auth"
local PROFILE_CLAIM = "https://api.openai.com/profile"

local plan_labels = {
  free = "Free",
  go = "Go",
  plus = "Plus",
  pro = "Pro",
  prolite = "Pro Lite",
  team = "Business",
  self_serve_business_prolite = "Business",
  self_serve_business_usage_based = "Business",
  business = "Enterprise",
  ent26 = "Enterprise",
  enterprise_cbp_automation = "Enterprise (Automation)",
  enterprise_cbp_usage_based = "Enterprise",
  enterprise = "Enterprise",
  education = "Edu",
  edu = "Edu",
  edu_plus = "Edu Plus",
  edu_pro = "Edu Pro",
  k12 = "K-12",
  quorum = "Quorum",
}

local function safe_metadata_text(value, maximum)
  if type(value) ~= "string" then return nil end
  value = util.trim(value)
  if value == "" or #value > maximum
      or not util.is_valid_utf8(value)
      or value:find("[%z\1-\31\127]") then
    return nil
  end
  return value
end

local function encode_fields(fields)
  local keys, result = {}, {}
  for key in pairs(fields) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    result[#result + 1] = vim.uri_encode(key, "rfc2396") .. "="
      .. vim.uri_encode(tostring(fields[key]), "rfc2396")
  end
  return table.concat(result, "&")
end

local function decode_fields(value)
  local result = {}
  for pair in (value or ""):gmatch("[^&]+") do
    local key, item = pair:match("^([^=]+)=?(.*)$")
    if key then
      result[vim.uri_decode(key:gsub("+", " "))] = vim.uri_decode(item:gsub("+", " "))
    end
  end
  return result
end

local function base64url(value)
  return vim.base64.encode(value):gsub("+", "-"):gsub("/", "_"):gsub("=+$", "")
end

local function random_urlsafe(bytes)
  return base64url(vim.uv.random(bytes))
end

local function hex_bytes(value)
  return value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)
end

local function decode_jwt(token)
  if type(token) ~= "string" then return nil end
  local payload = token:match("^[^.]+%.([^.]+)%.[^.]+$")
  if not payload then return nil end
  payload = payload:gsub("-", "+"):gsub("_", "/")
  payload = payload .. string.rep("=", (4 - #payload % 4) % 4)
  local ok, decoded = pcall(function() return vim.json.decode(vim.base64.decode(payload)) end)
  return ok and type(decoded) == "table" and decoded or nil
end

local function token_metadata(token)
  local payload = decode_jwt(token)
  if not payload then return {} end
  local auth = type(payload[CLAIM]) == "table" and payload[CLAIM] or {}
  local profile = type(payload[PROFILE_CLAIM]) == "table" and payload[PROFILE_CLAIM] or {}
  local email = safe_metadata_text(payload.email, 254)
    or safe_metadata_text(profile.email, 254)
  return {
    account_id = type(auth.chatgpt_account_id) == "string"
      and auth.chatgpt_account_id ~= "" and auth.chatgpt_account_id or nil,
    email = email,
    plan = safe_metadata_text(auth.chatgpt_plan_type, 64),
  }
end

local function public_metadata(credential)
  local fallback = token_metadata(credential and credential.access)
  local result = {}
  local email = safe_metadata_text(credential and credential.email, 254) or fallback.email
  local raw_plan = safe_metadata_text(credential and credential.plan, 64) or fallback.plan
  if email then result.email = email end
  if raw_plan then
    local plan = plan_labels[raw_plan:lower():gsub("%-", "_"):gsub("%s+", "_")]
    if plan then result.plan = plan end
  end
  if next(result) == nil then result.account = "ChatGPT" end
  return result
end

local function parse_authorization(value)
  value = util.trim(value or "")
  local query = value:match("^https?://[^?]+%?([^#]+)")
  return query and decode_fields(query) or {}
end

local function close_handle(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function reply(client, status, message)
  local body = "<html><body><p>" .. message .. "</p></body></html>"
  local response = table.concat({
    "HTTP/1.1 " .. status,
    "Content-Type: text/html; charset=utf-8",
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body,
  }, "\r\n")
  client:write(response, function() close_handle(client) end)
end

local function start_callback_server(expected_state, host)
  local server = vim.uv.new_tcp()
  local bound, bind_err = server:bind(host or "127.0.0.1", 1455)
  if not bound then close_handle(server) return nil, bind_err end
  local waiter, pending
  local listened, listen_err = server:listen(16, function(err)
    if err then return end
    local client = vim.uv.new_tcp()
    if not server:accept(client) then close_handle(client) return end
    local buffer = ""
    client:read_start(function(read_err, chunk)
      if read_err then close_handle(client) return end
      if not chunk then close_handle(client) return end
      buffer = buffer .. chunk
      if not buffer:find("\r\n\r\n", 1, true) and #buffer < 16384 then return end
      client:read_stop()
      local target = buffer:match("^GET%s+(%S+)") or ""
      local path, query = target:match("^([^?]+)%??(.*)$")
      local fields = decode_fields(query)
      if path ~= "/auth/callback" then
        reply(client, "404 Not Found", "Callback route not found.")
      elseif fields.state ~= expected_state then
        reply(client, "400 Bad Request", "State mismatch.")
      elseif not fields.code or fields.code == "" then
        reply(client, "400 Bad Request", "Missing authorization code.")
      else
        reply(client, "200 OK", "OpenAI authentication completed. You can close this window.")
        pending = fields.code
        if waiter then waiter.resolve(pending) end
      end
    end)
  end)
  if not listened then close_handle(server) return nil, listen_err end
  return {
    wait = function()
      return async.await(function(done)
        waiter = done
        if pending then done.resolve(pending) end
        return function() close_handle(server) end
      end)
    end,
    close = function() close_handle(server) end,
  }
end

local function await_prompt(interaction, prompt)
  return async.await(function(done) return interaction.prompt(prompt, done) end)
end

local function delay(milliseconds)
  return async.await(function(done)
    local timer = vim.uv.new_timer()
    timer:start(math.max(1, milliseconds), 0, function()
      timer:stop()
      close_handle(timer)
      done.resolve(true)
    end)
    return function()
      timer:stop()
      close_handle(timer)
    end
  end)
end

function M.new(opts)
  opts = opts or {}
  local http = opts.http or curl
  local now = opts.now or util.now_ms
  local auth_base = opts.auth_base_url or AUTH_BASE_URL
  local token_url = auth_base .. "/oauth/token"
  local callback_host = opts.callback_host or "127.0.0.1"
  local start_server = opts.start_callback_server or start_callback_server
  local sleep = opts.sleep or delay

  local function post(url, headers, body)
    local result = http.fetch({ request = { url = url, headers = headers, body = body } }):await()
    if not result.ok then error(result.error, 0) end
    local decoded, value = pcall(vim.json.decode, result.body or "")
    if not decoded or type(value) ~= "table" then
      error(util.error("auth", "OpenAI returned invalid JSON", result.body), 0)
    end
    if result.status < 200 or result.status >= 300 then
      local detail = type(value.error) == "table" and value.error.message or value.error
      error(util.error("auth", "OpenAI authentication failed (HTTP " .. result.status .. ")", detail), 0)
    end
    return value
  end

  local function credential(value, previous)
    if type(value.access_token) ~= "string" or value.access_token == ""
        or type(value.refresh_token) ~= "string" or value.refresh_token == ""
        or type(value.expires_in) ~= "number" then
      error(util.error("auth", "OpenAI token response is missing fields"), 0)
    end
    local access = token_metadata(value.access_token)
    local identity = token_metadata(value.id_token)
    local account_id = access.account_id or identity.account_id
    if not account_id then
      error(util.error("auth", "Failed to extract accountId from OpenAI token"), 0)
    end
    return {
      type = "oauth",
      access = value.access_token,
      refresh = value.refresh_token,
      expires = now() + value.expires_in * 1000,
      accountId = account_id,
      email = identity.email or access.email
        or safe_metadata_text(previous and previous.email, 254),
      plan = identity.plan or access.plan
        or safe_metadata_text(previous and previous.plan, 64),
    }
  end

  local function exchange(code, verifier, redirect_uri)
    return credential(post(token_url, { ["Content-Type"] = "application/x-www-form-urlencoded" }, encode_fields({
      grant_type = "authorization_code",
      client_id = CLIENT_ID,
      code = code,
      code_verifier = verifier,
      redirect_uri = redirect_uri,
    })))
  end

  local function browser_login(interaction)
    local verifier = random_urlsafe(32)
    local state = random_urlsafe(16)
    local challenge = base64url(hex_bytes(vim.fn.sha256(verifier)))
    local url = auth_base .. "/oauth/authorize?" .. encode_fields({
      response_type = "code",
      client_id = CLIENT_ID,
      redirect_uri = REDIRECT_URI,
      scope = "openid profile email offline_access",
      code_challenge = challenge,
      code_challenge_method = "S256",
      state = state,
      id_token_add_organizations = "true",
      codex_cli_simplified_flow = "true",
      originator = "neoagent",
    })
    local server = start_server(state, callback_host)
    interaction.notify({
      type = "auth_url",
      url = url,
      instructions = "Complete login in your browser to finish.",
    })
    local code
    if server then
      local ok, value = pcall(server.wait)
      server.close()
      if not ok then error(value, 0) end
      code = value
    else
      local input = await_prompt(interaction, {
        type = "manual_code",
        message = "Paste the redirect URL:",
        placeholder = REDIRECT_URI,
      })
      local parsed = parse_authorization(input)
      if parsed.state and parsed.state ~= state then error(util.error("auth", "OAuth state mismatch"), 0) end
      code = parsed.code
    end
    if not code or code == "" then error(util.error("auth", "Missing authorization code"), 0) end
    return exchange(code, verifier, REDIRECT_URI)
  end

  local function device_login(interaction)
    local device = post(auth_base .. "/api/accounts/deviceauth/usercode",
      { ["Content-Type"] = "application/json" }, vim.json.encode({ client_id = CLIENT_ID }))
    local interval = tonumber(device.interval)
    if type(device.device_auth_id) ~= "string" or type(device.user_code) ~= "string"
        or not interval or interval < 0 then
      error(util.error("auth", "Invalid OpenAI device code response"), 0)
    end
    interaction.notify({
      type = "device_code",
      userCode = device.user_code,
      verificationUri = auth_base .. "/codex/device",
      intervalSeconds = interval,
      expiresInSeconds = 900,
    })
    local deadline = now() + 900000
    while now() < deadline do
      sleep(interval * 1000)
      local result = http.fetch({ request = {
        url = auth_base .. "/api/accounts/deviceauth/token",
        headers = { ["Content-Type"] = "application/json" },
        body = vim.json.encode({ device_auth_id = device.device_auth_id, user_code = device.user_code }),
      } }):await()
      if not result.ok then error(result.error, 0) end
      if result.status == 200 then
        local ok, code = pcall(vim.json.decode, result.body or "")
        if not ok or type(code) ~= "table" or type(code.authorization_code) ~= "string"
            or type(code.code_verifier) ~= "string" then
          error(util.error("auth", "Invalid OpenAI device authorization response"), 0)
        end
        return exchange(code.authorization_code, code.code_verifier, DEVICE_REDIRECT_URI)
      elseif result.status ~= 403 and result.status ~= 404 then
        local ok, failure = pcall(vim.json.decode, result.body or "")
        local detail = ok and type(failure) == "table" and failure.error or nil
        local code = type(detail) == "table" and detail.code or detail
        if code == "deviceauth_authorization_pending" then
          -- Keep polling at the current interval.
        elseif code == "slow_down" then
          interval = interval + 5
        else
          error(util.error(
            "auth", "OpenAI device authorization failed (HTTP " .. result.status .. ")", result.body
          ), 0)
        end
      end
    end
    error(util.error("auth", "OpenAI device authorization timed out"), 0)
  end

  return {
    type = "oauth",
    name = "OpenAI (ChatGPT Plus/Pro)",
    login = function(interaction)
      return async.run(function()
        local choice = await_prompt(interaction, {
          type = "select",
          message = "Select OpenAI Codex login method:",
          options = {
            { id = "browser", label = "Browser login (default)" },
            { id = "device_code", label = "Device code login (headless)" },
          },
        })
        local value
        if choice == "browser" then value = browser_login(interaction)
        elseif choice == "device_code" then value = device_login(interaction)
        else error(util.error("auth", "Unknown OpenAI Codex login method: " .. tostring(choice)), 0) end
        return { ok = true, credential = value }
      end, { error_kind = "auth" })
    end,
    refresh = function(current)
      return async.run(function()
        local value = post(token_url, { ["Content-Type"] = "application/x-www-form-urlencoded" }, encode_fields({
          grant_type = "refresh_token",
          refresh_token = current.refresh,
          client_id = CLIENT_ID,
        }))
        return { ok = true, credential = credential(value, current) }
      end, { error_kind = "auth" })
    end,
    public_metadata = public_metadata,
    request_opts = function(current)
      if type(current.accountId) ~= "string" or current.accountId == "" then
        error(util.error("auth", "Stored OpenAI credential has no accountId"), 0)
      end
      return { headers = {
        Authorization = "Bearer " .. current.access,
        ["chatgpt-account-id"] = current.accountId,
        originator = "neoagent",
        ["OpenAI-Beta"] = "responses=experimental",
        ["User-Agent"] = "neoagent",
      } }
    end,
  }
end

return M
