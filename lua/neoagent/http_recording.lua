local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local Recorder = {}
Recorder.__index = Recorder

local DIRECTORY_MODE = 448 -- 0700
local FILE_MODE = 384 -- 0600
local FORMAT_VERSION = 1
local DIAGNOSTIC_LIMIT = 1024
local global_sequence = 0

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

local function safe_string(value)
  if type(value) ~= "string" then
    value = value == nil and "" or tostring(value)
  end
  if util.is_valid_utf8(value) then return value end
  return "*"
end

local function report(self, message)
  if not self._report then return end
  local selected = safe_string(message):gsub("%s+", " ")
  if #selected > DIAGNOSTIC_LIMIT then
    selected = selected:sub(1, DIAGNOSTIC_LIMIT - 3) .. "..."
  end
  pcall(self._report, "neoagent: HTTP recording: " .. selected,
    vim.log.levels.ERROR)
end

local function pattern_escape(value)
  return (value:gsub("([^%w])", "%%%1"))
end

local function add_secret(secrets, value)
  if type(value) ~= "string" or value == "" or value == "*" then return end
  secrets[value] = true
  local bearer = value:match("^[Bb]earer%s+(.+)$")
    or value:match("^[Bb]asic%s+(.+)$")
  if bearer and bearer ~= "" then secrets[bearer] = true end
end

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

local collect_text_url_secrets
local sanitize_text_urls

local function redact_text(value, secrets, authentication, skip_urls)
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

local function normalized_key(value)
  return type(value) == "string"
      and value:lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", "")
        :gsub("_+$", "") or ""
end

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

local function uri_decode(value)
  local ok, decoded = pcall(vim.uri_decode, value)
  return ok and decoded or value
end

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

local function content_type(headers)
  for _, name in ipairs(sorted_keys(headers)) do
    local value = headers[name]
    if type(name) == "string" and name:lower() == "content-type" then
      return type(value) == "string" and value:lower() or ""
    end
  end
  return ""
end

