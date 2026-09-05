local async = require("neoagent.async")
local local_callback = require("neoagent.auth.local_callback")
local util = require("neoagent.util")

local M = {}

local CONSOLE_ORIGIN = "https://modelstudio.console.alibabacloud.com"
local CALLBACK_TIMEOUT_MS = 15 * 60 * 1000

local function decode_fields(value)
  local result = {}
  for pair in (value or ""):gmatch("[^&]+") do
    local key, item = pair:match("^([^=]+)=?(.*)$")
    if key then
      result[vim.uri_decode(key:gsub("+", " "))] =
        vim.uri_decode(item:gsub("+", " "))
    end
  end
  return result
end

local function random_state()
  return (vim.uv.random(16):gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end))
end

local function field_from_object(value, names)
  if type(value) ~= "table" or util.is_list(value) then return nil end
  for _, name in ipairs(names) do
    local field = value[name]
    if type(field) == "string" and util.trim(field) ~= "" then
      return util.trim(field)
    end
  end
  return field_from_object(value.data, names)
end

local function field_from_multipart(body, content_type, names)
  local boundary = content_type:match(
    '[Bb][Oo][Uu][Nn][Dd][Aa][Rr][Yy]%s*=%s*"([^";]+)"')
    or content_type:match(
      "[Bb][Oo][Uu][Nn][Dd][Aa][Rr][Yy]%s*=%s*([^;%s]+)")
  if not boundary then return nil end
  local delimiter = "--" .. boundary
  local position = 1
  while true do
    local first = body:find(delimiter, position, true)
    if not first then break end
    local following = first + #delimiter
    local next_part = body:find(delimiter, following, true)
    if not next_part then break end
    local part = body:sub(following, next_part - 1)
    local lower = part:lower()
    local selected = false
    for _, name in ipairs(names) do
      local lower_name = name:lower()
      if lower:find('name="' .. lower_name .. '"', 1, true)
          or lower:find("name='" .. lower_name .. "'", 1, true) then
        selected = true
        break
      end
    end
    if selected then
      local value = part:match("\r\n\r\n(.*)") or part:match("\n\n(.*)")
      value = value and util.trim(value:gsub("[\r\n]+$", "")) or nil
      if value and value ~= "" then return value end
    end
    position = next_part
  end
end

local ACCESS_NAMES = { "access_token", "accessToken" }

local function access_token_from_request(request)
  local result = field_from_object(decode_fields(
    request.target:match("%?(.*)$") or ""), ACCESS_NAMES)
  local content_type = request.headers["content-type"] or ""
  if content_type:lower():find("multipart/form-data", 1, true) then
    result = result or field_from_multipart(
      request.body, content_type, ACCESS_NAMES)
  elseif content_type:lower():find("json", 1, true)
      or request.body:match("^%s*{") then
    local ok, decoded = pcall(vim.json.decode, request.body)
    if ok then
      result = result or field_from_object(decoded, ACCESS_NAMES)
    end
  else
    result = result or field_from_object(
      decode_fields(request.body), ACCESS_NAMES)
  end
  return result
end

local function callback_server(expected_state, host)
  return local_callback.listen({
    host = host,
    port = 0,
    timeout_ms = CALLBACK_TIMEOUT_MS,
    max_request_bytes = 65536,
    handler = function(request)
      if request.method == "OPTIONS" then
        return { status = 204, headers = {
          ["Access-Control-Allow-Origin"] = "*",
          ["Access-Control-Allow-Methods"] =
            "GET, POST, PUT, PATCH, OPTIONS",
          ["Access-Control-Allow-Headers"] = "Content-Type",
        } }
      end
      if request.method ~= "GET" and request.method ~= "POST"
          and request.method ~= "PUT" and request.method ~= "PATCH" then
        return { status = 404, body = "Callback route not found.\n" }
      end
      local fields = decode_fields(request.target:match("%?(.*)$") or "")
      if fields.state ~= expected_state then
        return { status = 400, body = "State mismatch.\n" }
      end
      local access = access_token_from_request(request)
      if not access then
        return { status = 400, body = "Missing console access token.\n" }
      end
      return {
        status = 200,
        body = "Alibaba Cloud authentication completed. "
          .. "You can close this window.\n",
        headers = { ["Access-Control-Allow-Origin"] = "*" },
        done = true,
        value = access,
      }
    end,
  })
end

function M.new(opts)
  opts = opts or {}
  local state_source = opts.random_state or random_state
  local start_server = opts.start_callback_server or callback_server
  local callback_host = opts.callback_host or "127.0.0.1"
  local console_origin = opts.console_origin or CONSOLE_ORIGIN

  return {
    type = "api_key",
    name = "Alibaba Cloud dashboard",
    login_label = "Login to dashboard (optional to see quotas)",
    logout_label = "Logout from dashboard",
    login = function(interaction)
      return async.run(function()
        local state = state_source()
        if type(state) ~= "string" or state == "" then
          error(util.error("auth",
            "Failed to create console login state"), 0)
        end
        local server, listen_err = start_server(state, callback_host)
        if not server then
          error(util.error("auth",
            "Could not start Alibaba Cloud console login callback",
            tostring(listen_err or "listener unavailable")), 0)
        end
        local url = console_origin .. "/console-login?notice="
          .. callback_host .. ":" .. tostring(server.port)
          .. "?state=" .. vim.uri_encode(state, "rfc2396")
        interaction.notify({
          type = "auth_url",
          url = url,
          instructions =
            "Complete Alibaba Cloud dashboard login in your browser.",
        })
        local ok, access = pcall(server.wait)
        server.close()
        if not ok then error(access, 0) end
        access = type(access) == "string" and util.trim(access) or ""
        if access == "" then
          error(util.error("auth",
            "Alibaba Cloud dashboard login returned no access token"), 0)
        end
        return { ok = true, credential = {
          type = "api_key",
          key = access,
        } }
      end, { error_kind = "auth" })
    end,
    request_opts = function(credential)
      local access = type(credential.key) == "string"
          and util.trim(credential.key) or ""
      if access == "" then
        error(util.error("auth",
          "Alibaba Cloud dashboard authorization is unavailable"), 0)
      end
      return { headers = { Authorization = "Bearer " .. access } }
    end,
  }
end

return M
