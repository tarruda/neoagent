local fs = require("neoagent.fs")
local file_lock = require("neoagent.file_lock")
local tree = require("neoagent.session_tree")
local util = require("neoagent.util")

local M = {}
local Store = {}
Store.__index = Store

local INDEX_FILENAME = "session-index.json"
local INDEX_VERSION = 1
local INDEX_LOCK_TIMEOUT_MS = 15000
local INDEX_LOCK_POLL_MS = 50
local INDEX_LOCK_STALE_MS = 120000

local function session_lock(path)
  return file_lock.new({
    path = path .. ".lock",
    timeout_ms = INDEX_LOCK_TIMEOUT_MS,
    poll_ms = INDEX_LOCK_POLL_MS,
    stale_ms = INDEX_LOCK_STALE_MS,
  })
end

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

local function encode_session_value(value, label)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then return nil, storage_error("Failed to encode " .. label, encoded) end
  if not util.is_valid_utf8(encoded) then
    return nil, storage_error("Failed to encode " .. label, "strings must contain valid UTF-8")
  end
  return encoded
end

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function copy_metadata(value)
  if type(value) == "table" and next(value) == nil then return vim.empty_dict() end
  return util.copy(value)
end

local function mtime_ms(stat)
  local mtime = stat and stat.mtime or {}
  return (tonumber(mtime.sec) or 0) * 1000
    + math.floor((tonumber(mtime.nsec) or 0) / 1000000)
end

local function empty_index()
  return { version = INDEX_VERSION, sessions = vim.empty_dict() }
end

local function index_entry(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.text) ~= "string" or value.text == "" then
    return nil
  end
  if value.parent_session ~= nil and value.parent_session ~= vim.NIL
      and type(value.parent_session) ~= "string" then
    return nil
  end
  local result = { text = value.text }
  if type(value.parent_session) == "string" then
    result.parent_session = value.parent_session
  end
  return result
end

local function read_index(path)
  if not vim.uv.fs_stat(path) then return empty_index() end
  local data = fs.read(path)
  if not data then return empty_index() end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= "table" or util.is_list(decoded)
      or decoded.version ~= INDEX_VERSION
      or type(decoded.sessions) ~= "table" or util.is_list(decoded.sessions) then
    return empty_index()
  end
  local sessions = vim.empty_dict()
  for filename, value in pairs(decoded.sessions) do
    if type(filename) == "string" and filename ~= ""
        and not filename:find("[/\\]") and filename:sub(-6) == ".jsonl" then
      local selected = index_entry(value)
      if selected then sessions[filename] = selected end
    end
  end
  return { version = INDEX_VERSION, sessions = sessions }
end

local function write_index(path, document)
  local temporary = path .. "." .. random_id(8) .. ".tmp"
  local ok, err = fs.write_all(temporary,
    util.json_encode(document) .. "\n", "wx", 384)
  if not ok then return nil, err end
  ok, err = vim.uv.fs_rename(temporary, path)
  if not ok then
    vim.uv.fs_unlink(temporary)
    return nil, err
  end
  vim.uv.fs_chmod(path, 384)
  return true
end

local function modify_index(path, modifier)
  local ok, result = pcall(function()
    return file_lock.new({
      path = path .. ".lock",
      timeout_ms = INDEX_LOCK_TIMEOUT_MS,
      poll_ms = INDEX_LOCK_POLL_MS,
      stale_ms = INDEX_LOCK_STALE_MS,
    }):with(function()
      local document = read_index(path)
      modifier(document.sessions)
      return write_index(path, document)
    end)
  end)
  if not ok then return nil end
  return result
end

local function workspace_index_path(workspace)
  return fs.join(workspace.directory, INDEX_FILENAME)
end

local function session_index_path(path)
  local sessions_directory = vim.fs.dirname(path)
  if vim.fs.basename(sessions_directory) ~= "sessions" then return nil end
  return fs.join(vim.fs.dirname(sessions_directory), INDEX_FILENAME)
end

local function picker_text(value)
  value = type(value) == "string" and value or ""
  value = util.trim(value:gsub("[%c%s]+", " "))
  if value == "" then value = "(no messages)" end
  if vim.fn.strchars(value) > 80 then
    value = vim.fn.strcharpart(value, 0, 80) .. "…"
  end
  return value
