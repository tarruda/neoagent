local estimate = require("neoagent.context_estimate")
local tree = require("neoagent.session_tree")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.CompactionOptions
---@field auto? boolean
---@field reserve_tokens? integer
---@field keep_recent_tokens? integer

---@class Neoagent.CompactionSettings: Neoagent.CompactionOptions
---@field auto boolean
---@field reserve_tokens integer
---@field keep_recent_tokens integer

---@class Neoagent.CompactionCut
---@field first_kept_index integer
---@field turn_start_index? integer
---@field split_turn boolean

---@class Neoagent.CompactionPreparation
---@field first_kept_entry_id string
---@field messages Neoagent.Message[]
---@field turn_prefix Neoagent.Message[]
---@field split_turn boolean
---@field tokens_before integer
---@field previous_summary? string
---@field settings Neoagent.CompactionSettings

---@type Neoagent.CompactionSettings
M.defaults = {
  auto = true,
  reserve_tokens = 16384,
  keep_recent_tokens = 20000,
}

M.usage_tokens = estimate.usage_tokens
M.estimate_tokens = estimate.estimate_tokens
M.estimate_context = estimate.estimate_context

---@param configured? Neoagent.CompactionOptions
---@param context_window? number
---@param defaults? Neoagent.CompactionSettings
---@return Neoagent.CompactionSettings
function M.settings(configured, context_window, defaults)
  local merged = util.deep_merge(defaults or M.defaults, configured or {})
  ---@cast merged Neoagent.CompactionSettings
  local reserve = merged.reserve_tokens
  local keep = merged.keep_recent_tokens
  if type(context_window) == "number" and context_window > 0 then
    reserve = math.min(reserve, math.max(1, math.floor(context_window / 4)))
    keep = math.min(keep, math.max(1, math.floor((context_window - reserve) / 2)))
  end
  return { auto = merged.auto, reserve_tokens = reserve, keep_recent_tokens = keep }
end

---@param context_tokens number
---@param context_window number
---@param settings Neoagent.CompactionSettings
---@return boolean
function M.should_compact(context_tokens, context_window, settings)
  return settings.auto and context_window > 0 and context_tokens > context_window - settings.reserve_tokens
end

---@param entry Neoagent.JournalEntry
---@return Neoagent.Message?
local function entry_message(entry)
  if entry.type == "message" then
    return util.copy(entry.message)
  end
  return nil
end

---@param entry Neoagent.JournalEntry
---@return boolean
local function is_cut_point(entry)
  if entry.type ~= "message" then
    return false
  end
  ---@cast entry Neoagent.MessageEntry
  local role = entry.message.role
  return role == "user" or role == "assistant"
end

---@param entry Neoagent.JournalEntry
---@return boolean
local function is_turn_start(entry)
  if entry.type ~= "message" then
    return false
  end
  ---@cast entry Neoagent.MessageEntry
  return entry.message.role == "user"
end

---@param entries Neoagent.JournalEntry[]
---@param entry_index integer
---@param start_index integer
---@return integer?
function M.find_turn_start(entries, entry_index, start_index)
  for index = entry_index, start_index, -1 do
    if is_turn_start(assert(entries[index])) then
      return index
    end
  end
  return nil
end

---@param entries Neoagent.JournalEntry[]
---@param start_index integer
---@param end_index integer
---@param keep_recent_tokens integer
---@return Neoagent.CompactionCut
function M.find_cut_point(entries, start_index, end_index, keep_recent_tokens)
  ---@type integer[]
  local cut_points = {}
  for index = start_index, end_index do
    if is_cut_point(assert(entries[index])) then
      cut_points[#cut_points + 1] = index
    end
  end
  if #cut_points == 0 then
    return { first_kept_index = start_index, split_turn = false }
  end
  local accumulated = 0
  local cut_index = cut_points[1]
  assert(cut_index)
  for index = end_index, start_index, -1 do
    local entry = assert(entries[index])
    if entry.type == "message" then
      accumulated = accumulated + M.estimate_tokens(entry.message)
    end
    if accumulated >= keep_recent_tokens then
      for _, candidate in ipairs(cut_points) do
        if candidate > index then
          break
        end
        cut_index = candidate
      end
      break
    end
  end
  while cut_index > start_index do
    local previous = assert(entries[cut_index - 1])
    if previous.type == "compaction" or previous.type == "message" then
      break
    end
    cut_index = cut_index - 1
  end
  local turn_start
  if not is_turn_start(assert(entries[cut_index])) then
    turn_start = M.find_turn_start(entries, cut_index, start_index)
  end
  return {
    first_kept_index = cut_index,
    turn_start_index = turn_start,
    split_turn = turn_start ~= nil,
  }
end

---@param path_entries Neoagent.JournalEntry[]
---@param settings Neoagent.CompactionSettings
---@return Neoagent.CompactionPreparation?, Neoagent.Error?
function M.prepare(path_entries, settings)
  if #path_entries == 0 or assert(path_entries[#path_entries]).type == "compaction" then
    return nil
  end
  local previous_index
  for index = #path_entries, 1, -1 do
    if assert(path_entries[index]).type == "compaction" then
      previous_index = index
      break
    end
  end
  local boundary_start = 1
  local previous_summary
  if previous_index then
    local previous = path_entries[previous_index]
    ---@cast previous Neoagent.CompactionEntry
    previous_summary = previous.summary
    for index, entry in ipairs(path_entries) do
      if entry.id == previous.first_kept_entry_id then
        boundary_start = index
        break
      end
    end
    if boundary_start == 1 and assert(path_entries[1]).id ~= previous.first_kept_entry_id then
      boundary_start = previous_index + 1
    end
  end
  local context = tree.to_llm(tree.messages(path_entries, true))
  local cut = M.find_cut_point(path_entries, boundary_start, #path_entries, settings.keep_recent_tokens)
  local first_kept = assert(path_entries[cut.first_kept_index])
  local history_end = cut.turn_start_index or cut.first_kept_index
  ---@type Neoagent.Message[]
  local messages = {}
  for index = boundary_start, history_end - 1 do
    local message = entry_message(assert(path_entries[index]))
    if message then
      messages[#messages + 1] = message
    end
  end
  ---@type Neoagent.Message[]
  local turn_prefix = {}
  if cut.split_turn then
    for index = assert(cut.turn_start_index), cut.first_kept_index - 1 do
      local message = entry_message(assert(path_entries[index]))
      if message then
        turn_prefix[#turn_prefix + 1] = message
      end
    end
  end
  if #messages == 0 and #turn_prefix == 0 then
    return nil, util.error("compaction", "Nothing can be compacted while retaining the recent context")
  end
  return {
    first_kept_entry_id = first_kept.id,
    messages = messages,
    turn_prefix = turn_prefix,
    split_turn = cut.split_turn,
    tokens_before = math.ceil(M.estimate_context(context).tokens),
    previous_summary = previous_summary,
    settings = util.copy(settings),
  }
end

return M
