local assert = require("luassert")
local async = require("neoagent.async")
local M = {}

---@generic T
---@param run Neoagent.Run<T, unknown>
---@param timeout? integer
---@return Neoagent.RunResult<T>
function M.wait(run, timeout)
  assert(
    vim.wait(timeout or 5000, function()
      return run:is_done()
    end, 5),
    "process operation did not settle"
  )
  return (assert(run:result()))
end

---@generic T
---@param fn async fun(): T
---@param timeout? integer
---@return Neoagent.RunResult<T>
function M.complete(fn, timeout)
  return M.wait(async.run(fn), timeout)
end

---@param command string
---@param options? {argv?: string[], cwd?: string, stdio?: Neoagent.SubprocessStdio, environment?: Neoagent.SubprocessEnvironment, timeout_ms?: integer, kill_grace_ms?: integer}
---@return Neoagent.SubprocessSpec
function M.spec(command, options)
  options = options or {}
  return {
    argv = options.argv or { "sh", "-c", command },
    cwd = options.cwd or assert(vim.uv.cwd()),
    stdio = options.stdio or { kind = "pipes" },
    environment = options.environment,
    timeout_ms = options.timeout_ms,
    kill_grace_ms = options.kill_grace_ms,
  }
end

---@param fn fun()
---@return Neoagent.Error
function M.failure(fn)
  local ok, err = pcall(fn)
  assert.is_false(ok)
  assert(type(err) == "table")
  return require("neoagent.util").normalize_error(err)
end

return M
