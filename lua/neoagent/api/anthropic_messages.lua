local async = require("neoagent.async")
local request = require("neoagent.api.anthropic_messages.request")
local curl = require("neoagent.transport.curl")
local sse = require("neoagent.transport.sse")
local util = require("neoagent.util")

local M = {}

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

local function update_usage(usage, raw)
  if type(raw) ~= "table" then return end
  if type(raw.input_tokens) == "number" then usage.input = raw.input_tokens end
  if type(raw.output_tokens) == "number" then usage.output = raw.output_tokens end
  if type(raw.cache_read_input_tokens) == "number" then
    usage.cacheRead = raw.cache_read_input_tokens
  end
  if type(raw.cache_creation_input_tokens) == "number" then
    usage.cacheWrite = raw.cache_creation_input_tokens
  end
  usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
end

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

local function has_content(message)
  return type(message) == "table" and type(message.content) == "table" and #message.content > 0
end

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

local Model = {}
Model.__index = Model

function Model:_request(call_opts)
  return request.build(self, call_opts)
end

function Model:stream(opts)
  opts = opts or {}
  assert(type(opts.messages) == "table", "messages are required")
  local transport = self._transport
  local message
  return async.run(function(run)
    local ok, outcome = pcall(function()
      local outgoing = self:_request(opts)
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
      local blocks = {}
      local message_start_seen = false
      local message_stop_seen = false
      local stop_seen = false

      local function emit_usage(raw)
        update_usage(message.usage, raw)
        run:emit({ type = "usage", usage = util.copy(message.usage) })
      end

      local function append_delta(state, field, value, event_type)
        if not nonempty(value) then return end
        state.block[field] = state.block[field] .. value
        run:emit({ type = event_type, text = value })
      end

      local function start_block(event)
        local index = event.index
        local raw = event.content_block
        if type(index) ~= "number" or type(raw) ~= "table" then
          error(util.error("protocol", "Invalid Anthropic content_block_start"), 0)
        end
        if blocks[index] then
          error(util.error("protocol", "Anthropic content block started twice"), 0)
        end
        local block
        local state = { stopped = false }
        if raw.type == "text" then
          block = { type = "text", text = "" }
          state.block = block
          blocks[index] = state
          message.content[#message.content + 1] = block
          append_delta(state, "text", raw.text, "text_delta")
        elseif raw.type == "thinking" then
          block = { type = "thinking", thinking = "", thinkingSignature = "" }
          state.block = block
          blocks[index] = state
          message.content[#message.content + 1] = block
          append_delta(state, "thinking", raw.thinking, "thinking_delta")
        elseif raw.type == "redacted_thinking" then
          block = {
            type = "thinking",
            thinking = "[Reasoning redacted]",
            thinkingSignature = raw.data or "",
            redacted = true,
          }
          state.block = block
          blocks[index] = state
          message.content[#message.content + 1] = block
          run:emit({ type = "thinking_delta", text = block.thinking })
        elseif raw.type == "tool_use" then
          block = {
            type = "toolCall",
            id = raw.id or "",
            name = raw.name or "",
            arguments = vim.empty_dict(),
          }
          state.block = block
          state.input = type(raw.input) == "table" and util.copy(raw.input) or vim.empty_dict()
          state.raw = ""
          blocks[index] = state
          message.content[#message.content + 1] = block
        else
          error(util.error("protocol", "Unsupported Anthropic content block: " .. tostring(raw.type)), 0)
        end
      end

      local function delta_block(event)
        local state = blocks[event.index]
        local delta = event.delta
        if not state or state.stopped or type(delta) ~= "table" then
          error(util.error("protocol", "Anthropic delta has no active content block"), 0)
        end
        if delta.type == "text_delta" and state.block.type == "text" then
          append_delta(state, "text", delta.text, "text_delta")
        elseif delta.type == "thinking_delta" and state.block.type == "thinking" then
          append_delta(state, "thinking", delta.thinking, "thinking_delta")
        elseif delta.type == "signature_delta" and state.block.type == "thinking" then
          if nonempty(delta.signature) then
            state.block.thinkingSignature = state.block.thinkingSignature .. delta.signature
          end
        elseif delta.type == "input_json_delta" and state.block.type == "toolCall" then
          local value = type(delta.partial_json) == "string" and delta.partial_json or ""
          state.raw = state.raw .. value
          run:emit({
            type = "tool_call_delta",
            index = event.index,
            id = state.block.id ~= "" and state.block.id or nil,
            name = state.block.name ~= "" and state.block.name or nil,
            arguments_delta = value ~= "" and value or nil,
          })
        elseif delta.type ~= "citations_delta" then
          error(util.error("protocol", "Unsupported Anthropic content delta: " .. tostring(delta.type)), 0)
        end
      end

      local function stop_block(event)
        local state = blocks[event.index]
        if not state or state.stopped then
          error(util.error("protocol", "Anthropic content block stopped without a start"), 0)
        end
        state.stopped = true
        if state.block.type ~= "toolCall" then return end
        if not nonempty(state.block.id) then
          error(util.error("protocol", "Tool call is missing an id"), 0)
        end
        if not nonempty(state.block.name) then
          error(util.error("protocol", "Tool call is missing a name"), 0)
        end
        local input = state.input
        if state.raw ~= "" then
          local decoded, value = pcall(vim.json.decode, state.raw)
          if not decoded then
            error(util.error("protocol", "Tool input is not valid JSON", value), 0)
          end
          input = value
        end
        if type(input) ~= "table" or util.is_list(input) then
          error(util.error("protocol", "Tool input is not a JSON object"), 0)
        end
        state.block.arguments = next(input) == nil and vim.empty_dict() or input
      end

      local function process_payload(payload)
        local decoded, event = pcall(vim.json.decode, payload)
        if not decoded or type(event) ~= "table" then
          error(util.error("protocol", "Invalid JSON in Anthropic SSE response", decoded and payload or event), 0)
        end
        if event.type == "ping" then
          return
        elseif event.type == "error" then
          local provider_error = type(event.error) == "table" and event.error or {}
          error(util.error("model", provider_error.message or "Provider returned an error", payload), 0)
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

      local parser = sse.new({ on_event = process_payload })
      local child = transport.request({
        request = {
          url = outgoing.url,
          headers = outgoing.headers,
          body = vim.json.encode(outgoing.body),
        },
        on_chunk = function(chunk)
          local parsed, err = parser:feed(chunk)
          if not parsed then error(util.error("protocol", err), 0) end
        end,
      })
      local transport_ok, transport_result = pcall(function() return child:await() end)
      if transport_ok and transport_result.ok then parser:finish() end
      if not transport_ok then error(transport_result, 0) end
      if not transport_result.ok then error(transport_result.error, 0) end
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
      return message
    end)

    if not ok then
      local err = util.normalize_error(outcome, "model")
      local partial = has_content(message) and message or nil
      if partial then
        partial.stopReason = err.kind == "cancelled" and "aborted" or "error"
        partial.errorMessage = err.message
      end
      return { ok = false, message = partial, error = err }
    end
    return { ok = true, message = outcome, text = util.text_content(outcome.content) }
  end, {
    on_event = opts.on_event,
    on_done = opts.on_done,
    error_kind = "model",
  })
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.provider) == "string" and opts.provider ~= "", "provider is required")
  assert(type(opts.model) == "string" and opts.model ~= "", "model is required")
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "base_url is required")
  assert(opts.max_output_tokens == nil or (type(opts.max_output_tokens) == "number"
    and opts.max_output_tokens > 0 and opts.max_output_tokens % 1 == 0),
    "max_output_tokens must be a positive integer")
  local layers = {}
  for _, layer in ipairs(opts.request_opts_layers or {}) do layers[#layers + 1] = layer end
  if opts.request_opts ~= nil then layers[#layers + 1] = opts.request_opts end
  return setmetatable({
    api = "anthropic-messages",
    provider = opts.provider,
    id = opts.model,
    context_window = opts.context_window,
    thinking = util.copy(opts.thinking),
    _base_url = opts.base_url:gsub("/+$", ""),
    _api_key = opts.api_key,
    _max_output_tokens = opts.max_output_tokens or 4096,
    _anthropic_version = "2023-06-01",
    _request_opts = layers,
    _transport = opts.transport or curl,
  }, Model)
end

M._encode_messages = request.encode_messages

return M
