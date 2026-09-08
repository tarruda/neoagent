local util = require("neoagent.util")

local M = {}

---@alias Neoagent.MessageRole 'user'|'assistant'|'toolResult'

---@class Neoagent.TextBlock
---@field type 'text'
---@field text string
---@field index? integer
---@field textSignature? string
---@field phase? string

---@class Neoagent.ThinkingBlock
---@field type 'thinking'
---@field thinking string
---@field index? integer
---@field thinkingSignature? string
---@field redacted? boolean

---@class Neoagent.ToolCallData
---@field type? 'toolCall'
---@field id? string
---@field name? string
---@field arguments table<string, Neoagent.JsonValue>
---@field argumentsError? string
---@field index? integer

---@class Neoagent.ToolCallBlock: Neoagent.ToolCallData
---@field type 'toolCall'
---@field id string
---@field name string
---@field arguments table<string, Neoagent.JsonValue>
---@field argumentsError? string
---@field index? integer

---@class Neoagent.ImageBlock
---@field type 'image'
---@field data string
---@field mimeType string
---@field id? string
---@field revision? string|number

---@alias Neoagent.Block Neoagent.TextBlock|Neoagent.ThinkingBlock|Neoagent.ToolCallBlock|Neoagent.ImageBlock
---@alias Neoagent.AssistantBlock Neoagent.TextBlock|Neoagent.ThinkingBlock|Neoagent.ToolCallBlock
---@alias Neoagent.InputBlock Neoagent.TextBlock|Neoagent.ImageBlock

---@class Neoagent.UsageCost
---@field input? number
---@field output? number
---@field cacheRead? number
---@field cacheWrite? number
---@field total? number

---@class Neoagent.Usage
---@field input? number
---@field output? number
---@field cacheRead? number
---@field cacheWrite? number
---@field reasoning? number
---@field totalTokens? number
---@field cost? Neoagent.UsageCost

---@class Neoagent.UserMessage
---@field role 'user'
---@field content string|Neoagent.InputBlock[]
---@field timestamp? integer

---@class Neoagent.AssistantMessage
---@field role 'assistant'
---@field content Neoagent.AssistantBlock[]
---@field timestamp? integer
---@field api? string
---@field provider? string
---@field model? string
---@field usage? Neoagent.Usage
---@field stopReason? string
---@field responseId? string
---@field errorMessage? string

---@class Neoagent.ToolResultMessage
---@field role 'toolResult'
---@field content Neoagent.InputBlock[]
---@field timestamp? integer
---@field toolCallId string
---@field toolName? string
---@field isError? boolean
---@field details? Neoagent.JsonValue
---@field usage? Neoagent.Usage

---@alias Neoagent.Message Neoagent.UserMessage|Neoagent.AssistantMessage|Neoagent.ToolResultMessage

---@class Neoagent.ToolResult
---@field content Neoagent.InputBlock[]
---@field isError? boolean
---@field is_error? boolean
---@field details? Neoagent.JsonValue
---@field usage? Neoagent.Usage

---@class Neoagent.AssistantValidationError: Neoagent.Error
---@field kind 'protocol'
---@field code 'invalid_assistant_message'|'missing_tool_call'

---@class Neoagent.ContentOptions
---@field transient? boolean

local MAX_ID_BYTES = 512
local MAX_TYPE_BYTES = 128

local message_fields = {
  user = {
    role = true, content = true, timestamp = true,
  },
  assistant = {
    role = true, content = true, timestamp = true, api = true,
    provider = true, model = true, usage = true, stopReason = true,
    responseId = true, errorMessage = true,
  },
  toolResult = {
    role = true, content = true, timestamp = true, toolCallId = true,
    toolName = true, isError = true, details = true, usage = true,
  },
}

local block_fields = {
  text = {
    type = true, text = true, index = true, textSignature = true,
    phase = true,
  },
  thinking = {
    type = true, thinking = true, index = true, thinkingSignature = true,
    redacted = true,
  },
  toolCall = {
    type = true, id = true, name = true, arguments = true,
    argumentsError = true, index = true,
  },
  image = {
    type = true, data = true, mimeType = true, id = true, revision = true,
  },
}

local role_blocks = {
  user = { text = true, image = true },
  assistant = { text = true, thinking = true, toolCall = true },
  toolResult = { text = true, image = true },
}

local usage_fields = {
  input = true, output = true, cacheRead = true, cacheWrite = true,
  reasoning = true, totalTokens = true, cost = true,
}