local function parse_form(body)
  local parsed = {}
  for part in (body .. "&"):gmatch("(.-)&") do
    local key, value = part:match("^([^=]*)=(.*)$")
    parsed[#parsed + 1] = { raw = part, key = key, value = value }
  end
  return parsed
end

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

local function raw_body_state(body)
  if body == nil then return { absent = true } end
  if type(body) ~= "string" then body = tostring(body) end
  return {
    body = body,
    valid_utf8 = util.is_valid_utf8(body),
  }
end

local function body_state(body, headers)
  local state = raw_body_state(body)
  if state.absent then return state end
  state.content_type = content_type(headers)
  if not state.valid_utf8 then return state end
  if state.content_type:find(
      "application/x%-www%-form%-urlencoded") then
    state.form = parse_form(body)
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

local function exact_body_state(state)
  if state.absent then return nil, nil end
  if state.valid_utf8 then return state.body, nil end
  return vim.base64.encode(state.body), "base64"
end

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

local function parse_parameters(value)
  local result = {}
  for part in (value .. "&"):gmatch("(.-)&") do
    local key, entry = part:match("^([^=]*)=(.*)$")
    result[#result + 1] = { raw = part, key = key, value = entry }
  end
  return result
end

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

local function collect_header_secrets(headers, secrets, authentication)
  for _, name in ipairs(sorted_keys(headers)) do
    local value = headers[name]
    local text = safe_string(value)
    if text ~= "" and sensitive_header(name) then
      add_secret(secrets, text)
      local selected = normalized_key(name)
      if selected:find("cookie", 1, true) then
        local index = 0
        for part in text:gmatch("[^;]+") do
          local _, entry = part:match("^%s*([^=]+)=(.-)%s*$")
          index = index + 1
          if entry and entry ~= ""
              and (selected ~= "set_cookie" or index == 1) then
            add_secret(secrets, entry)
          end
        end
      end
    elseif text ~= "" then
      collect_text_url_secrets(text, secrets, authentication)
    end
  end
end

local function sanitize_headers(headers, secrets, authentication)
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

local function iso_timestamp(milliseconds)
  local seconds = math.floor(milliseconds / 1000)
  return os.date("!%Y-%m-%dT%H:%M:%S", seconds)
    .. string.format(".%03dZ", milliseconds % 1000)
end

local function filename_timestamp(milliseconds)
  local seconds = math.floor(milliseconds / 1000)
  return os.date("!%Y%m%dT%H%M%S", seconds)
    .. string.format(".%03dZ", milliseconds % 1000)
end

local function slug(value)
  local selected = safe_string(value):gsub("[^%w._-]+", "-")
    :gsub("^-+", ""):gsub("-+$", "")
  if selected == "" then selected = "workspace" end
  if #selected > 48 then selected = selected:sub(1, 48) end
  return selected
end

local function ensure_directory(path)
  local ok, err = fs.ensure_private_directory(path, DIRECTORY_MODE)
  if not ok then return nil, err end
  return true
end

local function default_yq()
  return {
    available = function()
      if vim.fn.executable("yq") ~= 1 then return false end
      local result = vim.system({ "yq", "--version" }, { text = true }):wait(2000)
      local version = ((result and result.stdout) or ""):lower()
      local major = version:find("version v4", 1, true)
        or version:find("version 4", 1, true)
      return result and result.code == 0
        and (version:find("mikefarah", 1, true) ~= nil
          or version:find("github.com/mikefarah/yq", 1, true) ~= nil)
        and major ~= nil
    end,
    convert = function(path, done)
      return vim.system({ "yq", "-p=json", "-o=yaml", "-P", ".", path }, {
        text = false,
      }, function(result)
        if result.code == 0 and type(result.stdout) == "string" then
          done(result.stdout, nil)
        else
          done(nil, "yq conversion failed with status "
            .. tostring(result and result.code or "unknown"))
        end
      end)
    end,
  }
end

local function context_value(value)
  if type(value) == "function" then
    local ok, selected = pcall(value)
    return ok and type(selected) == "table" and selected or {}
  end
  return type(value) == "table" and value or {}
end

local function merge_context(left, right)
  local result = util.copy(context_value(left))
  for key, value in pairs(context_value(right)) do result[key] = value end
  return result
end

function Recorder:_append(exchange, event)
  if exchange.failed or exchange.closed then return false end
  local ok, encoded = pcall(util.json_encode, event)
  if not ok then
    exchange.failed = true
    report(self, "failed to encode exchange " .. exchange.id)
    return false
  end
  local data = encoded .. "\n"
  local written, err = exchange.file:append(data, exchange.offset)
  if not written then
    exchange.failed = true
    report(self, "failed to append exchange " .. exchange.id .. ": "
      .. tostring(err))
    return false
  end
  exchange.offset = exchange.offset + #data
  return true
end

function Recorder:_at(exchange)
  return math.max(0, math.floor((self._hrtime() - exchange.started_ns) / 1000))
end

function Recorder:_start(operation, request, supplied_context)
  if self._destroyed then return nil end
  local context = merge_context(self._context, supplied_context)
  local workspace
  if context.workspace ~= nil then
    assert(type(context.workspace) == "string" and context.workspace ~= "",
      "recording context workspace must be a non-empty string")
    workspace = fs.canonical(context.workspace)
  end
  local secrets = {}
  local authentication = context.origin == "authentication"
  local model_exchange = context.origin == "model"
  local credential_response_body = context.credential_response_body == true
  local request_url = url_state(request.url)
  local request_body = model_exchange and raw_body_state(request.body)
    or body_state(request.body, request.headers)
  collect_url_secrets(request_url, secrets, authentication)
  collect_header_secrets(request.headers, secrets, authentication)
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
  global_sequence = global_sequence + 1
  local sequence = global_sequence
  local now = math.floor(self._now())
  local selected_context = sanitize_context(context, secrets)
  local provider = slug(selected_context.provider
    or selected_context.auth_method or "http")
  local scope_directory
  local directories = { self._directory }
  local workspace_directory
  if workspace then
    local workspaces_directory = fs.join(self._directory, "workspaces")
    workspace_directory = require("neoagent.workspace_settings").new({
      directory = workspaces_directory,
      root = workspace,
    }).directory
    scope_directory = fs.join(workspace_directory, "recordings")
    directories[#directories + 1] = workspaces_directory
    directories[#directories + 1] = workspace_directory
  else
    local providers_directory = fs.join(
      self._directory, "provider-recordings")
    scope_directory = fs.join(providers_directory, provider)
    directories[#directories + 1] = providers_directory
  end
  directories[#directories + 1] = scope_directory
  local day_directory = fs.join(scope_directory,
    os.date("!%Y-%m-%d", math.floor(now / 1000)))
  directories[#directories + 1] = day_directory
  local ok, err = true
  for _, directory in ipairs(directories) do
    ok, err = ensure_directory(directory)
    if not ok then break end
  end
  if not ok then
    report(self, "failed to create recording directory: " .. tostring(err))
    return nil
  end
  local index_path = workspace_directory
      and fs.join(workspace_directory, "workspace.json") or nil
  if index_path and not vim.uv.fs_stat(index_path) then
    local indexed = fs.atomic_replace(index_path, util.json_encode({
      version = FORMAT_VERSION,
      root = select(1, redact_text(workspace, secrets)),
    }) .. "\n", { mode = FILE_MODE })
    if not indexed then
      report(self, "failed to write Workspace recording index")
    end
  end
  local origin = slug(selected_context.origin or operation)
  local base = string.format("%s-%06d-%08d-%s-%s",
    filename_timestamp(now), vim.uv.os_getpid(), sequence, provider, origin)
  local extension = self._format == "yaml" and ".yaml" or ".jsonl"
  local final_path = fs.join(day_directory, base .. extension)
  local stage_path = fs.join(day_directory, base .. ".partial.ndjson")
  local first = {
    schema = "neoagent-http-recording",
    version = FORMAT_VERSION,
    type = "exchange",
    id = tostring(vim.uv.os_getpid()) .. "-" .. tostring(sequence),
    sequence = sequence,
    started_at = iso_timestamp(now),
    operation = operation,
    workspace = workspace
      and { root = select(1, redact_text(workspace, secrets)) } or nil,
    context = selected_context,
    request = {
      method = select(1, redact_text(
        tostring(request.method or "POST"), secrets)),
      url = sanitized_url,
      headers = sanitized_headers,
      body = recorded_body,
      body_encoding = body_encoding,
      body_bytes = request_body.absent and 0 or #request_body.body,
      redacted = body_redacted or nil,
      timeout_ms = request.timeout_ms,
      max_response_bytes = request.max_response_bytes,
    },
  }
  local encoded_ok, encoded = pcall(util.json_encode, first)
  if not encoded_ok then
    report(self, "failed to encode a recording header")
    return nil
  end
  local created, create_err = fs.atomic_replace(
    stage_path, encoded .. "\n", { mode = FILE_MODE })
  if not created then
    report(self, "failed to create a recording: " .. tostring(create_err))
    return nil
  end
  local file, open_err = fs.open_regular(stage_path, { mode = FILE_MODE })
  if not file then
    pcall(vim.uv.fs_unlink, stage_path)
    report(self, "failed to open a recording: " .. tostring(open_err))
    return nil
  end
  local exchange = {
    id = first.id,
    sequence = sequence,
    started_ns = self._hrtime(),
    stage_path = stage_path,
    final_path = final_path,
    file = file,
    offset = #encoded + 1,
    chunks = {},
    secrets = secrets,
    authentication = authentication,
    credential_response_body = credential_response_body,
    failed = false,
    closed = false,
    finished = false,
  }
  self._exchanges[exchange] = true
  return exchange
end

function Recorder:_chunk(exchange, data, at_us)
  if not exchange or exchange.finished then return end
  local chunk = type(data) == "string" and data or tostring(data or "")
  local event = {
    type = "response_chunk",
    index = #exchange.chunks + 1,
    at_us = at_us or self:_at(exchange),
    bytes = #chunk,
  }
  exchange.chunks[#exchange.chunks + 1] = chunk
  self:_append(exchange, event)
end

function Recorder:_conversion_done(exchange, output)
  if output then
    local written, write_err = fs.atomic_replace(
      exchange.final_path, output, { mode = FILE_MODE })
    if written then
      pcall(vim.uv.fs_unlink, exchange.stage_path)
    else
      report(self, "failed to write YAML recording " .. exchange.id .. ": "
        .. tostring(write_err))
    end
  else
    report(self, "failed to convert recording " .. exchange.id)
  end
  self._pending_conversions = math.max(0, self._pending_conversions - 1)
end

function Recorder:_publish(exchange)
  if self._format == "json" then
    local moved, err = vim.uv.fs_rename(exchange.stage_path, exchange.final_path)
    if not moved then
      report(self, "failed to publish recording " .. exchange.id .. ": "
        .. tostring(err))
    end
    return
  end
  self._pending_conversions = self._pending_conversions + 1
  local settled = false
  local function done(output, err)
    if settled then return end
    settled = true
    self:_conversion_done(exchange, output, err)
  end
  local ok, conversion_err = pcall(
    self._yq.convert, exchange.stage_path, done)
  if not ok then done(nil, conversion_err) end
end

local function response_from(result, operation)
  if type(result) ~= "table" then return nil end
  if operation == "fetch" then
    if result.status ~= nil or result.headers ~= nil or result.body ~= nil then
      return {
        status = result.status,
        headers = result.headers or {},
        body = result.body,
      }
    end
    if type(result.error) == "table"
        and type(result.error.response) == "table" then
      return result.error.response
    end
    return nil
  end
  if type(result.response) == "table" then return result.response end
  if type(result.error) == "table"
      and type(result.error.response) == "table" then
    return result.error.response
  end
end

function Recorder:_finish(exchange, result, operation)
  if not exchange or exchange.finished then return end
  local settled_at = self:_at(exchange)
  local response = response_from(result, operation) or {}
  if operation == "fetch" and type(response.body) == "string" then
    self:_chunk(exchange, response.body, settled_at)
  elseif operation == "request" and #exchange.chunks == 0 then
    local body = type(response.body) == "string" and response.body
      or type(response.stdout) == "string" and response.stdout or nil
    if body then self:_chunk(exchange, body, settled_at) end
  end
  exchange.finished = true
  local raw = {}
  for _, chunk in ipairs(exchange.chunks) do raw[#raw + 1] = chunk end
  local raw_body = table.concat(raw)
  local successful = type(result) == "table" and result.ok == true
  local normalized
  local detail_state
  if not successful then
    local source = type(result) == "table" and result.error or result
    normalized = util.normalize_error(source, "transport")
    if normalized.detail then
      detail_state = exchange.credential_response_body
          and body_state(normalized.detail, {})
        or raw_body_state(normalized.detail)
    end
  end
  local response_body = exchange.credential_response_body
      and body_state(raw_body, response.headers)
    or raw_body_state(raw_body)
  collect_header_secrets(
    response.headers, exchange.secrets, exchange.authentication)
  if exchange.credential_response_body then
    collect_body_secrets(
      response_body, exchange.secrets, exchange.authentication)
  end
  if exchange.credential_response_body and detail_state then
    collect_body_secrets(
      detail_state, exchange.secrets, exchange.authentication)
  end
  if exchange.credential_response_body then
    if raw_body ~= "" then add_secret(exchange.secrets, raw_body) end
    if normalized and normalized.detail and normalized.detail ~= "" then
      add_secret(exchange.secrets, normalized.detail)
    end
  end
  local response_headers = sanitize_headers(
    response.headers, exchange.secrets, exchange.authentication)
  local body, body_encoding, redacted
  if exchange.credential_response_body and raw_body ~= "" then
    body, redacted = "*", true
  else
    body, body_encoding = exact_body_state(response_body)
  end
  self:_append(exchange, {
    type = "response_body",
    at_us = settled_at,
    body = body,
    body_encoding = body_encoding,
    bytes = #raw_body,
    redacted = redacted or nil,
  })
  self:_append(exchange, {
    type = "response",
    at_us = settled_at,
    status = response.status,
    headers = response_headers,
  })
  local completion = {
    type = "complete",
    at_us = settled_at,
    ok = successful,
  }
  if not successful then
    local detail, detail_encoding
    if normalized.detail then
      if exchange.credential_response_body then
        detail = normalized.detail == "" and "" or "*"
      else
        detail, detail_encoding = exact_body_state(detail_state)
      end
    end
    completion.error = {
      kind = normalized.kind,
      message = select(1, redact_text(
        normalized.message, exchange.secrets, exchange.authentication)),
      detail = detail,
      detail_encoding = detail_encoding,
    }
    for _, key in ipairs({
      "code", "exit_code", "retry_after_ms", "retryable", "status",
    }) do
      local value = normalized[key]
      if type(value) == "number" or type(value) == "boolean"
          or type(value) == "string" then
        completion.error[key] = type(value) == "string"
          and select(1, redact_text(
            value, exchange.secrets, exchange.authentication)) or value
      end
    end
  end
  self:_append(exchange, completion)
  local verified = exchange.file:verify_path()
  local closed, close_err = exchange.file:close()
  exchange.closed = true
  self._exchanges[exchange] = nil
  if exchange.failed or not verified or not closed then
    report(self, "failed to close recording " .. exchange.id .. ": "
      .. tostring(close_err or "path identity changed"))
    return
  end
  self:_publish(exchange)
end

local function shallow_copy(value)
  local result = {}
  for key, entry in pairs(value or {}) do result[key] = entry end
  return result
end

function Recorder:transport(base, context)
  assert(type(base) == "table", "recording transport is required")
  local recorder = self
  local function wrap(operation)
    if type(base[operation]) ~= "function" then return nil end
    return function(opts)
      opts = opts or {}
      local selected = shallow_copy(opts)
      local request = assert(opts.request, "request is required")
      local recorded, exchange = pcall(
        recorder._start, recorder, operation, request, context)
      if not recorded then
        report(recorder, "failed to start an exchange")
        exchange = nil
      end
      local on_chunk, on_done = opts.on_chunk, opts.on_done
      if operation == "request" then
        selected.on_chunk = function(chunk)
          local ok = pcall(recorder._chunk, recorder, exchange, chunk)
          if not ok then report(recorder, "failed to record a response chunk") end
          if on_chunk then return on_chunk(chunk) end
        end
      end
      selected.on_done = nil
      local started, child = pcall(base[operation], selected)
      if not started then
        local ok = pcall(recorder._finish, recorder, exchange, {
          ok = false,
          error = util.normalize_error(child, "transport"),
        }, operation)
        if not ok then report(recorder, "failed to finish an exchange") end
        error(child, 0)
      end
      return async.run(function()
        local settled, result = pcall(function() return child:await() end)
        if not settled then
          local failure = {
            ok = false,
            error = util.normalize_error(result, "transport"),
          }
          local ok = pcall(
            recorder._finish, recorder, exchange, failure, operation)
          if not ok then report(recorder, "failed to finish an exchange") end
          error(failure.error, 0)
        end
        local ok = pcall(
          recorder._finish, recorder, exchange, result, operation)
        if not ok then report(recorder, "failed to finish an exchange") end
        return result
      end, { on_done = on_done, error_kind = "transport" })
    end
  end
  local wrapped = {
    request = wrap("request"),
    fetch = wrap("fetch"),
  }
  wrapped.with_context = function(extra)
    return recorder:transport(base, merge_context(context, extra))
  end
  return wrapped
end

function Recorder:format()
  return self._format
end

function Recorder:destroy()
  if self._destroyed then return false end
  self._destroyed = true
  local active = {}
  for exchange in pairs(self._exchanges) do active[#active + 1] = exchange end
  for _, exchange in ipairs(active) do
    self:_finish(exchange, {
      ok = false,
      error = util.error("cancelled", "Recording owner was destroyed"),
    }, "request")
  end
  if self._pending_conversions > 0 then
    vim.wait(5000, function() return self._pending_conversions == 0 end, 10)
  end
  return true
end

function M.new(opts)
  opts = opts or {}
  local selected = opts.config or { enabled = false, format = "auto" }
  assert(type(selected) == "table", "recording configuration is required")
  if selected.enabled ~= true then return nil end
  local yq = opts.yq or default_yq()
  local available = false
  local requested = selected.format or "auto"
  assert(requested == "auto" or requested == "yaml" or requested == "json",
    "recording format must be auto, yaml, or json")
  if requested ~= "json" then
    local ok, value = pcall(yq.available)
    if ok then available = value == true end
  end
  local format = requested == "json" and "json"
    or requested == "yaml" and "yaml"
    or available and "yaml" or "json"
  if format == "yaml" and not available then
    return nil, util.error("configuration",
      "recording.format is yaml but a compatible yq v4 is unavailable")
  end
  return setmetatable({
    _format = format,
    _directory = fs.normalize(opts.directory
      or selected.directory
      or vim.fn.stdpath("state") .. "/neoagent"),
    _context = opts.context,
    _report = opts.report,
    _now = opts.now or util.now_ms,
    _hrtime = opts.hrtime or vim.uv.hrtime,
    _yq = yq,
    _exchanges = {},
    _pending_conversions = 0,
    _destroyed = false,
  }, Recorder)
end

return M
