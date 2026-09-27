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
---@field thinking_level? string|vim.NIL

---@class Neoagent.JournalEntryInput
---@field [string] unknown
---@field type? unknown
---@field id? unknown
---@field parent_id? unknown
---@field created_at? unknown
---@field message? unknown
---@field request? unknown
---@field summary? unknown
---@field native? unknown
---@field first_kept_entry_id? unknown
---@field retained_users? unknown
---@field tokens_before? unknown
---@field target_id? unknown

---@class Neoagent.JournalEntryBase: Neoagent.JournalEntryInput
---@field id string
---@field parent_id? string|vim.NIL
---@field created_at integer

---@class Neoagent.MessageEntry: Neoagent.JournalEntryBase
---@field type "message"
---@field message Neoagent.Message
---@field request? Neoagent.JournalRequest

---@class Neoagent.RetainedUser
---@field entry_id string
---@field text_chars? integer Maximum text characters across blocks; images remain intact.

---@class Neoagent.CompactionEntry: Neoagent.JournalEntryBase
---@field type "compaction"
---@field summary? string Local summaries only.
---@field native? Neoagent.NativeCompactionMessage
---@field first_kept_entry_id? string
---@field retained_users? Neoagent.RetainedUser[]
---@field tokens_before integer

---@class Neoagent.LeafEntry: Neoagent.JournalEntryBase
---@field type "leaf"
---@field target_id? string|vim.NIL

---@alias Neoagent.JournalEntry Neoagent.MessageEntry|Neoagent.CompactionEntry|Neoagent.LeafEntry
---@alias Neoagent.JournalIndex table<string, Neoagent.JournalEntry>

---@class Neoagent.EntryPreparation
---@field type "message"|"compaction"|"leaf"
---@field id string
---@field parent_id? string|vim.NIL
---@field created_at integer
---@field payload? table<string, unknown>
---@field by_id? Neoagent.JournalIndex

---@class Neoagent.CompactionSummary
---@field role "compactionSummary"
---@field summary string
---@field tokens_before integer
---@field created_at integer

---@class Neoagent.CompactionCheckpoint
---@field role "compactionCheckpoint"
---@field tokens_before integer
---@field created_at integer

---@alias Neoagent.ProjectionMessage Neoagent.Message|Neoagent.CompactionSummary|Neoagent.CompactionCheckpoint

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
    if key ~= "model" and key ~= "thinking_level" then
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
  local thinking_level = rawget(request, "thinking_level")
  if thinking_level ~= nil and not is_null(thinking_level) and not safe_text(thinking_level) then
    return false, "message request thinking_level must be safe non-empty text"
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
    rawset(request, "thinking_level", thinking_level)
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
    if key ~= "role" and key ~= "summary" and key ~= "tokens_before" and key ~= "created_at" then
      return nil, "compaction summary has unsupported field: " .. tostring(key)
    end
  end
  if message.role ~= "compactionSummary" then
    return nil, "compaction summary role is required"
  end
  if not nonempty_string(message.summary) or not util.is_valid_utf8(message.summary) then
    return nil, "compaction summary must contain non-empty UTF-8 text"
  end
  if not finite_nonnegative_integer(message.tokens_before) then
    return nil, "compaction summary tokens_before must be a non-negative integer"
  end
  if not finite_nonnegative_integer(message.created_at) then
    return nil, "compaction summary created_at must be a non-negative integer"
  end
  ---@cast message Neoagent.CompactionSummary
  return util.copy(message)
end

