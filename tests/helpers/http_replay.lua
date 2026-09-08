local replay = require("neoagent.http_replay")
---@class Neoagent.TestHttpReplay: Neoagent.HttpReplay
---@field url string

local M = {}
---@param exchanges (string|Neoagent.ReplayEntryOptions)[]
---@return Neoagent.TestHttpReplay
function M.open(exchanges)
  local value = replay.new({ exchanges = exchanges })
  ---@cast value Neoagent.TestHttpReplay
  value.url = "https://api.test"
  return value
end
---@param value Neoagent.HttpReplay
function M.finish(value)
  value.close()
  value.assert_consumed()
end
return M
