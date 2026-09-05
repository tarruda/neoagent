local semantic_message = require("neoagent.semantic_message")

local M = {}

local USER_IMAGE_PLACEHOLDER = "(image omitted: model does not support images)"
local TOOL_IMAGE_PLACEHOLDER = "(tool image omitted: model does not support images)"

local function supports_images(model)
  assert(type(model) == "table" and type(model.input) == "table"
      and vim.tbl_contains(model.input, "text"),
    "messages.for_model requires a Model with declared input modalities")
  return vim.tbl_contains(model.input, "image")
end

local function replace_images(content, placeholder)
  if type(content) ~= "table" then return content end
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

local function with_content(message, content)
  local result = {}
  for key, value in pairs(message) do result[key] = value end
  result.content = content
  return result
end

local function foreign_assistant(message, model)
  return message.role == "assistant" and (
    (message.api ~= nil and message.api ~= model.api)
    or (message.provider ~= nil and message.provider ~= model.provider)
    or (message.model ~= nil and message.model ~= model.id))
end

local function portable_content(content)
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

function M.for_model(messages, model)
  assert(type(messages) == "table" and vim.islist(messages),
    "messages must be a list")
  for index, message in ipairs(messages) do
    local normalized, err = semantic_message.normalize(message)
    if not normalized then
      error("message " .. tostring(index) .. ": " .. err, 0)
    end
  end
  local images = supports_images(model)
  local result = {}
  local changed = false
  for index, message in ipairs(messages) do
    if foreign_assistant(message, model) then
      result[index] = with_content(message, portable_content(message.content))
    elseif not images and message.role == "user" and type(message.content) == "table" then
      result[index] = with_content(message,
        replace_images(message.content, USER_IMAGE_PLACEHOLDER))
    elseif not images and message.role == "toolResult" then
      result[index] = with_content(message,
        replace_images(message.content, TOOL_IMAGE_PLACEHOLDER))
    else
      result[index] = message
    end
    changed = changed or result[index] ~= message
  end
  return changed and result or messages
end

return M
