local M = {}

-- libuv reuses independent Lua states in its worker pool. Instrument the
-- original dumped function there, preserving its source and line information.
---@param bytecode string
---@param config LuaCov.Configuration
---@param ... unknown
---@return unknown ...
function M.run(bytecode, config, ...)
  local runner = require("luacov.runner")
  if not runner.initialized then
    local identity = tostring(vim.uv.thread_self()):gsub("%W", "_")
    config.statsfile = assert(config.statsfile):gsub("%.out$", "-" .. identity .. ".out")
    runner.init(config)
  else
    runner.resume()
    debug.sethook(runner.debug_hook, "l")
  end
  local function finish(ok, ...)
    debug.sethook()
    runner.save_stats()
    runner.pause()
    if not ok then
      error((...), 0)
    end
    return ...
  end
  return finish(pcall(assert(loadstring(bytecode)), ...))
end

---@param config LuaCov.Configuration
function M.install(config)
  local new_work = vim.uv.new_work
  local bootstrap = ("package.path = %q\npackage.cpath = %q\n"):format(package.path, package.cpath)
  local configuration = vim.inspect(config)
  vim.uv.new_work = function(work, completed)
    local source = bootstrap
      .. ("return require('tests.helpers.work_coverage').run(%q, %s, ...)"):format(string.dump(work), configuration)
    return new_work(assert(loadstring(source, "=instrumented work")), completed)
  end
end

return M
