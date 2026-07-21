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

local function valid_entry(entry)
  if entry.type == "message" then return valid_message(entry.message) end
  if entry.type == "model_change" then
    if type(entry.provider) ~= "string" or entry.provider == ""
        or type(entry.modelId) ~= "string" or entry.modelId == "" then
      return false, "model changes require provider and modelId"
    end
    return true
  end
  if entry.type == "thinking_level_change" then
    if type(entry.thinkingLevel) ~= "string" or entry.thinkingLevel == "" then
      return false, "thinking level changes require thinkingLevel"
    end
    return true
  end
  return false, "unsupported entry type: " .. tostring(entry.type)
end

local function apply_entry(store, entry)
  if entry.type == "message" then
    store._messages[#store._messages + 1] = util.copy(entry.message)
  elseif entry.type == "model_change" then
    store._model = { provider = entry.provider, model = entry.modelId }
  elseif entry.type == "thinking_level_change" then
    store._thinking_level = entry.thinkingLevel
  end
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

function Store:state()
  return {
    model = util.copy(self._model),
    thinking_level = self._thinking_level,
  }
end

function Store:_append(entry_type, values, persist)
  local entry = {
    type = entry_type,
    id = random_id(8),
    parentId = self._parent_id or vim.NIL,
    timestamp = iso_time(util.now_ms()),
  }
  for key, value in pairs(values) do entry[key] = util.copy(value) end
  local valid, validation_err = valid_entry(entry)
  if not valid then return nil, storage_error("Invalid " .. entry_type, validation_err) end

  if not self._persisted and not persist then
    self._pending[#self._pending + 1] = entry
    self._parent_id = entry.id
    apply_entry(self, entry)
    return true
  end

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
    local contents = { vim.json.encode(header), "\n" }
    for _, pending in ipairs(self._pending) do
      contents[#contents + 1] = vim.json.encode(pending)
      contents[#contents + 1] = "\n"
    end
    contents[#contents + 1] = encoded_entry
    ok, err = fs.write_all(self._path, table.concat(contents), "wx", 384)
    if not ok then
      return nil, storage_error("Failed to create session file", err)
    end
    self._persisted = true
    self._pending = {}
  else
    local ok, err = fs.write_all(self._path, encoded_entry, "a", 384)
    if not ok then
      return nil, storage_error("Failed to append session entry", err)
    end
  end
  self._parent_id = entry.id
  apply_entry(self, entry)
  return true
end

function Store:append(message)
  return self:_append("message", { message = message }, true)
end

function Store:append_model_change(provider, model_id)
  return self:_append("model_change", { provider = provider, modelId = model_id }, false)
end

function Store:append_thinking_level_change(level)
  return self:_append("thinking_level_change", { thinkingLevel = level }, false)
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.directory) == "string" and opts.directory ~= "", "directory is required")
  assert(type(opts.cwd) == "string" and opts.cwd ~= "", "cwd is required")
  local cwd = fs.canonical(opts.cwd)
  local id = random_id(12)
  local now = util.now_ms()
  local timestamp = iso_time(now)
  local filename = os.date("!%Y%m%dT%H%M%S", math.floor(now / 1000)) .. "_" .. id .. ".jsonl"
  local workspace = require("neoagent.workspace_settings").new({ directory = opts.directory, root = cwd })
  return setmetatable({
    _cwd = cwd,
    _id = id,
    _timestamp = timestamp,
    _path = fs.join(workspace.sessions_directory, filename),
    _persisted = false,
    _messages = {},
    _pending = {},
    _parent_id = nil,
    _model = nil,
    _thinking_level = nil,
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
  local model
  local thinking_level
  for index = 2, #decoded do
    local entry = decoded[index]
    if type(entry.id) ~= "string" or entry.id == "" or seen[entry.id] then
      return nil, storage_error("Invalid session at line " .. index, "missing or duplicate entry id")
    end
    local is_null = entry.parentId == vim.NIL or entry.parentId == nil
    if parent == nil and not is_null or parent ~= nil and entry.parentId ~= parent then
      return nil, storage_error("Invalid session at line " .. index, "broken or branching parent chain")
    end
    local valid, message_err = valid_entry(entry)
    if not valid then
      return nil, storage_error("Invalid session at line " .. index, message_err)
    end
    seen[entry.id] = true
    parent = entry.id
    if entry.type == "message" then
      messages[#messages + 1] = entry.message
    elseif entry.type == "model_change" then
      model = { provider = entry.provider, model = entry.modelId }
    else
      thinking_level = entry.thinkingLevel
    end
  end
  return setmetatable({
    _cwd = header.cwd,
    _id = header.id,
    _timestamp = header.timestamp,
    _path = path,
    _persisted = true,
    _messages = messages,
    _pending = {},
    _parent_id = parent,
    _model = model,
    _thinking_level = thinking_level,
  }, Store)
end

function M.list(directory, cwd)
  local namespace = require("neoagent.workspace_settings").new({
    directory = directory,
    root = cwd,
  }).sessions_directory
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
