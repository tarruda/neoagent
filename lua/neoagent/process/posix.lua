local M = {}
---@alias Neoagent.ProcessSignal fun(pid: integer, signal: integer): (0|true|false|nil), string?, string?

---@class Neoagent.PosixProcessTree
---@field pid? integer
---@field closed? boolean
---@field kill Neoagent.ProcessSignal
local Tree = {}
Tree.__index = Tree

---@param pid integer
---@return true
function Tree:attach(pid)
  if type(pid) == "number" and pid > 0 then self.pid = pid end
  return true
end

---@param signal integer
---@return boolean
function Tree:terminate(signal)
  if not self.pid or self.closed then return false end
  local ok = self.kill(-self.pid, signal)
  return ok ~= nil and ok ~= false
end

---@param terminate? boolean
function Tree:close(terminate)
  if self.closed then return end
  if terminate then self:terminate(9) end
  self.closed = true
end

---@param opts? {kill?: Neoagent.ProcessSignal}
---@return Neoagent.PosixProcessTree
function M.new(opts)
  opts = opts or {}
  return setmetatable({ kill = opts.kill or vim.uv.kill }, Tree)
end

M.detach = true

return M
