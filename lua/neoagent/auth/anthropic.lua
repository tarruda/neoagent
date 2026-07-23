local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local util = require("neoagent.util")

local M = {}

local CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
local AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
local TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
local REDIRECT_URI = "http://localhost:53692/callback"
local SCOPES = table.concat({
  "org:create_api_key",
  "user:profile",
  "user:inference",
  "user:sessions:claude_code",
  "user:mcp_servers",
  "user:file_upload",
}, " ")

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

local function parse_authorization(value)
  value = util.trim(value or "")
  local query = value:match("^[^?]+%?([^#]+)")
  if query then return decode_fields(query) end
  local code, state = value:match("^([^#]+)#(.+)$")
  if code then return { code = code, state = state } end
  if value:find("code=", 1, true) then return decode_fields(value) end
  return { code = value ~= "" and value or nil }
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

local function start_callback_server(expected_state, host, port, path)
  local server = vim.uv.new_tcp()
  local bound, bind_err = server:bind(host, port)
  if not bound then close_handle(server) return nil, bind_err end
  local waiter, pending
  local listened, listen_err = server:listen(16, function(err)
    if err then return end
    local client = vim.uv.new_tcp()
    if not server:accept(client) then close_handle(client) return end
    local buffer = ""
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then close_handle(client) return end
      buffer = buffer .. chunk
      if not buffer:find("\r\n\r\n", 1, true) and #buffer < 16384 then return end
      client:read_stop()
      local target = buffer:match("^GET%s+(%S+)") or ""
      local callback_path, query = target:match("^([^?]+)%??(.*)$")
      local fields = decode_fields(query)
      if callback_path ~= path then
        reply(client, "404 Not Found", "Callback route not found.")
      elseif fields.state ~= expected_state then
        reply(client, "400 Bad Request", "State mismatch.")
      elseif not fields.code or fields.code == "" then
        reply(client, "400 Bad Request", "Missing authorization code.")
      else
        reply(client, "200 OK", "Anthropic authentication completed. You can close this window.")
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

function M.new(opts)
  opts = opts or {}
  local http = opts.http or curl
  local now = opts.now or util.now_ms
  local authorize_url = opts.authorize_url or AUTHORIZE_URL
  local token_url = opts.token_url or TOKEN_URL
  local redirect_uri = opts.redirect_uri or REDIRECT_URI
  local callback_host = opts.callback_host or "127.0.0.1"
  local callback_port = opts.callback_port or 53692
  local callback_path = opts.callback_path or "/callback"
  local start_server = opts.start_callback_server or start_callback_server

  local function post(body)
    local result = http.fetch({ request = {
      url = token_url,
      headers = { ["Content-Type"] = "application/json", Accept = "application/json" },
      body = vim.json.encode(body),
    } }):await()
    if not result.ok then error(result.error, 0) end
    local decoded, value = pcall(vim.json.decode, result.body or "")
    if result.status < 200 or result.status >= 300 then
      local detail
      if decoded and type(value) == "table" then
        detail = type(value.error) == "table" and value.error.message or value.error
      end
      error(util.error("auth", "Anthropic authentication failed (HTTP " .. result.status .. ")", detail), 0)
    end
    if not decoded or type(value) ~= "table" then
      error(util.error("auth", "Anthropic returned invalid JSON"), 0)
    end
    return value
  end

  local function credential(value)
    if type(value.access_token) ~= "string" or value.access_token == ""
        or type(value.refresh_token) ~= "string" or value.refresh_token == ""
        or type(value.expires_in) ~= "number" then
      error(util.error("auth", "Anthropic token response is missing fields"), 0)
    end
    return {
      type = "oauth",
      access = value.access_token,
      refresh = value.refresh_token,
      expires = now() + value.expires_in * 1000 - 5 * 60 * 1000,
    }
  end

  local function exchange(code, state, verifier)
    return credential(post({
      grant_type = "authorization_code",
      client_id = CLIENT_ID,
      code = code,
      state = state,
      redirect_uri = redirect_uri,
      code_verifier = verifier,
    }))
  end

  local function login(interaction, mode)
    local verifier = random_urlsafe(32)
    local challenge = base64url(hex_bytes(vim.fn.sha256(verifier)))
    local url = authorize_url .. "?" .. encode_fields({
      code = "true",
      client_id = CLIENT_ID,
      response_type = "code",
      redirect_uri = redirect_uri,
      scope = SCOPES,
      code_challenge = challenge,
      code_challenge_method = "S256",
      state = verifier,
    })
    local server
    if mode == "browser" then
      local server_err
      server, server_err = start_server(verifier, callback_host, callback_port, callback_path)
      if not server then
        error(util.error("auth", "Failed to start Anthropic callback server", server_err), 0)
      end
    end
    interaction.notify({
      type = "auth_url",
      url = url,
      instructions = mode == "browser"
        and "Complete login in your browser to finish."
        or "Complete login, then paste the authorization code or final redirect URL.",
    })

    local code, state
    if server then
      local waited, value = pcall(server.wait)
      server.close()
      if not waited then error(value, 0) end
      code, state = value, verifier
    else
      local input = await_prompt(interaction, {
        type = "manual_code",
        message = "Paste the authorization code or redirect URL:",
        placeholder = redirect_uri,
      })
      local parsed = parse_authorization(input)
      if parsed.state and parsed.state ~= verifier then
        error(util.error("auth", "OAuth state mismatch"), 0)
      end
      code, state = parsed.code, parsed.state or verifier
    end
    if type(code) ~= "string" or code == "" then
      error(util.error("auth", "Missing authorization code"), 0)
    end
    interaction.notify({ type = "progress", message = "Exchanging authorization code for tokens..." })
    return exchange(code, state, verifier)
  end

  return {
    type = "oauth",
    name = "Anthropic (Claude Pro/Max)",
    login = function(interaction)
      return async.run(function()
        local mode = await_prompt(interaction, {
          type = "select",
          message = "Select Anthropic login method:",
          options = {
            { id = "browser", label = "Browser callback (default)" },
            { id = "manual", label = "Paste code or redirect URL (headless)" },
          },
        })
        if mode ~= "browser" and mode ~= "manual" then
          error(util.error("auth", "Unknown Anthropic login method: " .. tostring(mode)), 0)
        end
        return { ok = true, credential = login(interaction, mode) }
      end, { error_kind = "auth" })
    end,
    refresh = function(current)
      return async.run(function()
        return { ok = true, credential = credential(post({
          grant_type = "refresh_token",
          client_id = CLIENT_ID,
          refresh_token = current.refresh,
        })) }
      end, { error_kind = "auth" })
    end,
    request_opts = function(current)
      return { headers = {
        Authorization = "Bearer " .. current.access,
        Accept = "application/json",
        ["anthropic-beta"] = table.concat({
          "claude-code-20250219",
          "oauth-2025-04-20",
          "interleaved-thinking-2025-05-14",
        }, ","),
        ["anthropic-dangerous-direct-browser-access"] = "true",
        ["User-Agent"] = "claude-cli/2.1.75",
        ["x-app"] = "cli",
      } }
    end,
  }
end

return M
