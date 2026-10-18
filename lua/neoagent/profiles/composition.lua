local util = require("neoagent.util")
local config = require("neoagent.config")
local M = {}

---@class Neoagent.ProfileCompositionOptions
---@field profile Neoagent.Profile
---@field options? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@field model? Neoagent.ModelSelection
---@field thinking_level? Neoagent.ThinkingLevel
---@field automatic? boolean
---@field preference_source? Neoagent.WorkspacePreferenceSource
---@field workspace? string
---@field model_error? Neoagent.Error

---@class Neoagent.ProfileComposition
---@field profile Neoagent.Profile
---@field config Neoagent.Config<Neoagent.AgentToolEnvironment>
---@field options Neoagent.ConfigInput<Neoagent.AgentToolEnvironment> Explicit draft overrides.
---@field automatic boolean
---@field preference_source Neoagent.WorkspacePreferenceSource
---@field warnings string[]
---@field model_error? Neoagent.Error
---@field execution 'switchable'|'fixed'
---@field compaction Neoagent.CompactionComponent
---@field renderer? Neoagent.Renderer<unknown> Borrowed presentation dependency, separate from copied settings.
---@field renderer_factory? fun(): Neoagent.Renderer<unknown>

-- The registered recipe is an identity borrowed from the composition owner.
-- Mutable configuration and selection snapshots are independent values.
---@param resolved Neoagent.ProfileComposition
---@return Neoagent.ProfileComposition
function M.copy(resolved)
  local copy = util.shallow_copy(resolved)
  copy.config = util.copy(resolved.config)
  copy.options = config.copy(resolved.options)
  copy.preference_source = util.copy(resolved.preference_source)
  copy.warnings = util.copy(resolved.warnings)
  copy.model_error = util.copy(resolved.model_error)
  return copy
end

---@class Neoagent.UIPresentation
---@field config Neoagent.UIConfig Copied settings; renderer input has been normalized out.
---@field renderer Neoagent.Renderer<unknown> Borrowed Renderer.

---@param resolved Neoagent.ProfileComposition
---@return Neoagent.Tool<Neoagent.AgentToolEnvironment>[]
function M.tools(resolved)
  local configured = resolved.config
  if configured.tools then
    return util.copy(configured.tools)
  end
  local create = resolved.profile.create_tools
  return create and create(config.agent_settings(configured)) or {}
end

---@param resolved Neoagent.ProfileComposition
---@param overrides? Neoagent.UIConfigInput
---@return Neoagent.UIPresentation
function M.presentation(resolved, overrides)
  local base = util.shallow_copy(resolved.config.ui)
  base.renderer = resolved.renderer
  local selected, renderer = config.ui_settings(config.extend_ui(base, overrides))
  if not (overrides and (overrides.style or overrides.renderer)) and resolved.renderer_factory then
    renderer = resolved.renderer_factory()
    assert(renderer, "Profile renderer factory must return a renderer")
  elseif not (overrides and (overrides.style or overrides.renderer)) then
    renderer = resolved.renderer
  end
  return { config = selected, renderer = renderer or assert(require("neoagent.ui.renderers").get(selected.style)) }
end

return M
