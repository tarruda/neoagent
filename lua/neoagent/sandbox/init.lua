local util = require("neoagent.util")

---@class Neoagent.SandboxInfo: Neoagent.SandboxAvailability
---@field enabled? boolean
---@field active? boolean

---@class Neoagent.SandboxInfoConfig
---@field sandbox? {enabled?: boolean}
---@field _sandbox_status? Neoagent.SandboxInfo

local M = {}

---@param agent unknown
---@return Neoagent.SandboxInfo
function M.info(agent)
  local configured = agent
  if type(agent) == "table" and type(agent.config) == "function" then
    local source = agent --[[@as {config: fun(self: table): Neoagent.SandboxInfoConfig}]]
    configured = source:config()
  end
  configured = type(configured) == "table" and configured or {}
  ---@cast configured Neoagent.SandboxInfoConfig
  local enabled = configured.sandbox and configured.sandbox.enabled == true or false
  local recorded = util.copy(configured._sandbox_status or {})
  recorded.enabled = enabled
  if not enabled then
    recorded.active = false
  end
  return recorded
end

---@param status? Neoagent.SandboxInfo
---@return string
function M.format_info(status)
  status = status or {}
  local lines = {
    "Neoagent sandbox",
    "enabled: " .. (status.enabled and "yes" or "no"),
    "active: " .. (status.active and "yes" or "no"),
  }
  if status.platform then
    lines[#lines + 1] = "platform: " .. tostring(status.platform)
  end
  if status.enabled and status.active then
    lines[#lines + 1] = "isolation: " .. (status.degraded and "degraded" or "full")
    if status.degraded_reason then
      lines[#lines + 1] = "reason: " .. tostring(status.degraded_reason)
    end
    local capabilities = status.capabilities or {}
    local names = vim.tbl_keys(capabilities)
    table.sort(names)
    for _, name in ipairs(names) do
      local value = capabilities[name]
      if type(value) == "boolean" then
        value = value and "yes" or "no"
      end
      lines[#lines + 1] = "capability." .. name .. ": " .. tostring(value)
    end
  elseif status.enabled then
    if status.stage then
      lines[#lines + 1] = "stage: " .. tostring(status.stage)
    end
    if status.message then
      lines[#lines + 1] = "reason: " .. tostring(status.message)
    end
  end
  return table.concat(lines, "\n")
end

return M
