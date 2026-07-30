local util = require("neoagent.util")

local M = {}

local function unsupported(os)
  return {
    ok = false,
    platform = tostring(os),
    stage = "platform",
    message = "unsupported platform " .. tostring(os),
  }
end

function M.select(os, modules)
  os = os or jit.os
  modules = modules or {}
  if os == "Linux" then
    return modules.linux or require("neoagent.sandbox.linux")
  elseif os == "OSX" then
    return modules.macos or require("neoagent.sandbox.macos")
  end
  return nil, unsupported(os)
end

function M.status_error(status)
  status = status or unsupported(jit.os)
  local message = status.message or "sandbox requirements are unavailable"
  if status.stage then message = status.stage .. ": " .. message end
  return util.error("sandbox_unavailable", message)
end

return M
