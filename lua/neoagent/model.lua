local thinking = require("neoagent.thinking")
local util = require("neoagent.util")
local files = require("neoagent.files")

local M = {}

---@param err? Neoagent.Error
---@return boolean
function M.is_context_overflow(err)
  if not err then
    return false
  end
  if type(err.context_overflow) == "boolean" then
    return err.context_overflow
  end
  if err.code == "rate_limit_exceeded" or err.code == "rate_limit_error" then
    return false
  end
  local parts = { err.message or "", tostring(err.code or "") }
  if err["detail"] ~= nil then
    local ok, encoded = pcall(vim.json.encode, err["detail"])
    parts[#parts + 1] = ok and encoded or tostring(err["detail"])
  end
  local text = table.concat(parts, " "):lower()
  for _, pattern in ipairs({ "rate limit", "too many requests" }) do
    if text:find(pattern, 1, true) then
      return false
    end
  end
  for _, pattern in ipairs({
    "context_length_exceeded",
    "context_window_exceeded",
    "model_context_window_exceeded",
    "request_too_large",
    "prompt is too long",
    "prompt too long",
    "input is too long for requested model",
    "exceeds the context window",
    "maximum context length",
    "maximum prompt length",
    "reduce the length of the messages",
    "maximum allowed input length",
    "longer than the model's context length",
    "exceeds the available context size",
    "greater than the context length",
    "context window exceeds limit",
    "exceeded model token limit",
    "token limit exceeded",
    "too many tokens",
    "too large for model",
    "exceeds the configured context size",
    "range of input length should be",
    "request too large",
  }) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

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

---@class Neoagent.ModelRecovery
---@field message Neoagent.UserMessage Follow-up to commit before preparing another request.
---@field warning string Explanation of the provider recovery.

---@class Neoagent.ModelFailure: Neoagent.AsyncFailure
---@field recovery? Neoagent.ModelRecovery A single continuation owned by the calling Loop.
---@field message? Neoagent.AssistantMessage
---@field text? string

---@alias Neoagent.ModelResult Neoagent.ModelSuccess|Neoagent.ModelFailure

---@class Neoagent.RequestOverrides
---@field _preparation? Neoagent.RequestPreparation Internal request-scoped preparation.
---@field thinking_level? Neoagent.ThinkingLevel Selected semantic level, resolved by the Model.
---@field files? Neoagent.FileSource
---@field file_cache? Neoagent.FileCache Workspace-owned upload mappings.
---@field retry_attempt? integer
---@field system_prompt? string
---@field tools? Neoagent.ToolDefinition[]
---@field request_opts? Neoagent.RequestLayer
---@field request_context? Neoagent.RequestIdentity
---@field timeout_ms? number|false

---@class Neoagent.RequestOptions: Neoagent.RequestOverrides
---@field messages Neoagent.RequestMessage[]
---@field max_output_tokens? integer Enforced after request shaping.
---@field max_thinking_tokens? integer Caps explicit protocol thinking budgets after shaping.
---@field compaction_output_tokens? integer

---@class Neoagent.StreamOverrides: Neoagent.RequestOverrides
---@field max_output_tokens? integer Enforced after request shaping.
---@field max_thinking_tokens? integer Caps explicit protocol thinking budgets after shaping.
---@field on_event? fun(event: Neoagent.ModelEvent)
---@field on_done? fun(result: Neoagent.ModelResult)

---@class Neoagent.StreamOptions: Neoagent.StreamOverrides, Neoagent.RequestOptions
---@field compaction_output_tokens? nil

---@class Neoagent.NativeCompactionSuccess
---@field ok true
---@field item Neoagent.NativeCompactionMessage
---@field usage? Neoagent.Usage

---@alias Neoagent.NativeCompactionResult Neoagent.NativeCompactionSuccess|Neoagent.AsyncFailure

---@class Neoagent.NativeCompactionOptions: Neoagent.RequestOptions
---@field max_output_tokens? nil
---@field max_thinking_tokens? nil
---@field compaction_output_tokens? integer Explicit native output budget; omitted by default.
---@field on_event? fun(event: Neoagent.ModelEvent)
---@field on_done? fun(result: Neoagent.NativeCompactionResult)

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
---@field max_output_tokens? integer
---@field timeout_ms? number
---@field thinking? table<Neoagent.ThinkingLevel, Neoagent.RequestLayer>
---@field stream fun(self: Neoagent.Model, opts: Neoagent.StreamOptions): Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
---@field estimate_request? async fun(self: Neoagent.Model, options: Neoagent.RequestOptions, operation?: "compact"): integer
---@field compact? fun(self: Neoagent.Model, opts: Neoagent.NativeCompactionOptions): Neoagent.Run<Neoagent.NativeCompactionResult, Neoagent.ModelEvent>

---@param model Neoagent.MessageTarget
---@param identity? Neoagent.NativeContextIdentity
---@return true?, Neoagent.Error?
function M.compatible_context_identity(model, identity)
  if identity and (identity.api ~= model.api or identity.provider ~= model.provider or identity.model ~= model.id) then
    return nil, util.error("model", "Encrypted context requires its original API, provider, and Model")
  end
  return true
end

---@param model Neoagent.MessageTarget
---@param messages Neoagent.RequestMessage[]
---@return true?, Neoagent.Error?
function M.compatible_context(model, messages)
  for _, message in ipairs(messages) do
    if message.role == "nativeCompaction" then
      return M.compatible_context_identity(model, {
        api = message.api,
        provider = message.provider,
        model = message.model,
      })
    end
  end
  return true
end

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
  if value.estimate_request ~= nil and type(value.estimate_request) ~= "function" then
    return failure("Model estimate_request must be a function")
  end
  if value.compact ~= nil and type(value.compact) ~= "function" then
    return failure("Model compact must be a function")
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
  for _, name in ipairs({ "context_window", "timeout_ms", "max_output_tokens" }) do
    if value[name] ~= nil and not positive_finite(value[name]) then
      return failure("Model " .. name .. " must be a positive finite number")
    end
  end
  if value.max_output_tokens ~= nil and value.max_output_tokens % 1 ~= 0 then
    return failure("Model max_output_tokens must be an integer")
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
  if value.max_output_tokens ~= nil then
    result.max_output_tokens = value.max_output_tokens
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

---@param options Neoagent.StreamOptions|Neoagent.NativeCompactionOptions
function M.require_files(options)
  if options.files ~= nil then
    assert(files.valid(options.files), "Model attachment file reader is incomplete")
  end
  for _, message in ipairs(options.messages or {}) do
    if message.role ~= "nativeCompaction" and type(message.content) == "table" then
      for _, block in ipairs(message.content) do
        if block.type == "image" then
          assert(files.valid(options.files), "Model image messages require an attachment file reader")
          return
        end
      end
    end
  end
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
