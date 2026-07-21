local async = require("neoagent.async")
local request_opts = require("neoagent.api.request_opts")
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
    reasoning = 0,
    totalTokens = 0,
    cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 },
  }
end

local function input_content(content)
  local result = util.list()
  if type(content) == "string" then
    result[1] = { type = "input_text", text = content }
    return result
  end
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      result[#result + 1] = { type = "input_text", text = block.text or "" }
    elseif block.type == "image" then
      result[#result + 1] = {
        type = "input_image",
        detail = "auto",
        image_url = "data:" .. block.mimeType .. ";base64," .. block.data,
      }
    end
  end
  return result
end

local function signature_id(signature, fallback)
  if type(signature) ~= "string" or signature == "" then return fallback end
  if signature:sub(1, 1) ~= "{" then return signature end
  local ok, value = pcall(vim.json.decode, signature)
  return ok and type(value) == "table" and type(value.id) == "string" and value.id or fallback
end

local function split_call_id(value)
  local call_id, item_id = tostring(value or ""):match("^([^|]+)|(.+)$")
  return call_id or tostring(value or ""), item_id
end

local function encode_messages(messages, system_prompt, include_system)
  local result = util.list()
  if include_system ~= false and system_prompt and system_prompt ~= "" then
    result[#result + 1] = { role = "system", content = system_prompt }
  end
  for message_index, message in ipairs(messages) do
    if message.role == "user" then
      local content = input_content(message.content)
      if #content > 0 then result[#result + 1] = { role = "user", content = content } end
    elseif message.role == "assistant" then
      local text_index = 0
      for _, block in ipairs(message.content or {}) do
        if block.type == "thinking" and type(block.thinkingSignature) == "string" then
          local ok, item = pcall(vim.json.decode, block.thinkingSignature)
          if not ok or type(item) ~= "table" or item.type ~= "reasoning" then
            error(util.error("model", "Invalid reasoning signature"), 0)
          end
          result[#result + 1] = item
        elseif block.type == "text" then
          text_index = text_index + 1
          result[#result + 1] = {
            type = "message",
            role = "assistant",
            status = "completed",
            id = signature_id(block.textSignature,
              string.format("msg_neoagent_%d_%d", message_index, text_index)),
            content = { {
              type = "output_text",
              text = block.text or "",
              annotations = util.list(),
            } },
          }
        elseif block.type == "toolCall" then
          local call_id, item_id = split_call_id(block.id)
          local item = {
            type = "function_call",
            call_id = call_id,
            name = block.name,
            arguments = vim.json.encode(block.arguments or vim.empty_dict()),
          }
          if item_id then item.id = item_id end
          result[#result + 1] = item
        end
      end
    elseif message.role == "toolResult" then
      local call_id = split_call_id(message.toolCallId)
      local text = {}
      local output = util.list()
      for _, block in ipairs(message.content or {}) do
        if block.type == "text" then
          text[#text + 1] = block.text or ""
        elseif block.type == "image" then
          output[#output + 1] = {
            type = "input_image",
            detail = "auto",
            image_url = "data:" .. block.mimeType .. ";base64," .. block.data,
          }
        end
      end
      local joined = table.concat(text, "\n")
      if #output > 0 then
        if joined ~= "" then table.insert(output, 1, { type = "input_text", text = joined }) end
      else
        output = joined ~= "" and joined or "(no tool output)"
      end
      result[#result + 1] = { type = "function_call_output", call_id = call_id, output = output }
    else
      error(util.error("model", "Unsupported message role: " .. tostring(message.role)), 0)
    end
  end
  return result
end

local function encode_tools(tools, strict)
  local result = util.list()
  if strict == nil then strict = false end
  for _, tool in ipairs(tools or {}) do
    result[#result + 1] = {
      type = "function",
      name = tool.name,
      description = tool.description,
      parameters = util.copy(tool.input_schema),
      strict = strict,
    }
  end
  return result
end

local function usage_from(raw)
  local input_details = raw.input_tokens_details or {}
  local output_details = raw.output_tokens_details or {}
  local cache_read = input_details.cached_tokens or 0
  local cache_write = input_details.cache_write_tokens or 0
  local input = math.max(0, (raw.input_tokens or 0) - cache_read - cache_write)
  local output = raw.output_tokens or 0
  return {
    input = input,
    output = output,
    cacheRead = cache_read,
    cacheWrite = cache_write,
    reasoning = output_details.reasoning_tokens or 0,
    totalTokens = raw.total_tokens or (input + output + cache_read + cache_write),
    cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 },
  }
end

local function has_content(message)
  return message and #message.content > 0
end

local Model = {}
Model.__index = Model

function Model:_request(call_opts)
  local headers = {
    ["Accept"] = "text/event-stream",
    ["Content-Type"] = "application/json",
  }
  local api_key = self._api_key
  if type(api_key) == "function" then api_key = api_key() end
  if api_key ~= nil and api_key ~= "" then headers.Authorization = "Bearer " .. api_key end

  local codex = self._profile == "codex"
  local body = {
    model = self.id,
    input = encode_messages(call_opts.messages, call_opts.system_prompt, not codex),
    stream = true,
    store = false,
  }
  if codex then
    body.instructions = call_opts.system_prompt or "You are a helpful assistant."
    body.text = { verbosity = self._text_verbosity or "low" }
    body.include = { "reasoning.encrypted_content" }
    body.tool_choice = "auto"
    body.parallel_tool_calls = true
  end
  if self._max_output_tokens then body.max_output_tokens = math.max(16, self._max_output_tokens) end
  local tools = encode_tools(call_opts.tools, codex and vim.NIL or false)
  if #tools > 0 then body.tools = tools end
  if self._reasoning then
    body.reasoning = {
      effort = self._reasoning_effort or "medium",
      summary = self._reasoning_summary or "auto",
    }
    body.include = { "reasoning.encrypted_content" }
  end

  local request = {
    url = self._base_url .. "/responses",
    headers = headers,
    body = body,
  }
  local context = {
    model = self,
    messages = util.copy(call_opts.messages),
    system_prompt = call_opts.system_prompt,
    tools = util.copy(call_opts.tools or {}),
  }
  for _, layer in ipairs(self._request_opts) do
    request = request_opts.apply(request, layer, context)
  end
  return request_opts.apply(request, call_opts.request_opts, context)
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
      local slots = {}
      local finished = {}
      local reasoning = {}
      local item_indexes = {}
      local next_index = 0
      local terminal = false

      local function register_index(index, item_id)
        if index == nil then
          index = item_id and item_indexes[item_id] or nil
          if index == nil then
            index = next_index
            next_index = next_index + 1
          end
        elseif index >= next_index then
          next_index = index + 1
        end
        if item_id then item_indexes[item_id] = index end
        return index
      end

      local function create_slot(index, item)
        if item.type == "reasoning" then
          local block = { type = "thinking", thinking = "" }
          message.content[#message.content + 1] = block
          slots[index] = { type = "thinking", block = block }
        elseif item.type == "message" then
          local block = { type = "text", text = "" }
          message.content[#message.content + 1] = block
          slots[index] = { type = "text", block = block }
        elseif item.type == "function_call" then
          local call_id = item.call_id or ""
          local item_id = item.id or ""
          local block = {
            type = "toolCall",
            id = item_id ~= "" and (call_id .. "|" .. item_id) or call_id,
            name = item.name or "",
            arguments = vim.empty_dict(),
          }
          message.content[#message.content + 1] = block
          slots[index] = { type = "toolCall", block = block, raw = item.arguments or "" }
          run:emit({
            type = "tool_call_delta",
            index = index,
            id = block.id ~= "" and block.id or nil,
            name = block.name ~= "" and block.name or nil,
          })
        end
        return slots[index]
      end

      local function append_delta(slot, value, field, event_type)
        local previous = slot.block[field]
        local delta = value:sub(1, #previous) == previous and value:sub(#previous + 1) or ""
        slot.block[field] = value
        if delta ~= "" then run:emit({ type = event_type, text = delta }) end
      end

      local function finalize_item(index, item)
        if finished[index] then return end
        local slot = slots[index] or create_slot(index, item)
        if item.type == "reasoning" and slot and slot.type == "thinking" then
          local function join(parts)
            return table.concat(vim.tbl_map(function(part) return part.text or "" end, parts or {}), "\n\n")
          end
          local summary = join(item.summary)
          local text = summary ~= "" and summary or join(item.content)
          append_delta(slot, text ~= "" and text or slot.block.thinking, "thinking", "thinking_delta")
          slot.block.thinkingSignature = vim.json.encode(item)
          if item.id then reasoning[item.id] = slot.block end
        elseif item.type == "message" and slot and slot.type == "text" then
          local parts = {}
          for _, part in ipairs(item.content or {}) do
            parts[#parts + 1] = part.text or part.refusal or ""
          end
          append_delta(slot, table.concat(parts), "text", "text_delta")
          if item.id then slot.block.textSignature = item.id end
        elseif item.type == "function_call" and slot and slot.type == "toolCall" then
          local raw = item.arguments or slot.raw or "{}"
          local delta = raw:sub(1, #slot.raw) == slot.raw and raw:sub(#slot.raw + 1) or ""
          if delta ~= "" then
            run:emit({ type = "tool_call_delta", index = index, arguments_delta = delta })
          end
          local decoded, arguments = pcall(vim.json.decode, raw ~= "" and raw or "{}")
          if not decoded or type(arguments) ~= "table" or util.is_list(arguments) then
            error(util.error("protocol", "Tool arguments are not a JSON object"), 0)
          end
          if slot.block.id == "" then error(util.error("protocol", "Tool call is missing an id"), 0) end
          if slot.block.name == "" then error(util.error("protocol", "Tool call is missing a name"), 0) end
          slot.block.arguments = arguments
        end
        slots[index] = nil
        finished[index] = true
      end

      local function finish_response(response, incomplete)
        for position, item in ipairs(response.output or {}) do
          local index = register_index(item.id and item_indexes[item.id] or position - 1, item.id)
          finalize_item(index, item)
        end
        for _, item in ipairs(response.output or {}) do
          if item.type == "reasoning" and item.id and item.encrypted_content and reasoning[item.id] then
            reasoning[item.id].thinkingSignature = vim.json.encode(item)
          end
        end
        if response.id then message.responseId = response.id end
        if type(response.usage) == "table" then
          message.usage = usage_from(response.usage)
          run:emit({ type = "usage", usage = util.copy(message.usage) })
        end
        local status = response.status
        if incomplete or status == "incomplete" then
          message.stopReason = "length"
        elseif status ~= nil and status ~= "completed" and status ~= "in_progress" and status ~= "queued" then
          error(util.error("model", "Provider response status: " .. tostring(status)), 0)
        elseif vim.tbl_contains(vim.tbl_map(function(block) return block.type end, message.content), "toolCall") then
          message.stopReason = "toolUse"
        end
        terminal = true
      end

      local function process_payload(payload)
        if payload == "[DONE]" then return end
        local decoded, event = pcall(vim.json.decode, payload)
        if not decoded or type(event) ~= "table" then
          error(util.error("protocol", "Invalid JSON in SSE response", decoded and payload or event), 0)
        end
        if type(event.error) == "table" and event.type == nil then
          error(util.error("model", event.error.message or "Provider returned an error", payload), 0)
        end
        local item = event.item or {}
        local item_id = event.item_id or item.id
        local index = event.output_index
        if event.type == "response.created" then
          message.responseId = event.response and event.response.id or message.responseId
        elseif event.type == "response.output_item.added" then
          index = register_index(index, item_id)
          create_slot(index, item)
        elseif event.type == "response.reasoning_summary_text.delta"
            or event.type == "response.reasoning_text.delta" then
          index = register_index(index, item_id)
          local slot = slots[index]
          if slot and slot.type == "thinking" and type(event.delta) == "string" then
            slot.block.thinking = slot.block.thinking .. event.delta
            run:emit({ type = "thinking_delta", text = event.delta })
          end
        elseif event.type == "response.reasoning_summary_part.done" then
          index = register_index(index, item_id)
          local slot = slots[index]
          if slot and slot.type == "thinking" then
            slot.block.thinking = slot.block.thinking .. "\n\n"
            run:emit({ type = "thinking_delta", text = "\n\n" })
          end
        elseif event.type == "response.output_text.delta" or event.type == "response.refusal.delta" then
          index = register_index(index, item_id)
          local slot = slots[index]
          if slot and slot.type == "text" and type(event.delta) == "string" then
            slot.block.text = slot.block.text .. event.delta
            run:emit({ type = "text_delta", text = event.delta })
          end
        elseif event.type == "response.function_call_arguments.delta" then
          index = register_index(index, item_id)
          local slot = slots[index]
          if slot and slot.type == "toolCall" and type(event.delta) == "string" then
            slot.raw = slot.raw .. event.delta
            run:emit({ type = "tool_call_delta", index = index, arguments_delta = event.delta })
          end
        elseif event.type == "response.function_call_arguments.done" then
          index = register_index(index, item_id)
          local slot = slots[index]
          if slot and slot.type == "toolCall" and type(event.arguments) == "string" then
            local delta = event.arguments:sub(1, #slot.raw) == slot.raw
              and event.arguments:sub(#slot.raw + 1) or ""
            slot.raw = event.arguments
            if delta ~= "" then
              run:emit({ type = "tool_call_delta", index = index, arguments_delta = delta })
            end
          end
        elseif event.type == "response.output_item.done" then
          index = register_index(index, item_id)
          finalize_item(index, item)
        elseif event.type == "response.completed" or event.type == "response.done" then
          finish_response(event.response or {}, false)
        elseif event.type == "response.incomplete" then
          finish_response(event.response or {}, true)
        elseif event.type == "error" then
          error(util.error("model", event.message or "Provider returned an error", payload), 0)
        elseif event.type == "response.failed" then
          terminal = true
          local response = event.response or {}
          local detail = response.error or {}
          error(util.error("model", detail.message or "Provider response failed", payload), 0)
        end
      end

      local parser = sse.new({ on_event = process_payload })
      local child = transport.request({
        request = {
          url = request.url,
          headers = request.headers,
          body = vim.json.encode(request.body),
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
      if not terminal then error(util.error("protocol", "Stream ended before a terminal response event"), 0) end
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
  local layers = {}
  for _, layer in ipairs(opts.request_opts_layers or {}) do layers[#layers + 1] = layer end
  if opts.request_opts ~= nil then layers[#layers + 1] = opts.request_opts end
  return setmetatable({
    api = "openai-responses",
    provider = opts.provider,
    id = opts.model,
    _base_url = opts.base_url:gsub("/+$", ""),
    _api_key = opts.api_key,
    _max_output_tokens = opts.max_output_tokens,
    _reasoning = opts.reasoning == true,
    _reasoning_effort = opts.reasoning_effort,
    _reasoning_summary = opts.reasoning_summary,
    _profile = opts.profile,
    _text_verbosity = opts.text_verbosity,
    _request_opts = layers,
    _transport = opts.transport or curl,
  }, Model)
end

M._encode_messages = encode_messages

return M
