local util = require("neoagent.util")
local path_module = require("neoagent.sandbox.path")

local M = {}

local rank = { deny = 0, read = 1, write = 2 }
local tie = { deny = 3, write = 2, read = 1 }

local function access_for(profile, path, paths)
  local selected = profile.filesystem.default
  local specificity = -1
  for _, entry in ipairs(profile.filesystem.entries) do
    if paths.contains(entry.path, path) then
      local depth = paths.depth(entry.path)
      if depth > specificity
          or depth == specificity and tie[entry.access] > tie[selected] then
        selected = entry.access
        specificity = depth
      end
    end
  end
  return selected
end

local function workspace(ctx)
  local context = ctx and ctx.context
  local value = context and context.workspace or context
  if type(value) == "table" and type(value.resolve) == "function" then
    return value
  end
end

function M.resolve_path(ctx, path, paths)
  paths = paths or path_module.posix
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
    error(util.error("sandbox",
      "Sandbox path must be a non-empty string without NUL bytes"), 0)
  end
  local lexical
  if paths.is_absolute(path) then
    lexical = paths.normalize(path)
  else
    local active = workspace(ctx)
    if not active then
      error(util.error("sandbox",
        "Relative sandbox paths require ctx.context.workspace"), 0)
    end
    lexical = paths.normalize(active:resolve(path))
  end
  return lexical, paths.canonical_candidate(lexical)
end

function M.access(profile, lexical, canonical, paths)
  paths = paths or path_module.posix
  local first = access_for(profile, lexical, paths)
  local second = access_for(profile, canonical, paths)
  return rank[first] <= rank[second] and first or second, first, second
end

function M.allows(profile, lexical, canonical, required, paths)
  local granted, lexical_access, canonical_access =
    M.access(profile, lexical, canonical, paths)
  return rank[granted] >= rank[required],
    granted, lexical_access, canonical_access
end

return M
