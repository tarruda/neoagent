local M = {}

---@class Neoagent.ProcessChild
---@field pid integer
---@field kill fun(self: Neoagent.ProcessChild, signal: integer)
---@field write fun(self: Neoagent.ProcessChild, data?: string|string[])

---@class Neoagent.ProcessSpawnOptions: vim.SystemOpts
---@field stdout fun(err?: string, data?: string)
---@field stderr fun(err?: string, data?: string)

---@param env? table<string, string|number>|string[]
---@param clear? boolean
---@return table<string, string|number>|string[]|nil
local function environment(env, clear)
  if clear and env ~= nil and vim.fn.has("nvim-0.12") == 0 and not vim.islist(env) then
    ---@cast env table<string, string|number>
    local names = vim.tbl_keys(env)
    table.sort(names)
    return vim.tbl_map(function(name)
      return name .. "=" .. tostring(env[name])
    end, names)
  end
  return env
end

-- Commands and retained workers share native quoting, binary streams, and
-- environment compatibility. Their callers own supervision and lifetime.
---@param command string[]
---@param opts Neoagent.ProcessSpawnOptions
---@param on_exit fun(result: vim.SystemCompleted)
---@return Neoagent.ProcessChild|vim.SystemObj
function M.start(command, opts, on_exit)
  local platform = require(jit.os == "Windows" and "neoagent.process.windows" or "neoagent.process.posix")
  local selected = vim.tbl_extend("force", {}, opts, {
    env = environment(opts.env, opts.clear_env),
    text = false,
    detach = platform.detach,
  })
  return (platform.spawn or vim.system)(command, selected, on_exit)
end

return M
