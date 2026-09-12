local util = require("neoagent.util")
local path_module = require("neoagent.sandbox.path")

local M = {}

---@alias Neoagent.PathResolver {resolve: (fun(self: Neoagent.PathResolver, path: string): string)}
---@alias Neoagent.SandboxPathContext {context?: Neoagent.PathResolver|{workspace?: Neoagent.PathResolver}}

---@type table<Neoagent.SandboxAccess, integer>
local rank = { deny = 0, read = 1, write = 2 }
---@type table<Neoagent.SandboxAccess, integer>
local tie = { deny = 3, write = 2, read = 1 }

---@param profile Neoagent.SandboxProfile
---@param path string
---@param paths Neoagent.SandboxPaths
---@return Neoagent.SandboxAccess
local function access_for(profile, path, paths)
  ---@type Neoagent.SandboxAccess
  local selected = profile.filesystem.default
  local specificity = -1
  for _, entry in ipairs(profile.filesystem.entries) do
    if paths.contains(entry.path, path) then
      local depth = paths.depth(entry.path)
      if depth > specificity or depth == specificity and tie[entry.access] > tie[selected] then
        selected = entry.access
        specificity = depth
      end
    end
  end
  return selected
end

---@param ctx? Neoagent.SandboxPathContext
---@return Neoagent.PathResolver?
local function workspace(ctx)
  local context = ctx and ctx.context
  local value = context and rawget(context, "workspace") or context
  if type(value) == "table" and type(value.resolve) == "function" then
    ---@cast value Neoagent.PathResolver
    return value
  end
end

---@param ctx Neoagent.SandboxPathContext?
---@param path string
---@param paths? Neoagent.SandboxPaths
---@return string lexical
---@return string canonical
function M.resolve_path(ctx, path, paths)
  paths = paths or path_module.posix
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
    error(util.error("sandbox", "Sandbox path must be a non-empty string without NUL bytes"), 0)
  end
  local lexical
  if paths.is_absolute(path) then
    lexical = paths.normalize(path)
  else
    local active = workspace(ctx)
    if not active then
      error(util.error("sandbox", "Relative sandbox paths require ctx.context.workspace"), 0)
    end
    lexical = paths.normalize(active:resolve(path))
  end
  return lexical, paths.canonical_candidate(lexical)
end

---@param profile Neoagent.SandboxProfile
---@param lexical string
---@param canonical string
---@param paths? Neoagent.SandboxPaths
---@return Neoagent.SandboxAccess granted
---@return Neoagent.SandboxAccess lexical_access
---@return Neoagent.SandboxAccess canonical_access
function M.access(profile, lexical, canonical, paths)
  paths = paths or path_module.posix
  local first = access_for(profile, lexical, paths)
  local second = access_for(profile, canonical, paths)
  return rank[first] <= rank[second] and first or second, first, second
end

---@param profile Neoagent.SandboxProfile
---@param lexical string
---@param canonical string
---@param required Neoagent.SandboxAccess
---@param paths? Neoagent.SandboxPaths
---@return boolean allowed
---@return Neoagent.SandboxAccess granted
---@return Neoagent.SandboxAccess lexical_access
---@return Neoagent.SandboxAccess canonical_access
function M.allows(profile, lexical, canonical, required, paths)
  local granted, lexical_access, canonical_access = M.access(profile, lexical, canonical, paths)
  return rank[granted] >= rank[required], granted, lexical_access, canonical_access
end

return M
