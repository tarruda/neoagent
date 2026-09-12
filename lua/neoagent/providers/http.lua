local async = require("neoagent.async")
local http_client = require("neoagent.transport.http")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.ProviderHttpOptions
---@field name string
---@field base_url string
---@field transport? Neoagent.ByteBackend
---@field max_response_bytes? integer
---@field timeout_ms? number
---@field status_message? fun(status: number, resource: string): string?

---@class Neoagent.ProviderHttpSuccess
---@field ok true
---@field value Neoagent.JsonObject|Neoagent.JsonArray

---@alias Neoagent.ProviderHttpResult Neoagent.ProviderHttpSuccess|Neoagent.AsyncFailure

---@class Neoagent.ProviderHttpError: Neoagent.Error
---@field status? number

---@class Neoagent.ProviderHttpServiceOptions
---@field timeout_ms? integer
---@field max_response_bytes? integer

---@param value unknown
---@param provider string
---@return Neoagent.ProviderHttpServiceOptions
function M.service_options(value, provider)
  value = value or {}
  assert(
    type(value) == "table" and (next(value) == nil or not util.is_list(value)),
    provider .. " service_opts must be an object"
  )
  local allowed = { timeout_ms = true, max_response_bytes = true }
  for name, setting in pairs(value) do
    assert(allowed[name], "unknown " .. provider .. " service option: " .. tostring(name))
    assert(
      type(setting) == "number" and setting > 0 and setting < math.huge and setting % 1 == 0,
      provider .. " service option " .. name .. " must be a positive integer"
    )
  end
  ---@cast value Neoagent.ProviderHttpServiceOptions
  return util.copy(value)
end

local DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024
local DEFAULT_TIMEOUT_MS = 15 * 1000

---@param opts Neoagent.ProviderHttpOptions
---@return Neoagent.ProviderHttpClient
function M.new(opts)
  opts = opts or {}
  assert(type(opts.name) == "string" and opts.name ~= "", "provider HTTP client name is required")
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "provider HTTP client base_url is required")
  local transport = http_client.new(opts.transport)
  assert(
    opts.transport == nil or type(opts.transport) == "table" and type(opts.transport.fetch) == "function",
    "provider HTTP client transport requires fetch"
  )
  local maximum = opts.max_response_bytes or DEFAULT_MAX_RESPONSE_BYTES
  assert(
    type(maximum) == "number" and maximum >= 1024 and maximum % 1 == 0,
    "provider HTTP max_response_bytes must be an integer of at least 1024"
  )
  local timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS
  assert(
    type(timeout_ms) == "number" and timeout_ms > 0 and timeout_ms < math.huge,
    "provider HTTP timeout_ms must be positive and finite"
  )
  local base_url = opts.base_url:gsub("/+$", "")
  ---@class Neoagent.ProviderHttpClient
  local client = {}

  ---@param path string
  ---@param resource string
  ---@param headers? table<string, unknown>
  ---@return Neoagent.Run<Neoagent.ProviderHttpResult, nil>
  function client:get(path, resource, headers)
    assert(type(path) == "string" and path:sub(1, 1) == "/", "provider HTTP path must be absolute")
    assert(type(resource) == "string" and resource ~= "", "provider HTTP resource is required")
    return async.run(
      ---@return Neoagent.ProviderHttpSuccess
      function()
        local fetched = transport
          .fetch({
            request = {
              url = base_url .. path,
              method = "GET",
              headers = util.copy(headers or {}),
              timeout_ms = timeout_ms,
              max_response_bytes = maximum,
            },
          })
          :await()
        if fetched.ok == false then
          error(util.normalize_error(fetched.error, "provider"), 0)
        end
        local status = tonumber(fetched.status)
        if not status then
          error(util.error("provider", opts.name .. " " .. resource .. " response has no HTTP status"), 0)
        end
        if status < 200 or status >= 300 then
          local message
          if type(opts.status_message) == "function" then
            message = opts.status_message(status, resource)
          end
          ---@type Neoagent.ProviderHttpError
          local err = util.error(
            "provider",
            message or (opts.name .. " " .. resource .. " request failed (HTTP " .. tostring(status) .. ")")
          )
          err.status = status
          error(err, 0)
        end
        local decoded = fetched.body
        if type(decoded) ~= "table" then
          error(util.error("provider", opts.name .. " " .. resource .. " response contains invalid JSON"), 0)
        end
        return { ok = true, value = decoded }
      end,
      { error_kind = "provider" }
    )
  end

  return client
end

return M
