local util = require("neoagent.util")
local tree = require("neoagent.session_tree")

local M = {}
local Session = {}
Session.__index = Session

local function random_id()
  return (vim.uv.random(8):gsub(".", function(char)
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
  if entry.type == "leaf" and entry.targetId ~= nil and entry.targetId ~= vim.NIL
      and not self._by_id[entry.targetId] then
    return nil, util.error("session", "Invalid leaf", "entry not found: " .. tostring(entry.targetId))
  end
  if entry.type == "label" and not self._by_id[entry.targetId] then
    return nil, util.error("session", "Invalid label", "entry not found: " .. tostring(entry.targetId))
  end
  if entry.type == "compaction" and not self._by_id[entry.firstKeptEntryId] then
    return nil, util.error("session", "Invalid compaction", "entry not found: " .. tostring(entry.firstKeptEntryId))
  end
  self._entries[#self._entries + 1] = entry
  self._by_id[entry.id] = entry
  self._leaf_id = entry.type == "leaf"
      and ((entry.targetId == nil or entry.targetId == vim.NIL) and nil or entry.targetId) or entry.id
  local path = assert(tree.path(self._entries, self._leaf_id == nil and vim.NIL or self._leaf_id))
  self._messages = tree.messages(path, false)
  return true, nil, util.copy(entry)
end

function Session:append(message)
  assert(type(message) == "table", "message must be a table")
  local copy = util.copy(message)
  if self._store then
    local ok, err = self._store:append(copy)
    if not ok then
      return nil, util.normalize_error(err, "storage")
    end
    local loaded, load_err = self._store:load()
    if not loaded then return nil, util.normalize_error(load_err, "storage") end
    self._messages = util.copy(loaded)
    return true
  end
  return memory_append(self, "message", { message = copy })
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
  local requested = select("#", ...) > 0 and select(1, ...) or self._leaf_id
  if requested == nil then requested = vim.NIL end
  local path, err = tree.path(self._entries, requested)
  if not path then return nil, util.error("session", "Failed to build session path", err) end
  return path
end

function Session:state()
  if self._store and type(self._store.state) == "function" then return self._store:state() end
  local path, err = self:path()
  if not path then return nil, err end
  return tree.state(path)
end

function Session:label(id)
  if self._store and type(self._store.label) == "function" then return self._store:label(id) end
  local value
  for _, entry in ipairs(self._entries) do
    if entry.type == "label" and entry.targetId == id then
      value = (entry.label == nil or entry.label == vim.NIL) and nil or entry.label
    end
  end
  return value
end

function Session:name()
  if self._store and type(self._store.name) == "function" then return self._store:name() end
  local value
  for _, entry in ipairs(self._entries) do
    if entry.type == "session_info" and type(entry.name) == "string" and util.trim(entry.name) ~= "" then
      value = util.trim(entry.name)
    end
  end
  return value
end

function Session:append_entry(entry_type, values)
  if self._store then
    if type(self._store.append_entry) ~= "function" then
      return nil, util.error("session", "Store does not support session entries")
    end
    local ok, err, entry = self._store:append_entry(entry_type, values)
    if not ok then return nil, util.normalize_error(err, "storage") end
    self._messages = util.copy(assert(self._store:load()))
    return true, nil, entry
  end
  return memory_append(self, entry_type, values)
end

function Session:move_to(entry_id, summary)
  if entry_id ~= nil and not self:entry(entry_id) then
    return nil, util.error("session", "Entry not found: " .. tostring(entry_id))
  end
  if self._store then
    if type(self._store.set_leaf) ~= "function" then
      return nil, util.error("session", "Store does not support branching")
    end
    local ok, err = self._store:set_leaf(entry_id)
    if not ok then return nil, util.normalize_error(err, "storage") end
    self._messages = util.copy(assert(self._store:load()))
  else
    local ok, err = memory_append(self, "leaf", { targetId = entry_id or vim.NIL })
    if not ok then return nil, err end
  end
  if summary then
    assert(type(summary) == "table" and type(summary.summary) == "string", "summary.summary is required")
    return self:append_entry("branch_summary", {
      fromId = entry_id or "root",
      summary = summary.summary,
      details = summary.details,
      usage = summary.usage,
      fromHook = summary.from_hook,
    })
  end
  return true
end

function Session:metadata()
  if not self._store then
    return nil
  end
  return util.copy(self._store:metadata())
end

function M.new(opts)
  opts = opts or {}
  if opts.messages ~= nil and opts.store ~= nil then
    return nil, util.error("session", "messages and store are mutually exclusive")
  end
  local messages = {}
  local entries = {}
  local by_id = {}
  local leaf_id
  if opts.store then
    if type(opts.store.load) ~= "function" or type(opts.store.append) ~= "function" then
      return nil, util.error("session", "store does not implement the storage contract")
    end
    local loaded, err = opts.store:load()
    if not loaded then
      return nil, util.normalize_error(err, "storage")
    end
    messages = util.copy(loaded)
  elseif opts.messages then
    if type(opts.messages) ~= "table" then
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
  return setmetatable({
    _messages = messages,
    _store = opts.store,
    _entries = entries,
    _by_id = by_id,
    _leaf_id = leaf_id,
  }, Session)
end

return M
