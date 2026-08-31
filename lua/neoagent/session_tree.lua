local util = require("neoagent.util")

local M = {}

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local validators = {
  message = function(entry)
    if type(entry.message) ~= "table" then return false, "message must be an object" end
    if not nonempty_string(entry.message.role) then return false, "message role is required" end
    if entry.message.content == nil then
      return false, "message content is required"
    end
    return true
  end,
  model_change = function(entry)
    if not nonempty_string(entry.provider) or not nonempty_string(entry.modelId) then
      return false, "model changes require provider and modelId"
    end
    return true
  end,
  thinking_level_change = function(entry)
    if not nonempty_string(entry.thinkingLevel) then
      return false, "thinking level changes require thinkingLevel"
    end
    return true
  end,
  compaction = function(entry)
    if not nonempty_string(entry.summary) or not nonempty_string(entry.firstKeptEntryId)
        or type(entry.tokensBefore) ~= "number" then
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

function M.validate_entry(entry)
  if type(entry) ~= "table" then return false, "entry must be an object" end
  if not nonempty_string(entry.type) or not validators[entry.type] then
    return false, "unsupported entry type: " .. tostring(entry.type)
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
  return true
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
  if entry.type == "model_change" then
    result.model = { provider = entry.provider, model = entry.modelId }
  elseif entry.type == "thinking_level_change" then
    result.thinking_level = entry.thinkingLevel
  elseif entry.type == "message" and entry.message.role == "assistant"
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