local cost_fields = {
  input = true, output = true, cacheRead = true, cacheWrite = true,
  total = true,
}

---@param message string
---@return nil
---@return string
local function failure(message)
  return nil, message
end

---@param value unknown
---@return TypeGuard<table>
local function object(value)
  return type(value) == "table"
    and (next(value) == nil or not util.is_list(value))
end

---@param value unknown
---@param accepted table<string, boolean>
---@param label string
---@return true? valid
---@return string? error
local function fields(value, accepted, label)
  if not object(value) then return failure(label .. " must be an object") end
  for key in pairs(value) do
    if not accepted[key] then
      return failure(label .. " has unsupported field: " .. tostring(key))
    end
  end
  return true
end

---@param value unknown
---@return TypeGuard<number>
local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

---@param value unknown
---@param label string
---@param maximum integer
---@param allow_empty? boolean
---@return true? valid
---@return string? error
local function check_string(value, label, maximum, allow_empty)
  if type(value) ~= "string" or not allow_empty and value == "" then
    return failure(label .. (allow_empty
      and " must be a string" or " is required"))
  end
  if #value > maximum then
    return failure(label .. " exceeds " .. tostring(maximum) .. " bytes")
  end
  if not util.is_valid_utf8(value) then
    return failure(label .. " must contain valid UTF-8")
  end
  if value:find("[%z\1-\31\127]") then
    return failure(label .. " must not contain control characters")
  end
  return true
end

---@param value unknown
---@param label string
---@param maximum integer
---@param allow_empty? boolean
---@return true? valid
---@return string? error
local function check_optional_string(value, label, maximum, allow_empty)
  if value == nil then return true end
  return check_string(value, label, maximum, allow_empty)
end

---@param value unknown
---@param label string
---@return true? valid
---@return string? error
local function index(value, label)
  if value == nil then return true end
  if not finite(value) or value < 0 or value % 1 ~= 0 then
    return failure(label .. " must be a non-negative integer")
  end
  return true
end

---@param value unknown
---@param label string
---@param stack table<table, boolean>
---@param depth integer
---@param count { value: integer }
---@return true? valid
---@return string? error
local function json_value(value, label, stack, depth, count)
  if value == vim.NIL then return true end
  local kind = type(value)
  if kind == "string" then
    if not util.is_valid_utf8(value) then
      return failure(label .. " must contain valid UTF-8")
    end
    return true
  end
  if kind == "number" then
    if not finite(value) then return failure(label .. " must be finite") end
    return true
  end
  if kind == "boolean" or kind == "nil" then return true end
  if kind ~= "table" then return failure(label .. " must contain JSON values") end
  if depth >= 32 then return failure(label .. " exceeds the nesting limit") end
  if stack[value] then return failure(label .. " must not contain cycles") end
  count.value = count.value + 1
  if count.value > 10000 then return failure(label .. " exceeds the value limit") end
  stack[value] = true
  if util.is_list(value) then
    for item_index, item in ipairs(value) do
      local ok, err = json_value(item,
        label .. "[" .. tostring(item_index) .. "]", stack, depth + 1, count)
      if not ok then stack[value] = nil return nil, err end
    end
  else
    for key, item in pairs(value) do
      if type(key) ~= "string" or key == "" or not util.is_valid_utf8(key) then
        stack[value] = nil
        return failure(label .. " object keys must be non-empty UTF-8 strings")
      end
      local ok, err = json_value(item,
        label .. "." .. key, stack, depth + 1, count)
      if not ok then stack[value] = nil return nil, err end
    end
  end
  stack[value] = nil
  return true
end

---@param value unknown
---@param label string
---@return true? valid
---@return string? error
local function json(value, label)
  return json_value(value, label, {}, 0, { value = 0 })
end

---@param value unknown
---@return true? valid
---@return string? error
local function base64(value)
  if type(value) ~= "string" or value == "" then
    return failure("image data must be non-empty base64 text")
  end
  local body, padding = value:match("^([A-Za-z0-9+/]*)(=*)$")
  if not body or #padding > 2 or #value % 4 == 1
      or #padding > 0 and #value % 4 ~= 0 then
    return failure("image data must be valid base64")
  end
  return true
end

---@param value unknown
---@return string? normalized
---@return string? error
local function mime_type(value)
  local valid, err = check_string(value, "image mimeType", MAX_TYPE_BYTES)
  if not valid then return nil, err end
  local normalized = value:lower()
  local media_type, subtype = normalized:match("^([^/]+)/([^/]+)$")
  if media_type ~= "image" or not subtype
      or subtype:find("[^%w!#$%%&'*+%.%^_`|~%-]") then
    return failure("image mimeType must be an image media type")
  end
  return normalized
