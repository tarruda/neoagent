local util = require("neoagent.util")

local M = {}
---@alias Neoagent.RecordingSecrets table<string, boolean>

---@class Neoagent.RecordingParameter
---@field raw string
---@field key? string
---@field value string

---@class Neoagent.RecordingBodyState
---@field absent? boolean
---@field body? string
---@field valid_utf8? boolean
---@field content_type? string
---@field form? Neoagent.RecordingParameter[]
---@field json? unknown
---@field opaque? boolean

---@class Neoagent.RecordingPresentBody: Neoagent.RecordingBodyState
---@field body string
---@field valid_utf8 boolean

---@class Neoagent.RecordingUrl
---@field changed boolean
---@field userinfo? string
---@field base string
---@field query? string
---@field fragment? string
---@field query_parameters Neoagent.RecordingParameter[]
---@field fragment_parameters Neoagent.RecordingParameter[]

local sensitive_keys = {
  access = true,
  access_key = true,
  access_token = true,
  api_key = true,
  authorization = true,
  authorization_code = true,
  aws_secret_access_key = true,
  client_id = true,
  client_secret = true,
  code_verifier = true,
  cookie = true,
  credential = true,
  device_auth_id = true,
  id_token = true,
  password = true,
  private_key = true,
  refresh = true,
  refresh_token = true,
  secret = true,
  secret_access_key = true,
  security_token = true,
  session_token = true,
  token = true,
  user_code = true,
}

local sensitive_compact_keys = {}
for key in pairs(sensitive_keys) do
  sensitive_compact_keys[key:gsub("_", "")] = true
end

---@param value unknown
---@return string
local function safe_string(value)
  if type(value) ~= "string" then
    value = value == nil and "" or tostring(value)
  end
  if util.is_valid_utf8(value) then return value end
  return "*"
end

---@param value string
---@return string
local function pattern_escape(value)
  return (value:gsub("([^%w])", "%%%1"))
end

---@param secrets Neoagent.RecordingSecrets
---@param value unknown
local function add_secret(secrets, value)
  if type(value) ~= "string" or value == "" or value == "*" then return end
  secrets[value] = true
  local bearer = value:match("^[Bb]earer%s+(.+)$")
    or value:match("^[Bb]asic%s+(.+)$")
  if bearer and bearer ~= "" then secrets[bearer] = true end
end

---@param secrets Neoagent.RecordingSecrets
---@param value unknown
---@param seen table<table, boolean>
local function collect_strings(secrets, value, seen)
  if type(value) == "string" then add_secret(secrets, value) return end
  if type(value) == "number" or type(value) == "boolean" then
    add_secret(secrets, tostring(value))
    return
  end
  if type(value) ~= "table" or value == vim.NIL or seen[value] then return end
  seen[value] = true
  for _, child in pairs(value) do collect_strings(secrets, child, seen) end
  seen[value] = nil
end

---@type fun(value: unknown, secrets: Neoagent.RecordingSecrets, authentication?: boolean)
local collect_text_url_secrets
---@type fun(value: unknown, secrets: Neoagent.RecordingSecrets, authentication?: boolean): string, boolean
local sanitize_text_urls

