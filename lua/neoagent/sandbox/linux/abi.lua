local M = {}

---@class Neoagent.LinuxSandboxAbi
---@field audit_arch integer
---@field pivot_root integer
---@field mount_setattr integer
---@field close_range integer
---@field capset integer

---@type table<string, Neoagent.LinuxSandboxAbi>
local values = {
  x64 = {
    audit_arch = 0xC000003E,
    pivot_root = 155,
    mount_setattr = 442,
    close_range = 436,
    capset = 126,
  },
  arm64 = {
    audit_arch = 0xC00000B7,
    pivot_root = 41,
    mount_setattr = 442,
    close_range = 436,
    capset = 91,
  },
}

---@param arch? string
---@return Neoagent.LinuxSandboxAbi?
function M.current(arch)
  return values[arch or jit.arch]
end

---@param arch? string
---@return boolean
function M.supported(arch)
  return values[arch or jit.arch] ~= nil
end

return M
