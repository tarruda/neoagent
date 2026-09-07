local path_module = require("neoagent.sandbox.path")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.WindowsSandboxPolicy
---@field version 1
---@field write_roots string[]
---@field deny_read string[]
---@field deny_write string[]
---@field protected_create Neoagent.SandboxFilesystemEntry[]

---@param message string
---@return never
local function failure(message)
  error(util.error("sandbox_unavailable",
    "Windows sandbox cannot enforce this profile: " .. message), 0)
end

---@param values string[]
---@param paths Neoagent.SandboxPaths
---@return string[]
local function ordered(values, paths)
  table.sort(values, function(left, right)
    local left_depth, right_depth = paths.depth(left), paths.depth(right)
    if left_depth ~= right_depth then return left_depth < right_depth end
    return paths.key(left) < paths.key(right)
  end)
  return values
end

---@param entries Neoagent.SandboxFilesystemEntry[]
---@param entry Neoagent.SandboxFilesystemEntry
---@param paths Neoagent.SandboxPaths
---@return Neoagent.SandboxFilesystemEntry?
local function ancestor(entries, entry, paths)
  local selected
  local depth = -1
  for _, candidate in ipairs(entries) do
    if candidate ~= entry and paths.contains(candidate.path, entry.path) then
      local candidate_depth = paths.depth(candidate.path)
      if candidate_depth > depth then
        selected, depth = candidate, candidate_depth
      end
    end
  end
  return selected
end

---@param write_roots string[]
---@param path string
---@param paths Neoagent.SandboxPaths
---@return string?
local function writable_ancestor(write_roots, path, paths)
  for _, root in ipairs(write_roots) do
    if paths.contains(root, path) then return root end
  end
end

---@param profile Neoagent.SandboxProfile
---@param opts? {paths?: Neoagent.SandboxPaths}
---@return Neoagent.WindowsSandboxPolicy
function M.compile(profile, opts)
  opts = opts or {}
  local paths = opts.paths or path_module.windows()
  local entries = profile.filesystem.entries
  ---@type string[]
  local write_roots = {}

  for _, entry in ipairs(entries) do
    local parent = ancestor(entries, entry, paths)
    if parent and parent.access == "deny" and entry.access ~= "deny" then
      failure("cannot reopen " .. entry.access .. " access beneath deny path "
        .. parent.path)
    end
    if entry.access == "write" then
      if not parent or parent.access ~= "write" then
        write_roots[#write_roots + 1] = entry.path
      end
    end
  end

  local deny_read, deny_write = {}, {}
  local seen_read, seen_write = {}, {}
  ---@param target string[]
  ---@param seen table<string, boolean>
  ---@param path string
  local function add(target, seen, path)
    local key = paths.key(path)
    if not seen[key] then
      seen[key] = true
      target[#target + 1] = path
    end
  end

  ---@type Neoagent.SandboxFilesystemEntry[]
  local protected_create = {}
  for _, entry in ipairs(entries) do
    local write_root = writable_ancestor(write_roots, entry.path, paths)
    local needs_deny_read = entry.access == "deny"
    local needs_deny_write = entry.access == "deny"
      or entry.access == "read" and write_root ~= nil
    local exists = paths.stat(entry.path) ~= nil
    if not exists and needs_deny_write then
      if needs_deny_read and not write_root then
        failure("cannot protect missing deny path outside a writable root "
          .. entry.path)
      end
      local parent = paths.dirname(entry.path)
      local parent_stat = paths.stat(parent)
      if not parent_stat or parent_stat.type ~= "directory" then
        failure("missing protected path requires an existing parent "
          .. entry.path)
      end
    end
    if needs_deny_read then add(deny_read, seen_read, entry.path) end
    if needs_deny_write then add(deny_write, seen_write, entry.path) end
    if needs_deny_write and write_root then
      protected_create[#protected_create + 1] = {
        path = entry.path,
        access = entry.access,
      }
    end
  end

  return {
    version = 1,
    write_roots = ordered(write_roots, paths),
    deny_read = ordered(deny_read, paths),
    deny_write = ordered(deny_write, paths),
    protected_create = protected_create,
  }
end

return M
