local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}

function M.resolve(ctx, opts)
  opts = opts or {}
  assert(type(ctx) == "table" and type(ctx.resolve_auth) == "function",
    (opts.name or "provider") .. " request requires auth resolution")
  assert(type(opts.ambient_api_key) == "function",
    "ambient_api_key must be a function")
  return async.run(function()
    local resolved = ctx.resolve_auth():await()
    if resolved.ok == false then error(resolved.error, 0) end
    if resolved.configured then
      local headers = type(resolved.request_opts) == "table"
        and resolved.request_opts.headers or nil
      if type(headers) ~= "table" or util.is_list(headers) then
        error(util.error("auth",
          (opts.name or "Provider") .. " credentials returned no request headers"), 0)
      end
      return { ok = true, headers = util.copy(headers) }
    end
    local ok, key = pcall(opts.ambient_api_key)
    if not ok then
      error(util.error("auth", "Failed to resolve "
        .. tostring(opts.environment or "provider API key"), key), 0)
    end
    if type(key) ~= "string" or util.trim(key) == "" then
      error(util.error("auth", opts.missing_message or
        ((opts.name or "Provider") .. " credentials are required")), 0)
    end
    key = util.trim(key)
    local headers
    if type(opts.ambient_headers) == "function" then
      headers = opts.ambient_headers(key)
    else
      headers = { Authorization = "Bearer " .. key }
    end
    return { ok = true, headers = headers }
  end, { error_kind = "provider" })
end

return M
