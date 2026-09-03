local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local History = {}
History.__index = History

local function history_error(message, detail)
  return util.error("history", message, detail)
end

function History:load()
  if not vim.uv.fs_stat(self.path) then return {} end
  local content, err = fs.read(self.path)
  if not content then return nil, history_error("Failed to read input history", err) end
  local chronological = vim.split(content, "\n", { plain = true })
  local history = {}
  for index = #chronological, 1, -1 do
    if chronological[index] ~= "" then
      local ok, entry = pcall(vim.json.decode, chronological[index])
      if not ok or type(entry) ~= "string" then
        return nil, history_error("Invalid input history", "line " .. index)
      end
      if util.trim(entry) ~= "" then history[#history + 1] = entry end
      if #history == self.limit then break end
    end
  end
  return history
end

local function encode_history(self, history)
  assert(util.is_list(history), "history must be a list")
  local lines = {}
  for index = math.min(#history, self.limit), 1, -1 do
    assert(type(history[index]) == "string" and util.trim(history[index]) ~= "",
      "history entries must be non-empty strings")
    lines[#lines + 1] = vim.json.encode(history[index])
  end
  return table.concat(lines, "\n") .. "\n"
end

local function prepare_directory(self)
  local ok, err = fs.ensure_private_directory(self.directory, 448)
  if not ok then return nil, history_error("Failed to create workspace directory", err) end
  return true
end

local function replace(self, history, encoded)
  local ok, err, stage = fs.atomic_replace(
    self.path, encoded, { mode = 384 })
  if not ok then
    local action = stage == "temporary"
        and "create input history temporary file"
      or stage == "rename" and "replace input history"
      or "write input history"
    return nil, history_error("Failed to " .. action, err)
  end
  return vim.list_slice(history, 1, self.limit)
end

local function with_lock(self, fn)
  local result, err = file_lock.new({ path = self.path .. ".lock" }):with(fn)
  if not result and type(err) == "table" and err.kind == "file_lock" then
    local releasing = err.code == "release" or err.code == "ownership"
    local action = releasing and "release" or "acquire"
    return nil, history_error("Failed to " .. action .. " input history lock",
      err.detail or err.message)
  end
  return result, err
end

function History:write(history)
  local encoded = encode_history(self, history)
  local prepared, prepare_err = prepare_directory(self)
  if not prepared then return nil, prepare_err end
  return with_lock(self, function() return replace(self, history, encoded) end)
end

function History:add(text)
  assert(type(text) == "string", "history input must be a string")
  text = util.trim(text)
  if text == "" then return self:load() end
  local prepared, prepare_err = prepare_directory(self)
  if not prepared then return nil, prepare_err end
  return with_lock(self, function()
    local history, read_err = self:load()
    if not history then return nil, read_err end
    if history[1] == text then return history end
    table.insert(history, 1, text)
    if #history > self.limit then table.remove(history) end
    return replace(self, history, encode_history(self, history))
  end)
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.directory) == "string" and opts.directory ~= "", "directory is required")
  assert(type(opts.root) == "string" and opts.root ~= "", "root is required")
  assert(opts.limit == nil or type(opts.limit) == "number" and opts.limit > 0
    and opts.limit % 1 == 0, "limit must be a positive integer")
  local root = fs.canonical(opts.root)
  local directory = require("neoagent.workspace_settings").new({
    directory = opts.directory,
    root = root,
  }).directory
  return setmetatable({
    root = root,
    directory = directory,
    path = fs.join(directory, "input-history.jsonl"),
    limit = opts.limit or 100,
  }, History)
end

return M
