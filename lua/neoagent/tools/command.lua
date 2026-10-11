local M = {}

---@param command string
---@return string[]
function M.argv(command)
  local argv = vim.fn.split(vim.o.shell)
  vim.list_extend(argv, vim.fn.split(vim.o.shellcmdflag))
  argv[#argv + 1] = command
  return argv
end

return M
