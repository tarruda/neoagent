local util = require("neoagent.util")

local M = {}

-- Adapters treat composition-supplied identity as opaque metadata.
function M.copy(value)
  if value == nil then return nil end
  if type(value) ~= "table"
      or next(value) ~= nil and util.is_list(value) then
    error(util.error("model", "request_context must be an object"), 0)
  end
  return util.copy(value)
end

function M.resolve(bound, supplied)
  local result = M.copy(supplied)
  if bound == nil then return result end
  result = result or {}
  for key, value in pairs(bound) do
    if result[key] ~= nil and not vim.deep_equal(value, result[key]) then
      error(util.error("model",
        "request_context conflicts with Model identity"), 0)
    end
    result[key] = util.copy(value)
  end
  return result
end

function M.bind_transport(transport, context)
  if type(transport) == "table"
      and type(transport.with_context) == "function" then
    return transport.with_context(context)
  end
  return transport
end

return M