end

---@param value unknown
---@return Neoagent.Usage? usage
---@return string? error
local function normalize_usage(value)
  if value == nil then return nil end
  local valid, err = fields(value, usage_fields, "message usage")
  if not valid then return nil, err end
  for key, item in pairs(value) do
    if key == "cost" then
      local cost_ok, cost_err = fields(item, cost_fields, "message usage cost")
      if not cost_ok then return nil, cost_err end
      for cost_key, cost in pairs(item) do
        if not finite(cost) or cost < 0 then
          return failure("message usage cost " .. cost_key
            .. " must be a non-negative finite number")
        end
      end
    elseif not finite(item) or item < 0 then
      return failure("message usage " .. key
        .. " must be a non-negative finite number")
    end
  end
  return util.copy(value)
end

---@param value unknown
---@param role Neoagent.MessageRole
---@param transient? boolean
---@return Neoagent.Block? block
---@return string? error
local function normalize_block(value, role, transient)
  if not object(value) then return failure("content block must be an object") end
  local block_type = value.type
  if type(block_type) ~= "string" or not role_blocks[role][block_type] then
    return failure("unsupported content block: " .. tostring(block_type))
  end
  -- The role whitelist restricts the tag to these four block schemas.
  ---@cast block_type 'text'|'thinking'|'toolCall'|'image'
  local valid, err = fields(value, block_fields[block_type], block_type)
  if not valid then return nil, err end
  local result = util.copy(value)
  if block_type == "text" then
    if type(result.text) ~= "string" then
      return failure("text block text must be a string")
    end
    if not util.is_valid_utf8(result.text) then
      return failure("text block text must contain valid UTF-8")
    end
    valid, err = index(result.index, "text block index")
    if not valid then return nil, err end
    valid, err = check_optional_string(result.textSignature,
      "text block signature", 4096)
    if not valid then return nil, err end
    valid, err = check_optional_string(result.phase, "text block phase", 128)
    if not valid then return nil, err end
  elseif block_type == "thinking" then
    if type(result.thinking) ~= "string"
        or not util.is_valid_utf8(result.thinking) then
      return failure("thinking block text must be a UTF-8 string")
    end
    valid, err = index(result.index, "thinking block index")
    if not valid then return nil, err end
    valid, err = check_optional_string(result.thinkingSignature,
      "thinking block signature", 1024 * 1024, true)
    if not valid then return nil, err end
    if result.redacted ~= nil and type(result.redacted) ~= "boolean" then
      return failure("thinking block redacted must be a boolean")
    end
  elseif block_type == "toolCall" then
    valid, err = check_string(result.id, "toolCall id", MAX_ID_BYTES)
    if not valid then return nil, err end
    valid, err = check_string(result.name, "toolCall name", MAX_ID_BYTES)
    if not valid then return nil, err end
    if not object(result.arguments) then
      return failure("toolCall arguments must be an object")
    end
    if next(result.arguments) == nil and util.is_list(result.arguments) then
      result.arguments = vim.empty_dict()
    end
    valid, err = json(result.arguments, "toolCall arguments")
    if not valid then return nil, err end
    valid, err = check_optional_string(result.argumentsError,
      "toolCall argumentsError", 4096)
    if not valid then return nil, err end
    valid, err = index(result.index, "toolCall index")
    if not valid then return nil, err end
  else
    valid, err = base64(result.data)
    if not valid then return nil, err end
    result.mimeType, err = mime_type(result.mimeType)
    if not result.mimeType then return nil, err end
    valid, err = check_optional_string(result.id, "image id", MAX_ID_BYTES)
    if not valid then return nil, err end
    if transient and result.id == nil then
      return failure("transient image id is required")
    end
    if result.revision ~= nil then
      local revision_type = type(result.revision)
      if revision_type == "string" then
        valid, err = check_string(result.revision,
          "image revision", MAX_TYPE_BYTES)
        if not valid then return nil, err end
      elseif not finite(result.revision) then
        return failure("image revision must be finite text or a number")
      end
    elseif transient then
      return failure("transient image revision is required")
    end
  end
  -- All fields of the selected variant have now passed validation.
  ---@cast result Neoagent.Block
  return result
end

