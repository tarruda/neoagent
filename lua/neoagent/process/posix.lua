local M = {}
local Tree = {}
Tree.__index = Tree

function Tree:attach(pid)
  if type(pid) == "number" and pid > 0 then self.pid = pid end
  return true
end

function Tree:terminate(signal)
  if not self.pid or self.closed then return false end
  local ok = self.kill(-self.pid, signal)
  return ok ~= nil and ok ~= false
end

function Tree:close(terminate)
  if self.closed then return end
  if terminate then self:terminate(9) end
  self.closed = true
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({ kill = opts.kill or vim.uv.kill }, Tree)
end

M.detach = true

return M
