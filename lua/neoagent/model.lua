local thinking = require("neoagent.thinking")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.ToolDefinition
---@field name string
---@field description string
---@field input_schema Neoagent.ToolSchema

---@class Neoagent.ModelTextDelta
---@field type 'text_delta'
---@field text string
---@field index? integer
---@field phase? string

---@class Neoagent.ModelThinkingDelta
---@field type 'thinking_delta'
---@field text string
---@field index? integer

---@class Neoagent.ModelToolDelta
---@field type 'tool_call_delta'
---@field index integer
---@field id? string
---@field name? string
---@field arguments_delta? string

---@class Neoagent.ModelUsageEvent
---@field type 'usage'
---@field usage Neoagent.Usage

---@class Neoagent.ModelInferenceStats
---@field type 'inference_stats'
---@field generation_tokens_per_second? number
---@field prompt_tokens_per_second? number
---@field elapsed_ms? number

---@class Neoagent.ModelWarning
---@field type 'warning'
---@field message string

---@class Neoagent.ModelProviderStatus
---@field type 'provider_status'
---@field text? string
---@field details? Neoagent.JsonObject
---@field reconnecting? boolean

---@alias Neoagent.ModelEvent Neoagent.ModelTextDelta|Neoagent.ModelThinkingDelta|Neoagent.ModelToolDelta|Neoagent.ModelUsageEvent|Neoagent.ModelInferenceStats|Neoagent.ModelWarning|Neoagent.ModelProviderStatus

---@class Neoagent.ModelSuccess
---@field ok true
---@field message Neoagent.AssistantMessage
---@field text? string

---@class Neoagent.ModelFailure: Neoagent.AsyncFailure
---@field message? Neoagent.AssistantMessage
---@field text? string

---@alias Neoagent.ModelResult Neoagent.ModelSuccess|Neoagent.ModelFailure

---@class Neoagent.StreamOverrides
---@field retry_attempt? integer
---@field system_prompt? string
---@field tools? Neoagent.ToolDefinition[]
---@field request_opts? Neoagent.RequestLayer
---@field request_context? Neoagent.RequestIdentity
---@field timeout_ms? number|false
---@field on_event? fun(event: Neoagent.ModelEvent)
---@field on_done? fun(result: Neoagent.ModelResult)

---@class Neoagent.StreamOptions: Neoagent.StreamOverrides
---@field messages Neoagent.Message[]

---@class Neoagent.MessageTarget
---@field input ("text"|"image")[]
---@field api? string
---@field provider? string
---@field id? string

---@class Neoagent.Model: Neoagent.MessageTarget
---@field api string
---@field provider string
---@field id string
---@field input ('text'|'image')[]
---@field context_window? number
---@field timeout_ms? number
---@field thinking? table<Neoagent.ThinkingLevel, Neoagent.RequestLayer>
---@field stream fun(self: Neoagent.Model, opts: Neoagent.StreamOptions): Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>

---@param message string
---@return nil
---@return Neoagent.Error
local function failure(message)
  return nil, util.error("model", message)
end

---@param value unknown
---@param name string
---@param maximum integer
---@return string? value
---@return Neoagent.Error? error
local function safe_text(value, name, maximum)
  if
    type(value) ~= "string"
    or value == ""
    or #value > maximum
    or not util.is_valid_utf8(value)
    or value:find("[%z\1-\31\127]")
  then
    return failure(name .. " must be safe non-empty text of at most " .. tostring(maximum) .. " bytes")
  end
  return value
end

---@param value unknown
---@return TypeGuard<number>
local function positive_finite(value)
  return type(value) == "number" and value > 0 and value == value and value ~= math.huge and value ~= -math.huge
end

---@param value unknown
---@return Neoagent.Model? model
---@return Neoagent.Error? error
function M.capabilities(value)
  if type(value) ~= "table" or util.is_list(value) then
    return failure("Model must be an object")
  end
  local api, err = safe_text(value.api, "Model api", 128)
  if not api then
    return nil, err
  end
  local provider
  provider, err = safe_text(value.provider, "Model provider", 512)
  if not provider then
    return nil, err
  end
  local id
  id, err = safe_text(value.id, "Model id", 512)
  if not id then
    return nil, err
  end
  if type(value.stream) ~= "function" then
    return failure("Model requires a stream function")
  end
  if type(value.input) ~= "table" or not util.is_list(value.input) or #value.input == 0 then
    return failure("Model input must be a non-empty modality list")
  end
  local input, seen = {}, {}
  for _, modality in ipairs(value.input) do
    if (modality ~= "text" and modality ~= "image") or seen[modality] then
      return failure("Model input must contain unique text or image modalities")
    end
    seen[modality] = true
    input[#input + 1] = modality
  end
  if not seen.text then
    return failure("Model input must include text")
  end
  for _, name in ipairs({ "context_window", "timeout_ms" }) do
    if value[name] ~= nil and not positive_finite(value[name]) then
      return failure("Model " .. name .. " must be a positive finite number")
    end
  end
  local declared_thinking
  if value.thinking ~= nil then
    if type(value.thinking) ~= "table" or next(value.thinking) ~= nil and util.is_list(value.thinking) then
      return failure("Model thinking must be an object")
    end
    declared_thinking = {}
    for level, layer in pairs(value.thinking) do
      if not thinking.is_level(level) then
        return failure("Model thinking contains an unknown level: " .. tostring(level))
      end
      if layer ~= false and type(layer) ~= "table" and type(layer) ~= "function" then
        return failure("Model thinking levels must contain request-option layers")
      end
      if layer ~= false then
        declared_thinking[level] = util.copy(layer)
      end
    end
  end
  local result = {
    api = api,
    provider = provider,
    id = id,
    stream = value.stream,
    input = input,
  }
  if value.context_window ~= nil then
    result.context_window = value.context_window
  end
  if value.timeout_ms ~= nil then
    result.timeout_ms = value.timeout_ms
  end
  if declared_thinking ~= nil then
    result.thinking = declared_thinking
  end
  return result
end

---@param value unknown
---@return Neoagent.Model? model
---@return Neoagent.Error? error
function M.validate(value)
  local capabilities, err = M.capabilities(value)
  if not capabilities then
    return nil, err
  end
  value.input = capabilities.input
  value.thinking = capabilities.thinking
  return value
end

---@param value unknown
---@param owner? string
---@return Neoagent.Model
function M.assert(value, owner)
  local validated, err = M.validate(value)
  assert(validated, (owner or "Model") .. " must return a complete Model: " .. (err and err.message or "invalid Model"))
  return validated
end

-- Cancellation interrupts await even when the child has already produced a
-- partial message. Model wrappers must preserve that output without turning a
-- cancelled parent back into a successful operation.
---@async
---@param child Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
---@return Neoagent.ModelResult
function M.await_result(child)
  local ok, result = pcall(child.await, child)
  if ok then
    return result
  end
  child:cancel()
  local err = util.normalize_error(result, "model")
  local settled = child:result()
  local message = settled and settled.message and util.copy(settled.message)
  if message then
    message.stopReason = err.kind == "cancelled" and "aborted" or "error"
    message.errorMessage = err.message
    message = require("neoagent.semantic_message").normalize_partial_assistant(message)
  end
  return { ok = false, error = err, message = message }
end

return M
