local fs = require("neoagent.fs")
local tree = require("neoagent.session_tree")
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

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function copy_metadata(value)
  if type(value) == "table" and next(value) == nil then return vim.empty_dict() end
  return util.copy(value)
end

local function rebuild(store)
  local path, err = tree.path(store._entries, store._leaf_id == nil and vim.NIL or store._leaf_id)
  if not path then return nil, err end
  store._messages = tree.messages(path, false)
  store._state = tree.state(path)
  return true
end

function Store:load()
  return util.copy(self._messages)
end

function Store:context_messages()
  local path, err = self:path()
  if not path then return nil, storage_error("Failed to build session context", err) end
  return tree.to_llm(tree.messages(path, true))
end

function Store:entries()
  return util.copy(self._entries)
end

function Store:entry(id)
  return util.copy(self._by_id[id])
end

function Store:leaf_id()
  return self._leaf_id
end

function Store:path(...)
  local requested = select("#", ...) > 0 and select(1, ...) or self._leaf_id
  if requested == nil then requested = vim.NIL end
  local path, err = tree.path(self._entries, requested)
  if not path then return nil, storage_error("Failed to build session path", err) end
  return path
end

function Store:find_entries(entry_type)
  local result = {}
  for _, entry in ipairs(self._entries) do
    if entry.type == entry_type then result[#result + 1] = util.copy(entry) end
  end
  return result
end

function Store:label(id)
  local label
  for _, entry in ipairs(self._entries) do
    if entry.type == "label" and entry.targetId == id then
      label = is_null(entry.label) and nil or entry.label
    end
  end
  return label
end

function Store:name()
  local name
  for _, entry in ipairs(self._entries) do
    if entry.type == "session_info" and type(entry.name) == "string" then
      local candidate = util.trim(entry.name)
      if candidate ~= "" then name = candidate end
    end
  end
  return name
end

function Store:metadata()
  return {
    id = self._id,
    path = self._path,
    cwd = self._cwd,
    timestamp = self._timestamp,
    persisted = self._persisted,
    parent_session = self._parent_session,
    data = copy_metadata(self._metadata),
  }
end

function Store:state()
  return util.copy(self._state)
end

function Store:_append(entry_type, values, persist)
  local entry = {
    type = entry_type,
    id = random_id(8),
    parentId = self._leaf_id or vim.NIL,
    timestamp = iso_time(util.now_ms()),
  }
  for key, value in pairs(values) do
    if key ~= "type" and key ~= "id" and key ~= "parentId" and key ~= "timestamp" then
      entry[key] = util.copy(value)
    end
  end
  local valid, validation_err = tree.validate_entry(entry)
  if not valid then return nil, storage_error("Invalid " .. entry_type, validation_err) end

  if entry.type == "leaf" and not is_null(entry.targetId) and not self._by_id[entry.targetId] then
    return nil, storage_error("Invalid leaf", "leaf target does not exist")
  end
  if entry.type == "label" and not self._by_id[entry.targetId] then
    return nil, storage_error("Invalid label", "label target does not exist")
  end
  if entry.type == "compaction" and not self._by_id[entry.firstKeptEntryId] then
    return nil, storage_error("Invalid compaction", "first kept entry does not exist")
  end

  if not self._persisted and not persist then
    self._pending[#self._pending + 1] = entry
    self._entries[#self._entries + 1] = util.copy(entry)
    self._by_id[entry.id] = self._entries[#self._entries]
    self._leaf_id = entry.type == "leaf" and (is_null(entry.targetId) and nil or entry.targetId) or entry.id
    local rebuilt, rebuild_err = rebuild(self)
    if not rebuilt then return nil, storage_error("Failed to update session", rebuild_err) end
    return true, nil, util.copy(entry)
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
    if self._parent_session then header.parentSession = self._parent_session end
    if self._metadata then header.metadata = copy_metadata(self._metadata) end
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
  self._entries[#self._entries + 1] = util.copy(entry)
  self._by_id[entry.id] = self._entries[#self._entries]
  self._leaf_id = entry.type == "leaf" and (is_null(entry.targetId) and nil or entry.targetId) or entry.id
  local rebuilt, rebuild_err = rebuild(self)
  if not rebuilt then return nil, storage_error("Failed to update session", rebuild_err) end
  return true, nil, util.copy(entry)
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

function Store:append_active_tools_change(names)
  return self:_append("active_tools_change", { activeToolNames = names }, false)
end

function Store:append_entry(entry_type, values)
  return self:_append(entry_type, values or {}, entry_type == "message")
end

function Store:set_leaf(id)
  if id ~= nil and not self._by_id[id] then
    return nil, storage_error("Failed to move session leaf", "entry not found: " .. tostring(id))
  end
  return self:_append("leaf", { targetId = id or vim.NIL }, self._persisted)
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
    _entries = {},
    _by_id = {},
    _pending = {},
    _leaf_id = nil,
    _state = { model = nil, thinking_level = nil, active_tools = nil },
    _parent_session = opts.parent_session,
    _metadata = copy_metadata(opts.metadata),
  }, Store)
end

function M.open(path)
  path = fs.normalize(path)
  local data, read_err = fs.read(path)
  if not data then
    return nil, storage_error("Failed to read session", read_err)
  end
  local lines = vim.tbl_filter(function(line) return util.trim(line) ~= "" end,
    vim.split(data, "\n", { plain = true }))
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
      or type(header.id) ~= "string" or header.id == ""
      or type(header.timestamp) ~= "string" or header.timestamp == ""
      or type(header.cwd) ~= "string" or header.cwd == "" then
    return nil, storage_error("Invalid session at line 1", "expected pi session v3 header")
  end
  if header.parentSession ~= nil and header.parentSession ~= vim.NIL
      and type(header.parentSession) ~= "string" then
    return nil, storage_error("Invalid session at line 1", "parentSession must be a string")
  end
  if header.metadata ~= nil and header.metadata ~= vim.NIL
      and (type(header.metadata) ~= "table" or util.is_list(header.metadata)) then
    return nil, storage_error("Invalid session at line 1", "metadata must be an object")
  end

  local entries = {}
  for index = 2, #decoded do entries[#entries + 1] = decoded[index] end
  local validated, validation_err, invalid_index = tree.validate_entries(entries)
  if not validated then
    return nil, storage_error("Invalid session at line " .. ((invalid_index or 1) + 1), validation_err)
  end
  local store = setmetatable({
    _cwd = header.cwd,
    _id = header.id,
    _timestamp = header.timestamp,
    _path = path,
    _persisted = true,
    _messages = {},
    _entries = entries,
    _by_id = validated.by_id,
    _pending = {},
    _leaf_id = validated.leaf_id,
    _state = {},
    _parent_session = header.parentSession ~= vim.NIL and header.parentSession or nil,
    _metadata = header.metadata ~= vim.NIL and header.metadata or nil,
  }, Store)
  local rebuilt, rebuild_err = rebuild(store)
  if not rebuilt then return nil, storage_error("Failed to open session", rebuild_err) end
  return store
end

function M.fork(source, opts)
  opts = opts or {}
  if type(source) == "string" then
    local opened, err = M.open(source)
    if not opened then return nil, err end
    source = opened
  end
  if type(source) ~= "table" or type(source.entries) ~= "function" then
    return nil, storage_error("Failed to fork session", "source store is required")
  end
  assert(type(opts.directory) == "string" and opts.directory ~= "", "directory is required")
  local source_metadata = source:metadata()
  if not source_metadata.persisted then
    return nil, storage_error("Failed to fork session", "source session is not persisted")
  end
  local cwd = opts.cwd or source_metadata.cwd
  local entries
  if opts.entry_id then
    local target = source:entry(opts.entry_id)
    if not target then return nil, storage_error("Failed to fork session", "entry not found: " .. opts.entry_id) end
    local leaf_id = target.id
    if (opts.position or "before") == "before" then
      if target.type ~= "message" or target.message.role ~= "user" then
        return nil, storage_error("Failed to fork session", "before position requires a user message")
      end
      leaf_id = is_null(target.parentId) and nil or target.parentId
    elseif opts.position ~= "at" then
      return nil, storage_error("Failed to fork session", "position must be before or at")
    end
    entries = assert(source:path(leaf_id))
  else
    entries = source:entries()
  end

  local validated, validation_err = tree.validate_entries(entries)
  if not validated then return nil, storage_error("Failed to fork session", validation_err) end
  local store = M.new({
    directory = opts.directory,
    cwd = cwd,
    parent_session = source_metadata.path,
    metadata = opts.metadata or source_metadata.data,
  })
  local ok, err = fs.mkdirp(vim.fs.dirname(store._path))
  if not ok then return nil, storage_error("Failed to create session directory", err) end
  local header = {
    type = "session",
    version = 3,
    id = store._id,
    timestamp = store._timestamp,
    cwd = store._cwd,
    parentSession = source_metadata.path,
  }
  if store._metadata then header.metadata = copy_metadata(store._metadata) end
  local contents = { vim.json.encode(header), "\n" }
  for _, entry in ipairs(entries) do
    contents[#contents + 1] = vim.json.encode(entry)
    contents[#contents + 1] = "\n"
  end
  ok, err = fs.write_all(store._path, table.concat(contents), "wx", 384)
  if not ok then return nil, storage_error("Failed to create forked session", err) end
  store._persisted = true
  store._entries = util.copy(entries)
  local forked = assert(tree.validate_entries(store._entries))
  store._by_id = forked.by_id
  store._leaf_id = forked.leaf_id
  local rebuilt, rebuild_err = rebuild(store)
  if not rebuilt then return nil, storage_error("Failed to open forked session", rebuild_err) end
  return store
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
