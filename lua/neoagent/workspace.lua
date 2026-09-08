local fs = require("neoagent.fs")

local M = {}
---@class Neoagent.WorkspaceOptions
---@field root string
---@field cwd? string

---@class Neoagent.Workspace
---@field root string
---@field cwd string
local Workspace = {}
Workspace.__index = Workspace

---@param path string
---@return string
function Workspace:resolve(path)
  assert(type(path) == "string" and path ~= "", "path must be a non-empty string")
  if fs.is_absolute(path) then
    return fs.normalize(path)
  end
  return fs.normalize(fs.join(self.cwd, path))
end

---@param path string
---@return string
function Workspace:canonical(path)
  return fs.canonical(self:resolve(path))
end

---@param opts Neoagent.WorkspaceOptions
---@return Neoagent.Workspace
function M.new(opts)
  opts = opts or {}
  assert(type(opts.root) == "string" and opts.root ~= "", "root is required")
  local root = fs.canonical(opts.root)
  local cwd = fs.canonical(opts.cwd or root)
  return setmetatable({ root = root, cwd = cwd }, Workspace)
end

return M
