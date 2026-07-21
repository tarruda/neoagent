local fs = require("neoagent.fs")

local M = {}
local Workspace = {}
Workspace.__index = Workspace

function Workspace:resolve(path)
  assert(type(path) == "string" and path ~= "", "path must be a non-empty string")
  if path:sub(1, 1) == "/" then
    return fs.normalize(path)
  end
  return fs.normalize(fs.join(self.cwd, path))
end

function Workspace:canonical(path)
  return fs.canonical(self:resolve(path))
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.root) == "string" and opts.root ~= "", "root is required")
  local root = fs.canonical(opts.root)
  local cwd = fs.canonical(opts.cwd or root)
  return setmetatable({ root = root, cwd = cwd }, Workspace)
end

return M
