local async = require("neoagent.async")
local model_contract = require("neoagent.model")
local request = require("neoagent.api.anthropic_messages.request")
local request_opts = require("neoagent.api.request_opts")
local request_context = require("neoagent.api.request_context")
local semantic_message = require("neoagent.semantic_message")
local tool_arguments = require("neoagent.api.tool_arguments")
local http = require("neoagent.transport.http")
local http_response = require("neoagent.api.http_response")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.AnthropicUsage: Neoagent.Usage
---@field input number
---@field output number
---@field cacheRead number
---@field cacheWrite number
---@field totalTokens number

---@class Neoagent.AnthropicMessage: Neoagent.AssistantMessage
---@field usage Neoagent.AnthropicUsage

---@class Neoagent.AnthropicBlockState
---@field block Neoagent.TextBlock|Neoagent.AnthropicThinkingBlock|Neoagent.ToolCallBlock
---@field stopped boolean

---@class Neoagent.AnthropicToolState: Neoagent.AnthropicBlockState
---@field block Neoagent.ToolCallBlock
---@field input Neoagent.JsonValue
---@field raw string

---@class Neoagent.AnthropicThinkingBlock: Neoagent.ThinkingBlock
---@field thinkingSignature string

---@return Neoagent.AnthropicUsage
local function zero_usage()
  return {
    input = 0,
    output = 0,
    cacheRead = 0,
    cacheWrite = 0,
    totalTokens = 0,
    cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 },
  }
end

---@param usage Neoagent.AnthropicUsage
---@param raw unknown
local function update_usage(usage, raw)
  if type(raw) ~= "table" then
    return
  end
  if type(raw.input_tokens) == "number" then
    usage.input = raw.input_tokens
  end
  if type(raw.output_tokens) == "number" then
    usage.output = raw.output_tokens
  end
  if type(raw.cache_read_input_tokens) == "number" then
    usage.cacheRead = raw.cache_read_input_tokens
  end
  if type(raw.cache_creation_input_tokens) == "number" then
    usage.cacheWrite = raw.cache_creation_input_tokens
  end
  usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
end

---@param reason unknown
---@param details unknown
---@return "stop"|"length"|"toolUse"
local function stop_reason(reason, details)
  if reason == "end_turn" or reason == "stop_sequence" or reason == "pause_turn" then
    return "stop"
  elseif reason == "max_tokens" then
    return "length"
  elseif reason == "tool_use" then
    return "toolUse"
  elseif reason == "refusal" then
    local message = type(details) == "table" and details.explanation or nil
    error(util.error("model", message or "Provider refused the request"), 0)
  elseif reason == "sensitive" then
    error(util.error("model", "Provider blocked sensitive content"), 0)
  end
  error(util.error("model", "Provider stop_reason: " .. tostring(reason)), 0)
end

---@param value unknown
---@return TypeGuard<string>
local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

---@param value unknown
---@param field string
---@return string
local function block_string(value, field)
  if not value then
    return ""
  end
  if type(value) ~= "string" then
    error(util.error("protocol", "Invalid Anthropic " .. field .. ": expected a string"), 0)
  end
  return value
end

