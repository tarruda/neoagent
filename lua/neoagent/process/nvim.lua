local util = require("neoagent.util")

local M = {}

---@param command string[]
---@return string[]
local function resolve(command)
  local program = command[1]
  if type(program) == "string" and program ~= "" then
    local found = vim.fn.exepath(program)
    if found ~= "" then
      program = found
    end
    command[1] = vim.uv.fs_realpath(program) or program
  end
  return command
end

---@param configured? string|string[]
---@return string[]
function M.command(configured)
  if type(configured) == "string" and configured ~= "" then
    return resolve({ configured })
  elseif type(configured) == "table" and util.is_list(configured) and #configured > 0 then
    return resolve(util.copy(configured))
  end
  -- Packaged launchers can expose the ELF loader as v:progpath. Preserve
  -- its arguments through the Neovim executable, resolving the launcher
  -- before a worker's cwd or restricted PATH changes executable discovery.
  local fd = vim.uv.fs_open("/proc/self/cmdline", "r", 0)
  if fd then
    local data = vim.uv.fs_read(fd, 64 * 1024, 0)
    vim.uv.fs_close(fd)
    if data and type(vim.v.argv[1]) == "string" then
      local commandline = {}
      for value in data:gmatch("([^%z]+)") do
        commandline[#commandline + 1] = value
      end
      for index, value in ipairs(commandline) do
        if value == vim.v.argv[1] then
          return resolve(vim.list_slice(commandline, 1, index))
        end
      end
    end
  end
  return resolve({ vim.v.progpath })
end

return M
