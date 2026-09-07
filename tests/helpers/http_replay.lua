local replay = require("neoagent.http_replay")
local M = {}
function M.open(exchanges)
  local value = replay.new({ exchanges = exchanges })
  value.url = "https://api.test"
  return value
end
function M.finish(value)
  value.close()
  value.assert_consumed()
end
return M