---@param content unknown
---@param role Neoagent.MessageRole
---@param transient? boolean
---@return string|Neoagent.Block[]|nil content
---@return string? error
local function normalize_content(content, role, transient)
  if role == "user" and type(content) == "string" then
    if not util.is_valid_utf8(content) then
      return failure("user content must contain valid UTF-8")
    end
    return content
  end
  if type(content) ~= "table" or not util.is_list(content) then
    return failure(role .. " content must be a block list")
  end
  local result = {}
  local calls = {}
  local image_ids = {}
  for block_index, block in ipairs(content) do
    local normalized, err = normalize_block(block, role, transient)
    if not normalized then
      return nil, "content block " .. tostring(block_index) .. ": " .. err
    end
    if normalized.type == "toolCall" then
      if calls[normalized.id] then
        return failure("duplicate toolCall id: " .. normalized.id)
      end
      calls[normalized.id] = true
    elseif normalized.type == "image" and normalized.id ~= nil then
      if image_ids[normalized.id] then
        return failure("duplicate image id: " .. normalized.id)
      end
      image_ids[normalized.id] = true
    end
    result[block_index] = normalized
  end
  return result
end

---@param block unknown
---@param opts? Neoagent.ContentOptions
---@return Neoagent.ImageBlock? image
---@return string? error
function M.normalize_image(block, opts)
  if type(block) ~= "table" or block.type ~= "image" then
    return failure("image block is required")
  end
  local normalized, err = normalize_block(block, "user", opts and opts.transient == true)
  -- Normalization preserves the image tag checked above.
  ---@cast normalized Neoagent.ImageBlock?
  return normalized, err
end

---@param message unknown
---@return Neoagent.Message? message
---@return string? error
---@return_overload Neoagent.Message
---@return_overload nil, string
function M.normalize(message)
  if not object(message) then return failure("message must be an object") end
  local role = message.role
  if not message_fields[role] then
    return failure("unsupported message role: " .. tostring(role))
  end
  local valid, err = fields(message, message_fields[role], role .. " message")
  if not valid then return nil, err end
  if message.content == nil then return failure("message content is required") end
  local result = util.copy(message)
  result.content, err = normalize_content(result.content, role, false)
  if result.content == nil then return nil, err end
  if result.timestamp ~= nil and (not finite(result.timestamp)
      or result.timestamp < 0 or result.timestamp % 1 ~= 0) then
    return failure("message timestamp must be a non-negative integer")
  end
  if role == "assistant" then
    for _, name in ipairs({ "api", "provider", "model", "stopReason",
      "responseId" }) do
      valid, err = check_optional_string(result[name],
        "assistant " .. name, name == "responseId" and 4096 or MAX_ID_BYTES)
      if not valid then return nil, err end
    end
    if result.errorMessage ~= nil then
      if type(result.errorMessage) ~= "string"
          or not util.is_valid_utf8(result.errorMessage) then
        return failure("assistant errorMessage must be a UTF-8 string")
      end
    end
    result.usage, err = normalize_usage(result.usage)
    if message.usage ~= nil and result.usage == nil then return nil, err end
  elseif role == "toolResult" then
    valid, err = check_string(result.toolCallId,
      "toolResult toolCallId", MAX_ID_BYTES)
    if not valid then return nil, err end
    valid, err = check_optional_string(result.toolName,
      "toolResult toolName", MAX_ID_BYTES)
    if not valid then return nil, err end
    if result.isError ~= nil and type(result.isError) ~= "boolean" then
      return failure("toolResult isError must be a boolean")
    end
    if result.details ~= nil then
      valid, err = json(result.details, "toolResult details")
      if not valid then return nil, err end
      result.details = util.copy(result.details)
    end
    result.usage, err = normalize_usage(result.usage)
    if message.usage ~= nil and result.usage == nil then return nil, err end
  end
  -- The role, permitted block variants and every retained field are validated.
  ---@cast result Neoagent.Message
  return result
end

---@param message unknown
---@return Neoagent.AssistantMessage? message
---@return Neoagent.AssistantValidationError? error
---@return_overload Neoagent.AssistantMessage
---@return_overload nil, Neoagent.AssistantValidationError
function M.normalize_model_response(message)
  local result, err = M.normalize(message)
  if not result then
    return nil, { kind = "protocol", code = "invalid_assistant_message",
      message = "Invalid assistant message: " .. err, detail = err }
  end
  if result.role ~= "assistant" then
    return nil, { kind = "protocol", code = "invalid_assistant_message",
      message = "assistant message is required" }
  end
  if result.stopReason == "toolUse" then
    for _, block in ipairs(result.content) do
      if block.type == "toolCall" then return result end
    end
    return nil, { kind = "protocol", code = "missing_tool_call",
      message = "Provider declared tool use without supplying a tool call" }
  end
  return result
