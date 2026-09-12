local semantic_message = require("neoagent.semantic_message")

local M = {}

local USER_IMAGE_PLACEHOLDER = "(image omitted: model does not support images)"
local TOOL_IMAGE_PLACEHOLDER = "(tool image omitted: model does not support images)"

---@param model Neoagent.MessageTarget
---@return boolean
local function supports_images(model)
  assert(
    type(model) == "table" and type(model.input) == "table" and vim.tbl_contains(model.input, "text"),
    "messages.for_model requires a Model with declared input modalities"
  )
  return vim.tbl_contains(model.input, "image")
end

---@param content Neoagent.InputBlock[]
---@param placeholder string
---@return Neoagent.InputBlock[]
local function replace_images(content, placeholder)
  ---@type Neoagent.InputBlock[]
  local result = {}
  local previous_was_placeholder = false
  for _, block in ipairs(content) do
    if block.type == "image" then
      if not previous_was_placeholder then
        result[#result + 1] = { type = "text", text = placeholder }
      end
      previous_was_placeholder = true
    else
      result[#result + 1] = block
      previous_was_placeholder = block.type == "text" and block.text == placeholder
    end
  end
  return result
end

---@param message Neoagent.Message
---@param content Neoagent.AssistantBlock[]|Neoagent.InputBlock[]
---@return Neoagent.Message
local function with_content(message, content)
  local result = {}
  for key, value in pairs(message) do
    result[key] = value
  end
  result.content = content
  -- The callers retain the role and replace content with blocks valid for that role.
  ---@cast result Neoagent.Message
  return result
end

---@param message Neoagent.Message
---@param model Neoagent.MessageTarget
---@return TypeGuard<Neoagent.AssistantMessage>
local function foreign_assistant(message, model)
  return message.role == "assistant"
    and (
      (message.api ~= nil and message.api ~= model.api)
      or (message.provider ~= nil and message.provider ~= model.provider)
      or (message.model ~= nil and message.model ~= model.id)
    )
end

---@param content Neoagent.AssistantBlock[]
---@return Neoagent.AssistantBlock[]
local function portable_content(content)
  ---@type Neoagent.AssistantBlock[]
  local result = {}
  for _, block in ipairs(content) do
    if block.type == "thinking" then
      if not block.redacted and block.thinking ~= "" then
        result[#result + 1] = { type = "text", text = block.thinking }
      end
    elseif block.type == "text" then
      result[#result + 1] = { type = "text", text = block.text }
    else
      result[#result + 1] = block
    end
  end
  return result
end

---@param messages Neoagent.Message[]
---@param model Neoagent.MessageTarget
---@return Neoagent.Message[]
function M.for_model(messages, model)
  assert(type(messages) == "table" and vim.islist(messages), "messages must be a list")
  for index, message in ipairs(messages) do
    local normalized, err = semantic_message.normalize(message)
    if not normalized then
      error("message " .. tostring(index) .. ": " .. err, 0)
    end
  end
  local images = supports_images(model)
  ---@type Neoagent.Message[]
  local result = {}
  local changed = false
  for index, message in ipairs(messages) do
    if foreign_assistant(message, model) then
      result[index] = with_content(message, portable_content(message.content))
    elseif not images and message.role == "user" and type(message.content) == "table" then
      result[index] = with_content(message, replace_images(message.content, USER_IMAGE_PLACEHOLDER))
    elseif not images and message.role == "toolResult" then
      result[index] = with_content(message, replace_images(message.content, TOOL_IMAGE_PLACEHOLDER))
    else
      result[index] = message
    end
    changed = changed or result[index] ~= message
  end
  return changed and result or messages
end

return M
