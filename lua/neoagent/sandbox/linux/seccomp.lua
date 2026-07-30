local M = {}

local syscalls = {
  x64 = {
    socket = 41,
    socketpair = 53,
    clone = 56,
    clone3 = 435,
    network_deny = {
      42, 43, 44, 48, 49, 50, 51, 52, 54, 55, 288, 299, 307,
    },
    deny = {
      101, 165, 166, 169, 175, 176, 246, 248, 249, 250, 272, 275,
      278, 298, 304, 308, 310, 311, 313, 321, 323, 425, 426, 427,
      428, 429, 430, 431, 432, 433, 438, 440, 442,
    },
  },
  arm64 = {
    socket = 198,
    socketpair = 199,
    clone = 220,
    clone3 = 435,
    network_deny = {
      200, 201, 202, 203, 204, 205, 206, 208, 209, 210, 242, 243,
      269,
    },
    deny = {
      39, 40, 97, 104, 105, 106, 117, 142, 217, 218, 219, 241,
      265, 268, 270, 271, 273, 280, 282, 425, 426, 427, 428, 429,
      430, 431, 432, 433, 438, 440, 442,
    },
  },
}

function M.rules(arch, network)
  local source = syscalls[arch or jit.arch]
  if not source then return nil end
  local result = {}
  for _, number in ipairs(source.deny) do result[#result + 1] = number end
  table.sort(result)
  local network_deny
  if network == "restricted" then
    network_deny = {}
    for _, number in ipairs(source.network_deny) do
      network_deny[#network_deny + 1] = number
    end
    table.sort(network_deny)
  end
  return {
    deny = result,
    socket = network == "restricted" and source.socket or nil,
    socketpair = network == "restricted" and source.socketpair or nil,
    network_deny = network_deny,
    clone = source.clone,
    clone3 = source.clone3,
    namespace_flags = 0x7e020080,
  }
end

return M
