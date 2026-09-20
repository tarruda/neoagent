local util = require("neoagent.util")
local nvim_command = require("neoagent.process.nvim").command

local M = {}

---@return string
local function worker_file()
  local matches = vim.api.nvim_get_runtime_file("scripts/tool_worker.lua", false)
  local path = matches[1]
  path = path and (vim.uv.fs_realpath(path) or vim.fs.normalize(path)) or nil
  local stat = path and vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    error(util.error("worker_start", "Tool worker source was not found"), 0)
  end
  return assert(path)
end

---@param nvim string[]
---@param worker string
---@return string[]
function M.argv(nvim, worker)
  local argv = util.copy(nvim)
  local version = (vim.version --[[@as fun(): vim.Version]])()
  if version.major == 0 and version.minor < 13 then
    vim.list_extend(argv, {
      "--headless",
      "--noplugin",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-n",
      "-c",
      "lua dofile(assert(vim.env.NEOAGENT_WORKER_FILE))",
    })
  else
    vim.list_extend(argv, {
      "--headless",
      "--noplugin",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-n",
      "-l",
      worker,
    })
  end
  return argv
end

---@param worker string
---@param nvim string[]
---@return string[]
function M.bootstrap_paths(worker, nvim)
  local root = assert(vim.fs.dirname(assert(vim.fs.dirname(worker))))
  local modules = vim.fs.joinpath(root, "lua", "neoagent")
  local stat = vim.uv.fs_stat(modules)
  if not stat or stat.type ~= "directory" then
    error(util.error("worker_start", "Tool worker modules were not found"), 0)
  end
  local values = { worker, modules }
  for _, item in ipairs(nvim) do
    local item_stat = item:find("[/\\]") and vim.uv.fs_stat(item) or nil
    if item_stat and (item_stat.type == "file" or item_stat.type == "directory") then
      values[#values + 1] = vim.uv.fs_realpath(item) or vim.fs.normalize(item)
    end
  end
  if type(vim.env.VIMRUNTIME) == "string" and vim.env.VIMRUNTIME ~= "" then
    values[#values + 1] = vim.uv.fs_realpath(vim.env.VIMRUNTIME) or vim.fs.normalize(vim.env.VIMRUNTIME)
  end
  return values
end

M.worker_file = worker_file
M.nvim_command = nvim_command
return M
