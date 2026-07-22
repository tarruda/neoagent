local compaction = require("neoagent.compaction")

local M = {}

function M.usage_tokens(usage)
  if type(usage) ~= "table" then return nil end
  if type(usage.totalTokens) == "number" and usage.totalTokens >= 0 then
    return usage.totalTokens
  end
  local total = 0
  for _, key in ipairs({ "input", "output", "cacheRead", "cacheWrite" }) do
    if type(usage[key]) == "number" then total = total + usage[key] end
  end
  return total
end

local function estimate_messages(messages, first)
  local characters = 0
  for index = first, #messages do
    local ok, encoded = pcall(vim.json.encode, messages[index])
    if ok then characters = characters + #encoded end
  end
  return math.ceil(characters / 4)
end

local function valid_assistant_usage(message)
  if not message or message.role ~= "assistant"
      or message.stopReason == "aborted" or message.stopReason == "error" then
    return nil
  end
  return M.usage_tokens(message.usage)
end

local function historical_usage_is_current(session)
  local path = session:path()
  if not path then return true end
  local compaction_index
  for index, entry in ipairs(path) do
    if entry.type == "compaction" then compaction_index = index end
  end
  if not compaction_index then return true end
  for index = compaction_index + 1, #path do
    local entry = path[index]
    if entry.type == "message" and valid_assistant_usage(entry.message) ~= nil then return true end
  end
  return false
end

local function estimate_projected(messages)
  local used = 0
  for _, message in ipairs(messages) do used = used + compaction.estimate_tokens(message) end
  return used
end

function M.tokens(session, messages, live_usage)
  if live_usage then
    return live_usage.tokens + estimate_messages(messages, live_usage.message_count + 1)
  end
  if historical_usage_is_current(session) then
    for index = #messages, 1, -1 do
      local tokens = valid_assistant_usage(messages[index])
      if tokens ~= nil then return tokens + estimate_messages(messages, index + 1) end
    end
  end
  return estimate_projected(messages)
end

function M.display(session, model, live_usage)
  local total = model and model.context_window
  if type(total) ~= "number" or total <= 0 or not session then return false end
  local messages = session:context_messages()
  if not messages then return false end
  local used = M.tokens(session, messages, live_usage)
  return { used = used, total = total, percent = used / total * 100 }
end

return M