end

local function rebuild(store)
  local path, err = tree.indexed_path(store._by_id, store._leaf_id == nil and vim.NIL or store._leaf_id)
  if not path then return nil, err end
  store._messages = tree.messages(path, false)
  store._state = tree.state(path)
  return true
end

local function project_append(store, entry)
  local messages = tree.entry_messages(entry)
  vim.list_extend(store._messages, messages)
  store._state = tree.apply_state(store._state, entry)
  return messages
end

local function commit_entry(store, entry)
  local stored = util.copy(entry)
  store._entries[#store._entries + 1] = stored
  store._by_id[stored.id] = stored
  if stored.type == "leaf" then
    store._leaf_id = is_null(stored.targetId) and nil or stored.targetId
    local rebuilt, err = rebuild(store)
    if not rebuilt then return nil, err end
    return true, { type = "replace", messages = util.copy(store._messages) }
  end
  store._leaf_id = stored.id
  local messages = project_append(store, stored)
  return true, { type = "append", messages = util.copy(messages) }
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
  local path, err = tree.indexed_path(self._by_id, requested)
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
    if entry.type == "session_info" then
      name = type(entry.name) == "string" and util.trim(entry.name) or nil
      if name == "" then name = nil end
    end
  end
  return name
end

function Store:info()
  local first_message
  local message_count = 0
  local modified_at
  local unknown_activity = false
  for _, entry in ipairs(self._entries) do
    if entry.type == "message" then
      message_count = message_count + 1
      local message = entry.message
      if message.role == "user" or message.role == "assistant" then
        if type(message.timestamp) == "number" then
          modified_at = math.max(modified_at or 0, message.timestamp)
        else
          unknown_activity = true
        end
        if not first_message and message.role == "user" then
          local ok, text = pcall(util.text_content, message.content)
          if ok and text ~= "" then first_message = text end
        end
      end
    end
  end
  if modified_at == nil or unknown_activity then
    local stat = vim.uv.fs_stat(self._path)
    local mtime = stat and stat.mtime
    if mtime then
      modified_at = math.max(modified_at or 0,
        mtime.sec * 1000 + math.floor((mtime.nsec or 0) / 1000000))
    end
  end
  return {
    path = self._path,
    id = self._id,
    cwd = self._cwd,
    name = self:name(),
    parent_session = self._parent_session,
    created_at = self._timestamp,
    modified_at = modified_at or 0,
    message_count = message_count,
    first_message = first_message or "(no messages)",
  }
end

local function store_index_entry(store)
  local info = store:info()
  local result = { text = picker_text(info.name or info.first_message) }
  if store._parent_session then result.parent_session = store._parent_session end
  return result
end

local function update_store_index(store)
  if not store._index_path then return end
  local filename = vim.fs.basename(store._path)
  local value = store_index_entry(store)
  modify_index(store._index_path, function(sessions)
    sessions[filename] = value
  end)
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
  if self._by_id[entry.id] then
    return nil, storage_error("Invalid " .. entry_type, "duplicate entry id")
  end
  local encoded_entry, encode_err = encode_session_value(entry, entry_type)
  if not encoded_entry then return nil, encode_err end

  local references, reference_err = tree.validate_references(entry, self._by_id)
  if not references then
    return nil, storage_error("Invalid " .. entry_type, reference_err)
  end

  if not self._persisted and not persist then
    self._pending[#self._pending + 1] = entry
    local committed, projection = commit_entry(self, entry)
    if not committed then return nil, storage_error("Failed to update session", projection) end
    return true, nil, util.copy(entry), projection
  end

  local first_persistence = not self._persisted
  if first_persistence then
    local header = {
      type = "session",
      version = 3,
      id = self._id,
      timestamp = self._timestamp,
      cwd = self._cwd,
    }
    if self._parent_session then header.parentSession = self._parent_session end
    if self._metadata then header.metadata = copy_metadata(self._metadata) end
    local encoded_header, header_err = encode_session_value(header, "session header")
    if not encoded_header then return nil, header_err end
    local contents = { encoded_header, "\n" }
    for _, pending in ipairs(self._pending) do
      local encoded_pending, pending_err = encode_session_value(pending, pending.type)
      if not encoded_pending then return nil, pending_err end
      contents[#contents + 1] = encoded_pending
      contents[#contents + 1] = "\n"
    end
    contents[#contents + 1] = encoded_entry .. "\n"
    local ok, err = fs.mkdirp(vim.fs.dirname(self._path))
    if not ok then
      return nil, storage_error("Failed to create session directory", err)
    end
    ok, err = fs.write_all(self._path, table.concat(contents), "wx", 384)
    if not ok then
      return nil, storage_error("Failed to create session file", err)
    end
    self._persisted = true
    self._pending = {}
  else
    local ok, err = session_lock(self._path):with(function()
      return fs.write_all(self._path, encoded_entry .. "\n", "a", 384)
    end)
    if not ok then
      if type(err) == "table" and err.kind == "file_lock" then
        err = err.detail or err.message
      end
      return nil, storage_error("Failed to append session entry", err)
    end
  end
  local committed, projection = commit_entry(self, entry)
  if not committed then return nil, storage_error("Failed to update session", projection) end
  if first_persistence or entry_type == "session_info" then
    update_store_index(self)
  end
  return true, nil, util.copy(entry), projection
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
    _index_path = workspace_index_path(workspace),
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
  local data, read_err = session_lock(path):with(function() return fs.read(path) end)
  if not data then
    if type(read_err) == "table" and read_err.kind == "file_lock" then
      read_err = read_err.detail or read_err.message
    end
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
    _index_path = session_index_path(path),
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
  local header = {
    type = "session",
    version = 3,
    id = store._id,
    timestamp = store._timestamp,
    cwd = store._cwd,
    parentSession = source_metadata.path,
  }
  if store._metadata then header.metadata = copy_metadata(store._metadata) end
  local encoded_header, header_err = encode_session_value(header, "session header")
  if not encoded_header then return nil, header_err end
  local contents = { encoded_header, "\n" }
  for _, entry in ipairs(entries) do
    local encoded_entry, entry_err = encode_session_value(entry, entry.type)
    if not encoded_entry then return nil, entry_err end
    contents[#contents + 1] = encoded_entry
    contents[#contents + 1] = "\n"
  end
  local ok, err = fs.mkdirp(vim.fs.dirname(store._path))
  if not ok then return nil, storage_error("Failed to create session directory", err) end
  ok, err = fs.write_all(store._path, table.concat(contents), "wx", 384)
  if not ok then return nil, storage_error("Failed to create forked session", err) end
  store._persisted = true
  store._entries = util.copy(entries)
  local forked = assert(tree.validate_entries(store._entries))
  store._by_id = forked.by_id
  store._leaf_id = forked.leaf_id
  local rebuilt, rebuild_err = rebuild(store)
  if not rebuilt then return nil, storage_error("Failed to open forked session", rebuild_err) end
  update_store_index(store)
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

function M.list_sessions(directory, cwd)
  local workspace = require("neoagent.workspace_settings").new({
    directory = directory,
    root = cwd,
  })
  local index_path = workspace_index_path(workspace)
  local indexed = read_index(index_path)
  local sessions = {}
  local repairs = {}
  local present = {}
  for _, path in ipairs(M.list(directory, cwd)) do
    local filename = vim.fs.basename(path)
    present[filename] = true
    local value = indexed.sessions[filename]
    if not value then
      local store = M.open(path)
      if store then
        value = store_index_entry(store)
        repairs[filename] = value
      end
    end
    local stat = value and vim.uv.fs_stat(path)
    if value and stat then
      sessions[#sessions + 1] = {
        path = path,
        parent_session = value.parent_session,
        text = value.text,
        modified_at = mtime_ms(stat),
      }
    end
  end
  local stale = {}
  for filename in pairs(indexed.sessions) do
    if not present[filename] then stale[#stale + 1] = filename end
  end
  if next(repairs) or #stale > 0 then
    modify_index(index_path, function(values)
      for filename, value in pairs(repairs) do
        if not values[filename] then values[filename] = value end
      end
      for _, filename in ipairs(stale) do
        if not vim.uv.fs_stat(fs.join(workspace.sessions_directory, filename)) then
          values[filename] = nil
        end
      end
    end)
  end
  table.sort(sessions, function(a, b)
    if a.modified_at == b.modified_at then return a.path > b.path end
    return a.modified_at > b.modified_at
  end)
  return sessions
end

return M
