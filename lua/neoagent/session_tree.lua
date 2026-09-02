local util = require("neoagent.util")
local semantic_message = require("neoagent.semantic_message")

local M = {}

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local function finite_nonnegative_integer(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
    and value >= 0 and value % 1 == 0
end

local function safe_text(value)
  return nonempty_string(value) and #value <= 512
    and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

local function validate_request(request)
  if request == nil then return true end
  if type(request) ~= "table"
      or (next(request) ~= nil and util.is_list(request)) then
    return false, "message request must be an object"
  end
  for key in pairs(request) do
    if key ~= "model" and key ~= "thinkingLevel" then
      return false, "unsupported message request field: " .. tostring(key)
    end
  end
  if request.model ~= nil then
    local model = request.model
    if type(model) ~= "table" or util.is_list(model)
        or not safe_text(model.provider) or not safe_text(model.model) then
      return false, "message request model requires provider and model"
    end
    for key in pairs(model) do
      if key ~= "provider" and key ~= "model" then
        return false, "unsupported message request model field: "
          .. tostring(key)
      end
    end
  end
  local thinking_level = rawget(request, "thinkingLevel")
  if thinking_level ~= nil and not is_null(thinking_level)
      and not safe_text(thinking_level) then
    return false,
      "message request thinkingLevel must be safe non-empty text"
  end
  return true
end

function M.normalize_request_state(state)
  state = state or {}
  if type(state) ~= "table"
      or (next(state) ~= nil and util.is_list(state)) then
    return nil, "message state must be an object"
  end
  for key in pairs(state) do
    if key ~= "model" and key ~= "thinking_level" then
      return nil, "unsupported message state field: " .. tostring(key)
    end
  end
  local request = {}
  if state.model ~= nil then request.model = util.copy(state.model) end
  local thinking_level = rawget(state, "thinking_level")
  if thinking_level ~= nil then
    request.thinkingLevel = thinking_level
  end
  local valid, err = validate_request(next(request) and request or nil)
  if not valid then return nil, err end
  return next(request) and request or nil
end

local function normalize_compaction_summary(message)
  if type(message) ~= "table"
      or (util.is_list(message) and next(message) ~= nil) then
    return nil, "compaction summary must be an object"
  end
  for key in pairs(message) do
    if key ~= "role" and key ~= "summary" and key ~= "tokensBefore"
        and key ~= "timestamp" then
      return nil, "compaction summary has unsupported field: "
        .. tostring(key)
    end
  end
  if message.role ~= "compactionSummary" then
    return nil, "compaction summary role is required"
  end
  if not nonempty_string(message.summary)
      or not util.is_valid_utf8(message.summary) then
    return nil, "compaction summary must contain non-empty UTF-8 text"
  end
  if not finite_nonnegative_integer(message.tokensBefore) then
    return nil, "compaction summary tokensBefore must be a non-negative integer"
  end
  if not finite_nonnegative_integer(message.timestamp) then
    return nil, "compaction summary timestamp must be a non-negative integer"
  end
  return util.copy(message)
end

function M.normalize_projection_message(message)
  if type(message) == "table" and message.role == "compactionSummary" then
    return normalize_compaction_summary(message)
  end
  return semantic_message.normalize(message)
end

function M.normalize_projection(messages)
  if type(messages) ~= "table" or not util.is_list(messages) then
    return nil, "messages must be a list"
  end
  local result = {}
  local segment = {}
  local segment_start = 1
  local function flush()
    if #segment == 0 then return true end
    local normalized, err = semantic_message.normalize_list(segment, {
      index_offset = segment_start - 1,
    })
    if not normalized then return nil, err end
    vim.list_extend(result, normalized)
    segment = {}
    return true
  end
  for index, message in ipairs(messages) do
    if type(message) == "table" and message.role == "compactionSummary" then
      local ok, err = flush()
      if not ok then return nil, err end
      local normalized
      normalized, err = normalize_compaction_summary(message)
      if not normalized then
        return nil, "message " .. tostring(index) .. ": " .. err
      end
      result[#result + 1] = normalized
      segment_start = index + 1
    else
      if #segment == 0 then segment_start = index end
      segment[#segment + 1] = message
    end
  end
  local ok, err = flush()
  if not ok then return nil, err end
  return result
end

local validators = {
  message = function(entry)
    local _, err = semantic_message.normalize(entry.message)
    if err then return false, err end
    return validate_request(entry.request)
  end,
  compaction = function(entry)
    if not nonempty_string(entry.summary)
        or not util.is_valid_utf8(entry.summary)
        or not nonempty_string(entry.firstKeptEntryId)
        or not finite_nonnegative_integer(entry.tokensBefore) then
      return false, "compactions require summary, firstKeptEntryId, and tokensBefore"
    end
    return true
  end,
  leaf = function(entry)
    if not is_null(entry.targetId) and not nonempty_string(entry.targetId) then
      return false, "leaf targetId must be an entry id or null"
    end
    return true
  end,
}

local entry_fields = {
  message = {
    type = true, id = true, parentId = true, timestamp = true,
    message = true, request = true,
  },
  compaction = {
    type = true, id = true, parentId = true, timestamp = true,
    summary = true, firstKeptEntryId = true, tokensBefore = true,
  },
  leaf = {
    type = true, id = true, parentId = true, timestamp = true,
    targetId = true,
  },
}

function M.validate_entry(entry)
  if type(entry) ~= "table" then return false, "entry must be an object" end
  if not nonempty_string(entry.type) or not validators[entry.type] then
    return false, "unsupported entry type: " .. tostring(entry.type)
  end
  for key in pairs(entry) do
    if not entry_fields[entry.type][key] then
      return false, "unsupported " .. entry.type .. " entry field: "
        .. tostring(key)
    end
  end
  if not nonempty_string(entry.id) then return false, "entry id is required" end
  if not is_null(entry.parentId) and not nonempty_string(entry.parentId) then
    return false, "parentId must be an entry id or null"
  end
  if not nonempty_string(entry.timestamp) then return false, "entry timestamp is required" end
  return validators[entry.type](entry)
end

function M.validate_references(entry, by_id)
  if entry.type == "leaf" and not is_null(entry.targetId)
      and not by_id[entry.targetId] then
    return nil, "leaf target does not exist"
  end
  if entry.type == "compaction" then
    if not by_id[entry.firstKeptEntryId] then
      return nil, "compaction first kept entry does not exist"
    end
    local current = is_null(entry.parentId) and nil or by_id[entry.parentId]
    while current and current.id ~= entry.firstKeptEntryId do
      current = is_null(current.parentId) and nil or by_id[current.parentId]
    end
    if not current then
      return nil, "compaction first kept entry is not on the active path"
    end
  end
  if entry.type == "message" then
    local message = entry.message
    local new_calls = {}
    if message.role == "assistant" then
      for _, block in ipairs(message.content) do
        if block.type == "toolCall" then new_calls[block.id] = true end
      end
    end
    local result_id = message.role == "toolResult"
      and message.toolCallId or nil
    local result_name = message.role == "toolResult"
      and message.toolName or nil
    local matched_result = result_id == nil
    local current = is_null(entry.parentId) and nil or by_id[entry.parentId]
    while current do
      if current.type == "compaction" then break end
      if current.type == "message" then
        local ancestor = current.message
        if ancestor.role == "toolResult"
            and ancestor.toolCallId == result_id then
          break
        end
        if ancestor.role == "assistant" then
          for _, block in ipairs(ancestor.content) do
            if block.type == "toolCall" then
              if new_calls[block.id] then
                return nil, "duplicate conversation toolCall id: " .. block.id
              end
              if block.id == result_id then
                if result_name ~= nil and result_name ~= block.name then
                  return nil, "toolResult toolName does not match its toolCall"
                end
                matched_result = true
                break
              end
            end
          end
        end
      end
      if matched_result and next(new_calls) == nil then break end
      current = is_null(current.parentId) and nil or by_id[current.parentId]
    end
    if not matched_result then
      return nil, "toolResult references an unknown toolCall: "
        .. tostring(result_id)
    end
  end
  return true
end

function M.prepare_entry(opts)
  if type(opts) ~= "table" or util.is_list(opts) then
    return nil, "entry preparation options must be an object"
  end
  local payload = opts.payload
  if payload == nil then payload = {} end
  if type(payload) ~= "table"
      or next(payload) ~= nil and util.is_list(payload) then
    return nil, "entry payload must be an object"
  end
  for _, name in ipairs({ "type", "id", "parentId", "timestamp" }) do
    if rawget(payload, name) ~= nil then
      return nil, "entry payload must not set protected field " .. name
    end
  end
  local entry = {
    type = opts.type,
    id = opts.id,
    parentId = opts.parent_id == nil and vim.NIL or opts.parent_id,
    timestamp = opts.timestamp,
  }
  for key, value in pairs(payload) do entry[key] = util.copy(value) end
  local valid, validation_err = M.validate_entry(entry)
  if not valid then return nil, validation_err end
  local by_id = opts.by_id
  if by_id == nil then by_id = {} end
  if type(by_id) ~= "table" then return nil, "entry index must be a table" end
  if by_id[entry.id] then return nil, "duplicate entry id" end
  local referenced, reference_err = M.validate_references(entry, by_id)
  if not referenced then return nil, reference_err end
  return util.copy(entry)
end

function M.validate_entries(entries)
  if type(entries) ~= "table" or not util.is_list(entries) then
    return nil, "entries must be an array"
  end
  local by_id = {}
  local leaf_id
  for index, entry in ipairs(entries) do
    local valid, err = M.validate_entry(entry)
    if not valid then return nil, err, index end
    if by_id[entry.id] then return nil, "duplicate entry id", index end
    if not is_null(entry.parentId) and not by_id[entry.parentId] then
      return nil, "parent entry does not precede child", index
    end
    local references, reference_err = M.validate_references(entry, by_id)
    if not references then return nil, reference_err, index end
    if entry.type == "leaf" then
      leaf_id = is_null(entry.targetId) and nil or entry.targetId
    else
      leaf_id = entry.id
    end
    by_id[entry.id] = entry
  end
  return { by_id = by_id, leaf_id = leaf_id }
end

local function indexed_path(by_id, leaf_id)
  if leaf_id == vim.NIL then return {} end
  if not leaf_id then return {} end
  local current = by_id[leaf_id]
  if not current then return nil, "entry not found: " .. tostring(leaf_id) end
  local reversed = {}
  while current do
    reversed[#reversed + 1] = current
    current = is_null(current.parentId) and nil or by_id[current.parentId]
  end
  local result = {}
  for index = #reversed, 1, -1 do
    result[#result + 1] = util.copy(reversed[index])
  end
  return result
end

function M.indexed_path(by_id, leaf_id)
  return indexed_path(by_id, leaf_id)
end

function M.path(entries, leaf_id)
  local validated, err, index = M.validate_entries(entries)
  if not validated then return nil, err, index end
  return indexed_path(validated.by_id, leaf_id or validated.leaf_id)
end

local function timestamp_ms(value)
  local year, month, day, hour, minute, second, millis = value:match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?(%d*)Z$"
  )
  if not year then return value end
  local local_seconds = os.time({
    year = tonumber(year), month = tonumber(month), day = tonumber(day),
    hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second),
  })
  local utc_offset = os.difftime(os.time(os.date("!*t", local_seconds)), local_seconds)
  return (local_seconds - utc_offset) * 1000 + tonumber((millis .. "000"):sub(1, 3))
end

function M.entry_messages(entry)
  if entry.type == "message" then return { util.copy(entry.message) } end
  if entry.type == "compaction" then
    return { {
      role = "compactionSummary",
      summary = entry.summary,
      tokensBefore = entry.tokensBefore,
      timestamp = timestamp_ms(entry.timestamp),
    } }
  end
  return {}
end

local function latest_compaction(path)
  local selected
  for index, entry in ipairs(path) do
    if entry.type == "compaction" then selected = index end
  end
  return selected
end

local function retained_before(path, compaction_index)
  local result = {}
  local keeping = false
  local first_kept = path[compaction_index].firstKeptEntryId
  for index = 1, compaction_index - 1 do
    if path[index].id == first_kept then keeping = true end
    if keeping then result[#result + 1] = util.copy(path[index]) end
  end
  return result
end

local function compacted_entries(path)
  local compaction_index = latest_compaction(path)
  if not compaction_index then return util.copy(path) end
  local compaction = util.copy(path[compaction_index])
  local result = { compaction }
  vim.list_extend(result, retained_before(path, compaction_index))
  for index = compaction_index + 1, #path do
    result[#result + 1] = util.copy(path[index])
  end
  return result
end

function M.context_entries(path)
  return compacted_entries(path)
end

function M.transcript_entries(path)
  return compacted_entries(path)
end

function M.messages(entries, context_only)
  local source = context_only and M.context_entries(entries) or entries
  local result = {}
  for _, entry in ipairs(source) do
    vim.list_extend(result, M.entry_messages(entry))
  end
  return result
end

local function tagged(prefix, summary, suffix)
  return { { type = "text", text = prefix .. summary .. suffix } }
end

function M.to_llm(messages)
  local result = {}
  for _, message in ipairs(messages) do
    if message.role == "user" or message.role == "assistant" or message.role == "toolResult" then
      result[#result + 1] = util.copy(message)
    elseif message.role == "compactionSummary" then
      result[#result + 1] = {
        role = "user",
        content = tagged("The conversation history before this point was compacted into the following summary:\n\n<summary>\n",
          message.summary, "\n</summary>"),
        timestamp = message.timestamp,
      }
    end
  end
  return result
end

local function apply_state(result, entry)
  local request = entry.type == "message" and entry.request or nil
  if request then
    if request.model then result.model = util.copy(request.model) end
    local thinking_level = rawget(request, "thinkingLevel")
    if thinking_level ~= nil then
      if is_null(thinking_level) then
        result.thinking_level = nil
      else
        result.thinking_level = thinking_level
      end
    end
  end
  if entry.type == "message" and (not request or not request.model)
      and entry.message.role == "assistant"
      and nonempty_string(entry.message.provider) and nonempty_string(entry.message.model) then
    result.model = { provider = entry.message.provider, model = entry.message.model }
  end
end

function M.apply_state(state, entry)
  local result = util.copy(state)
  apply_state(result, entry)
  return result
end

function M.state(path)
  local result = { model = nil, thinking_level = nil }
  for _, entry in ipairs(path) do apply_state(result, entry) end
  return result
end

return M
