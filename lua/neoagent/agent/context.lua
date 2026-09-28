local compaction = require("neoagent.compaction")

local M = {}

---@class Neoagent.LiveContextUsage
---@field tokens number
---@field message_count integer

---@class Neoagent.ContextDisplay
---@field used number
---@field total number
---@field percent number

M.usage_tokens = compaction.usage_tokens

---@param messages Neoagent.RequestMessage[]
---@param first integer
---@return integer
local function estimate_messages(messages, first)
  local tokens = 0
  for index = first, #messages do
    tokens = tokens + compaction.estimate_tokens(messages[index])
  end
  return tokens
end

---@param session Neoagent.Session
---@return boolean
local function historical_usage_is_current(session)
  local path = session:path()
  if not path then
    return false
  end
  return compaction.has_usage_after_checkpoint(path)
end

---@param session Neoagent.Session
---@param messages Neoagent.RequestMessage[]
---@param live_usage? Neoagent.LiveContextUsage
---@return number
function M.tokens(session, messages, live_usage)
  if live_usage then
    return live_usage.tokens + estimate_messages(messages, live_usage.message_count + 1)
  end
  if historical_usage_is_current(session) then
    return compaction.estimate_context(messages).tokens
  end
  return estimate_messages(messages, 1)
end

---@param session? Neoagent.Session
---@param model? Neoagent.Model
---@param live_usage? Neoagent.LiveContextUsage
---@return Neoagent.ContextDisplay|false
function M.display(session, model, live_usage)
  local total = model and model.context_window
  if type(total) ~= "number" or total <= 0 or not session then
    return false
  end
  local messages = session:context_messages()
  if not messages then
    return false
  end
  local used = M.tokens(session, messages, live_usage)
  return { used = used, total = total, percent = used / total * 100 }
end

return M