---@param message unknown
---@return Neoagent.CompactionCheckpoint?, string?
local function normalize_compaction_checkpoint(message)
  if type(message) ~= "table" or (util.is_list(message) and next(message) ~= nil) then
    return nil, "compaction checkpoint must be an object"
  end
  for key in pairs(message) do
    if key ~= "role" and key ~= "tokens_before" and key ~= "created_at" then
      return nil, "compaction checkpoint has unsupported field: " .. tostring(key)
    end
  end
  if message.role ~= "compactionCheckpoint" then
    return nil, "compaction checkpoint role is required"
  end
  if not finite_nonnegative_integer(message.tokens_before) then
    return nil, "compaction checkpoint tokens_before must be a non-negative integer"
  end
  if not finite_nonnegative_integer(message.created_at) then
    return nil, "compaction checkpoint created_at must be a non-negative integer"
  end
  ---@cast message Neoagent.CompactionCheckpoint
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
  if type(message) == "table" and message.role == "compactionCheckpoint" then
    return normalize_compaction_checkpoint(message)
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
    if type(message) == "table" and (message.role == "compactionSummary" or message.role == "compactionCheckpoint") then
      local ok, err = flush()
      if not ok then
        return nil, err
      end
      local normalized
      if message.role == "compactionSummary" then
        normalized, err = normalize_compaction_summary(message)
      else
        normalized, err = normalize_compaction_checkpoint(message)
      end
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
    if not finite_nonnegative_integer(entry.tokens_before) then
      return false, "compactions require tokens_before"
    end
    if entry.native ~= nil then
      if entry.summary ~= nil then
        return false, "native compactions cannot contain a summary"
      end
      local normalized, native_err = semantic_message.normalize_native_compaction(entry.native)
      if not normalized then
        return false, native_err
      end
      if
        entry.first_kept_entry_id ~= nil
        or type(entry.retained_users) ~= "table"
        or not util.is_list(entry.retained_users)
      then
        return false, "native compactions require retained_users and no first_kept_entry_id"
      end
      for _, retained in ipairs(entry.retained_users) do
        if type(retained) ~= "table" or not safe_text(retained.entry_id) then
          return false, "native compaction retained entry ids must be safe text"
        end
        for key in pairs(retained) do
          if key ~= "entry_id" and key ~= "text_chars" then
            return false, "native compaction retained user has an unsupported field"
          end
        end
        if retained.text_chars ~= nil and not finite_nonnegative_integer(retained.text_chars) then
          return false, "native compaction retained text limit must be a non-negative integer"
        end
      end
    elseif
      not nonempty_string(entry.summary)
      or not util.is_valid_utf8(entry.summary)
      or entry.first_kept_entry_id ~= nil and not safe_text(entry.first_kept_entry_id)
      or entry.retained_users ~= nil
    then
      return false, "local compactions require a summary, optional safe first_kept_entry_id, and no retained_users"
    end
    return true
  end,
  leaf = function(entry)
    if not is_null(entry.target_id) and not safe_text(entry.target_id) then
      return false, "leaf target_id must be a safe entry id or null"
    end
    return true
  end,
}

