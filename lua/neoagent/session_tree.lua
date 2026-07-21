local util = require("neoagent.util")

local M = {}

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local function valid_string_array(value)
  if type(value) ~= "table" or not util.is_list(value) then return false end
  for _, item in ipairs(value) do
    if type(item) ~= "string" then return false end
  end
  return true
end

local validators = {
  message = function(entry)
    if type(entry.message) ~= "table" then return false, "message must be an object" end
    if not nonempty_string(entry.message.role) then return false, "message role is required" end
    if entry.message.role ~= "bashExecution" and entry.message.content == nil then
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
  active_tools_change = function(entry)
    if not valid_string_array(entry.activeToolNames) then
      return false, "active tool changes require an array of tool names"
    end
    return true
  end,
  compaction = function(entry)
    if not nonempty_string(entry.summary) or not nonempty_string(entry.firstKeptEntryId)
        or type(entry.tokensBefore) ~= "number" then
      return false, "compactions require summary, firstKeptEntryId, and tokensBefore"
    end
    if entry.fromHook ~= nil and entry.fromHook ~= vim.NIL and type(entry.fromHook) ~= "boolean" then
      return false, "compaction fromHook must be boolean"
    end
    return true
  end,
  branch_summary = function(entry)
    if not nonempty_string(entry.fromId) or not nonempty_string(entry.summary) then
      return false, "branch summaries require fromId and summary"
    end
    if entry.fromHook ~= nil and entry.fromHook ~= vim.NIL and type(entry.fromHook) ~= "boolean" then
      return false, "branch summary fromHook must be boolean"
    end
    return true
  end,
  custom = function(entry)
    if not nonempty_string(entry.customType) then return false, "custom entries require customType" end
    return true
  end,
  custom_message = function(entry)
    if not nonempty_string(entry.customType) or (type(entry.content) ~= "string" and type(entry.content) ~= "table")
        or type(entry.display) ~= "boolean" then
      return false, "custom messages require customType, content, and display"
    end
    return true
  end,
  label = function(entry)
    if not nonempty_string(entry.targetId)
        or (not is_null(entry.label) and type(entry.label) ~= "string") then
      return false, "labels require targetId and an optional string label"
    end
    return true
  end,
  session_info = function(entry)
    if not is_null(entry.name) and type(entry.name) ~= "string" then
      return false, "session info name must be a string"
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

function M.validate_entries(entries)
  local by_id = {}
  local leaf_id
  for index, entry in ipairs(entries) do
    local valid, err = M.validate_entry(entry)
    if not valid then return nil, err, index end
    if by_id[entry.id] then return nil, "duplicate entry id", index end
    if not is_null(entry.parentId) and not by_id[entry.parentId] then
      return nil, "parent entry does not precede child", index
    end
    if entry.type == "leaf" then
      if not is_null(entry.targetId) and not by_id[entry.targetId] then
        return nil, "leaf target does not exist", index
      end
      leaf_id = is_null(entry.targetId) and nil or entry.targetId
    else
      leaf_id = entry.id
    end
    by_id[entry.id] = entry
  end
  return { by_id = by_id, leaf_id = leaf_id }
end

function M.path(entries, leaf_id)
  local validated, err, index = M.validate_entries(entries)
  if not validated then return nil, err, index end
  if leaf_id == vim.NIL then return {} end
  leaf_id = leaf_id or validated.leaf_id
  if not leaf_id then return {} end
  local current = validated.by_id[leaf_id]
  if not current then return nil, "entry not found: " .. tostring(leaf_id) end
  local result = {}
  while current do
    table.insert(result, 1, util.copy(current))
    current = is_null(current.parentId) and nil or validated.by_id[current.parentId]
  end
  return result
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
  if entry.type == "custom_message" then
    return { {
      role = "custom",
      customType = entry.customType,
      content = util.copy(entry.content),
      display = entry.display,
      details = util.copy(entry.details),
      timestamp = timestamp_ms(entry.timestamp),
    } }
  end
  if entry.type == "branch_summary" then
    return { {
      role = "branchSummary",
      summary = entry.summary,
      fromId = entry.fromId,
      timestamp = timestamp_ms(entry.timestamp),
    } }
  end
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

function M.context_entries(path)
  local compaction_index
  for index, entry in ipairs(path) do
    if entry.type == "compaction" then compaction_index = index end
  end
  if not compaction_index then return util.copy(path) end
  local compaction = path[compaction_index]
  local result = { util.copy(compaction) }
  local keeping = false
  for index = 1, compaction_index - 1 do
    if path[index].id == compaction.firstKeptEntryId then keeping = true end
    if keeping then result[#result + 1] = util.copy(path[index]) end
  end
  for index = compaction_index + 1, #path do result[#result + 1] = util.copy(path[index]) end
  return result
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
    elseif message.role == "bashExecution" and not message.excludeFromContext then
      local text = "Ran `" .. tostring(message.command or "") .. "`\n"
      text = text .. ((message.output and message.output ~= "") and ("```\n" .. message.output .. "\n```") or "(no output)")
      if message.cancelled then
        text = text .. "\n\n(command cancelled)"
      elseif message.exitCode ~= nil and message.exitCode ~= vim.NIL and message.exitCode ~= 0 then
        text = text .. "\n\nCommand exited with code " .. tostring(message.exitCode)
      end
      result[#result + 1] = { role = "user", content = tagged("", text, ""), timestamp = message.timestamp }
    elseif message.role == "custom" then
      result[#result + 1] = {
        role = "user",
        content = type(message.content) == "string" and tagged("", message.content, "") or util.copy(message.content),
        timestamp = message.timestamp,
      }
    elseif message.role == "branchSummary" then
      result[#result + 1] = {
        role = "user",
        content = tagged("The following is a summary of a branch that this conversation came back from:\n\n<summary>\n",
          message.summary, "\n</summary>"),
        timestamp = message.timestamp,
      }
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

function M.state(path)
  local result = { model = nil, thinking_level = nil, active_tools = nil }
  for _, entry in ipairs(path) do
    if entry.type == "model_change" then
      result.model = { provider = entry.provider, model = entry.modelId }
    elseif entry.type == "thinking_level_change" then
      result.thinking_level = entry.thinkingLevel
    elseif entry.type == "active_tools_change" then
      result.active_tools = util.copy(entry.activeToolNames)
    elseif entry.type == "message" and entry.message.role == "assistant"
        and nonempty_string(entry.message.provider) and nonempty_string(entry.message.model) then
      result.model = { provider = entry.message.provider, model = entry.message.model }
    end
  end
  return result
end

return M
