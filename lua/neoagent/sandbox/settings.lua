local util = require("neoagent.util")

local M = {}

---@alias Neoagent.SandboxProfileSetting<C> Neoagent.SandboxProfileOverrides|(fun(default: Neoagent.SandboxProfile, ctx: C): Neoagent.SandboxProfile)

---@class Neoagent.SandboxSettings<C = unknown>
---@field enabled boolean
---@field profile? Neoagent.SandboxProfileSetting<Neoagent.ToolContext<C>>
---@field parent_tools? Neoagent.Tool<C>[]

---@generic C
---@param settings Neoagent.SandboxSettings<C>
function M.validate(settings)
  assert(type(settings) == "table" and not util.is_list(settings), "sandbox must be a table")
  for key in pairs(settings) do
    assert(
      key == "enabled" or key == "profile" or key == "parent_tools",
      "unsupported sandbox setting: " .. tostring(key)
    )
  end
  assert(type(settings.enabled) == "boolean", "sandbox.enabled must be boolean")
  if settings.profile ~= nil then
    assert(
      type(settings.profile) == "table" or type(settings.profile) == "function",
      "sandbox.profile must be a table or function"
    )
  end
  assert(
    settings.parent_tools == nil or type(settings.parent_tools) == "table" and util.is_list(settings.parent_tools),
    "sandbox.parent_tools must be a list"
  )
end

return M
