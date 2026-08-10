local session_tree = require("neoagent.session_tree")
local util = require("neoagent.util")

local M = {}

local activation_fields = {
  "session", "session_id", "model", "model_selection", "thinking_level",
  "workspace", "workspace_settings", "workspace_overrides", "store",
  "store_seeded", "live_usage", "provider_status", "pending_events",
  "steering", "last_result",
}

local function checkpoint(state)
  local result = {}
  for _, field in ipairs(activation_fields) do result[field] = state[field] end
  return result
end

local function restore(state, saved)
  for _, field in ipairs(activation_fields) do state[field] = saved[field] end
end

local function clear_activity(state)
  state.live_usage, state.provider_status = nil, nil
  state.pending_events, state.steering, state.last_result = {}, {}, nil
end

function M.transcript_messages(session)
  local path, err = session:path()
  if not path then error(err, 0) end
  return session_tree.messages(session_tree.transcript_entries(path))
end

function M.entry_label(entry, current)
  local label = entry.type .. " · " .. entry.id:sub(1, 8)
  if entry.type == "message" then
    local ok, value = pcall(util.text_content, entry.message.content)
    value = ok and util.trim(value:gsub("[%c%s]+", " ")) or ""
    if value ~= "" then
      if vim.fn.strchars(value) > 70 then value = vim.fn.strcharpart(value, 0, 70) .. "…" end
      label = entry.message.role .. " · " .. value
    else
      label = entry.message.role .. " · " .. entry.id:sub(1, 8)
    end
  end
  return entry.id == current and "● " .. label or label
end

function M.new(opts)
  local state = opts.state
  local config = opts.config
  local lifecycle = {}

  local function restore_preferences(stored)
    state.model, state.model_selection, state.thinking_level = nil, nil, nil
    local workspace_default = opts.preferences().default_model
    local candidates = {}
    if stored.model then candidates[#candidates + 1] = stored.model end
    if workspace_default and (not stored.model or workspace_default.provider ~= stored.model.provider
        or workspace_default.model ~= stored.model.model) then
      candidates[#candidates + 1] = workspace_default
    end
    for _, selected in ipairs(candidates) do
      local ok, model = pcall(require("neoagent.models").resolve, selected.provider, selected.model,
        config, opts.auth_manager)
      if ok then
        state.model = model
        state.model_selection = util.copy(selected)
        break
      else
        opts.notify("could not restore model " .. tostring(selected.provider) .. "/" .. tostring(selected.model)
          .. ": " .. tostring(model), vim.log.levels.WARN)
      end
    end
    if state.model then
      state.thinking_level = opts.thinking_level(state.model, stored.thinking_level)
    end
  end

  local function publish_active(session)
    opts.publish_messages(M.transcript_messages(session))
    opts.update_context()
  end

  function lifecycle.make(cwd)
    opts.require_workspace_trust(cwd)
    local Session = require("neoagent.session")
    opts.activate_workspace(cwd)
    local persistence = config.persistence
    if persistence.enabled then
      state.store = require("neoagent.storage").new({
        directory = persistence.directory,
        cwd = state.workspace.root,
      })
      state.store_seeded = false
      local session, err = Session.new({ store = state.store })
      if not session then return nil, err end
      local seeded, seed_err = opts.seed_store()
      if not seeded then return nil, seed_err end
      return session
    end
    state.store, state.store_seeded = nil, false
    return Session.new()
  end

  function lifecycle.new_session()
    if state.run then
      opts.notify("cannot create a session while the agent is running", vim.log.levels.WARN)
      return nil
    end
    local cwd = vim.fn.getcwd()
    local trusted, trust_err = pcall(opts.require_workspace_trust, cwd)
    if not trusted then
      trust_err = util.normalize_error(trust_err, "workspace_trust")
      opts.notify(trust_err.message, vim.log.levels.ERROR)
      return nil, trust_err
    end
    local saved = checkpoint(state)
    local root = require("neoagent.fs").canonical(cwd)
    if state.workspace and state.workspace.root == root then
      state.model, state.model_selection, state.thinking_level = nil, nil, nil
    end
    clear_activity(state)
    local session, err = lifecycle.make(cwd)
    if not session then
      restore(state, saved)
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    if opts.preferences().default_model then
      local resolved, model_err = pcall(opts.ensure_model)
      if not resolved then
        restore(state, saved)
        model_err = util.normalize_error(model_err, "model")
        opts.notify(model_err.message, vim.log.levels.ERROR)
        return nil, model_err
      end
    end
    opts.activate_session(session)
    opts.publish_messages({})
    opts.update_context()
    return session
  end

  function lifecycle.resume(path)
    local store, err = require("neoagent.storage").open(path)
    if not store then
      opts.notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.ERROR)
      return nil, err
    end
    local cwd = store:metadata().cwd
    local trusted, trust_err = pcall(opts.require_workspace_trust, cwd)
    if not trusted then
      trust_err = util.normalize_error(trust_err, "workspace_trust")
      opts.notify(trust_err.message, vim.log.levels.ERROR)
      return nil, trust_err
    end
    local saved = checkpoint(state)
    local activated, activate_err = pcall(opts.activate_workspace, cwd)
    if not activated then
      restore(state, saved)
      activate_err = util.normalize_error(activate_err, "session")
      opts.notify(activate_err.message, vim.log.levels.ERROR)
      return nil, activate_err
    end
    local session
    session, err = require("neoagent.session").new({ store = store })
    if not session then
      restore(state, saved)
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    opts.activate_session(session)
    state.store, state.store_seeded = store, true
    clear_activity(state)
    restore_preferences(store:state())
    publish_active(session)
    return session
  end

  function lifecycle.branch(entry_id, summary)
    if state.run then
      opts.notify("cannot change branches while the agent is running", vim.log.levels.WARN)
      return nil
    end
    if not state.session then opts.notify("no active session") return nil end
    local ok, err = state.session:move_to(entry_id, summary)
    if not ok then opts.notify(err.message, vim.log.levels.ERROR) return nil, err end
    clear_activity(state)
    local stored = assert(state.session:state())
    restore_preferences(stored)
    state.store_seeded = stored.model ~= nil
    publish_active(state.session)
    return true
  end

  function lifecycle.fork(entry_id, position)
    if state.run then opts.notify("cannot fork while the agent is running", vim.log.levels.WARN) return nil end
    if not state.store or not state.store:metadata().persisted then
      opts.notify("the active session is not persisted")
      return nil
    end
    local selected_text
    if entry_id and (position == nil or position == "before") then
      local target = state.session:entry(entry_id)
      if target and target.type == "message" and target.message.role == "user" then
        local text_ok, text = pcall(util.text_content, target.message.content)
        if text_ok then selected_text = text end
      end
    end
    local store, err = require("neoagent.storage").fork(state.store, {
      directory = config.persistence.directory,
      cwd = state.workspace.root,
      entry_id = entry_id,
      position = position,
    })
    if not store then opts.notify(err.message, vim.log.levels.ERROR) return nil, err end
    local session
    session, err = require("neoagent.session").new({ store = store })
    if not session then opts.notify(err.message, vim.log.levels.ERROR) return nil, err end
    state.store, state.store_seeded = store, true
    opts.activate_session(session)
    clear_activity(state)
    restore_preferences(store:state())
    publish_active(session)
    return session, selected_text
  end

  return lifecycle
end

return M