end

---@param message unknown
---@return Neoagent.AssistantMessage?
function M.normalize_partial_assistant(message)
  if type(message) ~= "table" or message.role ~= "assistant"
      or type(message.content) ~= "table" then
    return nil
  end
  local candidate = util.copy(message)
  candidate.content = {}
  for _, block in ipairs(message.content) do
    if type(block) == "table" then
      local retained = util.copy(block)
      if retained.type == "thinking" and retained.thinkingSignature == "" then
        retained.thinkingSignature = nil
      elseif retained.type == "text" and retained.textSignature == "" then
        retained.textSignature = nil
      end
      local meaningful = retained.type == "text"
          and type(retained.text) == "string" and retained.text ~= ""
        or retained.type == "thinking"
          and type(retained.thinking) == "string" and retained.thinking ~= ""
        or retained.type == "toolCall"
      if meaningful then candidate.content[#candidate.content + 1] = retained end
    end
  end
  if #candidate.content == 0 then return nil end
  local normalized = M.normalize(candidate)
  -- The candidate retains the assistant role checked at entry.
  ---@cast normalized Neoagent.AssistantMessage?
  return normalized
end

---@param messages unknown
---@param opts? { index_offset?: integer }
---@return Neoagent.Message[]? messages
---@return string? error
function M.normalize_list(messages, opts)
  if type(messages) ~= "table" or not util.is_list(messages) then
    return failure("messages must be a list")
  end
  assert(opts == nil or type(opts) == "table",
    "message normalization options must be an object")
  local index_offset = opts and opts.index_offset or 0
  assert(type(index_offset) == "number" and index_offset >= 0
      and index_offset % 1 == 0,
    "message index_offset must be a non-negative integer")
  local result = {}
  local calls = {}
  local seen_calls = {}
  for message_index, message in ipairs(messages) do
    local displayed_index = message_index + index_offset
    local normalized, err = M.normalize(message)
    if not normalized then
      return nil, "message " .. tostring(displayed_index) .. ": " .. err
    end
    if normalized.role == "assistant" then
      for _, block in ipairs(normalized.content) do
        if block.type == "toolCall" then
          if seen_calls[block.id] then
            return failure("message " .. tostring(displayed_index)
              .. ": duplicate conversation toolCall id: " .. block.id)
          end
          seen_calls[block.id] = true
          calls[block.id] = block.name
        end
      end
    elseif normalized.role == "toolResult" then
      local name = calls[normalized.toolCallId]
      if name == nil then
        return failure("message " .. tostring(displayed_index)
          .. ": toolResult references an unknown toolCall: "
          .. normalized.toolCallId)
      end
      if normalized.toolName ~= nil and normalized.toolName ~= name then
        return failure("message " .. tostring(displayed_index)
          .. ": toolResult toolName does not match its toolCall")
      end
      calls[normalized.toolCallId] = nil
    end
    result[message_index] = normalized
  end
  return result
end

---@param result unknown
---@param opts? Neoagent.ContentOptions
---@return Neoagent.ToolResult? result
---@return string? error
---@return_overload Neoagent.ToolResult
---@return_overload nil, string
function M.normalize_tool_result(result, opts)
  if not object(result) then
    return failure("Tool must return a result with content blocks")
  end
  local accepted = {
    content = true, isError = true, is_error = true, details = true, usage = true,
  }
  local valid, err = fields(result, accepted, "Tool result")
  if not valid then return nil, err end
  if result.content == nil then
    return failure("Tool must return a result with content blocks")
  end
  local normalized = util.copy(result)
  normalized.content, err = normalize_content(
    normalized.content, "toolResult", opts and opts.transient == true)
  if not normalized.content then return nil, err end
  if normalized.isError ~= nil and type(normalized.isError) ~= "boolean"
      or normalized.is_error ~= nil and type(normalized.is_error) ~= "boolean" then
    return failure("Tool result error state must be a boolean")
  end
  if normalized.details ~= nil then
    valid, err = json(normalized.details, "Tool result details")
    if not valid then return nil, err end
  end
  normalized.usage, err = normalize_usage(normalized.usage)
  if result.usage ~= nil and normalized.usage == nil then return nil, err end
  -- Input blocks, error flags, details and usage have all passed validation.
  ---@cast normalized Neoagent.ToolResult
  return normalized
end

return M
