local M = {}

---@class Neoagent.ContextEstimate
---@field tokens number
---@field usage_tokens number
---@field trailing_tokens number
---@field last_usage_index? integer

---@param content? string|Neoagent.InputBlock[]
---@return integer
local function content_chars(content)
  if type(content) == "string" then
    return vim.fn.strchars(content)
  end
  local count = 0
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      count = count + vim.fn.strchars(block.text or "")
    elseif block.type == "image" then
      count = count + 4800
    end
  end
  return count
end

---@param usage? Neoagent.Usage
---@return number?
function M.usage_tokens(usage)
  if type(usage) ~= "table" then
    return nil
  end
  if type(usage.totalTokens) == "number" and usage.totalTokens > 0 then
    return usage.totalTokens
  end
  ---@type number
  local total = 0
  for _, key in ipairs({ "input", "output", "cacheRead", "cacheWrite" }) do
    if type(usage[key]) == "number" then
      total = total + usage[key]
    end
  end
  return total > 0 and total or nil
end

---@param message Neoagent.ProjectionMessage|Neoagent.NativeCompactionMessage
---@return integer
function M.estimate_tokens(message)
  if message.role == "user" then
    ---@cast message Neoagent.UserMessage
    return math.ceil(content_chars(message.content) / 4)
  end
  if message.role == "toolResult" then
    ---@cast message Neoagent.ToolResultMessage
    return math.ceil(content_chars(message.content) / 4)
  end
  if message.role == "assistant" then
    ---@cast message Neoagent.AssistantMessage
    local chars = 0
    for _, block in ipairs(message.content or {}) do
      if block.type == "text" then
        chars = chars + vim.fn.strchars(block.text or "")
      elseif block.type == "thinking" then
        chars = chars + vim.fn.strchars(block.thinking or "")
      elseif block.type == "toolCall" then
        local ok, encoded = pcall(vim.json.encode, block.arguments or {})
        chars = chars + #(block.name or "") + (ok and #encoded or 16)
      end
    end
    return math.ceil(chars / 4)
  end
  if message.role == "compactionSummary" then
    return math.ceil(#(message.summary or "") / 4)
  end
  if message.role == "compactionCheckpoint" then
    return 0
  end
  if message.role == "nativeCompaction" then
    -- Ciphertext length is only a planning estimate, not a decoded token count.
    return math.ceil(#message.encrypted_content * 3 / 16)
  end
  return 0
end

---@param message? Neoagent.ProjectionMessage|Neoagent.NativeCompactionMessage
---@return number?
function M.valid_assistant_usage(message)
  if not message or message.role ~= "assistant" or message.stopReason == "aborted" or message.stopReason == "error" then
    return nil
  end
  return M.usage_tokens(message.usage)
end

---@param messages (Neoagent.ProjectionMessage|Neoagent.NativeCompactionMessage)[]
---@return Neoagent.ContextEstimate
function M.estimate_context(messages)
  for index = #messages, 1, -1 do
    local usage = M.valid_assistant_usage(messages[index])
    if usage then
      local trailing = 0
      for trailing_index = index + 1, #messages do
        trailing = trailing + M.estimate_tokens(messages[trailing_index])
      end
      return { tokens = usage + trailing, usage_tokens = usage, trailing_tokens = trailing, last_usage_index = index }
    end
  end
  local total = 0
  for _, message in ipairs(messages) do
    total = total + M.estimate_tokens(message)
  end
  return { tokens = total, usage_tokens = 0, trailing_tokens = total }
end

return M
