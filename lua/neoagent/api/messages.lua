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

function M.for_model(messages, model)
  assert(type(messages) == "table" and vim.islist(messages),
    "messages must be a list")
  for index, message in ipairs(messages) do
    local normalized, err = semantic_message.normalize(message)
    if not normalized then
      error("message " .. tostring(index) .. ": " .. err, 0)
    end
  end
  if supports_images(model) then return messages end
  local result = {}
  for index, message in ipairs(messages) do
    if message.role == "user" and type(message.content) == "table" then
      result[index] = with_content(message,
        replace_images(message.content, USER_IMAGE_PLACEHOLDER))
    elseif message.role == "toolResult" then
      result[index] = with_content(message,
        replace_images(message.content, TOOL_IMAGE_PLACEHOLDER))
    else
      result[index] = message
    end
  end
  return result
end

return M
