local util = require("neoagent.util")

local M = {}

-- API adapters classify unsuccessful HTTP responses. The HTTP client itself
-- leaves status handling to its consumer (including auth polling and caches).
function M.check(result)
  local response = result.ok and result or result.error and result.error.response or {}
  local status = response.status
  if status and (status < 200 or status >= 300) then
    local err = result.error or util.error("transport", "HTTP " .. status)
    local body = result.body
    local message = type(body) == "table" and body.error or nil
    if type(message) == "table" then message = message.message or message.code end
    if type(message) ~= "string" and type(body) == "table" then
      message = body.message or body.detail
    end
    if type(message) ~= "string" and err.kind ~= "transport" then message = err.message end
    err.message = "HTTP " .. status .. (type(message) == "string" and ": " .. message or "")
    err.response = { status = status, headers = response.headers or {} }
    err.detail = result.detail or err.detail
    error(err, 0)
  end
  if not result.ok then error(result.error, 0) end
  return result
end

return M
