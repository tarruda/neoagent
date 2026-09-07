local util = require("neoagent.util")

local M = {}

---@param body unknown
---@return string?
local function error_message(body)
  if type(body) ~= "table" then return nil end
  local message = body.error
  if type(message) == "table" then message = message.message or message.code end
  if type(message) ~= "string" then message = body.message or body.detail end
  if type(message) == "string" then return message end
end

-- API adapters classify unsuccessful HTTP responses. The HTTP client itself
-- leaves status handling to its consumer (including auth polling and caches).
---@param result Neoagent.HttpResult
---@return Neoagent.HttpSuccess
function M.check(result)
  ---@type Neoagent.HttpError?
  local failure = not result.ok and result.error or nil
  local response = result.ok and result or failure and failure.response or { headers = {} }
  local status = response.status
  if status and (status < 200 or status >= 300) then
    ---@type Neoagent.HttpError
    local err = failure or util.error("transport", "HTTP " .. status)
    local message = error_message(result.ok and result.body or nil)
    if type(message) ~= "string" and err.kind ~= "transport" then message = err.message end
    err.message = "HTTP " .. status .. (type(message) == "string" and ": " .. message or "")
    err.response = { status = status, headers = response.headers or {} }
    err.detail = result.ok and result.detail or err.detail
    error(err, 0)
  end
  if not result.ok then error(result.error, 0) end
  -- Only successful transport results survive classification.
  ---@cast result Neoagent.HttpSuccess
  return result
end

return M
