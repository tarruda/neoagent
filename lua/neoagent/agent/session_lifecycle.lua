local session_tree = require("neoagent.session_tree")
local util = require("neoagent.util")

---@class Neoagent.TranscriptCompactionMessage: Neoagent.CompactionSummary
---@field _neoagent_entry_id? string

---@alias Neoagent.TranscriptMessage Neoagent.ObservedMessage|Neoagent.TranscriptCompactionMessage

---@class Neoagent.SessionLifecycleState
---@field session Neoagent.Session
---@field activity? Neoagent.AgentActivity
---@field live_usage? Neoagent.LiveContextUsage
---@field provider_status? string
---@field inference_stats? {prompt_tokens_per_second?: number, generation_tokens_per_second?: number}
---@field pending_events Neoagent.AgentEvent[]
---@field last_result? Neoagent.AgentCompletion
---@field steering Neoagent.Steering
---@field session_selection_pending? boolean

---@class Neoagent.SessionLifecycleOptions
---@field state Neoagent.SessionLifecycleState
---@field restore_selection? boolean
---@field request_selection Neoagent.RequestSelection
---@field preferences fun(): Neoagent.WorkspacePreferences
---@field notify fun(message: string, level: integer)
---@field bind_provider fun(provider: string): unknown
---@field publish_messages fun(messages: Neoagent.TranscriptMessage[])
---@field update_context fun()

---@class Neoagent.SessionLifecycle
---@field initialize fun(): true?, Neoagent.Error?
---@field branch fun(entry_id: string): true?, Neoagent.Error?

local M = {}

---@param session Neoagent.Session
---@return Neoagent.TranscriptMessage[]
function M.transcript_messages(session)
  local path, err = session:path()
  if not path then
    error(err, 0)
  end
  local messages = {}
  for _, entry in ipairs(session_tree.transcript_entries(path)) do
    for _, message in ipairs(session_tree.entry_messages(entry)) do
      local observed = message --[[@as Neoagent.TranscriptMessage]]
      observed._neoagent_entry_id = entry.id
      messages[#messages + 1] = observed
    end
  end
  return messages
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

  ---@param stored Neoagent.SelectionState
  local function restore_preferences(stored)
    local selection = opts.request_selection
    selection:clear(true)
    local workspace_default = opts.preferences().default_model
    local candidates = {}
    if stored.model then
      candidates[#candidates + 1] = stored.model
    end
    if
      workspace_default
      and (
        not stored.model
        or workspace_default.provider ~= stored.model.provider
        or workspace_default.model ~= stored.model.model
      )
    then
      candidates[#candidates + 1] = workspace_default
    end
    for _, selected in ipairs(candidates) do
      local model, err = selection:resolve(selected, stored.thinking_level)
      if model then
        break
      end
      opts.notify(
        "could not restore model "
          .. tostring(selected.provider)
          .. "/"
          .. tostring(selected.model)
          .. ": "
          .. err.message,
        vim.log.levels.WARN
      )
    end
    local selected = selection:model_selection()
    if selected then
      opts.bind_provider(selected.provider)
    end
  end

  local function publish_active()
    opts.publish_messages(M.transcript_messages(state.session))
    opts.update_context()
  end

  ---@return true?, Neoagent.Error?
  function lifecycle.initialize()
    if opts.restore_selection then
      local stored, err = state.session:state()
      if not stored then
        return nil, err
      end
      restore_preferences(stored)
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
    state.steering:clear()
    local stored
    stored, err = state.session:state()
    if not stored then
      return nil, err
    end
    if not state.session_selection_pending then
      restore_preferences(stored)
    end
    publish_active()
    return true
  end

  return lifecycle
end

return M
