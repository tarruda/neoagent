local async = require("neoagent.async")
local request_opts = require("neoagent.api.request_opts")
local tool_schema = require("neoagent.api.tool_schema")
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

local function encode_content(content)
  if type(content) == "string" then
    return content
  end
  local result = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      result[#result + 1] = { type = "text", text = block.text or "" }
    elseif block.type == "image" then
      result[#result + 1] = {
        type = "image_url",
        image_url = { url = "data:" .. block.mimeType .. ";base64," .. block.data },
      }
    end
  end
  return result
end

local reasoning_fields = { "reasoning_content", "reasoning", "reasoning_text" }
local reasoning_field = {}
for _, field in ipairs(reasoning_fields) do reasoning_field[field] = true end

local function encode_messages(messages, system_prompt, requires_reasoning_content)
  local result = {}
  if system_prompt and system_prompt ~= "" then
    result[#result + 1] = { role = "system", content = system_prompt }
  end
  for _, message in ipairs(messages) do
    if message.role == "user" then
      result[#result + 1] = { role = "user", content = encode_content(message.content) }
    elseif message.role == "assistant" then
      local text = {}
      local calls = {}
      local reasoning = {}
      for _, block in ipairs(message.content or {}) do
        if block.type == "text" then
          text[#text + 1] = block.text or ""
        elseif block.type == "thinking" and type(block.thinking) == "string" and block.thinking ~= "" then
          local field = requires_reasoning_content and "reasoning_content" or block.thinkingSignature
          if reasoning_field[field] then
            reasoning[field] = reasoning[field] or {}
            reasoning[field][#reasoning[field] + 1] = block.thinking
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
        for _, image in ipairs(images) do
          content[#content + 1] = {
            type = "image_url",
            image_url = { url = "data:" .. image.mimeType .. ";base64," .. image.data },
          }
        end
        result[#result + 1] = { role = "user", content = content }
      end
    else
      error(util.error("model", "Unsupported message role: " .. tostring(message.role)), 0)
    end
  end
  return result
end

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

local function has_content(message)
  return message and #message.content > 0
end

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

local function usage_from(raw)
  local details = raw.prompt_tokens_details or {}
  local input = raw.prompt_tokens or 0
  local output = raw.completion_tokens or 0
  local cache_read = details.cached_tokens or raw.prompt_cache_hit_tokens or 0
  return {
    input = input,
    output = output,
    cacheRead = cache_read,
    cacheWrite = details.cache_write_tokens or 0,
    totalTokens = raw.total_tokens or (input + output),
    cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 },
  }
end

local Model = {}
Model.__index = Model

function Model:_request(call_opts)
  local headers = { ["Content-Type"] = "application/json" }
  local api_key = self._api_key
  if type(api_key) == "function" then
    api_key = api_key()
  end
  if api_key ~= nil and api_key ~= "" then
    headers.Authorization = "Bearer " .. api_key
  end
  local body = {
    model = self.id,
    messages = encode_messages(call_opts.messages, call_opts.system_prompt, self._requires_reasoning_content),
    stream = true,
  }
  if self._max_output_tokens then
    body.max_completion_tokens = self._max_output_tokens
  end
  local schemas = encode_tools(call_opts.tools)
  if #schemas > 0 then
    body.tools = schemas
  end
  local request = {
    url = self._base_url .. "/chat/completions",
    headers = headers,
    body = body,
  }
  local ctx = {
    model = self,
    messages = util.copy(call_opts.messages),
    system_prompt = call_opts.system_prompt,
    tools = util.copy(call_opts.tools or {}),
  }
  for _, layer in ipairs(self._request_opts) do
    request = request_opts.apply(request, layer, ctx)
  end
  request = request_opts.apply(request, call_opts.request_opts, ctx)
  return request
end

function Model:stream(opts)
  opts = opts or {}
  assert(type(opts.messages) == "table", "messages are required")
  local transport = self._transport
  local message
  return async.run(function(run)
    local ok, outcome = pcall(function()
      local request = self:_request(opts)
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
      local text_block
      local thinking_block
      local calls = {}
      local finish_seen = false
      local done_seen = false
      local protocol_error

      local function process_payload(payload)
        if payload == "[DONE]" then
          done_seen = true
          return
        end
        local decoded_ok, chunk = pcall(vim.json.decode, payload)
        if not decoded_ok or type(chunk) ~= "table" then
          error(util.error("protocol", "Invalid JSON in SSE response", decoded_ok and payload or chunk), 0)
        end
        if type(chunk.error) == "table" then
          error(util.error("model", chunk.error.message or "Provider returned an error", payload), 0)
        end
        if type(chunk.usage) == "table" then
          message.usage = usage_from(chunk.usage)
          run:emit({ type = "usage", usage = util.copy(message.usage) })
        end
        local choice = type(chunk.choices) == "table" and chunk.choices[1] or nil
        if not choice then
          return
        end
        if choice.finish_reason ~= nil and choice.finish_reason ~= vim.NIL then
          finish_seen = true
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
          if not thinking_block then
            thinking_block = { type = "thinking", thinking = "", thinkingSignature = thinking_signature }
            message.content[#message.content + 1] = thinking_block
          end
          thinking_block.thinking = thinking_block.thinking .. thinking
          run:emit({ type = "thinking_delta", text = thinking })
        end
        for _, raw_call in ipairs(delta.tool_calls or {}) do
          local index = raw_call.index or 0
          local call = calls[index]
          if not call then
            call = { type = "toolCall", id = "", name = "", arguments = vim.empty_dict(), _raw = "" }
            calls[index] = call
            message.content[#message.content + 1] = call
          end
          if type(raw_call.id) == "string" and raw_call.id ~= "" and call.id == "" then
            call.id = raw_call.id
          end
          local fn = raw_call["function"] or {}
          if type(fn.name) == "string" and fn.name ~= "" then
            call.name = call.name .. fn.name
          end
          local arguments_delta
          if type(fn.arguments) == "string" and fn.arguments ~= "" then
            arguments_delta = fn.arguments
            call._raw = call._raw .. arguments_delta
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

      local parser = sse.new({ on_event = process_payload })
      local child = transport.request({
        request = {
          url = request.url,
          headers = request.headers,
          body = util.json_encode(request.body),
        },
        on_chunk = function(chunk)
          local parsed, err = parser:feed(chunk)
          if not parsed then
            error(util.error("protocol", err), 0)
          end
        end,
      })
      local transport_ok, transport_result = pcall(function() return child:await() end)
      if transport_ok and transport_result.ok then
        parser:finish()
      end
      for _, call in pairs(calls) do
        local decoded_ok, arguments = pcall(vim.json.decode, call._raw ~= "" and call._raw or "{}")
        call._raw = nil
        if not decoded_ok or type(arguments) ~= "table" or util.is_list(arguments) then
          protocol_error = util.error("protocol", "Tool arguments are not a JSON object", decoded_ok and call.name or arguments)
        else
          call.arguments = arguments
        end
        if call.id == "" then
          protocol_error = util.error("protocol", "Tool call is missing an id")
        elseif call.name == "" then
          protocol_error = util.error("protocol", "Tool call is missing a name")
        end
      end
      if not transport_ok then
        error(transport_result, 0)
      end
      if not transport_result.ok then
        error(transport_result.error, 0)
      end
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
      local partial = type(message) == "table" and message or nil
      if partial and has_content(partial) then
        partial.stopReason = err.kind == "cancelled" and "aborted" or "error"
        partial.errorMessage = err.message
      else
        partial = nil
      end
      return { ok = false, message = partial, error = err }
    end
    local message = outcome
    return { ok = true, message = message, text = util.text_content(message.content) }
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
  local layers = {}
  for _, layer in ipairs(opts.request_opts_layers or {}) do
    layers[#layers + 1] = layer
  end
  if opts.request_opts ~= nil then
    layers[#layers + 1] = opts.request_opts
  end
  return setmetatable({
    api = "openai-completions",
    provider = opts.provider,
    id = opts.model,
    context_window = opts.context_window,
    _base_url = opts.base_url:gsub("/+$", ""),
    _api_key = opts.api_key,
    _max_output_tokens = opts.max_output_tokens,
    _requires_reasoning_content = opts.requires_reasoning_content == true or opts.provider == "deepseek",
    thinking = util.copy(opts.thinking),
    _request_opts = layers,
    _transport = opts.transport or curl,
  }, Model)
end

M._encode_messages = encode_messages

return M
