local util = require("neoagent.util")

local M = {}

---@class Neoagent.RpcWorkerOptions
---@field cwd string
---@field on_stdout fun(data: string)
---@field on_stderr? fun(data: string)
---@field on_exit? fun(result: Neoagent.WorkerResult)
---@field nvim? string|string[]
---@field env? table<string, string>

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

---@param configured? string|string[]
---@return string[]
local function nvim_command(configured)
  if type(configured) == "string" and configured ~= "" then
    return { configured }
  elseif type(configured) == "table" and util.is_list(configured) and #configured > 0 then
    return util.copy(configured)
  end
  -- Packaged Neovim launchers can make v:progpath point at the ELF loader
  -- while v:argv points at the executable later in the real command line.
  -- Preserve that prefix so a worker starts through the same usable launcher.
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
          local command = {}
          for part = 1, index do
            command[part] = commandline[part]
          end
          return command
        end
      end
    end
  end
  return { vim.v.progpath }
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

---@return table<string, string>
function M.environment()
  local source = vim.fn.environ()
  local result = {}
  for _, name in ipairs({
    "PATH",
    "HOME",
    "LANG",
    "LC_ALL",
    "TERM",
    "TMPDIR",
    "TMP",
    "TEMP",
    "SystemRoot",
    "WINDIR",
    "COMSPEC",
    "PATHEXT",
    "VIMRUNTIME",
  }) do
    if type(source[name]) == "string" and source[name] ~= "" then
      result[name] = source[name]
    end
  end
  return result
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

---@param opts Neoagent.RpcWorkerOptions
---@return Neoagent.WorkerLease
function M.start(opts)
  assert(type(opts) == "table", "host Tool worker options are required")
  local worker = worker_file()
  local environment = util.copy(opts.env or M.environment())
  environment.NEOAGENT_WORKER_FILE = worker
  return require("neoagent.rpc.worker_lease").start({
    argv = M.argv(nvim_command(opts.nvim), worker),
    cwd = opts.cwd,
    env = environment,
    clear_env = true,
    on_stdout = opts.on_stdout,
    on_stderr = opts.on_stderr,
    on_exit = opts.on_exit,
  })
end

M.worker_file = worker_file
M.nvim_command = nvim_command
return M
