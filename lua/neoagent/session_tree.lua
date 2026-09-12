local util = require("neoagent.util")
local semantic_message = require("neoagent.semantic_message")

local M = {}

---@class Neoagent.ModelSelection
---@field provider string
---@field model string

---@class Neoagent.RequestStateInput
---@field [string] unknown
---@field model? unknown
---@field thinking_level? unknown

---@class Neoagent.SelectionState
---@field model? Neoagent.ModelSelection
---@field thinking_level? string

---@class Neoagent.JournalRequest
---@field model? Neoagent.ModelSelection
---@field thinkingLevel? string|vim.NIL

---@class Neoagent.JournalEntryInput
---@field [string] unknown
---@field type? unknown
---@field id? unknown
---@field parentId? unknown
---@field timestamp? unknown
---@field message? unknown
---@field request? unknown
---@field summary? unknown
---@field firstKeptEntryId? unknown
---@field tokensBefore? unknown
---@field targetId? unknown

---@class Neoagent.JournalEntryBase: Neoagent.JournalEntryInput
---@field id string
---@field parentId? string|vim.NIL
---@field timestamp string

---@class Neoagent.MessageEntry: Neoagent.JournalEntryBase
---@field type "message"
---@field message Neoagent.Message
---@field request? Neoagent.JournalRequest

---@class Neoagent.CompactionEntry: Neoagent.JournalEntryBase
---@field type "compaction"
---@field summary string
---@field firstKeptEntryId string
---@field tokensBefore integer

---@class Neoagent.LeafEntry: Neoagent.JournalEntryBase
---@field type "leaf"
---@field targetId? string|vim.NIL

---@alias Neoagent.JournalEntry Neoagent.MessageEntry|Neoagent.CompactionEntry|Neoagent.LeafEntry
---@alias Neoagent.JournalIndex table<string, Neoagent.JournalEntry>

---@class Neoagent.EntryPreparation
---@field type "message"|"compaction"|"leaf"
---@field id string
---@field parent_id? string|vim.NIL
---@field timestamp string
---@field payload? table<string, unknown>
---@field by_id? Neoagent.JournalIndex

---@class Neoagent.CompactionSummary
---@field role "compactionSummary"
---@field summary string
---@field tokensBefore integer
---@field timestamp integer

---@alias Neoagent.ProjectionMessage Neoagent.Message|Neoagent.CompactionSummary

---@param value unknown
---@return TypeGuard<nil|vim.NIL>
local function is_null(value)
  return value == nil or value == vim.NIL
end

---@param value unknown
---@return TypeGuard<string>
local function nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

---@param value unknown
---@return TypeGuard<integer>
local function finite_nonnegative_integer(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value >= 0
    and value % 1 == 0
end

---@param value unknown
---@return TypeGuard<string>
local function safe_text(value)
  return nonempty_string(value) and #value <= 512 and util.is_valid_utf8(value) and not value:find("[%z\1-\31\127]")
end

-- Journal dates are UTC; calendar arithmetic avoids local timezone and DST.
---@param value string
---@return integer?
local function timestamp_ms(value)
  local date, fraction = value:match("^(.-)%.(%d+)Z$")
  date = date or value:match("^(.-)Z$")
  if not date then
    return nil
  end
  local year, month, day, hour, minute, second = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)$")
  if not year then
    return nil
  end
  local y, m, d = tonumber(year), tonumber(month), tonumber(day)
  local h, min, sec = tonumber(hour), tonumber(minute), tonumber(second)
  ---@cast y integer
  ---@cast m integer
  ---@cast d integer
  ---@cast h integer
  ---@cast min integer
  ---@cast sec integer
  if y < 1970 or m < 1 or m > 12 or d < 1 or h > 23 or min > 59 or sec > 59 then
    return nil
  end
  local leap = y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
  local month_days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if d > month_days[m] then
    return nil
  end
  local previous_year = y - 1
  local days = previous_year * 365
    + math.floor(previous_year / 4)
    - math.floor(previous_year / 100)
    + math.floor(previous_year / 400)
    - 719162
    + d
    - 1
  for index = 1, m - 1 do
    days = days + assert(month_days[index])
  end
  local millis = tonumber(((fraction or "") .. "000"):sub(1, 3))
  ---@cast millis integer
  return ((days * 24 + h) * 60 * 60 + min * 60 + sec) * 1000 + millis
