local session_tree = require("neoagent.session_tree")
local util = require("neoagent.util")

local M = {}

function M.transcript_messages(session)
  local path, err = session:path()
  if not path then error(err, 0) end
  local messages = {}
  for _, entry in ipairs(session_tree.transcript_entries(path)) do
    for _, message in ipairs(session_tree.entry_messages(entry)) do
      message._neoagent_entry_id = entry.id
      messages[#messages + 1] = message
    end
  end
  return messages
end

function M.entry_label(entry, current)
  local label = entry.type .. " · " .. entry.id:sub(1, 8)
  if entry.type == "message" then
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

function M.new(opts)
  local state = opts.state
  local lifecycle = {}

  local function restore_preferences(stored)
    local selection = opts.request_selection
    selection:clear(true)
    local workspace_default = opts.preferences().default_model
    local candidates = {}
    if stored.model then candidates[#candidates + 1] = stored.model end
    if workspace_default and (not stored.model
        or workspace_default.provider ~= stored.model.provider
        or workspace_default.model ~= stored.model.model) then
      candidates[#candidates + 1] = workspace_default
    end
    for _, selected in ipairs(candidates) do
      local model, err = selection:resolve(selected, stored.thinking_level)
      if model then
        break
      end
      opts.notify("could not restore model " .. tostring(selected.provider)
        .. "/" .. tostring(selected.model) .. ": " .. err.message,
        vim.log.levels.WARN)
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

  function lifecycle.initialize()
    assert(state.session, "Agent Session is required")
    opts.activate_workspace(opts.workspace)
    if opts.restore_selection then
      local stored, err = state.session:state()
      if not stored then return nil, err end
      restore_preferences(stored)
    end
    return true
  end

  function lifecycle.branch(entry_id)
    if state.activity then
      opts.notify("cannot change branches while the agent is running",
        vim.log.levels.WARN)
      return nil
    end
    local ok, err = state.session:move_to(entry_id)
    if not ok then
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    state.live_usage, state.provider_status, state.inference_stats = nil, nil, nil
    state.pending_events, state.last_result = {}, nil
    state.steering:clear()
    local stored
    stored, err = state.session:state()
    if not stored then return nil, err end
    if not state.session_selection_pending then
      restore_preferences(stored)
    end
    publish_active()
    return true
  end

  return lifecycle
end

return M
