local util = require("neoagent.util")
local tool_arguments = require("neoagent.api.tool_arguments")
local http_response = require("neoagent.api.http_response")

local M = {}

---@param value unknown
---@param field string
---@return string?
local function optional_string(value, field)
  if not value then return nil end
  if type(value) ~= "string" then
    error(util.error("protocol", "Invalid OpenAI Responses " .. field .. ": expected a string"), 0)
  end
  return value
end

---@param value? Neoagent.JsonValue
---@param field string
---@return Neoagent.JsonObject|Neoagent.JsonArray
local function json_table(value, field)
  if not value then return {} end
  if type(value) ~= "table" then
    error(util.error("protocol", "Invalid OpenAI Responses " .. field .. ": expected a table"), 0)
  end
  return value
end

---@param value? Neoagent.JsonValue
---@param separator string
---@param refusal? boolean
---@return string
local function content_text(value, separator, refusal)
  ---@type (string|number)[]
  local values = {}
  for _, raw in ipairs(json_table(value, "content")) do
    local part = json_table(raw, "content part")
    local text = part.text or (refusal and part.refusal) or ""
    if type(text) ~= "string" and type(text) ~= "number" then
      error(util.error("protocol", "Invalid OpenAI Responses content text"), 0)
    end
    values[#values + 1] = text
  end
  return table.concat(values, separator)
end

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
  local block_indexes = {}
  local reasoning = {}
  local item_indexes = {}
  local next_index = 0
  local terminal = false

  local function register_index(raw_index, raw_id)
    ---@type integer?
    local index
    if raw_index ~= nil then
      if type(raw_index) ~= "number" or raw_index < 0 or raw_index % 1 ~= 0 then
        error(util.error("protocol", "Invalid OpenAI Responses output index"), 0)
      end
      ---@cast raw_index integer
      index = raw_index
    end
    local item_id = optional_string(raw_id, "item id")
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
      local block = { type = "thinking", thinking = "", index = index }
      message.content[#message.content + 1] = block
      block_indexes[block] = index
      slots[index] = { type = "thinking", block = block }
    elseif item.type == "message" then
      local block = { type = "text", text = "", index = index }
      if type(item.phase) == "string" and item.phase ~= "" then block.phase = item.phase end
      message.content[#message.content + 1] = block
      block_indexes[block] = index
      slots[index] = { type = "text", block = block }
    elseif item.type == "function_call" then
      local call_id = optional_string(item.call_id, "call id") or ""
      local item_id = optional_string(item.id, "item id") or ""
      local arguments = optional_string(item.arguments, "tool arguments") or ""
      local block = {
        type = "toolCall",
        id = item_id ~= "" and (call_id .. "|" .. item_id) or call_id,
        name = optional_string(item.name, "tool name") or "",
        arguments = vim.empty_dict(),
      }
      message.content[#message.content + 1] = block
      block_indexes[block] = index
      slots[index] = { type = "toolCall", block = block, raw = arguments }
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
    if not util.is_valid_utf8(value) then
      error(util.error("protocol",
        "OpenAI Responses delta must contain valid UTF-8"), 0)
    end
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
    local item_id = optional_string(item.id, "item id")
    if item.type == "reasoning" and slot and slot.type == "thinking" then
      local summary = content_text(item.summary, "\n\n")
      local text = summary ~= "" and summary or content_text(item.content, "\n\n")
      append_delta(slot, text ~= "" and text or slot.block.thinking,
        "thinking", "thinking_delta", { index = index })
      slot.block.thinkingSignature = vim.json.encode(item)
      if item_id then reasoning[item_id] = slot.block end
    elseif item.type == "message" and slot and slot.type == "text" then
      local text = content_text(item.content, "", true)
      if type(item.phase) == "string" and item.phase ~= "" then slot.block.phase = item.phase end
      append_delta(slot, text, "text", "text_delta", {
        index = index,
        phase = slot.block.phase,
      })
      if item_id then slot.block.textSignature = item_id end
    elseif item.type == "function_call" and slot and slot.type == "toolCall" then
      local raw = optional_string(item.arguments, "tool arguments") or slot.raw or "{}"
      local delta = raw:sub(1, #slot.raw) == slot.raw and raw:sub(#slot.raw + 1) or ""
      if delta ~= "" then
        emit({ type = "tool_call_delta", index = index, arguments_delta = delta })
      end
      if slot.block.id == "" then error(util.error("protocol", "Tool call is missing an id"), 0) end
      if slot.block.name == "" then error(util.error("protocol", "Tool call is missing a name"), 0) end
      slot.block.arguments, slot.block.argumentsError = tool_arguments.decode(raw)
    end
    slots[index] = nil
    finished[index] = true
  end

  local function finish_response(response, incomplete)
    local output = json_table(response.output, "output")
    local items = {}
    for position, raw_item in ipairs(output) do
      local item = json_table(raw_item, "output item")
      items[#items + 1] = item
      local item_id = optional_string(item.id, "item id")
      local index = register_index(item_id and item_indexes[item_id] or position - 1, item_id)
      finalize_item(index, item)
    end
    for _, item in ipairs(items) do
      local item_id = optional_string(item.id, "item id")
      if item.type == "reasoning" and item_id and item.encrypted_content and reasoning[item_id] then
        reasoning[item_id].thinkingSignature = vim.json.encode(item)
      end
    end
    local response_id = optional_string(response.id, "response id")
    if response_id then message.responseId = response_id end
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

  local function process_payload(event)
    if type(event) ~= "table" then
      error(util.error("protocol", "Expected an object in SSE response"), 0)
    end
    if type(event.error) == "table" and event.type == nil then
      error(util.error("model", http_response.error_message(event, "Provider returned an error"), util.json_encode(event)), 0)
    end
    local item = json_table(event.item, "item")
    local item_id = event.item_id or item.id
    local index = event.output_index
    if event.type == "response.created" then
      local response = json_table(event.response, "response")
      message.responseId = optional_string(response.id, "response id") or message.responseId
    elseif event.type == "response.output_item.added" then
      index = register_index(index, item_id)
      create_slot(index, item)
    elseif event.type == "response.reasoning_summary_text.delta"
        or event.type == "response.reasoning_text.delta" then
      index = register_index(index, item_id)
      local slot = slots[index]
      if slot and slot.type == "thinking" and type(event.delta) == "string" then
        if not util.is_valid_utf8(event.delta) then
          error(util.error("protocol",
            "OpenAI Responses thinking delta must contain valid UTF-8"), 0)
        end
        if event.type == "response.reasoning_summary_text.delta" then
          local summary_index = type(event.summary_index) == "number" and event.summary_index or nil
          local changed = summary_index ~= nil and slot.summary_index ~= nil
            and summary_index ~= slot.summary_index
          if (slot.summary_part_pending or changed) and slot.block.thinking ~= ""
              and event.delta ~= "" then
            slot.block.thinking = slot.block.thinking .. "\n\n"
            emit({ type = "thinking_delta", text = "\n\n", index = index })
          end
          slot.summary_part_pending = nil
          if summary_index ~= nil then slot.summary_index = summary_index end
        end
        slot.block.thinking = slot.block.thinking .. event.delta
        emit({ type = "thinking_delta", text = event.delta, index = index })
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
        if not util.is_valid_utf8(event.delta) then
          error(util.error("protocol",
            "OpenAI Responses text delta must contain valid UTF-8"), 0)
        end
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
      finish_response(json_table(event.response, "response"), false)
    elseif event.type == "response.incomplete" then
      finish_response(json_table(event.response, "response"), true)
    elseif event.type == "error" then
      error(util.error("model", http_response.error_message(event, "Provider returned an error"), util.json_encode(event)), 0)
    elseif event.type == "response.failed" then
      terminal = true
      local response = json_table(event.response, "response")
      error(util.error("model", http_response.error_message(response, "Provider response failed"), util.json_encode(event)), 0)
    end
  end

  return {
    message = message,
    process = process_payload,
    is_terminal = function() return terminal end,
    partial = function()
      local candidate = util.copy(message)
      candidate.content = {}
      for _, block in ipairs(message.content) do
        if finished[block_indexes[block]] then
          candidate.content[#candidate.content + 1] = util.copy(block)
        end
      end
      return candidate
    end,
  }
end

return M
