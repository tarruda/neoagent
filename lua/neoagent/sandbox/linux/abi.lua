local M = {}

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

function M.current(arch)
  return values[arch or jit.arch]
end

function M.supported(arch)
  return values[arch or jit.arch] ~= nil
end

return M
