local util = require("neoagent.util")

local M = {}

local function merge(request, override)
  for key in pairs(override) do
    if key ~= "url" and key ~= "headers" and key ~= "body" then
      error(util.error("model", "Unsupported request_opts field: " .. tostring(key)), 0)
    end
  end
  local result = util.copy(request)
  if override.url ~= nil then
    if type(override.url) ~= "string" or override.url == "" then
      error(util.error("model", "request_opts.url must be a non-empty string"), 0)
    end
    result.url = override.url
  end
  if override.headers ~= nil then
    if type(override.headers) ~= "table" or (next(override.headers) ~= nil and util.is_list(override.headers)) then
      error(util.error("model", "request_opts.headers must be a table"), 0)
    end
    result.headers = util.deep_merge(result.headers, override.headers, function(key)
      return type(key) == "string" and key:lower() or key
    end)
  end
  if override.body ~= nil then
    if type(override.body) ~= "table" or (next(override.body) ~= nil and util.is_list(override.body)) then
      error(util.error("model", "request_opts.body must be a table"), 0)
    end
    result.body = util.deep_merge(result.body, override.body)
  end
  return result
end

function M.apply(request, layer, context)
  if layer == nil then return request end
  local override = layer
  if type(layer) == "function" then
    local snapshot = util.copy(context)
    snapshot.request = util.copy(request)
    override = layer(snapshot)
  end
  if type(override) ~= "table" then
    error(util.error("model", "request_opts must be a table or return a table"), 0)
  end
  return merge(request, override)
end

return M
