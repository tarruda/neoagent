local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local Settings = {}
Settings.__index = Settings

local function settings_error(message, detail)
  return util.error("settings", message, detail)
end

function Settings:metadata()
  return {
    root = self.root,
    directory = self.directory,
    settings_path = self.settings_path,
    sessions_directory = self.sessions_directory,
  }
end

function Settings:load()
  if not vim.uv.fs_stat(self.settings_path) then return {} end
  local content, read_err = fs.read(self.settings_path)
  if not content then return nil, settings_error("Failed to read workspace settings", read_err) end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" or util.is_list(decoded) then
    return nil, settings_error("Invalid workspace settings", ok and "expected an object" or decoded)
  end
  return util.copy(decoded)
end

function Settings:merge(defaults)
  local overrides, err = self:load()
  if not overrides then return nil, err end
  return util.deep_merge(defaults or {}, overrides), overrides
end

function Settings:write(settings)
  assert(type(settings) == "table" and (next(settings) == nil or not util.is_list(settings)),
    "workspace settings must be an object")
  if next(settings) == nil then settings = vim.empty_dict() end
  local encoded_ok, encoded = pcall(vim.json.encode, settings)
  if not encoded_ok then return nil, settings_error("Failed to encode workspace settings", encoded) end

  local existed = vim.uv.fs_stat(self.directory) ~= nil
  local ok, err = fs.mkdirp(self.directory)
  if not ok then return nil, settings_error("Failed to create workspace directory", err) end
  if not existed then vim.uv.fs_chmod(self.directory, 448) end

  local suffix = vim.uv.random(8):gsub(".", function(char) return string.format("%02x", char:byte()) end)
  local temporary = self.settings_path .. "." .. suffix .. ".tmp"
  ok, err = fs.write_all(temporary, encoded .. "\n", "wx", 384)
  if not ok then return nil, settings_error("Failed to write workspace settings", err) end
  ok, err = vim.uv.fs_rename(temporary, self.settings_path)
  if not ok then
    vim.uv.fs_unlink(temporary)
    return nil, settings_error("Failed to replace workspace settings", err)
  end
  vim.uv.fs_chmod(self.settings_path, 384)
  return util.copy(settings)
end

function Settings:update(patch)
  assert(type(patch) == "table" and (next(patch) == nil or not util.is_list(patch)),
    "workspace settings patch must be an object")
  local current, err = self:load()
  if not current then return nil, err end
  return self:write(util.deep_merge(current, patch))
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.directory) == "string" and opts.directory ~= "", "directory is required")
  assert(type(opts.root) == "string" and opts.root ~= "", "root is required")
  local root = fs.canonical(opts.root)
  local directory = fs.join(fs.normalize(opts.directory), vim.fn.sha256(root))
  return setmetatable({
    root = root,
    directory = directory,
    settings_path = fs.join(directory, "settings.json"),
    sessions_directory = fs.join(directory, "sessions"),
  }, Settings)
end

return M
