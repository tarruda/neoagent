local util = require("neoagent.util")
local tree = require("neoagent.session_tree")
local semantic_message = require("neoagent.semantic_message")
local files = require("neoagent.files")
local projections = require("neoagent.session_projection")

local M = {}
---@class Neoagent.SessionMetadata
---@field path? string
---@field id string
---@field cwd? string
---@field created_at? integer
---@field persisted? boolean
---@field parent_session? string
---@field data? Neoagent.JsonObject

---@class Neoagent.SessionSnapshot
---@field id string
---@field workspace? string
---@field created_at? integer
---@field parent_session? string
---@field metadata? Neoagent.JsonObject
---@field entries Neoagent.JournalEntry[]
---@field leaf_id? string

---@class Neoagent.SessionStorage
---@field files? fun(self: Neoagent.SessionStorage): Neoagent.Files
---@field file_cache? fun(self: Neoagent.SessionStorage): Neoagent.FileCache?
---@field load fun(self: Neoagent.SessionStorage): unknown, unknown?
---@field append fun(self: Neoagent.SessionStorage, message: Neoagent.Message, state?: Neoagent.RequestStateInput): boolean?, unknown?, Neoagent.JournalEntry?, unknown?
---@field context_messages? fun(self: Neoagent.SessionStorage): unknown, unknown?
---@field checkpoint_identity? fun(self: Neoagent.SessionStorage): Neoagent.NativeContextIdentity?, Neoagent.Error?
---@field entries? fun(self: Neoagent.SessionStorage): Neoagent.JournalEntry[]
---@field entry? fun(self: Neoagent.SessionStorage, id: string): Neoagent.JournalEntry?
---@field leaf_id? fun(self: Neoagent.SessionStorage): string?
---@field path? fun(self: Neoagent.SessionStorage, ...: string|nil): Neoagent.JournalEntry[]?, Neoagent.Error?
---@field transcript_entries? fun(self: Neoagent.SessionStorage, segment_id?: string, direction?: 'first'|'previous'|'next'): Neoagent.JournalEntry[]?, Neoagent.Error?, Neoagent.TranscriptHistory?
---@field state? fun(self: Neoagent.SessionStorage): Neoagent.SelectionState?, Neoagent.Error?
---@field append_compaction? fun(self: Neoagent.SessionStorage, values: Neoagent.CompactionPayload): boolean?, unknown?, Neoagent.JournalEntry?, unknown?
---@field set_leaf? fun(self: Neoagent.SessionStorage, id?: string): boolean?, unknown?, Neoagent.JournalEntry?, unknown?
---@field metadata? fun(self: Neoagent.SessionStorage): Neoagent.SessionMetadata?

---@class Neoagent.CompactionPayload
---@field summary? string
---@field native? Neoagent.NativeCompactionMessage
---@field first_kept_entry_id? string
---@field retained_users? Neoagent.RetainedUser[]
---@field tokens_before integer

---@class Neoagent.SessionOptions
---@field files? Neoagent.Files
---@field file_cache? Neoagent.FileCache
---@field id? string
---@field messages? Neoagent.Message[]
---@field entries? Neoagent.JournalEntry[]
---@field leaf_id? string
---@field store? Neoagent.SessionStorage
---@field workspace? string
---@field created_at? integer
---@field parent_session? string
---@field metadata? Neoagent.JsonObject

---@class Neoagent.SessionHeader
---@field cwd? string
---@field created_at integer
---@field parent_session? string
---@field data? Neoagent.JsonObject

---@class Neoagent.Session
---@field _files Neoagent.Files
---@field _file_cache? Neoagent.FileCache
---@field _id string
---@field _identity table
---@field _header? Neoagent.SessionHeader
---@field _projection Neoagent.SessionProjectionState
---@field _store? Neoagent.SessionStorage
---@field _entries Neoagent.JournalEntry[]
---@field _by_id Neoagent.JournalIndex
---@field _leaf_id? string
local Session = {}
Session.__index = Session

---@class Neoagent.MessageCursor
---@field source Neoagent.ProjectionMessage[]
---@field count integer

---@class Neoagent.MessageUpdate
---@field messages Neoagent.ProjectionMessage[]
---@field reset boolean
---@field cursor Neoagent.MessageCursor

