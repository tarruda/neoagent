local util = require("neoagent.util")

---@class Neoagent.SandboxCapabilities
---@field [string] boolean|string|number
---@field procfs? 'fresh'|'host'

---@class Neoagent.SandboxStatus
---@field ok boolean
---@field platform string
---@field stage? string
---@field message? string
---@field degraded? boolean
---@field degraded_reason? string
---@field capabilities? Neoagent.SandboxCapabilities

---@class Neoagent.SandboxFilesystemService: Neoagent.ToolFilesystem
---@field create_temp_directory fun(prefix?: string, directory?: string): string?, string?

---@class Neoagent.SandboxCheckServices<N = string|string[]>
---@field fs? Neoagent.SandboxFilesystemService
---@field nvim? N
---@field system? fun(argv: string[], opts: vim.SystemOpts, timeout: integer): vim.SystemCompleted?
---@field sandbox_exec? string
---@field probe_timeout_ms? integer
---@field capabilities? Neoagent.SandboxCapabilities

---@class Neoagent.SandboxServices<N = string|string[]>: Neoagent.SandboxCheckServices<N>
---@field process fun(argv: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult

---@class Neoagent.SandboxRequest: Neoagent.ProcessOptions
---@field argv? string[]
---@field profile Neoagent.SandboxProfile
---@field env? table<string, string>

---@class Neoagent.SandboxProcessRequest: Neoagent.SandboxRequest
---@field argv string[]

---@class Neoagent.SandboxFilesystemOperation
---@field operation 'read'|'write_all'|'mkdirp'|'atomic_replace'
---@field path string
---@field canonical_path? string
---@field data? string
---@field flags? string
---@field mode? integer
---@field policy? Neoagent.AtomicPolicy
---@field suffix? string
---@field timeout_ms? integer

---@class Neoagent.SandboxFilesystemRequest: Neoagent.SandboxFilesystemOperation
---@field profile Neoagent.SandboxProfile

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
  elseif os == "Windows" then
    return modules.windows or require("neoagent.sandbox.windows")
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