---@param value unknown
---@param secrets? Neoagent.RecordingSecrets
---@param authentication? boolean
---@param skip_urls? boolean
---@return string, boolean
local function redact_text(value, secrets, authentication, skip_urls)
  secrets = secrets or {}
  local text = safe_string(value)
  local changed = text ~= value
  local ordered = {}
  for secret in pairs(secrets or {}) do ordered[#ordered + 1] = secret end
  table.sort(ordered, function(left, right) return #left > #right end)
  for _, secret in ipairs(ordered) do
    local count
    text, count = text:gsub(pattern_escape(secret), "*")
    if count > 0 then changed = true end
  end
  ---@type [string, string][]
  local substitutions = {
    { "([Bb]earer%s+)[%w%._~%+/%-=]+", "%1*" },
    { "([Bb]asic%s+)[%w%+/%-=]+", "%1*" },
    { "sk%-%w[%w_%-]+", "*" },
    { "gh[pousr]_[%w_%-]+", "*" },
    { "xox[baprs]%-[%w%-]+", "*" },
    { "AKIA" .. string.rep("[A-Z0-9]", 16), "*" },
    { "eyJ[%w_%-]+%.eyJ[%w_%-]+%.[%w_%-]+", "*" },
    {
      "%-%-%-%-%-BEGIN [^\n]-PRIVATE KEY%-%-%-%-%-"
        .. "[%s%S]-%-%-%-%-%-END [^\n]-PRIVATE KEY%-%-%-%-%-",
      "*",
    },
  }
  for _, substitution in ipairs(substitutions) do
    local count
    text, count = text:gsub(substitution[1], substitution[2])
    if count > 0 then changed = true end
  end
  for _, key in ipairs({
    "access_token", "api_key", "authorization_code", "client_id",
    "client_secret", "code_verifier", "id_token", "password",
    "refresh_token", "secret_access_key", "security_token", "token",
  }) do
    local count
    text, count = text:gsub(
      '("' .. key .. '"%s*:%s*")([^"]+)(")', "%1*%3")
    if count > 0 then changed = true end
  end
  if sanitize_text_urls and not skip_urls then
    local sanitized, urls_changed = sanitize_text_urls(
      text, secrets, authentication)
    text = sanitized
    changed = changed or urls_changed
  end
  return text, changed
end

---@param value unknown
---@return string
local function normalized_key(value)
  return type(value) == "string"
      and value:lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", "")
        :gsub("_+$", "") or ""
end

---@generic K
---@param value? table<K, unknown>
---@return K[]
local function sorted_keys(value)
  local keys = {}
  for key in pairs(value or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(left, right)
    local left_text, right_text = tostring(left), tostring(right)
    local left_folded, right_folded = left_text:lower(), right_text:lower()
    if left_folded == right_folded then return left_text < right_text end
    return left_folded < right_folded
  end)
  return keys
end

---@param value string
---@return string
local function uri_decode(value)
  local ok, decoded = pcall(vim.uri_decode, value)
  if ok then return decoded end
  return value
end

---@param key unknown
---@param authentication? boolean
---@return boolean?
local function sensitive_key(key, authentication)
  local selected = normalized_key(key)
  if sensitive_keys[selected]
      or sensitive_compact_keys[selected:gsub("_", "")] then
    return true
  end
  if selected:sub(-6) == "_token" or selected:sub(-7) == "_secret"
      or selected:sub(-9) == "_password" then
    return true
  end
  return authentication and selected == "code"
end

---@param value unknown
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@param key unknown
---@param seen table<table, boolean>
local function collect_json_secrets(
    value, secrets, authentication, key, seen)
  if value == vim.NIL then return end
  if sensitive_key(key, authentication) then
    collect_strings(secrets, value, {})
    return
  end
  if type(value) == "string" then
    if collect_text_url_secrets then
      collect_text_url_secrets(value, secrets, authentication)
    end
    return
  end
  if type(value) ~= "table" or seen[value] then return end
  seen[value] = true
  for child_key, child in pairs(value) do
    collect_json_secrets(
      child, secrets, authentication, child_key, seen)
  end
  seen[value] = nil
end

---@param value unknown
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@param key unknown
---@param seen table<table, boolean>
---@return unknown, boolean
local function sanitize_json_value(value, secrets, authentication, key, seen)
  if value == vim.NIL then return vim.NIL, false end
  if sensitive_key(key, authentication) then
    if value == "" then return "", false end
    collect_strings(secrets, value, {})
    return "*", true
  end
  if type(value) == "string" then
    return redact_text(value, secrets, authentication)
  end
  if type(value) ~= "table" then return value, false end
  if seen[value] then return "*", true end
  seen[value] = true
  local result = util.is_list(value) and {} or vim.empty_dict()
  local changed = false
  for child_key, child in pairs(value) do
    local sanitized, child_changed = sanitize_json_value(
      child, secrets, authentication, child_key, seen)
    result[child_key] = sanitized
    changed = changed or child_changed
  end
  seen[value] = nil
  return result, changed
end

---@param headers? table<string, unknown>
---@return string
local function content_type(headers)
  headers = headers or {}
  for _, name in ipairs(sorted_keys(headers)) do
    local value = headers[name]
    if type(name) == "string" and name:lower() == "content-type" then
      return type(value) == "string" and value:lower() or ""
    end
  end
  return ""
end

---@param body string
---@return Neoagent.RecordingParameter[]
local function parse_parameters(body)
  local parsed = {}
  for part in (body .. "&"):gmatch("(.-)&") do
    local key, value = part:match("^([^=]*)=(.*)$")
    parsed[#parsed + 1] = { raw = part, key = key, value = value or "" }
  end
  return parsed
end

---@param parsed Neoagent.RecordingParameter[]
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
local function collect_form_secrets(parsed, secrets, authentication)
  for _, entry in ipairs(parsed) do
    if entry.key and sensitive_key(uri_decode(entry.key), authentication) then
      local decoded = uri_decode(entry.value)
      if decoded ~= "" then add_secret(secrets, decoded) end
    elseif entry.value then
      collect_text_url_secrets(
        uri_decode(entry.value), secrets, authentication)
    end
  end
end

---@param parsed Neoagent.RecordingParameter[]
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@return string, boolean
local function sanitize_form(parsed, secrets, authentication)
  local changed = false
  local parts = {}
  for index, entry in ipairs(parsed) do
    local key, value = entry.key, entry.value
    if not key then
      parts[index] = entry.raw
    elseif sensitive_key(uri_decode(key), authentication) then
      if uri_decode(value) == "" then
        parts[index] = key .. "="
      else
        parts[index] = key .. "=*"
        changed = true
      end
    else
      local sanitized, redacted = redact_text(
        value, secrets, authentication)
      local _, decoded_redacted = redact_text(
        uri_decode(value), secrets, authentication)
      parts[index] = key .. "="
        .. (decoded_redacted and "*" or sanitized)
      changed = changed or redacted or decoded_redacted
    end
  end
  return table.concat(parts, "&"), changed
end

---@param body unknown
---@return Neoagent.RecordingBodyState
local function raw_body_state(body)
  if body == nil then return { absent = true } end
  if type(body) ~= "string" then body = tostring(body) end
  return {
    body = body,
    valid_utf8 = util.is_valid_utf8(body),
  }
end

---@param body unknown
---@param headers? table<string, unknown>
---@return Neoagent.RecordingBodyState
local function body_state(body, headers)
  local state = raw_body_state(body)
  if state.absent then return state end
  ---@cast state Neoagent.RecordingPresentBody
  state.content_type = content_type(headers)
  if not state.valid_utf8 then return state end
  if type(body) == "table" then
    state.json = body
    return state
  end
  body = state.body
  if state.content_type:find(
      "application/x%-www%-form%-urlencoded") then
    state.form = parse_parameters(body)
    return state
  end
  local first = body:match("^%s*(.)")
  if state.content_type:find("json", 1, true)
      or first == "{" or first == "[" then
    local ok, decoded = pcall(vim.json.decode, body)
    if ok and type(decoded) == "table" then state.json = decoded end
  end
  local media_type = state.content_type:match("^%s*([^;]+)") or ""
  local textual = media_type == "" or media_type:match("^text/")
    or media_type:find("json", 1, true)
    or media_type:find("xml", 1, true)
    or media_type:find("yaml", 1, true)
    or media_type:find("javascript", 1, true)
    or media_type:find("graphql", 1, true)
  state.opaque = not textual
  return state
end

---@param state Neoagent.RecordingBodyState
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
local function collect_body_secrets(state, secrets, authentication)
  if state.form then
    collect_form_secrets(state.form, secrets, authentication)
  elseif state.json then
    collect_json_secrets(
      state.json, secrets, authentication, "", {})
  elseif state.valid_utf8 then
    collect_text_url_secrets(state.body, secrets, authentication)
  end
end

---@param state Neoagent.RecordingBodyState
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@return string?, boolean
local function sanitize_body_state(state, secrets, authentication)
  if state.absent then return nil, false end
  if state.body == "" then return "", false end
  if not state.valid_utf8 or state.opaque then return "*", true end
  if state.form then
    return sanitize_form(state.form, secrets, authentication)
  end
  if state.json then
    local sanitized, changed = sanitize_json_value(
      state.json, secrets, authentication, "", {})
    if changed then return util.json_encode(sanitized), true end
  end
  return redact_text(state.body, secrets, authentication)
end

---@param state Neoagent.RecordingBodyState
---@return string?, "base64"?
local function exact_body_state(state)
  if state.absent then return nil, nil end
  ---@cast state Neoagent.RecordingPresentBody
  if state.valid_utf8 then return state.body, nil end
  return vim.base64.encode(state.body), "base64"
end

---@param body string?
---@param headers? table<string, unknown>
---@param encoding? string
---@return Neoagent.JsonValue?, boolean
local function json_body(body, headers, encoding)
  if encoding ~= nil or type(body) ~= "string" or body == ""
      or not util.is_valid_utf8(body) then
    return nil, false
  end
  local first = body:match("^%s*(.)")
  if not content_type(headers):find("json", 1, true)
      and first ~= "{" and first ~= "[" then
    return nil, false
  end
  local ok, decoded = pcall(vim.json.decode, body)
  return decoded, ok
end

---@param key unknown
---@param authentication? boolean
---@return boolean
local function sensitive_url_key(key, authentication)
  local selected = normalized_key(key)
  if sensitive_key(selected, authentication)
      or authentication and selected == "state" then
    return true
  end
  local padded = "_" .. selected .. "_"
  for _, term in ipairs({
    "account", "auth", "client_id", "credential", "key", "password",
    "secret", "sig", "signature", "token",
  }) do
    if padded:find("_" .. term .. "_", 1, true) then return true end
  end
  return false
end

---@param parameters Neoagent.RecordingParameter[]
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@param bare_is_sensitive boolean
local function collect_parameter_secrets(
    parameters, secrets, authentication, bare_is_sensitive)
  for _, entry in ipairs(parameters) do
    if entry.key and entry.value ~= ""
        and sensitive_url_key(uri_decode(entry.key), authentication) then
      add_secret(secrets, uri_decode(entry.value))
    elseif not entry.key and entry.raw ~= "" and bare_is_sensitive then
      add_secret(secrets, uri_decode(entry.raw))
    end
  end
end

---@param parameters Neoagent.RecordingParameter[]
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@param bare_is_sensitive boolean
---@return string, boolean
local function sanitize_parameters(
    parameters, secrets, authentication, bare_is_sensitive)
  local result, changed = {}, false
  for index, entry in ipairs(parameters) do
    if entry.key and entry.value == "" then
      result[index] = entry.key .. "="
    elseif entry.key
        and sensitive_url_key(uri_decode(entry.key), authentication) then
      result[index] = entry.key .. "=*"
      changed = true
    elseif entry.key then
      local sanitized, redacted = redact_text(
        entry.value, secrets, authentication)
      local _, decoded_redacted = redact_text(
        uri_decode(entry.value), secrets, authentication)
      result[index] = entry.key .. "="
        .. (decoded_redacted and "*" or sanitized)
      changed = changed or redacted or decoded_redacted
    elseif entry.raw == "" then
      result[index] = ""
    elseif bare_is_sensitive then
      result[index] = "*"
      changed = true
    else
      local sanitized, redacted = redact_text(
        entry.raw, secrets, authentication)
      local _, decoded_redacted = redact_text(
        uri_decode(entry.raw), secrets, authentication)
      result[index] = decoded_redacted and "*" or sanitized
      changed = changed or redacted or decoded_redacted
    end
  end
  return table.concat(result, "&"), changed
end

---@param url unknown
---@return Neoagent.RecordingUrl
local function url_state(url)
  local value = safe_string(url)
  local state = { changed = value ~= url }
  local scheme, userinfo, rest = value:match("^(%a[%w+.-]*://)([^/@]+)@(.+)$")
  if scheme then
    state.userinfo = userinfo
    value = scheme .. "*@" .. rest
    state.changed = true
  end
  local before_fragment, fragment = value:match("^(.-)#(.*)$")
  if before_fragment == nil then before_fragment = value end
  local base, query = before_fragment:match("^(.-)%?(.*)$")
  if base == nil then base = before_fragment end
  state.base = base
  state.query = query
  state.fragment = fragment
  state.query_parameters = query and parse_parameters(query) or {}
  state.fragment_parameters = fragment and parse_parameters(fragment) or {}
  return state
end

---@param state Neoagent.RecordingUrl
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
local function collect_url_secrets(state, secrets, authentication)
  if state.userinfo then
    add_secret(secrets, state.userinfo)
    add_secret(secrets, state.userinfo:match("^[^:]*:(.*)$"))
  end
  collect_parameter_secrets(
    state.query_parameters, secrets, authentication, false)
  collect_parameter_secrets(
    state.fragment_parameters, secrets, authentication, true)
end

---@param state Neoagent.RecordingUrl
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@return string, boolean
local function sanitize_url_state(state, secrets, authentication)
  local value = state.base
  local changed = state.changed
  if state.query ~= nil then
    local sanitized, redacted = sanitize_parameters(
      state.query_parameters, secrets, authentication, false)
    value = value .. "?" .. sanitized
    changed = changed or redacted
  end
  if state.fragment ~= nil then
    local sanitized, redacted = sanitize_parameters(
      state.fragment_parameters, secrets, authentication, true)
    value = value .. "#" .. sanitized
    changed = changed or redacted
  end
  local sanitized, redacted = redact_text(
    value, secrets, authentication, true)
  return sanitized, changed or redacted
end

---@param url unknown
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@return string, boolean
local function sanitize_url(url, secrets, authentication)
  local state = url_state(url)
  collect_url_secrets(state, secrets, authentication)
  return sanitize_url_state(state, secrets, authentication)
end

local embedded_url_pattern = "%a[%w+.-]*://[^%s\"'<>]+"

collect_text_url_secrets = function(value, secrets, authentication)
  for candidate in safe_string(value):gmatch(embedded_url_pattern) do
    collect_url_secrets(url_state(candidate), secrets, authentication)
  end
end

sanitize_text_urls = function(value, secrets, authentication)
  local changed = false
  local sanitized = safe_string(value):gsub(
    embedded_url_pattern, function(candidate)
      local result, redacted = sanitize_url(
        candidate, secrets, authentication)
      changed = changed or redacted
      return result
    end)
  return sanitized, changed
end

---@param name unknown
---@return boolean
local function sensitive_header(name)
  local selected = normalized_key(name)
  if sensitive_keys[selected] then return true end
  local padded = "_" .. selected .. "_"
  for _, term in ipairs({
    "account", "api_key", "auth", "authorization", "cookie", "credential",
    "csrf", "key", "nonce", "organization", "password", "project", "secret",
    "session", "signature", "token",
  }) do
    if padded:find("_" .. term .. "_", 1, true) then return true end
  end
  return false
end

-- Values a recording publishes itself: exchange context, the Workspace index,
-- and the Session directory name. A header that carries one of them, such as a
-- provider conversation-attribution header, identifies the conversation instead
-- of protecting a credential, so it never enters the redaction set.
---@param context Neoagent.RequestIdentity
---@param workspace? string
---@return Neoagent.RecordingSecrets
local function published_identity(context, workspace)
  local result = {}
  for _, key in ipairs({ "session_id", "agent_id" }) do
    local value = context[key]
    if type(value) == "string" and value ~= "" then result[value] = true end
  end
  if type(workspace) == "string" and workspace ~= "" then
    result[workspace] = true
  end
  return result
end

---@param headers? table<string, unknown>
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@param identity? Neoagent.RecordingSecrets
local function collect_header_secrets(headers, secrets, authentication,
    identity)
  headers = headers or {}
  local published = identity or {}
  local function register(value)
    if not published[value] then add_secret(secrets, value) end
  end
  for _, name in ipairs(sorted_keys(headers)) do
    local value = headers[name]
    local text = safe_string(value)
    if text ~= "" and sensitive_header(name) then
      register(text)
      local selected = normalized_key(name)
      if selected:find("cookie", 1, true) then
        local index = 0
        for part in text:gmatch("[^;]+") do
          local _, entry = part:match("^%s*([^=]+)=(.-)%s*$")
          index = index + 1
          if entry and entry ~= ""
              and (selected ~= "set_cookie" or index == 1) then
            register(entry)
          end
        end
      end
    elseif text ~= "" then
      collect_text_url_secrets(text, secrets, authentication)
    end
  end
end

---@param headers? table<string, unknown>
---@param secrets Neoagent.RecordingSecrets
---@param authentication? boolean
---@return table<string, string>
local function sanitize_headers(headers, secrets, authentication)
  headers = headers or {}
  local result = vim.empty_dict()
  for _, name in ipairs(sorted_keys(headers)) do
    local value = headers[name]
    local lower = type(name) == "string" and name:lower() or ""
    local text = safe_string(value)
    local selected_name = select(1, redact_text(
      safe_string(name), secrets))
    if text == "" then
      result[selected_name] = ""
    elseif sensitive_header(lower) then
      result[selected_name] = "*"
    elseif lower == "location" or lower == "content-location" then
      result[selected_name] = select(1,
        sanitize_url(text, secrets, authentication))
    else
      result[selected_name] = select(1,
        redact_text(text, secrets, authentication))
    end
  end
  return result
end

---@param context Neoagent.RequestIdentity
---@param secrets Neoagent.RecordingSecrets
---@return table<string, string>
local function sanitize_context(context, secrets)
  local result = vim.empty_dict()
  for _, key in ipairs({
    "agent_id", "auth_method", "model", "origin", "provider", "session_id",
  }) do
    if context[key] ~= nil then
      result[key] = select(1, redact_text(tostring(context[key]), secrets))
    end
  end
  return result
end

---@class Neoagent.RecordingSanitizer
---@field _secrets Neoagent.RecordingSecrets
---@field _identity Neoagent.RecordingSecrets
---@field _authentication boolean
---@field _format 'json'|'yaml'
---@field sensitive_response_body boolean
---@field context table<string, string>
---@field workspace? string
---@field request Neoagent.RecordedRequest
local Sanitizer = {}
Sanitizer.__index = Sanitizer

---@param request Neoagent.HttpRequest
---@param context Neoagent.RecordingContextData
---@param workspace? string
---@param format 'json'|'yaml'
---@return Neoagent.RecordingSanitizer
function M.new(request, context, workspace, format)
  local secrets = {}
  local authentication = context.origin == "authentication"
  local model_exchange = context.origin == "model"
  local credential_response_body = context.credential_response_body == true
  local identity = published_identity(context, workspace)
  local request_url = url_state(request.url)
  local request_body = model_exchange and raw_body_state(request.body)
    or body_state(request.body, request.headers)
  collect_url_secrets(request_url, secrets, authentication)
  collect_header_secrets(request.headers, secrets, authentication, identity)
  if not model_exchange then
    collect_body_secrets(request_body, secrets, authentication)
  end
  local sanitized_url = sanitize_url_state(
    request_url, secrets, authentication)
  local sanitized_headers = sanitize_headers(
    request.headers, secrets, authentication)
  local recorded_body, body_encoding, body_redacted
  if model_exchange then
    recorded_body, body_encoding = exact_body_state(request_body)
  else
    recorded_body, body_redacted = sanitize_body_state(
      request_body, secrets, authentication)
  end
  local decoded_request, request_is_json = json_body(
    recorded_body, request.headers, body_encoding)
  ---@type Neoagent.JsonValue?
  local persisted_request_body = recorded_body
  if format == "yaml" and request_is_json then
    persisted_request_body = decoded_request
  end
  return setmetatable({
    _secrets = secrets,
    _identity = identity,
    _authentication = authentication,
    _format = format,
    sensitive_response_body = credential_response_body,
    context = sanitize_context(context, secrets),
    workspace = workspace and select(1, redact_text(workspace, secrets)) or nil,
    request = {
      method = select(1, redact_text(
        tostring(request.method or "POST"), secrets)),
      url = sanitized_url,
      headers = sanitized_headers,
      body = persisted_request_body,
      body_encoding = body_encoding,
      body_format = request_is_json and "json" or nil,
      body_bytes = request_body.absent and 0 or #assert(request_body.body),
      redacted = body_redacted or nil,
      timeout_ms = request.timeout_ms,
      max_response_bytes = request.max_response_bytes,
    },
  }, Sanitizer)
end

---@class Neoagent.SanitizedRecordingResponse
---@field body Neoagent.RecordedBody
---@field headers table<string, string>
---@field ok boolean
---@field error? Neoagent.RecordedError

---@param raw_body string
---@param response Neoagent.RecordingResponse
---@param result unknown
---@return Neoagent.SanitizedRecordingResponse
function Sanitizer:response(raw_body, response, result)
  local successful = type(result) == "table" and result.ok == true
  ---@type Neoagent.HttpError?
  local normalized
  local detail_state
  if not successful then
    local source = type(result) == "table" and result.error or result
    normalized = util.normalize_error(source, "transport") --[[@as Neoagent.HttpError]]
    if normalized.detail then
      detail_state = self.sensitive_response_body
          and body_state(normalized.detail, {})
        or raw_body_state(normalized.detail)
    end
  end
  local response_body = self.sensitive_response_body
      and body_state(raw_body, response.headers)
    or raw_body_state(raw_body)
  collect_header_secrets(
    response.headers, self._secrets, self._authentication,
    self._identity)
  if self.sensitive_response_body then
    collect_body_secrets(
      response_body, self._secrets, self._authentication)
  end
  if self.sensitive_response_body and detail_state then
    collect_body_secrets(
      detail_state, self._secrets, self._authentication)
  end
  if self.sensitive_response_body then
    if raw_body ~= "" then add_secret(self._secrets, raw_body) end
    if normalized and normalized.detail and normalized.detail ~= "" then
      add_secret(self._secrets, normalized.detail)
    end
  end
  local response_headers = sanitize_headers(
    response.headers, self._secrets, self._authentication)
  local body, body_encoding, redacted
  if self.sensitive_response_body and raw_body ~= "" then
    body, redacted = "*", true
  else
    body, body_encoding = exact_body_state(response_body)
  end
  local decoded_response, response_is_json = json_body(
    body, response.headers, body_encoding)
  ---@type Neoagent.JsonValue?
  local persisted_response_body = body
  if self._format == "yaml" and response_is_json then
    persisted_response_body = decoded_response
  end
  ---@type Neoagent.SanitizedRecordingResponse
  local sanitized = {
    body = {
      body = persisted_response_body,
      body_encoding = body_encoding,
      body_format = response_is_json and "json" or nil,
      redacted = redacted or nil,
    },
    headers = response_headers,
    ok = successful,
  }
  if not successful then
    normalized = assert(normalized)
    local detail, detail_encoding
    if normalized.detail then
      if self.sensitive_response_body then
        detail = normalized.detail == "" and "" or "*"
      else
        detail, detail_encoding = exact_body_state((assert(detail_state)))
      end
    end
    sanitized.error = {
      kind = normalized.kind,
      message = select(1, redact_text(
        normalized.message, self._secrets, self._authentication)),
      detail = detail,
      detail_encoding = detail_encoding,
    }
    for _, key in ipairs({
      "code", "exit_code", "retry_after_ms", "retryable", "status",
    }) do
      local value = normalized[key]
      if type(value) == "number" or type(value) == "boolean"
          or type(value) == "string" then
        sanitized.error[key] = type(value) == "string"
          and select(1, redact_text(
            value, self._secrets, self._authentication)) or value
      end
    end
  end
  return sanitized
end

M.safe_string = safe_string
return M
