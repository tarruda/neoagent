local semantic_message = require("neoagent.semantic_message")
local util = require("neoagent.util")

local M = {}
local Steering = {}
Steering.__index = Steering

local function copy_record(record)
  return record and util.copy(record) or nil
end

local function index_of(self, id)
  for index, record in ipairs(self._records) do
    if record.id == id then return index, record end
  end
end

function Steering.new()
  return setmetatable({
    _records = {},
    _offered = nil,
  }, Steering)
end

function Steering:enqueue(id, text, timestamp)
  if type(id) ~= "number" or id < 1 or id % 1 ~= 0 then
    return nil, util.error("steering", "steering id must be a positive integer")
  end
  if type(text) ~= "string" or util.trim(text) == "" then
    return nil, util.error("steering", "steering text must contain content")
  end
  if type(timestamp) ~= "number" or timestamp < 0 or timestamp % 1 ~= 0
      or timestamp ~= timestamp or timestamp == math.huge then
    return nil, util.error("steering",
      "steering timestamp must be a non-negative integer")
  end
  if index_of(self, id) then
    return nil, util.error("steering", "steering ids must be unique")
  end
  local message, message_err = semantic_message.normalize({
    role = "user",
    content = text,
    timestamp = timestamp,
  })
  if not message then
    return nil, util.error("steering", "invalid steering message", message_err)
  end
  local record = { id = id, message = message }
  self._records[#self._records + 1] = record
  return copy_record(record)
end

function Steering:first()
  return copy_record(self._records[1])
end

function Steering:texts()
  return vim.tbl_map(function(record)
    return record.message.content
  end, self._records)
end

function Steering:offer()
  assert(self._offered == nil,
    "a steering record is already awaiting acknowledgement")
  local record = self._records[1]
  if not record then return nil end
  self._offered = record
  local active = true
  local function acknowledge(committed)
    if not active then return false end
    active = false
    if self._offered == record then self._offered = nil end
    if committed then
      local index, current = index_of(self, record.id)
      if current == record then table.remove(self._records, index) end
    end
    return copy_record(record)
  end
  return copy_record(record), acknowledge
end

function Steering:claim(id)
  assert(type(id) == "number" and id >= 1 and id % 1 == 0,
    "steering id must be a positive integer")
  if self._offered then
    return nil, util.error("steering",
      "Cannot claim steering while acknowledgement is pending")
  end
  local index, record = index_of(self, id)
  if not record then
    return nil, util.error("steering", "Steering submission is unavailable")
  end
  table.remove(self._records, index)
  local active = true
  local claim = { record = copy_record(record) }
  function claim:commit()
    if not active then return false end
    active = false
    return true
  end
  function claim:rollback()
    if not active then return false end
    active = false
    table.insert(self._owner._records,
      math.min(index, #self._owner._records + 1), record)
    return true
  end
  claim._owner = self
  return claim
end

function Steering:dequeue_all()
  assert(self._offered == nil,
    "cannot dequeue steering while acknowledgement is pending")
  local records = util.copy(self._records)
  self._records = {}
  return records
end

function Steering:clear()
  assert(self._offered == nil,
    "cannot clear steering while acknowledgement is pending")
  local changed = #self._records > 0
  self._records = {}
  return changed
end

function Steering:count()
  return #self._records
end

M.new = Steering.new
M.Steering = Steering

return M
