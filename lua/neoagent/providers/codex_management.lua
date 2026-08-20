local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local util = require("neoagent.util")

local M = {}

local DEFAULT_MAX_RESPONSE_BYTES = 512 * 1024
local DEFAULT_TIMEOUT_MS = 15 * 1000

local function clean_base_url(value)
  value = value:gsub("/+$", "")
  return value:gsub("/codex/responses$", ""):gsub("/codex$", "")
end

local function response_error(status)
  if status == 401 then
    return "Codex account request requires a ChatGPT login (HTTP 401)"
  end
  if status == 403 then
    return "Codex account request was denied (HTTP 403)"
  end
  return "Codex account request failed (HTTP " .. tostring(status) .. ")"
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.base_url) == "string" and opts.base_url ~= "",
    "Codex management base_url is required")
  local transport = opts.transport or curl
  assert(type(transport) == "table" and type(transport.fetch) == "function",
    "Codex management transport requires fetch")
  local maximum = opts.max_response_bytes or DEFAULT_MAX_RESPONSE_BYTES
  assert(type(maximum) == "number" and maximum >= 1024
      and maximum % 1 == 0,
    "Codex management max_response_bytes must be an integer of at least 1024")
  local timeout_ms = opts.timeout_ms == nil
    and DEFAULT_TIMEOUT_MS or opts.timeout_ms
  assert(type(timeout_ms) == "number" and timeout_ms > 0,
    "Codex management timeout_ms must be positive")
  local base_url = clean_base_url(opts.base_url)
  local client = {}

  local function request(ctx, path, method, body)
    return async.run(function()
      local resolved = ctx.resolve_auth():await()
      if resolved.ok == false then error(resolved.error, 0) end
      if resolved.configured ~= true then
        error(util.error("provider",
          "Sign in with ChatGPT to load Codex account information"), 0)
      end
      if resolved.credential_type ~= "oauth" then
        error(util.error("provider",
          "ChatGPT subscription login is required; API key authentication "
            .. "cannot load Codex account information"), 0)
      end
      local headers = util.copy(
        type(resolved.request_opts) == "table"
          and resolved.request_opts.headers or {})
      if body ~= nil then headers["Content-Type"] = "application/json" end
      local fetched = transport.fetch({ request = {
        url = base_url .. path,
        method = method or "GET",
        headers = headers,
        body = body and util.json_encode(body) or nil,
        timeout_ms = timeout_ms,
        max_response_bytes = maximum,
      } }):await()
      if fetched.ok == false then
        error(util.normalize_error(fetched.error, "provider"), 0)
      end
      local status = tonumber(fetched.status)
      if not status then
        error(util.error("provider",
          "Codex account response has no HTTP status"), 0)
      end
      if status < 200 or status >= 300 then
        local err = util.error("provider", response_error(status))
        err.status = status
        error(err, 0)
      end
      local response_body = fetched.body or ""
      if type(response_body) ~= "string" then
        error(util.error("provider",
          "Codex account response body must be text"), 0)
      end
      if #response_body > maximum then
        error(util.error("provider",
          "Codex account response exceeds " .. tostring(maximum)
            .. " bytes"), 0)
      end
      local ok, decoded = pcall(vim.json.decode, response_body)
      if not ok or type(decoded) ~= "table" or util.is_list(decoded) then
        error(util.error("provider",
          "Codex account response contains invalid JSON"), 0)
      end
      return {
        ok = true,
        value = decoded,
        metadata = util.copy(resolved.metadata or {}),
      }
    end, { error_kind = "provider" })
  end

  function client:usage(ctx)
    return request(ctx, "/wham/usage")
  end

  function client:activity(ctx)
    return request(ctx, "/wham/profiles/me")
  end

  function client:accounts(ctx)
    return request(ctx, "/wham/accounts/check")
  end

  function client:reset_credits(ctx)
    return request(ctx, "/wham/rate-limit-reset-credits")
  end

  function client:redeem(ctx, redeem_request_id, credit_id)
    assert(type(redeem_request_id) == "string" and redeem_request_id ~= "",
      "redeem_request_id is required")
    local body = { redeem_request_id = redeem_request_id }
    if credit_id ~= nil then
      assert(type(credit_id) == "string" and credit_id ~= "",
        "credit_id must be a non-empty string")
      body.credit_id = credit_id
    end
    return request(ctx, "/wham/rate-limit-reset-credits/consume",
      "POST", body)
  end

  return client
end

return M
