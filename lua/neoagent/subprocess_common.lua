local scopes = require("neoagent.subprocess.scope")

local M = {}

---@async
---@param spec Neoagent.SubprocessSpec
---@param options Neoagent.SubprocessRunOptions
---@return Neoagent.SubprocessResult
function M.run(spec, options)
  return scopes.run(spec, options)
end

---@return Neoagent.SubprocessScope
function M.scope()
  return (scopes.new())
end

return M
