local M = {}

-- A string names a pending call; false retains an already answered call ID.
---@alias Neoagent.MessageLinkage table<string, string|false>

---@class Neoagent.MessageLinkageUpdate
---@field base Neoagent.MessageLinkage
---@field changes Neoagent.MessageLinkage

---@param base? Neoagent.MessageLinkage
---@return Neoagent.MessageLinkageUpdate
function M.stage(base)
  return { base = base or {}, changes = {} }
end

---@param update Neoagent.MessageLinkageUpdate
function M.reset(update)
  update.base = {}
  update.changes = {}
end

---@param update Neoagent.MessageLinkageUpdate
---@param id string
---@return string|false|nil
local function lookup(update, id)
  local value = update.changes[id]
  if value ~= nil then
    return value
  end
  return update.base[id]
end

-- Schema normalization belongs to the caller. Changes remain private until
-- its entire message batch and durable acceptance have succeeded.
---@param update Neoagent.MessageLinkageUpdate
---@param message Neoagent.Message
---@param index? integer
---@return true?, string?
function M.check(update, message, index)
  local prefix = index and "message " .. tostring(index) .. ": " or ""
  if message.role == "assistant" then
    ---@cast message Neoagent.AssistantMessage
    for _, block in ipairs(message.content) do
      if block.type == "toolCall" then
        if lookup(update, block.id) ~= nil then
          return nil, prefix .. "duplicate conversation toolCall id: " .. block.id
        end
        update.changes[block.id] = block.name
      end
    end
  elseif message.role == "toolResult" then
    ---@cast message Neoagent.ToolResultMessage
    local name = lookup(update, message.toolCallId)
    if not name then
      return nil, prefix .. "toolResult references an unknown toolCall: " .. message.toolCallId
    end
    if message.toolName ~= nil and message.toolName ~= name then
      return nil, prefix .. "toolResult toolName does not match its toolCall"
    end
    update.changes[message.toolCallId] = false
  end
  return true
end

---@param update Neoagent.MessageLinkageUpdate
---@return Neoagent.MessageLinkage
function M.commit(update)
  for id, value in pairs(update.changes) do
    update.base[id] = value
  end
  return update.base
end

return M
