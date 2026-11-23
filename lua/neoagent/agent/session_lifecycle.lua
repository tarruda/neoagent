local session_tree = require("neoagent.session_tree")
local util = require("neoagent.util")

---@class Neoagent.TranscriptCompactionMessage: Neoagent.CompactionSummary
---@field _neoagent_entry_id? string

---@class Neoagent.TranscriptCheckpointMessage: Neoagent.CompactionCheckpoint
---@field _neoagent_entry_id? string

---@alias Neoagent.TranscriptMessage Neoagent.ObservedMessage|Neoagent.TranscriptCompactionMessage|Neoagent.TranscriptCheckpointMessage

---@class Neoagent.SessionLifecycleState
---@field session Neoagent.Session
---@field activity? Neoagent.AgentActivity
---@field live_usage? Neoagent.LiveContextUsage
---@field provider_status? string
---@field inference_stats? {prompt_tokens_per_second?: number, generation_tokens_per_second?: number}
---@field pending_events Neoagent.AgentEvent[]
---@field last_result? Neoagent.AgentCompletion
---@field steering Neoagent.Steering
---@field destroyed? boolean
---@field session_selection_pending? boolean
---@field session_restore? table
---@field transcript_segment_id? string Absent while following the latest segment.

---@class Neoagent.SessionLifecycleOptions
---@field state Neoagent.SessionLifecycleState
---@field restore_on_open? boolean
---@field restore_selection fun(stored: Neoagent.SelectionState, current: fun(): boolean): Neoagent.Error?
---@field notify fun(message: string, level: integer)
---@field publish_messages fun()
---@field update_context fun()

---@class Neoagent.SessionLifecycle
---@field initialize fun(): true?, Neoagent.Error?
---@field branch fun(entry_id: string): true?, Neoagent.Error?

local M = {}

---@param session Neoagent.Session
---@param segment_id? string
---@param direction? 'first'|'previous'|'next'
---@return Neoagent.TranscriptMessage[], Neoagent.TranscriptHistory
function M.transcript_messages(session, segment_id, direction)
  local entries, err, history = session:transcript_entries(segment_id, direction)
  if not entries then
    error(err, 0)
  end
  local messages = {}
  for _, entry in ipairs(entries) do
    for _, message in ipairs(session_tree.entry_messages(entry)) do
      local observed = message --[[@as Neoagent.TranscriptMessage]]
      observed._neoagent_entry_id = entry.id
      messages[#messages + 1] = observed
    end
  end
  return messages, assert(history)
end

---@param entry Neoagent.JournalEntry
---@param current string?
---@return string
function M.entry_label(entry, current)
  local label = entry.type .. " · " .. entry.id:sub(1, 8)
  if entry.type == "message" then
    ---@cast entry Neoagent.MessageEntry
    local ok, value = pcall(util.text_content, entry.message.content)
    value = ok and util.trim(value:gsub("[%c%s]+", " ")) or ""
    if value ~= "" then
      label = entry.message.role .. " · " .. value
    else
      label = entry.message.role .. " · " .. entry.id:sub(1, 8)
    end
  end
  return entry.id == current and "● " .. label or label
end

---@param opts Neoagent.SessionLifecycleOptions
---@return Neoagent.SessionLifecycle
function M.new(opts)
  local state = opts.state
  local lifecycle = {}

  ---@return boolean?, Neoagent.Error?
  local function restore_preferences()
    local token = {}
    local leaf = state.session:leaf_id()
    state.session_restore = token
    local function current()
      return state.session_restore == token and not state.destroyed and state.session:leaf_id() == leaf
    end
    local read, stored, read_err = pcall(state.session.state, state.session)
    if read and stored and current() then
      local called, failure = pcall(opts.restore_selection, stored, current)
      if current() and (not called or failure) then
        local err = util.normalize_error(failure, "model")
        if err.kind ~= "cancelled" then
          pcall(opts.notify, "could not restore Model: " .. err.message, vim.log.levels.WARN)
        end
      end
    end
    local owned = current()
    if state.session_restore == token then
      state.session_restore = nil
    end
    if not owned then
      return false
    end
    if not read then
      return nil, util.normalize_error(stored, "session")
    end
    if not stored then
      return nil, read_err
    end
    return true
  end

  local function publish_active()
    opts.publish_messages()
    opts.update_context()
  end

  ---@return true?, Neoagent.Error?
  function lifecycle.initialize()
    if opts.restore_on_open then
      local restored, err = restore_preferences()
      if restored == nil then
        return nil, err
      end
    end
    return true
  end

  ---@param entry_id string
  ---@return true?, Neoagent.Error?
  function lifecycle.branch(entry_id)
    if state.activity then
      opts.notify("cannot change branches while the agent is running", vim.log.levels.WARN)
      return nil
    end
    local ok, err = state.session:move_to(entry_id)
    if not ok then
      opts.notify(assert(err).message, vim.log.levels.ERROR)
      return nil, err
    end
    state.live_usage, state.provider_status, state.inference_stats = nil, nil, nil
    state.pending_events, state.last_result = {}, nil
    state.transcript_segment_id = nil
    state.steering:clear()
    if not state.session_selection_pending then
      local restored, restore_err = restore_preferences()
      if restored ~= true then
        return restored == false and true or nil, restore_err
      end
    end
    publish_active()
    return true
  end

  return lifecycle
end

return M
