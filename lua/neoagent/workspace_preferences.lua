local thinking = require("neoagent.thinking")
local model_config = require("neoagent.model_config")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.WorkspacePreferenceSource
---@field root string
---@field directory? string
---@field settings Neoagent.JsonObject
---@field warnings string[]

-- Retain the storage identity and raw scopes, independently of effective values.
-- Recomposition can reuse a snapshot only while its storage identity matches.
---@param configured Neoagent.Config<Neoagent.AgentToolEnvironment>
---@param root string
---@param previous? Neoagent.WorkspacePreferenceSource
---@return Neoagent.WorkspacePreferenceSource
function M.load(configured, root, previous)
  local persistence = configured.persistence
  local fs = require("neoagent.fs")
  root = fs.canonical(root)
  local directory = persistence.enabled and persistence.workspace_settings and fs.canonical(persistence.directory)
    or nil
  if previous and previous.root == root and previous.directory == directory then
    return util.copy(previous)
  end
  ---@type Neoagent.WorkspacePreferenceSource
  local source = { root = root, directory = directory, settings = {}, warnings = {} }
  if not directory then
    return source
  end
  local store = require("neoagent.workspace_settings").new({ directory = directory, root = root })
  local settings, err = store:load()
  if settings then
    source.settings = settings
    return source
  end
  assert(err)
  source.warnings = {
    err.message
      .. (err.detail and ": " .. err.detail or "")
      .. "; the file may be outdated, update or delete "
      .. store:metadata().settings_path,
  }
  return source
end

---@alias Neoagent.UiPosition "auto"|"left"|"right"|"top"|"bottom"|"center"

---@class Neoagent.WorkspacePreferencesInput
---@field default_model? unknown
---@field default_thinking_level? unknown
---@field ui_position? unknown

---@class Neoagent.WorkspacePreferences: Neoagent.WorkspacePreferencesInput
---@field default_model? Neoagent.ModelSelection
---@field default_thinking_level? Neoagent.ThinkingLevel
---@field ui_position? Neoagent.UiPosition

---@class Neoagent.WorkspacePreferenceDefaults: Neoagent.WorkspacePreferences
---@field default_thinking_level Neoagent.ThinkingLevel
---@field ui_position Neoagent.UiPosition

---@type table<string, boolean>
local ui_positions = {
  auto = true,
  left = true,
  right = true,
  top = true,
  bottom = true,
  center = true,
}

---@param value unknown
---@return TypeGuard<table<string, unknown>>
local function is_object(value)
  return type(value) == "table" and (next(value) == nil or not util.is_list(value))
end

---@param settings Neoagent.JsonObject
---@param defaults Neoagent.WorkspacePreferenceDefaults
---@param name string
---@param automatic? boolean
---@return Neoagent.WorkspacePreferences, string[]
function M.scope(settings, defaults, name, automatic)
  assert(is_object(settings), "workspace settings must be an object")
  assert(is_object(defaults), "workspace preference defaults must be an object")
  assert(type(name) == "string" and name ~= "", "workspace preference name must be a non-empty string")

  ---@type string[]
  local issues = {}
  for key in pairs(settings) do
    if key ~= "ui_position" and key ~= "agents" and key ~= "default_model" then
      issues[#issues + 1] = "unsupported workspace setting: " .. tostring(key)
    end
  end
  ---@type Neoagent.WorkspacePreferencesInput
  local accepted = { ui_position = rawget(settings, "ui_position") }
  local agents = rawget(settings, "agents")
  if agents ~= nil and not is_object(agents) then
    issues[#issues + 1] = "workspace agents must be an object"
    agents = nil
  end
  local scoped = agents and agents[name]
  if scoped ~= nil and not is_object(scoped) then
    issues[#issues + 1] = "workspace settings for " .. name .. " must be an object"
    scoped = nil
  end
  scoped = scoped or {}
  for key in pairs(scoped) do
    if key ~= "default_model" and key ~= "default_thinking_level" then
      issues[#issues + 1] = "unsupported workspace setting for " .. name .. ": " .. tostring(key)
    end
  end
  accepted.default_model = not automatic and rawget(scoped, "default_model") or rawget(settings, "default_model")
  accepted.default_thinking_level = rawget(scoped, "default_thinking_level")

  local merged = util.deep_merge(defaults, accepted)
  ---@cast merged Neoagent.WorkspacePreferencesInput
  if
    merged.default_model ~= nil
    and (
      type(merged.default_model) ~= "table"
      or not model_config.safe_provider_id(merged.default_model.provider)
      or not model_config.safe_id(merged.default_model.model)
    )
  then
    issues[#issues + 1] = "workspace default_model is invalid"
    accepted.default_model = nil
  end
  if not thinking.is_level(merged.default_thinking_level) then
    issues[#issues + 1] = "workspace default_thinking_level is invalid"
    accepted.default_thinking_level = nil
  end
  if not ui_positions[merged.ui_position] then
    issues[#issues + 1] = "workspace ui_position is invalid"
    accepted.ui_position = nil
  end
  ---@cast accepted Neoagent.WorkspacePreferences
  return accepted, issues
end

---@param issues string[]
---@param path string
---@return string?
function M.warning(issues, path)
  if #issues == 0 then
    return nil
  end
  return table.concat(issues, "; ") .. "; the file may be outdated, update or delete " .. path
end

---@param name string
---@param patch Neoagent.WorkspacePreferences
---@param automatic? boolean
---@return Neoagent.JsonObject
function M.patch(name, patch, automatic)
  local result = {}
  if patch.ui_position ~= nil then
    result.ui_position = patch.ui_position
  end
  local scoped = {}
  if patch.default_model ~= nil then
    if automatic then
      result.default_model = patch.default_model
    else
      scoped.default_model = patch.default_model
    end
  end
  if patch.default_thinking_level ~= nil then
    scoped.default_thinking_level = patch.default_thinking_level
  end
  if next(scoped) ~= nil then
    result.agents = { [name] = scoped }
  end
  return result
end

return M