end

---@param request unknown
---@return TypeGuard<Neoagent.JournalRequest?>
---@return string? error
local function validate_request(request)
  if request == nil then
    return true
  end
  if type(request) ~= "table" or (next(request) ~= nil and util.is_list(request)) then
    return false, "message request must be an object"
  end
  for key in pairs(request) do
    if key ~= "model" and key ~= "thinkingLevel" then
      return false, "unsupported message request field: " .. tostring(key)
    end
  end
  if request.model ~= nil then
    local model = request.model
    if type(model) ~= "table" or util.is_list(model) or not safe_text(model.provider) or not safe_text(model.model) then
      return false, "message request model requires provider and model"
    end
    for key in pairs(model) do
      if key ~= "provider" and key ~= "model" then
        return false, "unsupported message request model field: " .. tostring(key)
      end
    end
  end
  local thinking_level = rawget(request, "thinkingLevel")
  if thinking_level ~= nil and not is_null(thinking_level) and not safe_text(thinking_level) then
    return false, "message request thinkingLevel must be safe non-empty text"
  end
  return true
end

---@param state? Neoagent.RequestStateInput
---@return Neoagent.JournalRequest?, string?
function M.normalize_request_state(state)
  state = state or {}
  if type(state) ~= "table" or (next(state) ~= nil and util.is_list(state)) then
    return nil, "message state must be an object"
  end
  for key in pairs(state) do
    if key ~= "model" and key ~= "thinking_level" then
      return nil, "unsupported message state field: " .. tostring(key)
    end
  end
  ---@type table<string, unknown>
  local request = {}
  if state.model ~= nil then
    rawset(request, "model", util.copy(state.model))
  end
  local thinking_level = rawget(state, "thinking_level")
  if thinking_level ~= nil then
    rawset(request, "thinkingLevel", thinking_level)
  end
  local valid, err = validate_request(next(request) and request or nil)
  if not valid then
    return nil, err
  end
  ---@cast request Neoagent.JournalRequest
  return next(request) and request or nil
end

---@param message unknown
---@return Neoagent.CompactionSummary?, string?
---@return_overload Neoagent.CompactionSummary
---@return_overload nil, string
local function normalize_compaction_summary(message)
  if type(message) ~= "table" or (util.is_list(message) and next(message) ~= nil) then
    return nil, "compaction summary must be an object"
  end
  for key in pairs(message) do
    if key ~= "role" and key ~= "summary" and key ~= "tokensBefore" and key ~= "timestamp" then
      return nil, "compaction summary has unsupported field: " .. tostring(key)
    end
  end
  if message.role ~= "compactionSummary" then
    return nil, "compaction summary role is required"
  end
  if not nonempty_string(message.summary) or not util.is_valid_utf8(message.summary) then
    return nil, "compaction summary must contain non-empty UTF-8 text"
  end
  if not finite_nonnegative_integer(message.tokensBefore) then
    return nil, "compaction summary tokensBefore must be a non-negative integer"
  end
  if not finite_nonnegative_integer(message.timestamp) then
    return nil, "compaction summary timestamp must be a non-negative integer"
  end
  ---@cast message Neoagent.CompactionSummary
  return util.copy(message)
end

---@param message unknown
---@return Neoagent.ProjectionMessage?, string?
---@return_overload Neoagent.ProjectionMessage
---@return_overload nil, string
function M.normalize_projection_message(message)
  if type(message) == "table" and message.role == "compactionSummary" then
    return normalize_compaction_summary(message)
  end
  return semantic_message.normalize(message)
end

