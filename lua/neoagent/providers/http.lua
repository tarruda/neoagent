local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local util = require("neoagent.util")

local M = {}
local DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024
local DEFAULT_TIMEOUT_MS = 15 * 1000

function M.new(opts)
  opts = opts or {}
  assert(type(opts.name) == "string" and opts.name ~= "",
    "provider HTTP client name is required")
  assert(type(opts.base_url) == "string" and opts.base_url ~= "",
    "provider HTTP client base_url is required")
  local transport = opts.transport or curl
  assert(type(transport) == "table" and type(transport.fetch) == "function",
    "provider HTTP client transport requires fetch")
  local maximum = opts.max_response_bytes or DEFAULT_MAX_RESPONSE_BYTES
  assert(type(maximum) == "number" and maximum >= 1024
      and maximum % 1 == 0,
    "provider HTTP max_response_bytes must be an integer of at least 1024")
  local timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS
  assert(type(timeout_ms) == "number" and timeout_ms > 0
      and timeout_ms < math.huge,
    "provider HTTP timeout_ms must be positive and finite")
  local base_url = opts.base_url:gsub("/+$", "")
  local client = {}

  function client:get(path, resource, headers)
    assert(type(path) == "string" and path:sub(1, 1) == "/",
      "provider HTTP path must be absolute")
    assert(type(resource) == "string" and resource ~= "",
      "provider HTTP resource is required")
    return async.run(function()
      local fetched = transport.fetch({ request = {
        url = base_url .. path,
        method = "GET",
        headers = util.copy(headers or {}),
        timeout_ms = timeout_ms,
        max_response_bytes = maximum,
      } }):await()
      if fetched.ok == false then
        error(util.normalize_error(fetched.error, "provider"), 0)
      end
      local status = tonumber(fetched.status)
      if not status then
        error(util.error("provider",
          opts.name .. " " .. resource .. " response has no HTTP status"), 0)
      end
      if status < 200 or status >= 300 then
        local message
        if type(opts.status_message) == "function" then
          message = opts.status_message(status, resource)
        end
        local err = util.error("provider", message or (opts.name .. " "
          .. resource .. " request failed (HTTP " .. tostring(status) .. ")"))
        err.status = status
        error(err, 0)
      end
      local body = fetched.body
      if type(body) ~= "string" then
        error(util.error("provider",
          opts.name .. " " .. resource .. " response body must be text"), 0)
      end
      if #body > maximum then
        error(util.error("provider", opts.name .. " " .. resource
          .. " response exceeds " .. tostring(maximum) .. " bytes"), 0)
      end
      local ok, decoded = pcall(vim.json.decode, body)
      if not ok or type(decoded) ~= "table" then
        error(util.error("provider",
          opts.name .. " " .. resource .. " response contains invalid JSON"), 0)
      end
      return { ok = true, value = decoded }
    end, { error_kind = "provider" })
  end

  return client
end

return M
