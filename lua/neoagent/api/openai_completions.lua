local async = require("neoagent.async")
local messages = require("neoagent.api.messages")
local model_contract = require("neoagent.model")
local request_context = require("neoagent.api.request_context")
local request_opts = require("neoagent.api.request_opts")
local request_stream = require("neoagent.api.request_stream")
local semantic_message = require("neoagent.semantic_message")
local tool_arguments = require("neoagent.api.tool_arguments")
local tool_schema = require("neoagent.api.tool_schema")
local http = require("neoagent.transport.http")
local http_response = require("neoagent.api.http_response")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.CompletionsOptions: Neoagent.ApiModelOptions
---@field requires_reasoning_content? boolean

---@class Neoagent.CompletionsCall
---@field block Neoagent.ToolCallBlock
---@field raw string

---@class Neoagent.GenerationSample
---@field tokens number
---@field elapsed_ms number

---@class Neoagent.GenerationSamples
---@field generation_samples Neoagent.GenerationSample[]
---@field generation_head integer

---@return Neoagent.Usage
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

---@async
---@param content string|Neoagent.InputBlock[]
---@param image Neoagent.ImageEncoder
---@return string|Neoagent.JsonObject[]
local function encode_content(content, image)
  if type(content) == "string" then
    return content
  end
  local result = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      result[#result + 1] = { type = "text", text = block.text or "" }
    elseif block.type == "image" then
      result[#result + 1] = image(block)
    end
  end
  return result
end

local reasoning_fields = { "reasoning_content", "reasoning", "reasoning_text" }
local reasoning_field = {}
for _, field in ipairs(reasoning_fields) do
  reasoning_field[field] = true
end

---@param message Neoagent.AssistantMessage
---@param requires_reasoning_content? boolean
---@return Neoagent.JsonObject?
local function encode_assistant(message, requires_reasoning_content)
  local text = {}
  local calls = {}
  local reasoning = {}
  for _, block in ipairs(message.content or {}) do
    if block.type == "text" then
      text[#text + 1] = block.text or ""
    elseif block.type == "thinking" then
      if type(block.thinking) == "string" and block.thinking ~= "" then
        local field = requires_reasoning_content and "reasoning_content" or block.thinkingSignature
        if reasoning_field[field] then
          reasoning[field] = reasoning[field] or {}
          reasoning[field][#reasoning[field] + 1] = block.thinking
        end
      end
    elseif block.type == "toolCall" then
      calls[#calls + 1] = {
        id = block.id,
        type = "function",
        ["function"] = { name = block.name, arguments = util.json_encode(block.arguments or vim.empty_dict()) },
      }
    end
  end
  if #text > 0 or #calls > 0 then
    local encoded = {
      role = "assistant",
      content = #text > 0 and table.concat(text) or vim.NIL,
    }
    for field, values in pairs(reasoning) do
      encoded[field] = table.concat(values, "\n")
    end
    if requires_reasoning_content and encoded.reasoning_content == nil then
      encoded.reasoning_content = ""
    end
    if #calls > 0 then
      encoded.tool_calls = calls
    end
    return encoded
  end
end

---@async
---@param messages Neoagent.Message[]
---@param system_prompt? string
---@param requires_reasoning_content? boolean
---@param image? Neoagent.ImageEncoder
---@return Neoagent.JsonObject[]
local function encode_messages(messages, system_prompt, requires_reasoning_content, image)
  image = image or require("neoagent.api.images").inline("openai-completions")
  local result = {}
  if system_prompt and system_prompt ~= "" then
    result[#result + 1] = { role = "system", content = system_prompt }
  end
  local attachments = {}
  for _, message in ipairs(messages) do
    if message.role ~= "toolResult" and #attachments > 0 then
      vim.list_extend(result, attachments)
      attachments = {}
    end
    if message.role == "user" then
      result[#result + 1] = { role = "user", content = encode_content(message.content, image) }
    elseif message.role == "assistant" then
      local encoded = encode_assistant(message, requires_reasoning_content)
      if encoded then
        result[#result + 1] = encoded
      end
    elseif message.role == "toolResult" then
      local text = {}
      local images = {}
      for _, block in ipairs(message.content or {}) do
        if block.type == "text" then
          text[#text + 1] = block.text or ""
        elseif block.type == "image" then
          images[#images + 1] = block
        end
      end
      local tool_text = table.concat(text, "\n")
      if tool_text == "" then
        tool_text = #images > 0 and "(see attached image)" or "(no tool output)"
      end
      result[#result + 1] = {
        role = "tool",
        tool_call_id = message.toolCallId,
        content = tool_text,
      }
      if #images > 0 then
        local content = { { type = "text", text = "Attached image(s) from tool result:" } }
        for _, block in ipairs(images) do
          content[#content + 1] = image(block)
        end
        attachments[#attachments + 1] = { role = "user", content = content }
      end
    else
      error(util.error("model", "Unsupported message role: " .. tostring(message.role)), 0)
    end
  end
  vim.list_extend(result, attachments)
  return result
end

---@param tools? Neoagent.ToolDefinition[]
---@return Neoagent.JsonObject[]
local function encode_tools(tools)
  local result = {}
  for _, tool in ipairs(tools or {}) do
    result[#result + 1] = {
      type = "function",
      ["function"] = {
        name = tool.name,
        description = tool.description,
        parameters = tool_schema.normalize(tool.input_schema),
      },
    }
  end
  return result
end

---@param reason unknown
---@return string
local function stop_reason(reason)
  if reason == "tool_calls" or reason == "function_call" then
    return "toolUse"
  elseif reason == "length" then
    return "length"
  elseif reason == "stop" or reason == nil then
    return "stop"
  end
  return "error"
end

---@param message? Neoagent.AssistantMessage
---@param calls_complete boolean
---@param err Neoagent.Error
---@return Neoagent.AssistantMessage?
local function partial_message(message, calls_complete, err)
  if type(message) ~= "table" then
    return nil
  end
  local candidate = util.copy(message)
  candidate.content = {}
  for _, block in ipairs(message.content or {}) do
    local retained
    if block.type == "text" and type(block.text) == "string" and block.text ~= "" then
      retained = util.copy(block)
    elseif block.type == "thinking" and type(block.thinking) == "string" and block.thinking ~= "" then
      retained = util.copy(block)
    elseif
      block.type == "toolCall"
      and calls_complete
      and type(block.id) == "string"
      and block.id ~= ""
      and type(block.name) == "string"
      and block.name ~= ""
    then
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

---@param raw Neoagent.JsonObject|Neoagent.JsonArray
---@return Neoagent.Usage
local function usage_from(raw)
  local details = type(raw.prompt_tokens_details) == "table" and raw.prompt_tokens_details or {}
  local input = type(raw.prompt_tokens) == "number" and raw.prompt_tokens or 0
  local output = type(raw.completion_tokens) == "number" and raw.completion_tokens or 0
  local cache_read = type(details.cached_tokens) == "number" and details.cached_tokens
    or type(raw.prompt_cache_hit_tokens) == "number" and raw.prompt_cache_hit_tokens
    or 0
  return {
    input = input,
    output = output,
    cacheRead = cache_read,
    cacheWrite = type(details.cache_write_tokens) == "number" and details.cache_write_tokens or 0,
    totalTokens = type(raw.total_tokens) == "number" and raw.total_tokens or (input + output),
    cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 },
  }
end

---@param value unknown
---@return number?
local function positive_number(value)
  if type(value) == "string" then
    value = tonumber(value)
  end
  if type(value) ~= "number" or value <= 0 or value ~= value or value == math.huge then
    return nil
  end
  return value
end

---@param value unknown
---@return number?
local function nonnegative_number(value)
  if type(value) == "string" then
    value = tonumber(value)
  end
  if type(value) ~= "number" or value < 0 or value ~= value or value == math.huge then
    return nil
  end
  return value
end

---@param tokens unknown
---@param duration unknown
---@param scale? number
---@return number?
local function tokens_per_second(tokens, duration, scale)
  tokens = positive_number(tokens)
  duration = positive_number(duration)
  if not tokens or not duration then
    return nil
  end
  return positive_number(tokens * (scale or 1) / duration)
end

local GENERATION_WINDOW_MS = 3000

---@param timings Neoagent.JsonObject|Neoagent.JsonArray
---@param state Neoagent.GenerationSamples
---@return number? rate
---@return boolean cumulative
---@return number? tokens
local function rolling_generation_rate(timings, state)
  local tokens = nonnegative_number(timings.predicted_n)
  local elapsed_ms = nonnegative_number(timings.predicted_ms)
  if tokens == nil or elapsed_ms == nil then
    return nil, false, tokens
  end
  local samples = state.generation_samples
  local head = state.generation_head
  local previous = samples[#samples]
  if tokens <= 0 then
    state.generation_samples = {}
    state.generation_head = 1
    return nil, true, tokens
  end
  if previous and (tokens < previous.tokens or elapsed_ms < previous.elapsed_ms) then
    samples = {}
    state.generation_samples = samples
    state.generation_head = 1
    head = 1
  end
  previous = samples[#samples]
  if previous and tokens == previous.tokens then
    return nil, true, tokens
  end
  samples[#samples + 1] = { tokens = tokens, elapsed_ms = elapsed_ms }
  local cutoff = elapsed_ms - GENERATION_WINDOW_MS
  local next_sample = samples[head + 1]
  while next_sample and next_sample.elapsed_ms <= cutoff do
    head = head + 1
    next_sample = samples[head + 1]
  end
  if head > 128 then
    local retained = {}
    for index = head, #samples do
      retained[#retained + 1] = samples[index]
    end
    state.generation_samples = retained
    samples = retained
    head = 1
  end
  state.generation_head = head
  local baseline = samples[head]
  -- A sample was appended and head advances only to an existing sample.
  ---@cast baseline Neoagent.GenerationSample
  if baseline == samples[#samples] then
    return nil, true, tokens
  end
  return tokens_per_second(tokens - baseline.tokens, elapsed_ms - baseline.elapsed_ms, 1000), true, tokens
end

---@param chunk Neoagent.JsonObject|Neoagent.JsonArray
---@param timings Neoagent.JsonObject|Neoagent.JsonArray
---@return number? rate
---@return number? elapsed_ms
local function prompt_rate(chunk, timings)
  local progress = type(chunk.prompt_progress) == "table" and chunk.prompt_progress or nil
  if progress then
    local processed = nonnegative_number(progress.processed)
    local cached = nonnegative_number(progress.cache) or 0
    local elapsed_ms = nonnegative_number(progress.time_ms)
    local tokens = processed and math.max(0, processed - cached) or nil
    return tokens_per_second(tokens, elapsed_ms, 1000), elapsed_ms
  end
  local elapsed_ms = nonnegative_number(timings.prompt_ms)
  return positive_number(timings.prompt_per_second) or tokens_per_second(timings.prompt_n, elapsed_ms, 1000), elapsed_ms
end

---@param chunk Neoagent.JsonObject|Neoagent.JsonArray
---@param state Neoagent.GenerationSamples
---@return Neoagent.ModelInferenceStats?
local function inference_stats(chunk, state)
  local timings = type(chunk.timings) == "table" and chunk.timings or {}
  local generation, cumulative, generated = rolling_generation_rate(timings, state)
  if not cumulative then
    generation = positive_number(timings.predicted_per_second)
  end
  if generation then
    return {
      type = "inference_stats",
      generation_tokens_per_second = generation,
    }
  end
  if generated and generated > 0 then
    return nil
  end
  local prompt, elapsed_ms = prompt_rate(chunk, timings)
  if prompt then
    return {
      type = "inference_stats",
      elapsed_ms = elapsed_ms,
      prompt_tokens_per_second = prompt,
    }
  end
end

---@class Neoagent.CompletionsModel: Neoagent.Model
---@field _base_url string
---@field _api_key? string|fun(): string?
---@field _max_output_tokens? number
---@field _requires_reasoning_content boolean
---@field _request_opts Neoagent.RequestLayer[]
---@field _request_context? Neoagent.RequestIdentity
---@field _timeout_ms? integer
---@field _transport Neoagent.HttpClient
---@field _images? Neoagent.ImageRequest
local Model = {}
Model.__index = Model

---@param call_opts Neoagent.StreamOptions
---@return Neoagent.RequestPlan
---@return Neoagent.RequestIdentity?
function Model:_request(call_opts)
  call_opts = util.copy(call_opts)
  local headers = { ["Content-Type"] = "application/json" }
  local api_key = self._api_key
  if type(api_key) == "function" then
    api_key = api_key()
  end
  if api_key ~= nil and api_key ~= "" then
    headers.Authorization = "Bearer " .. api_key
  end
  ---@type Neoagent.JsonObject
  local body = {
    model = self.id,
    stream = true,
    stream_options = { include_usage = true },
  }
  if self._max_output_tokens then
    body.max_completion_tokens = self._max_output_tokens
  end
  local schemas = encode_tools(call_opts.tools)
  if #schemas > 0 then
    body.tools = schemas
  end
  ---@type Neoagent.ApiRequest
  local request = {
    url = self._base_url .. "/chat/completions",
    headers = headers,
    body = body,
    messages = util.copy(call_opts.messages),
    timeout_ms = request_opts.timeout(self._timeout_ms, call_opts.timeout_ms),
  }
  local ctx = {
    model = self,
    messages = util.copy(call_opts.messages),
    system_prompt = call_opts.system_prompt,
    tools = util.copy(call_opts.tools or {}),
    request_context = request_context.resolve(self._request_context, call_opts.request_context),
  }
  for _, layer in ipairs(self._request_opts) do
    request = request_opts.apply(request, layer, ctx)
  end
  request = request_opts.apply(request, call_opts.request_opts, ctx)
  local selected = messages.for_model(assert(request.messages), self)
  return {
    api = self.api,
    request = request,
    messages = selected,
    ---@async
    encode = function(image)
      local encoded = util.copy(request.body or {})
      encoded.messages = encode_messages(selected, call_opts.system_prompt, self._requires_reasoning_content, image)
      return encoded
    end,
  },
    ctx.request_context
end

---@param opts Neoagent.StreamOptions
---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
function Model:stream(opts)
  opts = util.copy(opts or {})
  assert(type(opts.messages) == "table", "messages are required")
  ---@type Neoagent.AssistantMessage?
  local message
  ---@type table<integer, Neoagent.CompletionsCall>
  local calls
  local calls_complete = false
  return async.run(
    ---@param run Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
    ---@return Neoagent.ModelResult
    function(run)
      local ok, outcome = pcall(function()
        require("neoagent.model").require_files(opts)
        local request, identity = self:_request(opts)
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
        ---@type Neoagent.TextBlock?
        local text_block
        ---@type Neoagent.ThinkingBlock?
        local thinking_block
        calls = {}
        local finish_seen = false
        local done_seen = false
        local protocol_error
        ---@type Neoagent.ModelInferenceStats?
        local last_inference_stats
        local inference_state = { generation_samples = {}, generation_head = 1 }

        ---@param chunk Neoagent.JsonValue
        local function process_payload(chunk)
          if type(chunk) ~= "table" then
            error(util.error("protocol", "Expected an object in SSE response"), 0)
          end
          if type(chunk.error) == "table" then
            error(
              util.error(
                "model",
                http_response.error_message(chunk, "Provider returned an error"),
                util.json_encode(chunk)
              ),
              0
            )
          end
          if type(chunk.usage) == "table" then
            message.usage = usage_from(chunk.usage)
            run:emit({ type = "usage", usage = util.copy(message.usage) })
          end
          local stats = inference_stats(chunk, inference_state)
          local stats_changed = false
          if stats then
            stats_changed = not last_inference_stats
              or stats.prompt_tokens_per_second ~= last_inference_stats.prompt_tokens_per_second
              or stats.generation_tokens_per_second ~= last_inference_stats.generation_tokens_per_second
              or stats.elapsed_ms ~= last_inference_stats.elapsed_ms
          end
          if stats and stats_changed then
            last_inference_stats = stats
            run:emit(util.copy(stats))
          end
          local choice = type(chunk.choices) == "table" and chunk.choices[1] or nil
          if not choice then
            return
          end
          if choice.finish_reason ~= nil and choice.finish_reason ~= vim.NIL then
            finish_seen = true
            calls_complete = true
            message.stopReason = stop_reason(choice.finish_reason)
            if message.stopReason == "error" then
              error(util.error("model", "Provider finish_reason: " .. tostring(choice.finish_reason)), 0)
            end
          end
          local delta = choice.delta
          if type(delta) ~= "table" then
            return
          end
          if type(delta.content) == "string" and delta.content ~= "" then
            if not util.is_valid_utf8(delta.content) then
              error(util.error("protocol", "OpenAI text delta must contain valid UTF-8"), 0)
            end
            if not text_block then
              text_block = { type = "text", text = "" }
              message.content[#message.content + 1] = text_block
            end
            text_block.text = text_block.text .. delta.content
            run:emit({ type = "text_delta", text = delta.content })
          end
          local thinking
          local thinking_signature
          for _, field in ipairs(reasoning_fields) do
            local value = delta[field]
            if type(value) == "string" and value ~= "" then
              thinking = value
              thinking_signature = field
              break
            end
          end
          if thinking then
            if not util.is_valid_utf8(thinking) then
              error(util.error("protocol", "OpenAI thinking delta must contain valid UTF-8"), 0)
            end
            if not thinking_block then
              thinking_block = { type = "thinking", thinking = "", thinkingSignature = thinking_signature }
              message.content[#message.content + 1] = thinking_block
            end
            thinking_block.thinking = thinking_block.thinking .. thinking
            run:emit({ type = "thinking_delta", text = thinking })
          end
          local tool_calls = type(delta.tool_calls) == "table" and delta.tool_calls or {}
          for _, raw_call in ipairs(tool_calls) do
            local index = raw_call.index or 0
            local pending = calls[index]
            if not pending then
              pending = {
                block = { type = "toolCall", id = "", name = "", arguments = vim.empty_dict() },
                raw = "",
              }
              calls[index] = pending
              message.content[#message.content + 1] = pending.block
            end
            local call = pending.block
            if type(raw_call.id) == "string" and raw_call.id ~= "" and call.id == "" then
              call.id = raw_call.id
            end
            local fn = type(raw_call["function"]) == "table" and raw_call["function"] or {}
            if type(fn.name) == "string" and fn.name ~= "" then
              call.name = call.name .. fn.name
            end
            local arguments_delta
            if type(fn.arguments) == "string" and fn.arguments ~= "" then
              arguments_delta = fn.arguments
              pending.raw = pending.raw .. arguments_delta
            end
            run:emit({
              type = "tool_call_delta",
              index = index,
              id = call.id ~= "" and call.id or nil,
              name = call.name ~= "" and call.name or nil,
              arguments_delta = arguments_delta,
            })
          end
        end

        local child = request_stream.send(transport, request, opts, {
          on_event = process_payload,
          on_done_marker = function()
            done_seen = true
            calls_complete = true
          end,
        }, self._images)
        local transport_ok, transport_result = pcall(function()
          return child:await()
        end)
        for _, pending in pairs(calls) do
          local call = pending.block
          if calls_complete and call.id ~= "" and call.name ~= "" then
            call.arguments, call.argumentsError = tool_arguments.decode(pending.raw)
          end
          if calls_complete and call.id == "" then
            protocol_error = util.error("protocol", "Tool call is missing an id")
          elseif calls_complete and call.name == "" then
            protocol_error = util.error("protocol", "Tool call is missing a name")
          end
        end
        if not transport_ok then
          error(transport_result, 0)
        end
        http_response.check(transport_result)
        if protocol_error then
          error(protocol_error, 0)
        end
        if not finish_seen and not done_seen then
          error(util.error("protocol", "Stream ended without finish_reason or [DONE]"), 0)
        end
        return message
      end)

      if not ok then
        local err = util.normalize_error(outcome, "model")
        local partial = partial_message(message, calls_complete, err)
        return { ok = false, message = partial, error = err }
      end
      local message, message_err = semantic_message.normalize_model_response(outcome)
      if not message then
        return {
          ok = false,
          error = message_err,
        }
      end
      return { ok = true, message = message, text = util.text_content(message.content) }
    end,
    {
      on_event = opts.on_event,
      on_done = opts.on_done,
      error_kind = "model",
    }
  )
end

---@param opts Neoagent.CompletionsOptions
---@return Neoagent.CompletionsModel
function M.new(opts)
  opts = opts or {}
  assert(type(opts.provider) == "string" and opts.provider ~= "", "provider is required")
  assert(type(opts.model) == "string" and opts.model ~= "", "model is required")
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "base_url is required")
  local layers = {}
  for _, layer in ipairs(opts.request_opts_layers or {}) do
    layers[#layers + 1] = layer
  end
  if opts.request_opts ~= nil then
    layers[#layers + 1] = opts.request_opts
  end
  local timeout_ms = request_opts.timeout(opts.timeout_ms)
  local model = model_contract.assert(
    setmetatable({
      api = "openai-completions",
      provider = opts.provider,
      id = opts.model,
      input = util.copy(opts.input or { "text", "image" }),
      context_window = opts.context_window,
      timeout_ms = timeout_ms,
      _base_url = opts.base_url:gsub("/+$", ""),
      _api_key = opts.api_key,
      _max_output_tokens = opts.max_output_tokens,
      _requires_reasoning_content = opts.requires_reasoning_content == true or opts.provider == "deepseek",
      thinking = util.copy(opts.thinking),
      _request_opts = layers,
      _request_context = request_context.copy(opts.request_context),
      _timeout_ms = timeout_ms,
      _transport = http.new(opts.transport),
      _images = request_stream.validate(opts._images),
    }, Model),
    "OpenAI Chat Completions constructor"
  )
  -- Validation normalizes public capabilities while retaining the adapter fields.
  ---@cast model Neoagent.CompletionsModel
  return model
end

M._encode_messages = encode_messages

return M