---@param messages unknown
---@return Neoagent.ProjectionMessage[]?, string?
---@return_overload Neoagent.ProjectionMessage[]
---@return_overload nil, string
function M.normalize_projection(messages)
  if type(messages) ~= "table" or not util.is_list(messages) then
    return nil, "messages must be a list"
  end
  ---@type Neoagent.ProjectionMessage[]
  local result = {}
  ---@type unknown[]
  local segment = {}
  local segment_start = 1
  ---@return true?, string?
  local function flush()
    if #segment == 0 then
      return true
    end
    local normalized, err = semantic_message.normalize_list(segment, {
      index_offset = segment_start - 1,
    })
    if not normalized then
      return nil, err
    end
    vim.list_extend(result, normalized)
    segment = {}
    return true
  end
  for index, message in ipairs(messages) do
    if type(message) == "table" and message.role == "compactionSummary" then
      local ok, err = flush()
      if not ok then
        return nil, err
      end
      local normalized
      normalized, err = normalize_compaction_summary(message)
      if not normalized then
        return nil, "message " .. tostring(index) .. ": " .. err
      end
      result[#result + 1] = normalized
      segment_start = index + 1
    else
      if #segment == 0 then
        segment_start = index
      end
      segment[#segment + 1] = message
    end
  end
  local ok, err = flush()
  if not ok then
    return nil, err
  end
  return result
end

---@type table<string, fun(entry: Neoagent.JournalEntryInput): boolean, string?>
local validators = {
  message = function(entry)
    local _, err = semantic_message.normalize(entry.message)
    if err then
      return false, err
    end
    return validate_request(entry.request)
  end,
  compaction = function(entry)
    if
      not nonempty_string(entry.summary)
      or not util.is_valid_utf8(entry.summary)
      or not nonempty_string(entry.firstKeptEntryId)
      or not finite_nonnegative_integer(entry.tokensBefore)
    then
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

---@type table<string, table<string, boolean>>
local entry_fields = {
  message = {
    type = true,
    id = true,
    parentId = true,
    timestamp = true,
    message = true,
    request = true,
  },
  compaction = {
    type = true,
    id = true,
    parentId = true,
    timestamp = true,
    summary = true,
    firstKeptEntryId = true,
    tokensBefore = true,
  },
  leaf = {
    type = true,
    id = true,
    parentId = true,
    timestamp = true,
    targetId = true,
  },
}

---@param entry unknown
---@return TypeGuard<Neoagent.JournalEntry>
---@return string? error
function M.validate_entry(entry)
  if type(entry) ~= "table" then
    return false, "entry must be an object"
  end
  if not nonempty_string(entry.type) or not validators[entry.type] then
    return false, "unsupported entry type: " .. tostring(entry.type)
  end
  for key in pairs(entry) do
    if not entry_fields[entry.type][key] then
      return false, "unsupported " .. entry.type .. " entry field: " .. tostring(key)
    end
  end
  if not nonempty_string(entry.id) then
    return false, "entry id is required"
  end
  if not is_null(entry.parentId) and not nonempty_string(entry.parentId) then
    return false, "parentId must be an entry id or null"
  end
  if not nonempty_string(entry.timestamp) then
    return false, "entry timestamp is required"
  end
  if timestamp_ms(entry.timestamp) == nil then
    return false, "entry timestamp must be a UTC ISO 8601 date"
  end
  return validators[entry.type](entry)
end

---@param entry Neoagent.JournalEntry
---@param by_id Neoagent.JournalIndex
---@return true?, string?
function M.validate_references(entry, by_id)
  if entry.type == "leaf" and not is_null(entry.targetId) and not by_id[entry.targetId] then
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
        if block.type == "toolCall" then
          new_calls[block.id] = true
        end
      end
    end
    local result_id = message.role == "toolResult" and message.toolCallId or nil
    local result_name = message.role == "toolResult" and message.toolName or nil
    local matched_result = result_id == nil
    local current = is_null(entry.parentId) and nil or by_id[entry.parentId]
    while current do
      if current.type == "compaction" then
        break
      end
      if current.type == "message" then
        local ancestor = current.message
        if ancestor.role == "toolResult" and ancestor.toolCallId == result_id then
          break
        end
        if ancestor.role == "assistant" then
          ---@cast ancestor Neoagent.AssistantMessage
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
      if matched_result and next(new_calls) == nil then
        break
      end
      current = is_null(current.parentId) and nil or by_id[current.parentId]
    end
    if not matched_result then
      return nil, "toolResult references an unknown toolCall: " .. tostring(result_id)
    end
  end
  return true
end

---@param opts Neoagent.EntryPreparation
---@return Neoagent.JournalEntry?, string?
---@return_overload Neoagent.JournalEntry
---@return_overload nil, string
function M.prepare_entry(opts)
  if type(opts) ~= "table" or util.is_list(opts) then
    return nil, "entry preparation options must be an object"
  end
  local payload = opts.payload
  if payload == nil then
    payload = {}
  end
  if type(payload) ~= "table" or next(payload) ~= nil and util.is_list(payload) then
    return nil, "entry payload must be an object"
  end
  for _, name in ipairs({ "type", "id", "parentId", "timestamp" }) do
    if rawget(payload, name) ~= nil then
      return nil, "entry payload must not set protected field " .. name
    end
  end
  ---@type Neoagent.JournalEntryInput
  local entry = {
    type = opts.type,
    id = opts.id,
    parentId = opts.parent_id == nil and vim.NIL or opts.parent_id,
    timestamp = opts.timestamp,
  }
  for key, value in pairs(payload) do
    entry[key] = util.copy(value)
  end
  local valid, validation_err = M.validate_entry(entry)
  if not valid then
    return nil, validation_err
  end
  ---@cast entry Neoagent.JournalEntry
  local by_id = opts.by_id
  if by_id == nil then
    by_id = {}
  end
  if type(by_id) ~= "table" then
    return nil, "entry index must be a table"
  end
  if by_id[entry.id] then
    return nil, "duplicate entry id"
  end
  local referenced, reference_err = M.validate_references(entry, by_id)
  if not referenced then
    return nil, reference_err
  end
  return util.copy(entry)
end

---@param entries unknown
---@return {by_id: Neoagent.JournalIndex, leaf_id?: string}?, string?, integer?
---@return_overload {by_id: Neoagent.JournalIndex, leaf_id?: string}
---@return_overload nil, string, integer?
function M.validate_entries(entries)
  if type(entries) ~= "table" or not util.is_list(entries) then
    return nil, "entries must be an array"
  end
  ---@type Neoagent.JournalIndex
  local by_id = {}
  ---@type string?
  local leaf_id
  for index, entry in ipairs(entries) do
    local valid, err = M.validate_entry(entry)
    if not valid then
      return nil, err, index
    end
    if by_id[entry.id] then
      return nil, "duplicate entry id", index
    end
    if not is_null(entry.parentId) and not by_id[entry.parentId] then
      return nil, "parent entry does not precede child", index
    end
    local references, reference_err = M.validate_references(entry, by_id)
    if not references then
      return nil, reference_err, index
    end
    if entry.type == "leaf" then
      leaf_id = entry.targetId ~= vim.NIL and entry.targetId or nil
    else
      leaf_id = entry.id
    end
    by_id[entry.id] = entry
  end
  return { by_id = by_id, leaf_id = leaf_id }
end

---@param by_id Neoagent.JournalIndex
---@param leaf_id? string|vim.NIL
---@return Neoagent.JournalEntry[]?, string?
local function indexed_path(by_id, leaf_id)
  if leaf_id == vim.NIL then
    return {}
  end
  if not leaf_id then
    return {}
  end
  local current = by_id[leaf_id]
  if not current then
    return nil, "entry not found: " .. tostring(leaf_id)
  end
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

---@param by_id Neoagent.JournalIndex
---@param leaf_id? string|vim.NIL
---@return Neoagent.JournalEntry[]?, string?
function M.indexed_path(by_id, leaf_id)
  return indexed_path(by_id, leaf_id)
end

---@param entries Neoagent.JournalEntry[]
---@param leaf_id? string|vim.NIL
---@return Neoagent.JournalEntry[]?, string?, integer?
function M.path(entries, leaf_id)
  local validated, err, index = M.validate_entries(entries)
  if not validated then
    return nil, err, index
  end
  return indexed_path(validated.by_id, leaf_id or validated.leaf_id)
end

---@param entry Neoagent.JournalEntry
---@return Neoagent.ProjectionMessage[]
function M.entry_messages(entry)
  if entry.type == "message" then
    return { util.copy(entry.message) }
  end
  if entry.type == "compaction" then
    ---@cast entry Neoagent.CompactionEntry
    return {
      {
        role = "compactionSummary",
        summary = entry.summary,
        tokensBefore = entry.tokensBefore,
        timestamp = assert(timestamp_ms(entry.timestamp)),
      },
    }
  end
  return {}
end

---@param path Neoagent.JournalEntry[]
---@return integer?
local function latest_compaction(path)
  local selected
  for index, entry in ipairs(path) do
    if entry.type == "compaction" then
      selected = index
    end
  end
  return selected
end

---@param path Neoagent.JournalEntry[]
---@param compaction_index integer
---@return Neoagent.JournalEntry[]
local function retained_before(path, compaction_index)
  local result = {}
  local keeping = false
  local compaction = path[compaction_index]
  ---@cast compaction Neoagent.CompactionEntry
  local first_kept = compaction.firstKeptEntryId
  for index = 1, compaction_index - 1 do
    local entry = assert(path[index])
    if entry.id == first_kept then
      keeping = true
    end
    if keeping then
      result[#result + 1] = util.copy(entry)
    end
  end
  return result
end

---@param path Neoagent.JournalEntry[]
---@return Neoagent.JournalEntry[]
local function compacted_entries(path)
  local compaction_index = latest_compaction(path)
  if not compaction_index then
    return util.copy(path)
  end
  local compaction = util.copy(path[compaction_index])
  local result = { compaction }
  vim.list_extend(result, retained_before(path, compaction_index))
  for index = compaction_index + 1, #path do
    result[#result + 1] = util.copy(path[index])
  end
  return result
end

---@param path Neoagent.JournalEntry[]
---@return Neoagent.JournalEntry[]
function M.context_entries(path)
  return compacted_entries(path)
end

---@param path Neoagent.JournalEntry[]
---@return Neoagent.JournalEntry[]
function M.transcript_entries(path)
  return compacted_entries(path)
end

---@param entries Neoagent.JournalEntry[]
---@param context_only? boolean
---@return Neoagent.ProjectionMessage[]
function M.messages(entries, context_only)
  local source = context_only and M.context_entries(entries) or entries
  local result = {}
  for _, entry in ipairs(source) do
    vim.list_extend(result, M.entry_messages(entry))
  end
  return result
end

---@param prefix string
---@param summary string
---@param suffix string
---@return Neoagent.TextBlock[]
local function tagged(prefix, summary, suffix)
  return { { type = "text", text = prefix .. summary .. suffix } }
end

---@param messages Neoagent.ProjectionMessage[]
---@return Neoagent.Message[]
function M.to_llm(messages)
  local result = {}
  for _, message in ipairs(messages) do
    if message.role == "user" or message.role == "assistant" or message.role == "toolResult" then
      result[#result + 1] = util.copy(message)
    elseif message.role == "compactionSummary" then
      result[#result + 1] = {
        role = "user",
        content = tagged(
          "The conversation history before this point was compacted into the following summary:\n\n<summary>\n",
          message.summary,
          "\n</summary>"
        ),
        timestamp = message.timestamp,
      }
    end
  end
  return result
end

---@param result Neoagent.SelectionState
---@param entry Neoagent.JournalEntry
local function apply_state(result, entry)
  local request = entry.type == "message" and entry.request or nil
  if request then
    if request.model then
      result.model = util.copy(request.model)
    end
    local thinking_level = rawget(request, "thinkingLevel")
    if thinking_level ~= nil then
      if is_null(thinking_level) then
        result.thinking_level = nil
      else
        result.thinking_level = thinking_level
      end
    end
  end
  if
    entry.type == "message"
    and (not request or not request.model)
    and entry.message.role == "assistant"
    and nonempty_string(entry.message.provider)
    and nonempty_string(entry.message.model)
  then
    result.model = { provider = entry.message.provider, model = entry.message.model }
  end
end

---@param state Neoagent.SelectionState
---@param entry Neoagent.JournalEntry
---@return Neoagent.SelectionState
function M.apply_state(state, entry)
  local result = util.copy(state)
  apply_state(result, entry)
  return result
end

---@param path Neoagent.JournalEntry[]
---@return Neoagent.SelectionState
function M.state(path)
  local result = { model = nil, thinking_level = nil }
  for _, entry in ipairs(path) do
    apply_state(result, entry)
  end
  return result
end

return M
