local util = require("neoagent.util")

local M = {}

---@alias Neoagent.RequestIdentity table<string, unknown>

-- Adapters treat composition-supplied identity as opaque metadata.
---@param value unknown
---@return Neoagent.RequestIdentity?
function M.copy(value)
  if value == nil then
    return nil
  end
  if type(value) ~= "table" or next(value) ~= nil and util.is_list(value) then
    error(util.error("model", "request_context must be an object"), 0)
  end
  return util.copy(value)
end

---@param bound? Neoagent.RequestIdentity
---@param supplied? Neoagent.RequestIdentity
---@return Neoagent.RequestIdentity?
function M.resolve(bound, supplied)
  local result = M.copy(supplied)
  if bound == nil then
    return result
  end
  result = result or {}
  for key, value in pairs(bound) do
    if result[key] ~= nil and not vim.deep_equal(value, result[key]) then
      error(util.error("model", "request_context conflicts with Model identity"), 0)
    end
    result[key] = util.copy(value)
  end
  return result
end

---@overload fun(transport: nil, context?: Neoagent.RequestIdentity): nil
---@generic T: { with_context?: fun(context?: Neoagent.RequestIdentity): T }
---@param transport T
---@param context? Neoagent.RequestIdentity
---@return T
function M.bind_transport(transport, context)
  local with_context = type(transport) == "table" and transport.with_context
  if type(with_context) == "function" then
    return with_context(context)
  end
  return transport
end

return M
