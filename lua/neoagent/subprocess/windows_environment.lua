local ffi = require("ffi")
local validate = require("neoagent.subprocess.validate")
local strings = require("neoagent.subprocess.windows_text")
local M = {}

ffi.cdef([[
int __stdcall LCMapStringW(unsigned long, unsigned long, const unsigned short *, int, unsigned short *, int);
]])

---@class Neoagent.WindowsEnvironmentKernel
---@field LCMapStringW fun(locale: integer, flags: integer, text: ffi.cdata*, length: integer, output: ffi.cdata*, capacity: integer): integer
local kernel = ffi.load("kernel32") --[[@as Neoagent.WindowsEnvironmentKernel]]

---@param ok boolean
local function check(ok)
  if not ok then
    error(validate.error("process_validation", "Could not normalize Windows environment name"), 0)
  end
end

-- Match libuv's environment-name comparison with the Windows invariant
-- uppercase map. Lua byte case conversion does not cover Unicode names.
---@param name string
---@return string
function M.key(name)
  local wide, length = strings.wide(name)
  if not wide or not length or length == 0 then
    error(validate.error("process_validation", "Could not normalize Windows environment name"), 0)
  end
  ---@type Neoagent.WindowsWideString
  local upper = ffi.new("unsigned short[?]", length)
  check(kernel.LCMapStringW(0x7f, 0x200, wide, length, upper, length) == length)
  return strings.narrow(upper, length)
end

return M
