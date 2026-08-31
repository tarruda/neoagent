local util = require("neoagent.util")
local tree = require("neoagent.session_tree")

local M = {}
local Session = {}
Session.__index = Session

local function random_id(bytes)
  return (vim.uv.random(bytes or 8):gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

local function iso_time()
  local ms = util.now_ms()
  return os.date("!%Y-%m-%dT%H:%M:%S", math.floor(ms / 1000)) .. string.format(".%03dZ", ms % 1000)
end

local function memory_append(self, entry_type, values)
  local entry = {
    type = entry_type,
    id = random_id(),
    parentId = self._leaf_id or vim.NIL,
    timestamp = iso_time(),
  }
  for key, value in pairs(values or {}) do entry[key] = util.copy(value) end
  local valid, err = tree.validate_entry(entry)
  if not valid then return nil, util.error("session", "Invalid " .. tostring(entry_type), err) end
  if self._by_id[entry.id] then
    return nil, util.error("session", "Invalid " .. tostring(entry_type), "duplicate entry id")
  end
  local references, reference_err = tree.validate_references(entry, self._by_id)
  if not references then
    return nil, util.error("session", "Invalid " .. tostring(entry_type), reference_err)
  end
  self._entries[#self._entries + 1] = entry
  self._by_id[entry.id] = entry
  if entry.type == "leaf" then
    self._leaf_id = (entry.targetId == nil or entry.targetId == vim.NIL) and nil or entry.targetId
    local path = assert(tree.indexed_path(self._by_id,
      self._leaf_id == nil and vim.NIL or self._leaf_id))
    self._messages = tree.messages(path, false)
  else
    self._leaf_id = entry.id
    vim.list_extend(self._messages, tree.entry_messages(entry))
  end
  return true, nil, util.copy(entry)
end

local function apply_store_projection(self, projection)
  if type(projection) ~= "table" or type(projection.messages) ~= "table"
      or not util.is_list(projection.messages) then
    return nil, util.error("storage", "Store returned an invalid projection")
  end
  if projection.type == "append" then
    vim.list_extend(self._messages, util.copy(projection.messages))
    return true
  end
  if projection.type == "replace" then
    self._messages = util.copy(projection.messages)
    return true
  end
  return nil, util.error("storage", "Store returned an unknown projection")
end

local function same_model(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.provider == right.provider and left.model == right.model
end

local function restore_memory(self, entries, messages, leaf_id)
  self._entries = entries
  self._messages = messages
  self._leaf_id = leaf_id
  self._by_id = {}
  for _, entry in ipairs(entries) do self._by_id[entry.id] = entry end
end

local function memory_append_message(self, message, state)
  if state.model == nil and state.thinking_level == nil then
    return memory_append(self, "message", { message = message })
  end
  local stored = assert(self:state())
  local model_changed = state.model ~= nil
    and not same_model(state.model, stored.model)
  local thinking_changed = state.thinking_level ~= nil
    and state.thinking_level ~= stored.thinking_level
  if not model_changed and not thinking_changed then
    return memory_append(self, "message", { message = message })
  end
  local entries = util.copy(self._entries)
  local messages = util.copy(self._messages)
  local leaf_id = self._leaf_id
  local function append_state(entry_type, values)
    local ok, err = memory_append(self, entry_type, values)
    if not ok then
      restore_memory(self, entries, messages, leaf_id)
      return nil, err
    end
    return true
  end
  if model_changed then
    local ok, err = append_state("model_change", {
      provider = state.model.provider,
      modelId = state.model.model,
    })
    if not ok then return nil, err end
  end
  if thinking_changed then
    local ok, err = append_state("thinking_level_change", {
      thinkingLevel = state.thinking_level,
    })
    if not ok then return nil, err end
  end
  local ok, err, entry = memory_append(self, "message", { message = message })
  if not ok then
    restore_memory(self, entries, messages, leaf_id)
    return nil, err
  end
  return true, nil, entry
end

function Session:append(message, state)
  assert(type(message) == "table", "message must be a table")
  assert(state == nil or type(state) == "table"
      and (next(state) == nil or not util.is_list(state)),
    "message state must be an object")
  local copy = util.copy(message)
  state = util.copy(state or {})
  if self._store then
    local ok, err, entry, projection = self._store:append(copy, state)
    if not ok then
      return nil, util.normalize_error(err, "storage")
    end
    local projected, projection_err = apply_store_projection(self, projection)
    if not projected then return nil, projection_err end
    return true, nil, entry
  end
  return memory_append_message(self, copy, state)
end

function Session:messages()
  return util.copy(self._messages)
end

function Session:context_messages()
  if self._store and type(self._store.context_messages) == "function" then
    local messages, err = self._store:context_messages()
    if not messages then return nil, util.normalize_error(err, "storage") end
    return messages
  end
  if #self._entries > 0 then
    local path, err = self:path()
    if not path then return nil, err end
    return tree.to_llm(tree.messages(path, true))
  end
  return tree.to_llm(self._messages)
end

function Session:entries()
  if self._store and type(self._store.entries) == "function" then return self._store:entries() end
  return util.copy(self._entries)
end

function Session:entry(id)
  if self._store and type(self._store.entry) == "function" then return self._store:entry(id) end
  return util.copy(self._by_id[id])
end

function Session:leaf_id()
  if self._store and type(self._store.leaf_id) == "function" then return self._store:leaf_id() end
  return self._leaf_id
end

function Session:path(...)
  if self._store and type(self._store.path) == "function" then return self._store:path(...) end
  local requested
  if select("#", ...) > 0 then
    requested = select(1, ...)
  else
    requested = self._leaf_id
  end
  if requested == nil then requested = vim.NIL end
  local path, err = tree.indexed_path(self._by_id, requested)
  if not path then return nil, util.error("session", "Failed to build session path", err) end
  return path
end

function Session:state()
  if self._store and type(self._store.state) == "function" then return self._store:state() end
  local path, err = self:path()
  if not path then return nil, err end
  return tree.state(path)
end

function Session:append_compaction(values)
  if self._store then
    if type(self._store.append_compaction) ~= "function" then
      return nil, util.error("session", "Store does not support compaction")
    end
    local ok, err, entry, projection = self._store:append_compaction(values)
    if not ok then return nil, util.normalize_error(err, "storage") end
    local projected, projection_err = apply_store_projection(self, projection)
    if not projected then return nil, projection_err end
    return true, nil, entry
  end
  return memory_append(self, "compaction", values)
end

function Session:move_to(entry_id)
  if entry_id ~= nil and not self:entry(entry_id) then
    return nil, util.error("session", "Entry not found: " .. tostring(entry_id))
  end
  if self._store then
    if type(self._store.set_leaf) ~= "function" then
      return nil, util.error("session", "Store does not support branching")
    end
    local ok, err, _, projection = self._store:set_leaf(entry_id)
    if not ok then return nil, util.normalize_error(err, "storage") end
    local projected, projection_err = apply_store_projection(self, projection)
    if not projected then return nil, projection_err end
  else
    local ok, err = memory_append(self, "leaf", { targetId = entry_id or vim.NIL })
    if not ok then return nil, err end
  end
  return true
end

function Session:metadata()
  if self._store then return util.copy(self._store:metadata()) end
  if not self._header then return nil end
  return {
    id = self._id,
    cwd = self._header.cwd,
    timestamp = self._header.timestamp,
    persisted = false,
    parent_session = self._header.parent_session,
    data = util.copy(self._header.data),
  }
end

function Session:id()
  return self._id
end

function Session:identity()
  return self._identity
end

function Session:store()
  return self._store
end

function Session:snapshot()
  local entries = self:entries()
  local validated, err = tree.validate_entries(entries)
  if not validated then
    return nil, util.error("session", "Invalid Session snapshot", err)
  end
  local leaf_id = self:leaf_id()
  if validated.leaf_id ~= leaf_id then
    return nil, util.error("session", "Invalid Session snapshot",
      "active leaf does not match the entry journal")
  end
  local metadata = self:metadata()
  return {
    id = self._id,
    workspace = metadata and metadata.cwd or nil,
    timestamp = metadata and metadata.timestamp or nil,
    parent_session = metadata and metadata.parent_session or nil,
    metadata = metadata and util.copy(metadata.data) or nil,
    entries = entries,
    leaf_id = leaf_id,
  }
end

function M.new(opts)
  opts = opts or {}
  local sources = 0
  for _, name in ipairs({ "messages", "entries", "store" }) do
    if opts[name] ~= nil then sources = sources + 1 end
  end
  if sources > 1 then
    return nil, util.error("session",
      "messages, entries, and store are mutually exclusive")
  end
  local messages = {}
  local entries = {}
  local by_id = {}
  local leaf_id
  local store_metadata
  if opts.store ~= nil then
    if type(opts.store) ~= "table"
        or type(opts.store.load) ~= "function"
        or type(opts.store.append) ~= "function" then
      return nil, util.error("session", "store does not implement the storage contract")
    end
    local loaded, err = opts.store:load()
    if not loaded then
      return nil, util.normalize_error(err, "storage")
    end
    messages = util.copy(loaded)
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
      return nil, util.error("session", "Invalid Session entries",
        "active leaf does not match the entry journal")
    end
    entries = util.copy(opts.entries)
    validated = assert(tree.validate_entries(entries))
    by_id = validated.by_id
    leaf_id = validated.leaf_id
    local path, path_err = tree.indexed_path(by_id,
      leaf_id == nil and vim.NIL or leaf_id)
    if not path then
      return nil, util.error("session", "Invalid Session entries", path_err)
    end
    messages = tree.messages(path, false)
  elseif opts.messages ~= nil then
    if type(opts.messages) ~= "table" or not util.is_list(opts.messages) then
      return nil, util.error("session", "messages must be an array")
    end
    messages = util.copy(opts.messages)
    for _, message in ipairs(messages) do
      local entry = {
        type = "message", id = random_id(), parentId = leaf_id or vim.NIL,
        timestamp = iso_time(), message = util.copy(message),
      }
      entries[#entries + 1] = entry
      by_id[entry.id] = entry
      leaf_id = entry.id
    end
  end
  local id = opts.id
  if id == nil then
    id = store_metadata and store_metadata.id or random_id(12)
  end
  if type(id) ~= "string" or id == "" then
    return nil, util.error("session", "Session id must be a non-empty string")
  end
  local explicit_header = opts.workspace ~= nil or opts.metadata ~= nil
    or opts.timestamp ~= nil or opts.parent_session ~= nil or opts.id ~= nil
  local header
  if explicit_header and not opts.store then
    header = {
      cwd = opts.workspace,
      timestamp = opts.timestamp or iso_time(),
      parent_session = opts.parent_session,
      data = util.copy(opts.metadata),
    }
  end
  return setmetatable({
    _id = id,
    _identity = {},
    _header = header,
    _messages = messages,
    _store = opts.store,
    _entries = entries,
    _by_id = by_id,
    _leaf_id = leaf_id,
  }, Session)
end

return M
