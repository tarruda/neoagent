local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.InputHistoryOptions: Neoagent.WorkspaceSettingsOptions
---@field limit? integer

---@class Neoagent.InputHistory
---@field root string
---@field directory string
---@field path string
---@field limit integer
---@field _workspace Neoagent.WorkspaceStorage
local History = {}
History.__index = History

---@param message string
---@param detail? unknown
---@return Neoagent.Error
local function history_error(message, detail)
  return util.error("history", message, detail)
end

---@return string[]?, Neoagent.Error?
function History:load()
  local valid, validation_err = self._workspace.validate()
  if not valid then
    return nil, validation_err
  end
  if not vim.uv.fs_stat(self.path) then
    return {}
  end
  local content, err = fs.read(self.path)
  if not content then
    return nil, history_error("Failed to read input history", err)
  end
  local chronological = vim.split(content, "\n", { plain = true })
  local history = {}
  for index = #chronological, 1, -1 do
    if chronological[index] ~= "" then
      local ok, entry = pcall(vim.json.decode, chronological[index])
      if not ok or type(entry) ~= "string" then
        return nil, history_error("Invalid input history", "line " .. index)
      end
      if util.trim(entry) ~= "" then
        history[#history + 1] = entry
      end
      if #history == self.limit then
        break
      end
    end
  end
  return history
end

---@param self Neoagent.InputHistory
---@param history string[]
---@return string
local function encode_history(self, history)
  assert(util.is_list(history), "history must be a list")
  local lines = {}
  for index = math.min(#history, self.limit), 1, -1 do
    assert(
      type(history[index]) == "string" and util.trim(history[index]) ~= "",
      "history entries must be non-empty strings"
    )
    lines[#lines + 1] = vim.json.encode(history[index])
  end
  return table.concat(lines, "\n") .. "\n"
end

---@param self Neoagent.InputHistory
---@return true?, Neoagent.Error?
local function prepare_directory(self)
  return self._workspace.prepare()
end

---@param self Neoagent.InputHistory
---@param history string[]
---@param encoded string
---@return string[]?, Neoagent.Error?
local function replace(self, history, encoded)
  local ok, err, stage = fs.atomic_replace(self.path, encoded, { mode = 384 })
  if not ok then
    local action = stage == "temporary" and "create input history temporary file"
      or stage == "rename" and "replace input history"
      or "write input history"
    return nil, history_error("Failed to " .. action, err)
  end
  return vim.list_slice(history, 1, self.limit)
end

---@param self Neoagent.InputHistory
---@param fn fun(): string[]?, Neoagent.Error?
---@return string[]?, Neoagent.Error?
local function with_lock(self, fn)
  local result, err = file_lock.new({ path = self.path .. ".lock" }):with(fn)
  if not result and type(err) == "table" and err.kind == "file_lock" then
    local releasing = err.code == "release" or err.code == "ownership"
    local action = releasing and "release" or "acquire"
    return nil, history_error("Failed to " .. action .. " input history lock", rawget(err, "detail") or err.message)
  end
  return result, err
end

---@param history string[]
---@return string[]?, Neoagent.Error?
function History:write(history)
  local encoded = encode_history(self, history)
  local prepared, prepare_err = prepare_directory(self)
  if not prepared then
    return nil, prepare_err
  end
  return with_lock(self, function()
    return replace(self, history, encoded)
  end)
end

---@param text string
---@return string[]?, Neoagent.Error?
function History:add(text)
  assert(type(text) == "string", "history input must be a string")
  text = util.trim(text)
  if text == "" then
    return self:load()
  end
  local prepared, prepare_err = prepare_directory(self)
  if not prepared then
    return nil, prepare_err
  end
  return with_lock(self, function()
    local history, read_err = self:load()
    if not history then
      return nil, read_err
    end
    if history[1] == text then
      return history
    end
    table.insert(history, 1, text)
    if #history > self.limit then
      table.remove(history)
    end
    return replace(self, history, encode_history(self, history))
  end)
end

---@param opts Neoagent.InputHistoryOptions
---@return Neoagent.InputHistory
function M.new(opts)
  opts = opts or {}
  assert(type(opts.directory) == "string" and opts.directory ~= "", "directory is required")
  assert(type(opts.root) == "string" and opts.root ~= "", "root is required")
  assert(
    opts.limit == nil or type(opts.limit) == "number" and opts.limit > 0 and opts.limit % 1 == 0,
    "limit must be a positive integer"
  )
  local root = fs.canonical(opts.root)
  local workspace = require("neoagent.workspace_storage").resolve(opts.directory, root)
  local directory = workspace.directory
  return setmetatable({
    root = root,
    directory = directory,
    _workspace = workspace,
    path = fs.join(directory, "input-history.jsonl"),
    limit = opts.limit or 100,
  }, History)
end

return M
