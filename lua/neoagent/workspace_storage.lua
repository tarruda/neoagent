local fs = require("neoagent.fs")
local file_lock = require("neoagent.file_lock")
local files = require("neoagent.files")
local blob_store = require("neoagent.files.blob_store")
local util = require("neoagent.util")
local M = {}

---@class Neoagent.WorkspaceStorage
---@field directory string
---@field sessions_directory string
---@field files Neoagent.Files
---@field file_cache Neoagent.FileCache
---@field prepare fun(): true?, Neoagent.Error?
---@field validate fun(): true?, Neoagent.Error?

---@param directory string
---@return Neoagent.WorkspaceStorage
function M.new(directory)
  assert(type(directory) == "string" and directory ~= "", "workspace storage directory is required")
  directory = fs.normalize(directory)
  local marker = fs.join(directory, "workspace.json")
  ---@type Neoagent.Error?
  local blocked
  local function validate()
    if blocked then
      return nil, blocked
    end
    local stat, stat_err, code = vim.uv.fs_lstat(directory)
    if not stat then
      if code == "ENOENT" then
        return true
      end
      return nil, files.error("Could not inspect workspace storage", stat_err)
    end
    if stat.type ~= "directory" then
      return nil, files.error("Workspace storage is not a directory")
    end
    local marked = vim.uv.fs_lstat(marker)
    if marked then
      local handle, open_err = fs.open_regular(marker)
      if not handle then
        return nil, files.error("Could not open workspace marker", open_err)
      end
      local size = handle:stat()
      local data = size and size.size <= 256 and handle:read_all() or nil
      local closed, close_err = handle:close()
      if not closed then
        return nil, files.error("Could not close workspace marker", close_err)
      end
      local ok, value = pcall(vim.json.decode, data or "")
      if ok and type(value) == "table" and value.format == "neoagent-workspace" and vim.tbl_count(value) == 1 then
        return true
      end
      return nil, files.error("Unsupported workspace storage format")
    end
    local scan, scan_err = vim.uv.fs_scandir(directory)
    if not scan then
      return nil, files.error("Could not inspect workspace storage", scan_err)
    end
    while true do
      local name = vim.uv.fs_scandir_next(scan)
      if not name then
        return true
      end
      if name ~= "workspace.json.lock" then
        return nil, files.error("Unsupported workspace storage: nonempty directory has no Neoagent marker")
      end
    end
  end
  local function prepare()
    local valid, validate_err = validate()
    if not valid then
      return nil, validate_err
    end
    if vim.uv.fs_lstat(marker) then
      return true
    end
    local created, create_err = fs.ensure_private_directory(directory, 448)
    if not created then
      return nil, files.error("Could not create workspace storage", create_err)
    end
    local saved, save_err = file_lock.new({ path = marker .. ".lock" }):with(function()
      local current, err = validate()
      if not current then
        return nil, err
      end
      if vim.uv.fs_lstat(marker) then
        return true
      end
      local written, write_err = fs.atomic_replace(
        marker,
        util.json_encode({ format = "neoagent-workspace" }) .. "\n",
        { mode = 384, durable = true }
      )
      if not written then
        return nil, files.error("Could not publish workspace marker", write_err)
      end
      local synced, sync_err = fs.sync_directory(assert(vim.fs.dirname(directory)))
      if not synced then
        return nil, files.error("Could not publish workspace directory", sync_err)
      end
      return true
    end)
    if not saved then
      blocked = files.error("Workspace publication failed; further writes are blocked", save_err)
      return nil, blocked
    end
    return true
  end
  local attachments = blob_store.new({ directory = fs.join(directory, "files"), prepare = prepare })
  return {
    directory = directory,
    sessions_directory = fs.join(directory, "sessions"),
    files = attachments,
    file_cache = require("neoagent.files.provider_cache").new({
      directory = fs.join(directory, "provider-cache"),
      scope = attachments.identity,
    }),
    prepare = prepare,
    validate = validate,
  }
end

---@param directory string
---@param root string
---@return Neoagent.WorkspaceStorage
function M.resolve(directory, root)
  assert(type(directory) == "string" and directory ~= "", "directory is required")
  assert(type(root) == "string" and root ~= "", "root is required")
  root = fs.canonical(root)
  local basename = assert(vim.fs.basename(root)):gsub('[%c<>:"/\\|?*]', "-")
  if basename == "" or basename == "." or basename == ".." then
    basename = "root"
  end
  return M.new(fs.join(fs.normalize(directory), basename .. "-" .. vim.fn.sha256(root)))
end

return M
