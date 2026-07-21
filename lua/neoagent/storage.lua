local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local Store = {}
Store.__index = Store

local function random_id(bytes)
  return (vim.uv.random(bytes or 8):gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

local function iso_time(ms)
  local seconds = math.floor(ms / 1000)
  return os.date("!%Y-%m-%dT%H:%M:%S", seconds) .. string.format(".%03dZ", ms % 1000)
end

local function storage_error(message, detail)
  return util.error("storage", message, detail)
end

local function valid_message(message)
  if type(message) ~= "table" then
    return false, "message must be an object"
  end
  if message.role ~= "user" and message.role ~= "assistant" and message.role ~= "toolResult" then
    return false, "unsupported message role: " .. tostring(message.role)
  end
  if message.content == nil then
    return false, "message content is required"
  end
  return true
end

function Store:load()
  return util.copy(self._messages)
end

function Store:metadata()
  return {
    id = self._id,
    path = self._path,
    cwd = self._cwd,
    timestamp = self._timestamp,
    persisted = self._persisted,
  }
end

function Store:append(message)
  local valid, validation_err = valid_message(message)
  if not valid then
    return nil, storage_error("Invalid message", validation_err)
  end
  local entry_id = random_id(8)
  local entry = {
    type = "message",
    id = entry_id,
    parentId = self._parent_id or vim.NIL,
    timestamp = iso_time(util.now_ms()),
    message = util.copy(message),
  }
  local encoded_entry = vim.json.encode(entry) .. "\n"

  if not self._persisted then
    local ok, err = fs.mkdirp(vim.fs.dirname(self._path))
    if not ok then
      return nil, storage_error("Failed to create session directory", err)
    end
    local header = {
      type = "session",
      version = 3,
      id = self._id,
      timestamp = self._timestamp,
      cwd = self._cwd,
    }
    ok, err = fs.write_all(self._path, vim.json.encode(header) .. "\n" .. encoded_entry, "wx", 384)
    if not ok then
      return nil, storage_error("Failed to create session file", err)
    end
    self._persisted = true
  else
    local ok, err = fs.write_all(self._path, encoded_entry, "a", 384)
    if not ok then
      return nil, storage_error("Failed to append session message", err)
    end
  end
  self._parent_id = entry_id
  self._messages[#self._messages + 1] = util.copy(message)
  return true
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.directory) == "string" and opts.directory ~= "", "directory is required")
  assert(type(opts.cwd) == "string" and opts.cwd ~= "", "cwd is required")
  local cwd = fs.canonical(opts.cwd)
  local id = random_id(12)
  local now = util.now_ms()
  local timestamp = iso_time(now)
  local namespace = vim.fn.sha256(cwd)
  local filename = os.date("!%Y%m%dT%H%M%S", math.floor(now / 1000)) .. "_" .. id .. ".jsonl"
  return setmetatable({
    _directory = fs.normalize(opts.directory),
    _cwd = cwd,
    _id = id,
    _timestamp = timestamp,
    _path = fs.join(opts.directory, namespace, filename),
    _persisted = false,
    _messages = {},
    _parent_id = nil,
  }, Store)
end

function M.open(path)
  path = fs.normalize(path)
  local data, read_err = fs.read(path)
  if not data then
    return nil, storage_error("Failed to read session", read_err)
  end
  if data == "" or data:sub(-1) ~= "\n" then
    return nil, storage_error("Invalid session at line 1", "incomplete JSONL line")
  end
  local lines = vim.split(data, "\n", { plain = true })
  table.remove(lines)
  local decoded = {}
  for line_number, line in ipairs(lines) do
    local ok, value = pcall(vim.json.decode, line)
    if not ok or type(value) ~= "table" then
      return nil, storage_error("Invalid session at line " .. line_number, ok and "expected object" or value)
    end
    decoded[#decoded + 1] = value
  end
  local header = decoded[1]
  if not header or header.type ~= "session" or header.version ~= 3
      or type(header.id) ~= "string" or type(header.timestamp) ~= "string"
      or type(header.cwd) ~= "string" then
    return nil, storage_error("Invalid session at line 1", "expected pi session v3 header")
  end

  local messages = {}
  local seen = {}
  local parent
  for index = 2, #decoded do
    local entry = decoded[index]
    if entry.type ~= "message" then
      return nil, storage_error("Invalid session at line " .. index, "unsupported entry type: " .. tostring(entry.type))
    end
    if type(entry.id) ~= "string" or entry.id == "" or seen[entry.id] then
      return nil, storage_error("Invalid session at line " .. index, "missing or duplicate entry id")
    end
    local expected_null = index == 2
    local is_null = entry.parentId == vim.NIL or entry.parentId == nil
    if expected_null and not is_null or not expected_null and entry.parentId ~= parent then
      return nil, storage_error("Invalid session at line " .. index, "broken or branching parent chain")
    end
    local valid, message_err = valid_message(entry.message)
    if not valid then
      return nil, storage_error("Invalid session at line " .. index, message_err)
    end
    seen[entry.id] = true
    parent = entry.id
    messages[#messages + 1] = entry.message
  end
  return setmetatable({
    _directory = vim.fs.dirname(vim.fs.dirname(path)),
    _cwd = header.cwd,
    _id = header.id,
    _timestamp = header.timestamp,
    _path = path,
    _persisted = true,
    _messages = messages,
    _parent_id = parent,
  }, Store)
end

function M.list(directory, cwd)
  local namespace = fs.join(fs.normalize(directory), vim.fn.sha256(fs.canonical(cwd)))
  local handle = vim.uv.fs_scandir(namespace)
  if not handle then
    return {}
  end
  local paths = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and name:sub(-6) == ".jsonl" then
      paths[#paths + 1] = fs.join(namespace, name)
    end
  end
  table.sort(paths, function(a, b) return a > b end)
  return paths
end

return M
