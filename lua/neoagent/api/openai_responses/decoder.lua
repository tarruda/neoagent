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

local function usage_from(raw)
  local input_details = type(raw.input_tokens_details) == "table" and raw.input_tokens_details or {}
  local output_details = type(raw.output_tokens_details) == "table" and raw.output_tokens_details or {}
  local cache_read = type(input_details.cached_tokens) == "number" and input_details.cached_tokens or 0
  local cache_write = type(input_details.cache_write_tokens) == "number" and input_details.cache_write_tokens or 0
  local raw_input = type(raw.input_tokens) == "number" and raw.input_tokens or 0
  local output = type(raw.output_tokens) == "number" and raw.output_tokens or 0
  local input = math.max(0, raw_input - cache_read - cache_write)
  return {
    input = input,
    output = output,
    cacheRead = cache_read,
    cacheWrite = cache_write,
    reasoning = type(output_details.reasoning_tokens) == "number" and output_details.reasoning_tokens or 0,
    totalTokens = type(raw.total_tokens) == "number" and raw.total_tokens
      or (input + output + cache_read + cache_write),
    cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 },
  }
end

function M.new(model, emit)
  local message = {
    role = "assistant",
    content = {},
    api = model.api,
    provider = model.provider,
    model = model.id,
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
      local block = { type = "text", text = "", index = index }
      if type(item.phase) == "string" and item.phase ~= "" then block.phase = item.phase end
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
      emit({
        type = "tool_call_delta",
        index = index,
        id = block.id ~= "" and block.id or nil,
        name = block.name ~= "" and block.name or nil,
      })
    end
    return slots[index]
  end

  local function append_delta(slot, value, field, event_type, event_fields)
    local previous = slot.block[field]
    local delta = value:sub(1, #previous) == previous and value:sub(#previous + 1) or ""
    slot.block[field] = value
    if delta ~= "" then
      local emitted = vim.tbl_extend("force", { type = event_type, text = delta }, event_fields or {})
      emit(emitted)
    end
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
      if type(item.phase) == "string" and item.phase ~= "" then slot.block.phase = item.phase end
      append_delta(slot, table.concat(parts), "text", "text_delta", {
        index = index,
        phase = slot.block.phase,
      })
      if item.id then slot.block.textSignature = item.id end
    elseif item.type == "function_call" and slot and slot.type == "toolCall" then
      local raw = item.arguments or slot.raw or "{}"
      local delta = raw:sub(1, #slot.raw) == slot.raw and raw:sub(#slot.raw + 1) or ""
      if delta ~= "" then
        emit({ type = "tool_call_delta", index = index, arguments_delta = delta })
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
      emit({ type = "usage", usage = util.copy(message.usage) })
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
        if event.type == "response.reasoning_summary_text.delta" then
          local summary_index = type(event.summary_index) == "number" and event.summary_index or nil
          local changed = summary_index ~= nil and slot.summary_index ~= nil
            and summary_index ~= slot.summary_index
          if (slot.summary_part_pending or changed) and slot.block.thinking ~= ""
              and event.delta ~= "" then
            slot.block.thinking = slot.block.thinking .. "\n\n"
            emit({ type = "thinking_delta", text = "\n\n" })
          end
          slot.summary_part_pending = nil
          if summary_index ~= nil then slot.summary_index = summary_index end
        end
        slot.block.thinking = slot.block.thinking .. event.delta
        emit({ type = "thinking_delta", text = event.delta })
      end
    elseif event.type == "response.reasoning_summary_part.added"
        or event.type == "response.reasoning_summary_part.done" then
      index = register_index(index, item_id)
      local slot = slots[index]
      if slot and slot.type == "thinking" then
        local summary_index = type(event.summary_index) == "number" and event.summary_index or nil
        slot.summary_part_pending = event.type == "response.reasoning_summary_part.done"
          or summary_index == nil or summary_index > 0
        if summary_index ~= nil then slot.summary_index = summary_index end
      end
    elseif event.type == "response.output_text.delta" or event.type == "response.refusal.delta" then
      index = register_index(index, item_id)
      local slot = slots[index]
      if slot and slot.type == "text" and type(event.delta) == "string" then
        slot.block.text = slot.block.text .. event.delta
        emit({ type = "text_delta", text = event.delta, index = index, phase = slot.block.phase })
      end
    elseif event.type == "response.function_call_arguments.delta" then
      index = register_index(index, item_id)
      local slot = slots[index]
      if slot and slot.type == "toolCall" and type(event.delta) == "string" then
        slot.raw = slot.raw .. event.delta
        emit({ type = "tool_call_delta", index = index, arguments_delta = event.delta })
      end
    elseif event.type == "response.function_call_arguments.done" then
      index = register_index(index, item_id)
      local slot = slots[index]
      if slot and slot.type == "toolCall" and type(event.arguments) == "string" then
        local delta = event.arguments:sub(1, #slot.raw) == slot.raw
          and event.arguments:sub(#slot.raw + 1) or ""
        slot.raw = event.arguments
        if delta ~= "" then
          emit({ type = "tool_call_delta", index = index, arguments_delta = delta })
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

  return {
    message = message,
    process = process_payload,
    is_terminal = function() return terminal end,
  }
end

return M