---@param message? Neoagent.AnthropicMessage
---@param blocks? table<number, Neoagent.AnthropicBlockState>
---@param err Neoagent.Error
---@return Neoagent.AssistantMessage?
local function partial_message(message, blocks, err)
  if type(message) ~= "table" then
    return nil
  end
  ---@type table<Neoagent.AssistantBlock, Neoagent.AnthropicBlockState>
  local states = {}
  for _, state in pairs(blocks or {}) do
    states[state.block] = state
  end
  local candidate = util.copy(message)
  candidate.content = {}
  for _, block in ipairs(message.content or {}) do
    local state = states[block]
    ---@type Neoagent.AssistantBlock?
    local retained
    if state and block.type == "text" and nonempty(block.text) then
      retained = util.copy(block)
    elseif state and block.type == "thinking" and nonempty(block.thinking) then
      retained = util.copy(block)
      if retained.thinkingSignature == "" then
        retained.thinkingSignature = nil
      end
    elseif state and state.stopped and block.type == "toolCall" and nonempty(block.id) and nonempty(block.name) then
      retained = util.copy(block)
    end
    if retained then
      candidate.content[#candidate.content + 1] = retained
    end
  end
  candidate.stopReason = err.kind == "cancelled" and "aborted" or "error"
  candidate.errorMessage = err.message
  return semantic_message.normalize_partial_assistant(candidate)
end

---@class Neoagent.AnthropicModelOptions: Neoagent.ApiModelOptions
---@field max_output_tokens? integer

---@class Neoagent.AnthropicModel: Neoagent.Model
---@field _base_url string
---@field _api_key? string|fun(): string?
---@field _max_output_tokens integer
---@field _timeout_ms? integer
---@field _anthropic_version string
---@field _request_opts Neoagent.RequestLayer[]
---@field _request_context? Neoagent.RequestIdentity
---@field _transport Neoagent.HttpClient
local Model = {}
Model.__index = Model

---@param call_opts Neoagent.StreamOptions
---@return Neoagent.ApiRequest, Neoagent.RequestIdentity?
function Model:_request(call_opts)
  return request.build(self, call_opts)
end

---@param opts Neoagent.StreamOptions
---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
function Model:stream(opts)
  opts = opts or {}
  assert(type(opts.messages) == "table", "messages are required")
  ---@type Neoagent.AnthropicMessage?
  local message
  ---@type table<number, Neoagent.AnthropicBlockState>?
  local blocks
  return async.run(
    ---@param run Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
    ---@return Neoagent.ModelResult
    function(run)
      local ok, outcome = pcall(function()
        local outgoing, identity = self:_request(opts)
        local transport = request_context.bind_transport(self._transport, identity)
        message = {
          role = "assistant",
          content = {},
          api = self.api,
          provider = self.provider,
          model = self.id,
          usage = zero_usage(),
          stopReason = "stop",
          timestamp = util.now_ms(),
        }
        blocks = {}
        local message_start_seen = false
        local message_stop_seen = false
        local stop_seen = false

        ---@param raw unknown
        local function emit_usage(raw)
          update_usage(message.usage, raw)
          run:emit({ type = "usage", usage = util.copy(message.usage) })
        end

        ---@param value unknown
        ---@return string?
        local function valid_delta(value)
          if not nonempty(value) then
            return nil
          end
          if not util.is_valid_utf8(value) then
            error(util.error("protocol", "Anthropic delta must contain valid UTF-8"), 0)
          end
          return value
        end

        ---@param block Neoagent.TextBlock
        ---@param value unknown
        local function append_text(block, value)
          local delta = valid_delta(value)
          if not delta then
            return
          end
          block.text = block.text .. delta
          run:emit({ type = "text_delta", text = delta })
        end

        ---@param block Neoagent.ThinkingBlock
        ---@param value unknown
        local function append_thinking(block, value)
          local delta = valid_delta(value)
          if not delta then
            return
          end
          block.thinking = block.thinking .. delta
          run:emit({ type = "thinking_delta", text = delta })
        end

        ---@param index number
        ---@param state Neoagent.AnthropicBlockState
        local function register_block(index, state)
          blocks[index] = state
          message.content[#message.content + 1] = state.block
        end

        ---@param event Neoagent.JsonObject|Neoagent.JsonArray
        local function start_block(event)
          local index = event.index
          local raw = event.content_block
          if type(index) ~= "number" or index < 0 or index % 1 ~= 0 or type(raw) ~= "table" then
            error(util.error("protocol", "Invalid Anthropic content_block_start"), 0)
          end
          ---@cast index integer
          if blocks[index] then
            error(util.error("protocol", "Anthropic content block started twice"), 0)
          end
          if raw.type == "text" then
            ---@type Neoagent.TextBlock
            local block = { type = "text", text = "" }
            register_block(index, { block = block, stopped = false })
            append_text(block, raw.text)
          elseif raw.type == "thinking" then
            ---@type Neoagent.AnthropicThinkingBlock
            local block = { type = "thinking", thinking = "", thinkingSignature = "" }
            register_block(index, { block = block, stopped = false })
            append_thinking(block, raw.thinking)
          elseif raw.type == "redacted_thinking" then
            ---@type Neoagent.AnthropicThinkingBlock
            local block = {
              type = "thinking",
              thinking = "[Reasoning redacted]",
              thinkingSignature = block_string(raw.data, "redacted thinking data"),
              redacted = true,
            }
            register_block(index, { block = block, stopped = false })
            run:emit({ type = "thinking_delta", text = block.thinking })
          elseif raw.type == "tool_use" then
            ---@type Neoagent.ToolCallBlock
            local block = {
              type = "toolCall",
              id = block_string(raw.id, "tool id"),
              name = block_string(raw.name, "tool name"),
              arguments = vim.empty_dict(),
            }
            ---@type Neoagent.AnthropicToolState
            local state = {
              block = block,
              stopped = false,
              raw = "",
              input = raw.input == nil and vim.empty_dict() or util.copy(raw.input),
            }
            register_block(index, state)
          else
            error(util.error("protocol", "Unsupported Anthropic content block: " .. tostring(raw.type)), 0)
          end
        end

        ---@param event Neoagent.JsonObject|Neoagent.JsonArray
        local function delta_block(event)
          local index = event.index
          local state = type(index) == "number" and blocks[index] or nil
          local delta = event.delta
          if not state or state.stopped or type(delta) ~= "table" then
            error(util.error("protocol", "Anthropic delta has no active content block"), 0)
          end
          -- This state was registered under a validated integral block index.
          ---@cast index integer
          local block = state.block
          if delta.type == "text_delta" and block.type == "text" then
            ---@cast block Neoagent.TextBlock
            append_text(block, delta.text)
          elseif delta.type == "thinking_delta" and block.type == "thinking" then
            append_thinking(block, delta.thinking)
          elseif delta.type == "signature_delta" and block.type == "thinking" then
            if nonempty(delta.signature) then
              if not util.is_valid_utf8(delta.signature) then
                error(util.error("protocol", "Anthropic thinking signature must contain valid UTF-8"), 0)
              end
              block.thinkingSignature = block.thinkingSignature .. delta.signature
            end
          elseif delta.type == "input_json_delta" and block.type == "toolCall" then
            ---@cast state Neoagent.AnthropicToolState
            local value = type(delta.partial_json) == "string" and delta.partial_json or ""
            state.raw = state.raw .. value
            run:emit({
              type = "tool_call_delta",
              index = index,
              id = block.id ~= "" and block.id or nil,
              name = block.name ~= "" and block.name or nil,
              arguments_delta = value ~= "" and value or nil,
            })
          elseif delta.type ~= "citations_delta" then
            error(util.error("protocol", "Unsupported Anthropic content delta: " .. tostring(delta.type)), 0)
          end
        end

        ---@param event Neoagent.JsonObject|Neoagent.JsonArray
        local function stop_block(event)
          local index = event.index
          local state = type(index) == "number" and blocks[index] or nil
          if not state or state.stopped then
            error(util.error("protocol", "Anthropic content block stopped without a start"), 0)
          end
          state.stopped = true
          if state.block.type ~= "toolCall" then
            return
          end
          ---@cast state Neoagent.AnthropicToolState
          if not nonempty(state.block.id) then
            error(util.error("protocol", "Tool call is missing an id"), 0)
          end
          if not nonempty(state.block.name) then
            error(util.error("protocol", "Tool call is missing a name"), 0)
          end
          local arguments
          local arguments_error
          if state.raw ~= "" then
            arguments, arguments_error = tool_arguments.decode(state.raw)
          else
            arguments, arguments_error = tool_arguments.normalize(state.input)
          end
          -- The input came from JSON; normalization retains only an outer object.
          ---@cast arguments Neoagent.JsonObject
          state.block.arguments = arguments
          state.block.argumentsError = arguments_error
        end

        ---@param event Neoagent.JsonValue
        local function process_payload(event)
          if type(event) ~= "table" then
            error(util.error("protocol", "Expected an object in Anthropic SSE response"), 0)
          end
          if event.type == "ping" then
            return
          elseif event.type == "error" then
            error(
              util.error(
                "model",
                http_response.error_message(event, "Provider returned an error"),
                util.json_encode(event)
              ),
              0
            )
          elseif event.type == "message_start" then
            if message_start_seen or type(event.message) ~= "table" then
              error(util.error("protocol", "Invalid Anthropic message_start"), 0)
            end
            message_start_seen = true
            message.responseId = event.message.id
            emit_usage(event.message.usage)
          elseif event.type == "content_block_start" then
            start_block(event)
          elseif event.type == "content_block_delta" then
            delta_block(event)
          elseif event.type == "content_block_stop" then
            stop_block(event)
          elseif event.type == "message_delta" then
            local delta = type(event.delta) == "table" and event.delta or {}
            if nonempty(delta.stop_reason) then
              message.stopReason = stop_reason(delta.stop_reason, delta.stop_details)
              stop_seen = true
            end
            emit_usage(event.usage)
          elseif event.type == "message_stop" then
            message_stop_seen = true
          else
            error(util.error("protocol", "Unsupported Anthropic event: " .. tostring(event.type)), 0)
          end
        end

        local child = transport.stream({
          request = {
            url = outgoing.url,
            headers = outgoing.headers,
            body = util.json_encode(outgoing.body),
            timeout_ms = outgoing.timeout_ms,
          },
          on_event = process_payload,
        })
        local transport_ok, transport_result = pcall(function()
          return child:await()
        end)
        if not transport_ok then
          error(transport_result, 0)
        end
        http_response.check(transport_result)
        if not message_start_seen then
          error(util.error("protocol", "Anthropic stream ended without message_start"), 0)
        end
        if not message_stop_seen then
          error(util.error("protocol", "Anthropic stream ended without message_stop"), 0)
        end
        if not stop_seen then
          error(util.error("protocol", "Anthropic stream ended without stop_reason"), 0)
        end
        for _, state in pairs(blocks) do
          if not state.stopped then
            error(util.error("protocol", "Anthropic stream ended with an open content block"), 0)
          end
        end
        local normalized, message_err = semantic_message.normalize_model_response(message)
        if not normalized then
          error(message_err, 0)
        end
        return normalized
      end)

      if not ok then
        local err = util.normalize_error(outcome, "model")
        local partial = partial_message(message, blocks, err)
        return { ok = false, message = partial, error = err }
      end
      return { ok = true, message = outcome, text = util.text_content(outcome.content) }
    end,
    {
      on_event = opts.on_event,
      on_done = opts.on_done,
      error_kind = "model",
    }
  )
end

---@param opts Neoagent.AnthropicModelOptions
---@return Neoagent.AnthropicModel
function M.new(opts)
  opts = opts or {}
  assert(type(opts.provider) == "string" and opts.provider ~= "", "provider is required")
  assert(type(opts.model) == "string" and opts.model ~= "", "model is required")
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "base_url is required")
  local timeout_ms = request_opts.timeout(opts.timeout_ms)
  assert(
    opts.max_output_tokens == nil
      or (type(opts.max_output_tokens) == "number" and opts.max_output_tokens > 0 and opts.max_output_tokens % 1 == 0),
    "max_output_tokens must be a positive integer"
  )
  local layers = {}
  for _, layer in ipairs(opts.request_opts_layers or {}) do
    layers[#layers + 1] = layer
  end
  if opts.request_opts ~= nil then
    layers[#layers + 1] = opts.request_opts
  end
  local result = model_contract.assert(
    setmetatable({
      api = "anthropic-messages",
      provider = opts.provider,
      id = opts.model,
      input = util.copy(opts.input or { "text", "image" }),
      context_window = opts.context_window,
      timeout_ms = timeout_ms,
      _timeout_ms = timeout_ms,
      thinking = util.copy(opts.thinking),
      _base_url = opts.base_url:gsub("/+$", ""),
      _api_key = opts.api_key,
      _max_output_tokens = opts.max_output_tokens or 4096,
      _anthropic_version = "2023-06-01",
      _request_opts = layers,
      _request_context = request_context.copy(opts.request_context),
      _transport = http.new(opts.transport),
    }, Model),
    "Anthropic Messages constructor"
  )
  ---@cast result Neoagent.AnthropicModel
  return result
end

M._encode_messages = request.encode_messages

return M
