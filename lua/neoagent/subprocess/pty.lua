local validate = require("neoagent.subprocess.validate")
local M = {}

---@param spec Neoagent.SubprocessSpec
---@param env table<string, string>
---@param callbacks Neoagent.SubprocessCallbacks
---@return Neoagent.SubprocessDriver
function M.new(spec, env, callbacks)
  local name = ({ Linux = "linux", OSX = "darwin" })[jit.os]
  if not name then
    error(validate.error("pty_unavailable", "Unsupported native PTY platform: " .. jit.os), 0)
  end
  return require("neoagent.subprocess." .. name .. "_pty").new(spec, env, callbacks)
end

return M