---@param bytes? integer
---@return string
local function random_id(bytes)
  return (
    assert(vim.uv.random(bytes or 8)):gsub(".", function(char)
      return string.format("%02x", char:byte())
    end)
  )
end

---@param self Neoagent.Session
---@param entry_type "message"|"compaction"|"leaf"
---@param values? table<string, unknown>
---@return true?, Neoagent.Error?, Neoagent.JournalEntry?
---@return_overload true, nil, Neoagent.JournalEntry
---@return_overload nil, Neoagent.Error
local function memory_append(self, entry_type, values)
  local entry, err = tree.prepare_entry({
    type = entry_type,
    id = random_id(),
    parent_id = self._leaf_id or vim.NIL,
    created_at = util.now_ms(),
    payload = values or {},
    by_id = self._by_id,
  })
  if not entry then
    return nil, util.error("session", "Invalid " .. tostring(entry_type), err)
  end
  self._entries[#self._entries + 1] = entry
  self._by_id[entry.id] = entry
  if entry.type == "leaf" then
    self._leaf_id = entry.target_id ~= vim.NIL and entry.target_id or nil
    local path = assert(tree.indexed_path(self._by_id, self._leaf_id == nil and vim.NIL or self._leaf_id))
    self._projection:replace(tree.messages(path, false))
  else
    self._leaf_id = entry.id
    assert(self._projection:append(tree.entry_messages(entry)))
  end
  return true, nil, util.copy(entry)
end

---@param self Neoagent.Session
---@param projection unknown
---@return true?, Neoagent.Error?
local function apply_store_projection(self, projection)
  if self._store and projections.for_store(self._store) == self._projection then
    return true
  end
  return self._projection:accept(projection)
end

---@param self Neoagent.Session
---@param message Neoagent.Message
---@param state? Neoagent.RequestStateInput
---@return true?, Neoagent.Error?, Neoagent.JournalEntry?
local function memory_append_message(self, message, state)
  local request, request_err = tree.normalize_request_state(state)
  if request_err then
    return nil, util.error("session", "Invalid message state", request_err)
  end
  local values = { message = message }
  if request then
    values.request = request
  end
  return memory_append(self, "message", values)
end

---@param message unknown
---@param state? Neoagent.RequestStateInput
---@return true?, Neoagent.Error?, Neoagent.JournalEntry?
---@return_overload true, nil, Neoagent.JournalEntry?
---@return_overload nil, Neoagent.Error
function Session:append(message, state)
  assert(type(message) == "table", "message must be a table")
  assert(
    state == nil or type(state) == "table" and (next(state) == nil or not util.is_list(state)),
    "message state must be an object"
  )
  local copy, message_err = semantic_message.normalize(message)
  if not copy then
    return nil, util.error("session", "Invalid Session message", message_err)
  end
  local published, file_err = files.check_messages(self._files, { copy })
  if not published then
    return nil, file_err
  end
  local linked, linkage_err = self._projection:check(copy)
  if not linked then
    return nil, util.error("session", "Invalid Session message", linkage_err)
  end
  state = util.copy(state or {})
  if self._store then
    local ok, err, entry, projection = self._store:append(copy, state)
    if not ok then
      return nil, util.normalize_error(err, "storage")
    end
    local projected, projection_err = apply_store_projection(self, projection)
    if not projected then
      return nil, projection_err
    end
    return true, nil, entry
  end
  local accepted, err, entry = memory_append_message(self, copy, state)
  if not accepted then
    return nil, err
  end
  return true, nil, entry
end

---@return Neoagent.ProjectionMessage[]
function Session:messages()
  return util.copy(self._projection.messages)
end

-- Replay counts durable messages independently of optional journal receipts.
-- Checkpoint cards have no corresponding message_end publication.
---@return integer
function Session:_message_count()
  local count = 0
  for _, message in ipairs(self._projection.messages) do
    if message.role ~= "compactionSummary" and message.role ~= "compactionCheckpoint" then
      count = count + 1
    end
  end
  return count
end

-- Cursors belong to Agent tool synchronization. A replacement invalidates
-- them; accepted appends preserve the source array and expose only its tail.
---@param cursor? Neoagent.MessageCursor
---@return Neoagent.MessageUpdate?
function Session:_message_update(cursor)
  local source = self._projection.messages
  local reset = not cursor or cursor.source ~= source
  local first = not reset and assert(cursor).count + 1 or 1
  if not reset and first > #source then
    return nil
  end
  local messages = {}
  for index = first, #source do
    messages[#messages + 1] = util.copy(source[index])
  end
  return {
    messages = messages,
    reset = reset,
    cursor = { source = source, count = #source },
  }
end

---@return Neoagent.RequestMessage[]?, Neoagent.Error?
function Session:context_messages()
  if self._store and type(self._store.context_messages) == "function" then
    local messages, err = self._store:context_messages()
    if not messages then
      return nil, util.normalize_error(err, "storage")
    end
    local normalized, message_err = semantic_message.normalize_request_list(messages)
    if not normalized then
      return nil, util.error("storage", "Store returned invalid context", message_err)
    end
    return normalized
  end
  if #self._entries > 0 then
    local messages, err = tree.indexed_context_messages(self._by_id, self._leaf_id or vim.NIL)
    if not messages then
      return nil, util.error("session", "Failed to build session context", err)
    end
    return messages
  end
  return tree.to_llm(self._projection.messages)
end

---@return Neoagent.NativeContextIdentity?, Neoagent.Error?
function Session:checkpoint_identity()
  if self._store and type(self._store.checkpoint_identity) == "function" then
    return self._store:checkpoint_identity()
  end
  if not self._store then
    local identity, err = tree.indexed_checkpoint_identity(self._by_id, self._leaf_id or vim.NIL)
    if err then
      return nil, util.error("session", "Failed to read checkpoint identity", err)
    end
    return identity
  end
  local path, err = self:path()
  if not path then
    return nil, err
  end
  return tree.checkpoint_identity(path)
end

---@return Neoagent.JournalEntry[]
function Session:entries()
  if self._store and type(self._store.entries) == "function" then
    return self._store:entries()
  end
  return util.copy(self._entries)
end

---@param id string
---@return Neoagent.JournalEntry?
function Session:entry(id)
  if self._store and type(self._store.entry) == "function" then
    return self._store:entry(id)
  end
  return util.copy(self._by_id[id])
end

---@return string?
function Session:leaf_id()
  if self._store and type(self._store.leaf_id) == "function" then
    return self._store:leaf_id()
  end
  return self._leaf_id
end

---@param ... string|nil
---@return Neoagent.JournalEntry[]?, Neoagent.Error?
function Session:path(...)
  if self._store and type(self._store.path) == "function" then
    return self._store:path(...)
  end
  local requested
  if select("#", ...) > 0 then
    requested = select(1, ...)
  else
    requested = self._leaf_id
  end
  if requested == nil then
    requested = vim.NIL
  end
  local path, err = tree.indexed_path(self._by_id, requested)
  if not path then
    return nil, util.error("session", "Failed to build session path", err)
  end
  return path
end

---@param segment_id? string
---@param direction? 'first'|'previous'|'next'
---@return Neoagent.JournalEntry[]?, Neoagent.Error?, Neoagent.TranscriptHistory?
function Session:transcript_entries(segment_id, direction)
  if self._store and type(self._store.transcript_entries) == "function" then
    return self._store:transcript_entries(segment_id, direction)
  end
  local entries, err, history
  if self._store then
    local path, path_err = self:path()
    if not path then
      return nil, path_err
    end
    entries, err, history = tree.transcript_entries(path, segment_id, direction)
  else
    entries, err, history =
      tree.indexed_transcript_entries(self._by_id, self._leaf_id or vim.NIL, segment_id, direction)
  end
  if not entries then
    return nil, util.error("session", "Failed to build session transcript", err)
  end
  return entries, nil, history
end

---@return Neoagent.SelectionState?, Neoagent.Error?
function Session:state()
  if self._store and type(self._store.state) == "function" then
    return self._store:state()
  end
  local path, err = self:path()
  if not path then
    return nil, err
  end
  return tree.state(path)
end

---@param values Neoagent.CompactionPayload
---@return Neoagent.RequestMessage[]?, Neoagent.Error?
function Session:preview_compaction(values)
  local path, path_err = self:path()
  if not path then
    return nil, path_err
  end
  return tree.preview_compaction(path, values)
end

---@param values Neoagent.CompactionPayload
---@return true?, Neoagent.Error?, Neoagent.JournalEntry?
function Session:append_compaction(values)
  if self._store then
    if type(self._store.append_compaction) ~= "function" then
      return nil, util.error("session", "Store does not support compaction")
    end
    local ok, err, entry, projection = self._store:append_compaction(values)
    if not ok then
      return nil, util.normalize_error(err, "storage")
    end
    local projected, projection_err = apply_store_projection(self, projection)
    if not projected then
      return nil, projection_err
    end
    return true, nil, entry
  end
  return memory_append(self, "compaction", values)
end

---@param entry_id? string
---@return true?, Neoagent.Error?
function Session:move_to(entry_id)
  if entry_id ~= nil and not self:entry(entry_id) then
    return nil, util.error("session", "Entry not found: " .. tostring(entry_id))
  end
  if self._store then
    if type(self._store.set_leaf) ~= "function" then
      return nil, util.error("session", "Store does not support branching")
    end
    local ok, err, _, projection = self._store:set_leaf(entry_id)
    if not ok then
      return nil, util.normalize_error(err, "storage")
    end
    local projected, projection_err = apply_store_projection(self, projection)
    if not projected then
      return nil, projection_err
    end
  else
    local ok, err = memory_append(self, "leaf", { target_id = entry_id or vim.NIL })
    if not ok then
      return nil, err
    end
  end
  return true
end

---@return Neoagent.SessionMetadata?
function Session:metadata()
  if self._store and type(self._store.metadata) == "function" then
    return util.copy(self._store:metadata())
  end
  if not self._header then
    return nil
  end
  return {
    id = self._id,
    cwd = self._header.cwd,
    created_at = self._header.created_at,
    persisted = false,
    parent_session = self._header.parent_session,
    data = util.copy(self._header.data),
  }
end

---@return string
function Session:id()
  return self._id
end

---@return table
function Session:identity()
  return self._identity
end

---@return Neoagent.SessionStorage?
function Session:store()
  return self._store
end

---@return Neoagent.Files
function Session:files()
  return self._files
end

---@return Neoagent.FileCache?
function Session:file_cache()
  return self._file_cache
end

---@return Neoagent.SessionSnapshot?, Neoagent.Error?
function Session:snapshot()
  local entries = self:entries()
  local validated, err = tree.validate_entries(entries)
  if not validated then
    return nil, util.error("session", "Invalid Session snapshot", err)
  end
  local leaf_id = self:leaf_id()
  if validated.leaf_id ~= leaf_id then
    return nil, util.error("session", "Invalid Session snapshot", "active leaf does not match the entry journal")
  end
  local metadata = self:metadata()
  return {
    id = self._id,
    workspace = metadata and metadata.cwd or nil,
    created_at = metadata and metadata.created_at or nil,
    parent_session = metadata and metadata.parent_session or nil,
    metadata = metadata and util.copy(metadata.data) or nil,
    entries = entries,
    leaf_id = leaf_id,
  }
end

---@param opts? Neoagent.SessionOptions
---@return Neoagent.Session?, Neoagent.Error?
---@return_overload Neoagent.Session
---@return_overload nil, Neoagent.Error
function M.new(opts)
  opts = opts or {}
  if
    opts.store ~= nil
    and (
      type(opts.store) ~= "table"
      or type(opts.store.load) ~= "function"
      or type(opts.store.append) ~= "function"
      or opts.store.files ~= nil and type(opts.store.files) ~= "function"
      or opts.store.file_cache ~= nil and type(opts.store.file_cache) ~= "function"
    )
  then
    return nil, util.error("session", "store does not implement the storage contract")
  end
  local attachment_store = opts.store and opts.store.files and opts.store:files() or opts.files
  if attachment_store ~= nil and not files.writable(attachment_store) then
    return nil, util.error("session", "Session requires a complete attachment store")
  end
  if opts.store and opts.files and attachment_store and attachment_store.identity ~= opts.files.identity then
    return nil, util.error("session", "Session and durable store must share attachment storage")
  end
  attachment_store = attachment_store or require("neoagent.files.memory").new()
  local cache = opts.store and opts.store.file_cache and opts.store:file_cache() or opts.file_cache
  if
    cache
    and (
      type(cache.read) ~= "function"
      or type(cache.publish) ~= "function"
      or cache.scope ~= attachment_store.identity
    )
  then
    return nil, util.error("session", "Upload cache must belong to the Session's file store")
  end
  local sources = 0
  for _, name in ipairs({ "messages", "entries", "store" }) do
    if opts[name] ~= nil then
      sources = sources + 1
    end
  end
  if sources > 1 then
    return nil, util.error("session", "messages, entries, and store are mutually exclusive")
  end
  local projection = assert(projections.new())
  ---@type Neoagent.JournalEntry[]
  local entries = {}
  ---@type Neoagent.JournalIndex
  local by_id = {}
  ---@type string?
  local leaf_id
  ---@type Neoagent.SessionMetadata?
  local store_metadata
  if opts.store ~= nil then
    local shared = projections.for_store(opts.store)
    if shared then
      projection = shared
    else
      local loaded, err = opts.store:load()
      if not loaded then
        return nil, util.normalize_error(err, "storage")
      end
      local normalized, message_err = projections.new(loaded)
      if not normalized then
        return nil, util.error("storage", "Store returned invalid messages", message_err)
      end
      projection = normalized
    end
    if type(opts.store.metadata) == "function" then
      store_metadata = opts.store:metadata()
    end
  elseif opts.entries ~= nil then
    if type(opts.entries) ~= "table" or not util.is_list(opts.entries) then
      return nil, util.error("session", "entries must be an array")
    end
    local validated, err = tree.validate_entries(opts.entries)
    if not validated then
      return nil, util.error("session", "Invalid Session entries", err)
    end
    if opts.leaf_id ~= nil and opts.leaf_id ~= validated.leaf_id then
      return nil, util.error("session", "Invalid Session entries", "active leaf does not match the entry journal")
    end
    entries = validated.entries
    by_id = validated.by_id
    leaf_id = validated.leaf_id
    local path, path_err = tree.indexed_path(by_id, leaf_id == nil and vim.NIL or leaf_id)
    if not path then
      return nil, util.error("session", "Invalid Session entries", path_err)
    end
    projection:replace(tree.messages(path, false))
  elseif opts.messages ~= nil then
    if type(opts.messages) ~= "table" or not util.is_list(opts.messages) then
      return nil, util.error("session", "messages must be an array")
    end
    local messages, message_err = semantic_message.normalize_list(opts.messages)
    if not messages then
      return nil, util.error("session", "Invalid Session messages", message_err)
    end
    local published, attachment_err = files.check_messages(attachment_store, messages)
    if not published then
      return nil, attachment_err
    end
    for _, message in ipairs(messages) do
      ---@type Neoagent.MessageEntry
      local entry = {
        type = "message",
        id = random_id(),
        parent_id = leaf_id or vim.NIL,
        created_at = util.now_ms(),
        message = util.copy(message),
      }
      entries[#entries + 1] = entry
      by_id[entry.id] = entry
      leaf_id = entry.id
    end
    projection:replace(messages)
  end
  local id = opts.id
  if id == nil then
    id = store_metadata and store_metadata.id or random_id(12)
  end
  if type(id) ~= "string" or id == "" then
    return nil, util.error("session", "Session id must be a non-empty string")
  end
  local explicit_header = opts.workspace ~= nil
    or opts.metadata ~= nil
    or opts.created_at ~= nil
    or opts.parent_session ~= nil
    or opts.id ~= nil
  ---@type Neoagent.SessionHeader?
  local header
  if explicit_header and not opts.store then
    header = {
      cwd = opts.workspace,
      created_at = opts.created_at or util.now_ms(),
      parent_session = opts.parent_session,
      data = util.copy(opts.metadata),
    }
  end
  return setmetatable({
    _id = id,
    _identity = {},
    _header = header,
    _projection = projection,
    _store = opts.store,
    _files = attachment_store,
    _file_cache = cache,
    _entries = entries,
    _by_id = by_id,
    _leaf_id = leaf_id,
  }, Session)
end

return M
