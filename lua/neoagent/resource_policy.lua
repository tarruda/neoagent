local fs = require("neoagent.fs")
local paths = require("neoagent.sandbox.path").for_os(jit.os)

local M = {}

---@param root string
---@param path string
---@return boolean
local function contains(root, path)
  return paths.contains(root, path)
end

---@param path string
---@param root string
---@return uv.fs_stat.result? stat
---@return string? root_or_error
local function inspect(path, root)
  root = fs.canonical(root)
  path = paths.normalize(path)
  if not contains(root, path) then
    return nil, "project resource path is outside the trusted root"
  end
  local current = path
  local selected
  while true do
    local stat, stat_err = vim.uv.fs_lstat(current)
    if not stat then
      return nil, stat_err
    end
    if stat.type == "link" then
      return nil, "project resource path contains a symbolic link"
    end
    selected = selected or stat
    if paths.key(current) == paths.key(root) then
      break
    end
    current = paths.dirname(current)
  end
  return selected, root
end

---@param left uv.fs_stat.result
---@param right uv.fs_stat.result
---@return boolean
local function same_directory(left, right)
  return left.type == "directory"
    and right.type == "directory"
    and left.dev == right.dev
    and left.ino == right.ino
end

---@param path string
---@param root string
---@return string? canonical
---@return string? error
function M.directory(path, root)
  local before, trusted_root = inspect(path, root)
  if not before then
    return nil, trusted_root
  end
  if before.type ~= "directory" then
    return nil, "project skill path is not a regular directory"
  end
  local canonical = fs.canonical(path)
  if not contains(assert(trusted_root), canonical) then
    return nil, "project skill path resolves outside the trusted root"
  end
  local current, current_err = vim.uv.fs_lstat(path)
  if not current or not same_directory(before, current) or paths.key(canonical) ~= paths.key(fs.canonical(path)) then
    return nil, current_err or "project skill path changed during inspection"
  end
  return canonical
end

---@param path string
---@param root string
---@return string? content
---@return string? canonical_or_error
function M.read(path, root)
  local stat, trusted_root = inspect(path, root)
  if not stat then
    return nil, trusted_root
  end
  local trusted = assert(trusted_root)
  local canonical = fs.canonical(path)
  if not contains(trusted, canonical) then
    return nil, "project resource resolves outside the trusted root"
  end
  local file, open_err = fs.open_regular(path, { read_only = true })
  if not file then
    return nil, open_err
  end
  local failure
  local confirmed = fs.canonical(path)
  if not contains(trusted, confirmed) or paths.key(canonical) ~= paths.key(confirmed) then
    failure = "project resource changed its resolved path during open"
  end
  if not failure then
    local verified, verify_err = file:verify_path()
    if not verified then
      failure = verify_err
    end
  end
  local content
  if not failure then
    content, failure = file:read_all()
  end
  if not failure then
    local verified, verify_err = file:verify_path()
    if not verified then
      content, failure = nil, verify_err
    end
  end
  local closed, close_err = file:close()
  if failure then
    return nil, failure
  end
  if not closed then
    return nil, close_err
  end
  return content, canonical
end

return M
