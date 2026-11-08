local replay = require("neoagent.http_replay")
local util = require("neoagent.util")

-- Retain exact matching while binding captured requests to the actual durable
-- Session identity created by each test's storage.
---@param entries (string|Neoagent.ReplayEntryOptions)[]
---@param session_id string
---@return Neoagent.HttpReplay
return function(entries, session_id)
  local bound = {}
  for _, entry in ipairs(entries) do
    local options = type(entry) == "string" and { path = entry } or util.copy(entry)
    local exchange = options.exchange or replay.read(assert(options.path))
    if exchange.request.url:match("/codex/responses$") then
      local headers = exchange.request.headers or {}
      headers["session-id"], headers["thread-id"] = session_id, session_id
      exchange.request.headers = headers
      local body = vim.json.decode((assert(exchange.request.body)))
      body.prompt_cache_key = session_id
      exchange.request.body = util.json_encode(body)
    end
    options.exchange, options.path = exchange, nil
    bound[#bound + 1] = options
  end
  return replay.new({ exchanges = bound })
end
