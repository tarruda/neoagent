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

function History:write(history)
  assert(util.is_list(history), "history must be a list")
  local lines = {}
  for index = math.min(#history, self.limit), 1, -1 do
    assert(type(history[index]) == "string" and util.trim(history[index]) ~= "",
      "history entries must be non-empty strings")
    lines[#lines + 1] = vim.json.encode(history[index])
  end
  local existed = vim.uv.fs_stat(self.directory) ~= nil
  local ok, err = fs.mkdirp(self.directory)
  if not ok then return nil, history_error("Failed to create workspace directory", err) end
  if not existed then vim.uv.fs_chmod(self.directory, 448) end

  local suffix = vim.uv.random(8):gsub(".", function(char)
    return string.format("%02x", char:byte())
  end)
  local temporary = self.path .. "." .. suffix .. ".tmp"
  ok, err = fs.write_all(temporary, table.concat(lines, "\n") .. "\n", "wx", 384)
  if not ok then return nil, history_error("Failed to write input history", err) end
  ok, err = vim.uv.fs_rename(temporary, self.path)
  if not ok then
    vim.uv.fs_unlink(temporary)
    return nil, history_error("Failed to replace input history", err)
  end
  vim.uv.fs_chmod(self.path, 384)
  return vim.list_slice(history, 1, self.limit)
end

function History:add(text)
  assert(type(text) == "string", "history input must be a string")
  text = util.trim(text)
  local history, err = self:load()
  if not history then return nil, err end
  if text == "" or history[1] == text then return history end
  table.insert(history, 1, text)
  if #history > self.limit then table.remove(history) end
  return self:write(history)
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.directory) == "string" and opts.directory ~= "", "directory is required")
  assert(type(opts.root) == "string" and opts.root ~= "", "root is required")
  assert(opts.limit == nil or type(opts.limit) == "number" and opts.limit > 0
    and opts.limit % 1 == 0, "limit must be a positive integer")
  local root = fs.canonical(opts.root)
  local directory = fs.join(fs.normalize(opts.directory), vim.fn.sha256(root))
  return setmetatable({
    root = root,
    directory = directory,
    path = fs.join(directory, "input-history.jsonl"),
    limit = opts.limit or 100,
  }, History)
end

return M
