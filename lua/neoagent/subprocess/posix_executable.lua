local validate = require("neoagent.subprocess.validate")
local M = {}

-- Prepare native execution attempts without consulting the ambient PATH or
-- resolving filesystem links. Linux libc and libuv's Darwin spawn lookup use
-- this NAME_MAX/PATH_MAX-bounded candidate construction. Drivers retain their
-- platform-specific execution and error arbitration.
---@param program string
---@param path? string
---@return string[]
function M.candidates(program, path)
  if program:find("/", 1, true) then
    return { program }
  end
  if path == nil then
    error(validate.error("pty_unavailable", "PTY lookup requires PATH or an explicit executable path"), 0)
  end
  local darwin = jit.os == "OSX"
  if #program > 255 then
    local code = darwin and 63 or 36 -- ENAMETOOLONG
    error(validate.error("process_start", "Process executable name failed (errno " .. code .. ")"), 0)
  end
  local limit = math.min(#path, darwin and 1023 or 4095) + 1
  local result = {}
  for _, directory in ipairs(vim.split(path, ":", { plain = true })) do
    if #directory < limit then
      result[#result + 1] = directory == "" and program or directory .. "/" .. program
    end
  end
  return result
end

return M
