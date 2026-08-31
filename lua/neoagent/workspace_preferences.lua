local thinking = require("neoagent.thinking")
local util = require("neoagent.util")

local M = {}

local ui_positions = {
  auto = true,
  left = true,
  right = true,
  top = true,
  bottom = true,
  center = true,
}

local function is_object(value)
  return type(value) == "table"
    and (next(value) == nil or not util.is_list(value))
end

function M.scope(settings, defaults, name)
  assert(is_object(settings), "workspace settings must be an object")
  assert(is_object(defaults), "workspace preference defaults must be an object")
  assert(type(name) == "string" and name ~= "",
    "workspace preference name must be a non-empty string")

  local issues = {}
  for key in pairs(settings) do
    if key ~= "ui_position" and key ~= "agents" then
      issues[#issues + 1] = "unsupported workspace setting: "
        .. tostring(key)
    end
  end
  local accepted = { ui_position = settings.ui_position }
  local agents = settings.agents
  if agents ~= nil and not is_object(agents) then
    issues[#issues + 1] = "workspace agents must be an object"
    agents = nil
  end
  local scoped = agents and agents[name]
  if scoped ~= nil and not is_object(scoped) then
    issues[#issues + 1] = "workspace settings for " .. name
      .. " must be an object"
    scoped = nil
  end
  scoped = scoped or {}
  for key in pairs(scoped) do
    if key ~= "default_model" and key ~= "default_thinking_level" then
      issues[#issues + 1] = "unsupported workspace setting for "
        .. name .. ": " .. tostring(key)
    end
  end
  accepted.default_model = scoped.default_model
  accepted.default_thinking_level = scoped.default_thinking_level

  local merged = util.deep_merge(defaults, accepted)
  if merged.default_model ~= nil and (type(merged.default_model) ~= "table"
      or type(merged.default_model.provider) ~= "string"
      or type(merged.default_model.model) ~= "string") then
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
  return accepted, issues
end

function M.warning(issues, path)
  if #issues == 0 then return nil end
  return table.concat(issues, "; ")
    .. "; the file may be outdated, update or delete " .. path
end

function M.patch(name, patch)
  local result = {}
  if patch.ui_position ~= nil then result.ui_position = patch.ui_position end
  local scoped = {}
  if patch.default_model ~= nil then scoped.default_model = patch.default_model end
  if patch.default_thinking_level ~= nil then
    scoped.default_thinking_level = patch.default_thinking_level
  end
  if next(scoped) ~= nil then result.agents = { [name] = scoped } end
  return result
end

return M
