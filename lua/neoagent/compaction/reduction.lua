local async = require("neoagent.async")
local request_preparation = require("neoagent.api.request_preparation")
local util = require("neoagent.util")

local M = {}

---@param message Neoagent.UserMessage|Neoagent.ToolResultMessage
---@return integer
local function text_chars(message)
  if type(message.content) == "string" then
    return vim.fn.strchars(message.content)
  end
  local count = 0
  for _, block in ipairs(message.content) do
    if block.type == "text" then
      count = count + vim.fn.strchars(block.text)
    end
  end
  return count
end

---@param message Neoagent.UserMessage|Neoagent.ToolResultMessage
---@param kept integer
---@param total integer
---@return Neoagent.UserMessage|Neoagent.ToolResultMessage
local function candidate(message, kept, total)
  local result = util.copy(message)
  local marker = "\n[... " .. tostring(total - kept) .. " characters truncated for compaction]"
  if type(result.content) == "string" then
    result.content = vim.fn.strcharpart(result.content, 0, kept) .. marker
  else
    ---@type Neoagent.InputBlock[]
    local content = {}
    local remaining = kept
    for _, block in ipairs(result.content) do
      if block.type == "image" then
        content[#content + 1] = block
      elseif remaining > 0 then
        local text = vim.fn.strcharpart(block.text, 0, remaining)
        if text ~= "" then
          content[#content + 1] = { type = "text", text = text }
        end
        remaining = remaining - vim.fn.strchars(text)
      end
    end
    content[#content + 1] = { type = "text", text = marker }
    result.content = content
  end
  return result
end

-- Reduce a copied request across messages, re-estimating through the Model
-- after every change so request layers remain authoritative for budgeting.
---@async
---@param model Neoagent.Model
---@param call Neoagent.RequestOptions
---@param target number
---@param users? boolean
---@param operation? "compact"
---@return Neoagent.RequestMessage[]?, Neoagent.Error?
function M.request(model, call, target, users, operation)
  call = request_preparation.copy(call)
  local estimate = require("neoagent.api.request_estimate")
  local tokens = estimate.request(model, call, operation) + 32
  local indices = {}
  for index = #call.messages, 1, -1 do
    if assert(call.messages[index]).role == "toolResult" then
      indices[#indices + 1] = index
    end
  end
  if users then
    for index, message in ipairs(call.messages) do
      if message.role == "user" then
        indices[#indices + 1] = index
      end
    end
  end
  for _, index in ipairs(indices) do
    if tokens <= target then
      break
    end
    async.yield()
    local message = assert(call.messages[index])
    ---@cast message Neoagent.UserMessage|Neoagent.ToolResultMessage
    local total = text_chars(message)
    if total > 0 then
      -- Evaluate the smallest valid excerpt first. Even when it cannot meet
      -- the target alone, its reduction can combine with later messages.
      call.messages[index] = candidate(message, 0, total)
      local minimum = estimate.request(model, call, operation) + 32
      if minimum < tokens then
        local selected = call.messages[index]
        local selected_tokens = minimum
        if minimum <= target then
          local low, high = 1, total - 1
          while low <= high do
            async.yield()
            local middle = math.floor((low + high) / 2)
            call.messages[index] = candidate(message, middle, total)
            local current = estimate.request(model, call, operation) + 32
            if current <= target then
              selected, selected_tokens = call.messages[index], current
              low = middle + 1
            else
              high = middle - 1
            end
          end
        end
        call.messages[index], tokens = selected, selected_tokens
      else
        call.messages[index] = message
      end
    end
  end
  if tokens > target then
    return nil, util.error("compaction", "Compaction request cannot be reduced below the Model window")
  end
  return call.messages
end

return M