---@type table<string, table<string, boolean>>
local entry_fields = {
  message = {
    type = true,
    id = true,
    parent_id = true,
    created_at = true,
    message = true,
    request = true,
  },
  compaction = {
    type = true,
    id = true,
    parent_id = true,
    created_at = true,
    summary = true,
    native = true,
    first_kept_entry_id = true,
    retained_users = true,
    tokens_before = true,
  },
  leaf = {
    type = true,
    id = true,
    parent_id = true,
    created_at = true,
    target_id = true,
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
  if not safe_text(entry.id) then
    return false, "entry id must be safe text"
  end
  if not is_null(entry.parent_id) and not safe_text(entry.parent_id) then
    return false, "parent_id must be a safe entry id or null"
  end
  if not finite_nonnegative_integer(entry.created_at) then
    return false, "entry created_at must be UTC milliseconds"
  end
  return validators[entry.type](entry)
end

---@param entry Neoagent.JournalEntry
---@param by_id Neoagent.JournalIndex
---@return true?, string?
function M.validate_references(entry, by_id)
  if entry.type == "leaf" and not is_null(entry.target_id) and not by_id[entry.target_id] then
    return nil, "leaf target does not exist"
  end
  if entry.type == "compaction" then
    if entry.native then
      local distance = {}
      local current = is_null(entry.parent_id) and nil or by_id[entry.parent_id]
      local index = 0
      while current do
        index = index + 1
        distance[current.id] = index
        current = is_null(current.parent_id) and nil or by_id[current.parent_id]
      end
      local previous_distance
      for _, selected in ipairs(assert(entry.retained_users)) do
        local id = selected.entry_id
        local retained = by_id[id]
        local selected_distance = distance[id]
        if not retained or retained.type ~= "message" or retained.message.role ~= "user" or not selected_distance then
          return nil, "native compaction retained entries must be user messages on the active path"
        end
        if previous_distance and selected_distance >= previous_distance then
          return nil, "native compaction retained entries must follow path order without duplicates"
        end
        previous_distance = selected_distance
      end
    else
      local first_kept = entry.first_kept_entry_id
      local previous = is_null(entry.parent_id) and nil or by_id[entry.parent_id]
      while previous do
        if previous.type == "compaction" then
          if previous.native then
            return nil, "local compaction cannot replace an encrypted checkpoint"
          end
          break
        end
        previous = is_null(previous.parent_id) and nil or by_id[previous.parent_id]
      end
      if first_kept then
        if not by_id[first_kept] then
          return nil, "compaction first kept entry does not exist"
        end
        local current = is_null(entry.parent_id) and nil or by_id[entry.parent_id]
        while current and current.id ~= first_kept do
          current = is_null(current.parent_id) and nil or by_id[current.parent_id]
        end
        if not current then
          return nil, "compaction first kept entry is not on the active path"
        end
      end
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
    local current = is_null(entry.parent_id) and nil or by_id[entry.parent_id]
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
      current = is_null(current.parent_id) and nil or by_id[current.parent_id]
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
  for _, name in ipairs({ "type", "id", "parent_id", "created_at" }) do
    if rawget(payload, name) ~= nil then
      return nil, "entry payload must not set protected field " .. name
    end
  end
  ---@type Neoagent.JournalEntryInput
  local entry = {
    type = opts.type,
    id = opts.id,
    parent_id = opts.parent_id == nil and vim.NIL or opts.parent_id,
    created_at = opts.created_at,
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
    if not is_null(entry.parent_id) and not by_id[entry.parent_id] then
      return nil, "parent entry does not precede child", index
    end
    local references, reference_err = M.validate_references(entry, by_id)
    if not references then
      return nil, reference_err, index
    end
    if entry.type == "leaf" then
      leaf_id = entry.target_id ~= vim.NIL and entry.target_id or nil
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
    current = is_null(current.parent_id) and nil or by_id[current.parent_id]
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
    if entry.native then
      return { { role = "compactionCheckpoint", tokens_before = entry.tokens_before, created_at = entry.created_at } }
    end
    return {
      {
        role = "compactionSummary",
        summary = assert(entry.summary),
        tokens_before = entry.tokens_before,
        created_at = entry.created_at,
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
---@return Neoagent.NativeContextIdentity?
function M.checkpoint_identity(path)
  local index = latest_compaction(path)
  local checkpoint = index and path[index] or nil
  if checkpoint and checkpoint.type == "compaction" and checkpoint.native then
    return { api = checkpoint.native.api, provider = checkpoint.native.provider, model = checkpoint.native.model }
  end
end

---@param path Neoagent.JournalEntry[]
---@param compaction_index integer
---@return Neoagent.JournalEntry[]
local function retained_before(path, compaction_index)
  local result = {}
  local keeping = false
  local compaction = path[compaction_index]
  ---@cast compaction Neoagent.CompactionEntry
  local first_kept = compaction.first_kept_entry_id
  if not first_kept then
    return result
  end
  for index = 1, compaction_index - 1 do
    local entry = assert(path[index])
    if entry.id == first_kept then
      keeping = true
    end
    -- The latest checkpoint already incorporates older summaries. Only the
    -- retained journal messages belong beside it in the active projection.
    if keeping and entry.type ~= "compaction" then
      result[#result + 1] = util.copy(entry)
    end
  end
  return result
end

---@param message Neoagent.UserMessage
---@param text_chars integer
local function truncate_user_text(message, text_chars)
  if type(message.content) == "string" then
    message.content = vim.fn.strcharpart(message.content, 0, text_chars)
    return
  end
  for _, block in ipairs(message.content) do
    if block.type == "text" then
      block.text = vim.fn.strcharpart(block.text, 0, text_chars)
      text_chars = text_chars - vim.fn.strchars(block.text)
    end
  end
end

---@param path Neoagent.JournalEntry[]
---@param compaction_index integer
---@param request boolean
---@return Neoagent.JournalEntry[]
local function native_retained_before(path, compaction_index, request)
  local compaction = path[compaction_index]
  ---@cast compaction Neoagent.CompactionEntry
  local selected = assert(compaction.retained_users)
  local result = {}
  local next_index = 1
  for index = 1, compaction_index - 1 do
    local entry = assert(path[index])
    local retained = selected[next_index]
    if retained and entry.id == retained.entry_id then
      local copy = util.copy(entry) --[[@as Neoagent.MessageEntry]]
      if request and retained.text_chars ~= nil then
        truncate_user_text(copy.message --[[@as Neoagent.UserMessage]], retained.text_chars)
      end
      result[#result + 1] = copy
      next_index = next_index + 1
    end
  end
  return result
end

---@param path Neoagent.JournalEntry[]
---@param request boolean
---@return Neoagent.JournalEntry[]
local function compacted_entries(path, request)
  local compaction_index = latest_compaction(path)
  if not compaction_index then
    return util.copy(path)
  end
  local compaction = util.copy(assert(path[compaction_index]))
  local result = compaction.native and native_retained_before(path, compaction_index, request) or { compaction }
  if compaction.native then
    result[#result + 1] = compaction
  else
    vim.list_extend(result, retained_before(path, compaction_index))
  end
  for index = compaction_index + 1, #path do
    result[#result + 1] = util.copy(path[index])
  end
  return result
end

---@param path Neoagent.JournalEntry[]
---@return Neoagent.JournalEntry[]
function M.context_entries(path)
  return compacted_entries(path, true)
end

---@param path Neoagent.JournalEntry[]
---@return Neoagent.JournalEntry[]
function M.transcript_entries(path)
  local compaction_index = latest_compaction(path)
  if compaction_index and assert(path[compaction_index]).native then
    return util.copy(path)
  end
  return compacted_entries(path, false)
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
        timestamp = message.created_at,
      }
    elseif message.role == "compactionCheckpoint" then
      error("Native compaction checkpoint requires its opaque request item", 0)
    end
  end
  return result
end

---@param path Neoagent.JournalEntry[]
---@return Neoagent.RequestMessage[]
function M.context_messages(path)
  local result = {}
  for _, entry in ipairs(M.context_entries(path)) do
    if entry.type == "compaction" and entry.native then
      result[#result + 1] = util.copy(entry.native)
    else
      vim.list_extend(result, M.to_llm(M.entry_messages(entry)))
    end
  end
  return result
end

-- Snapshot one source path for a planning operation. Candidate validation and
-- projection remain identical to Session publication, while the journal index
-- and prospective path are reused across retention attempts.
---@param path Neoagent.JournalEntry[]
---@return fun(values: Neoagent.CompactionPayload): Neoagent.RequestMessage[]?, Neoagent.Error?
function M.compaction_projector(path)
  local prospective = util.copy(path)
  local length = #prospective
  local by_id = {}
  for _, entry in ipairs(prospective) do
    by_id[entry.id] = entry
  end
  local id = "compaction-preview"
  while by_id[id] do
    id = id .. "_"
  end
  local leaf = prospective[length]
  return function(values)
    local entry, err = M.prepare_entry({
      type = "compaction",
      id = id,
      parent_id = leaf and leaf.id or vim.NIL,
      created_at = util.now_ms(),
      payload = values,
      by_id = by_id,
    })
    if not entry then
      return nil, util.error("session", "Invalid compaction", err)
    end
    prospective[length + 1] = entry
    local messages, message_err = semantic_message.normalize_request_list(M.context_messages(prospective))
    if not messages then
      return nil, util.error("session", "Invalid compacted context", message_err)
    end
    return messages
  end
end

-- Planning and acceptance use the same validation and projection as the
-- Session, without allocating a durable entry or changing its source path.
---@param path Neoagent.JournalEntry[]
---@param values Neoagent.CompactionPayload
---@return Neoagent.RequestMessage[]?, Neoagent.Error?
function M.preview_compaction(path, values)
  return M.compaction_projector(path)(values)
end

---@param result Neoagent.SelectionState
---@param entry Neoagent.JournalEntry
local function apply_state(result, entry)
  if entry.type == "compaction" and entry.native then
    -- A manually published checkpoint may precede any message using this
    -- Model. Its encrypted context determines the selection on resume.
    result.model = { provider = entry.native.provider, model = entry.native.model }
  end
  local request = entry.type == "message" and entry.request or nil
  if request then
    if request.model then
      result.model = util.copy(request.model)
    end
    local thinking_level = rawget(request, "thinking_level")
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
