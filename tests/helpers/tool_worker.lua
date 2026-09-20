local M = {}

---@class Neoagent.TestToolWorkerOptions
---@field cwd string
---@field on_stdout fun(data: string)
---@field on_stderr? fun(data: string)
---@field on_exit? fun(result: Neoagent.WorkerResult)
---@field nvim? string|string[]
---@field env? table<string, string>

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

---@param opts Neoagent.TestToolWorkerOptions
---@return Neoagent.WorkerLease
function M.start_worker(opts)
  assert(type(opts) == "table", "host Tool worker options are required")
  local bootstrap = require("neoagent.rpc.worker")
  local worker = bootstrap.worker_file()
  local environment = vim.deepcopy(opts.env or M.environment())
  environment.NEOAGENT_WORKER_FILE = worker
  return require("neoagent.rpc.worker_lease").start({
    argv = bootstrap.argv(bootstrap.nvim_command(opts.nvim), worker),
    cwd = opts.cwd,
    env = environment,
    clear_env = true,
    on_stdout = opts.on_stdout,
    on_stderr = opts.on_stderr,
    on_exit = opts.on_exit,
  })
end

return M
