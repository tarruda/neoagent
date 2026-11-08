local util = require("neoagent.util")
local tree = require("neoagent.session_tree")
local linkage = require("neoagent.message_linkage")

local M = {}

---@class Neoagent.SessionProjectionState
---@field messages Neoagent.ProjectionMessage[]
---@field linkage Neoagent.MessageLinkage
local State = {}
State.__index = State

-- A durable Store and its Session facades observe one accepted projection.
-- Keep this composition internal; injected Stores cross the normalization
-- boundary when they return messages or projection updates.
---@type table<Neoagent.SessionStorage, Neoagent.SessionProjectionState>
local owners = setmetatable({}, { __mode = "k" })

---@param messages Neoagent.ProjectionMessage[]
---@param base? Neoagent.MessageLinkage
---@param offset? integer
---@return Neoagent.MessageLinkageUpdate?, string?
local function stage(messages, base, offset)
  local update = linkage.stage(base)
  for index, message in ipairs(messages) do
    if message.role == "compactionSummary" or message.role == "compactionCheckpoint" then
      linkage.reset(update)
    else
      local accepted, err = linkage.check(update, message, (offset or 0) + index)
      if not accepted then
        return nil, err
      end
    end
  end
  return update
end

---@param messages? unknown
---@return Neoagent.SessionProjectionState?, string?
function M.new(messages)
  ---@type Neoagent.ProjectionMessage[]
  local normalized = {}
  if messages ~= nil then
    local accepted, err = tree.normalize_projection(messages)
    if not accepted then
      return nil, err
    end
    normalized = accepted
  end
  return setmetatable({
    messages = normalized,
    linkage = linkage.commit(assert(stage(normalized))),
  }, State)
end

---@param store Neoagent.SessionStorage
---@return Neoagent.SessionProjectionState?
function M.for_store(store)
  return owners[store]
end

---@param store Neoagent.SessionStorage
function State:bind(store)
  assert(owners[store] == nil, "Store already owns a Session projection")
  owners[store] = self
end

-- Entries have already crossed the journal's validation boundary. Their
-- projection contains owned copies and only needs conversation linkage.
---@param messages Neoagent.ProjectionMessage[]
function State:replace(messages)
  self.linkage = linkage.commit(assert(stage(messages)))
  self.messages = messages
end

---@param messages Neoagent.ProjectionMessage[]
---@return true?, string?
function State:append(messages)
  local update, err = stage(messages, self.linkage, #self.messages)
  if not update then
    return nil, err
  end
  vim.list_extend(self.messages, messages)
  self.linkage = linkage.commit(update)
  return true
end

---@param message Neoagent.Message
---@return true?, string?
function State:check(message)
  local update, err = stage({ message }, self.linkage, #self.messages)
  return update and true or nil, err
end

---@param projection unknown
---@return true?, Neoagent.Error?
function State:accept(projection)
  if type(projection) ~= "table" or type(projection.messages) ~= "table" or not util.is_list(projection.messages) then
    return nil, util.error("storage", "Store returned an invalid projection")
  end
  if projection.type == "append" then
    ---@type Neoagent.ProjectionMessage[]
    local normalized = {}
    for index, message in ipairs(projection.messages) do
      local value, err = tree.normalize_projection_message(message)
      if not value then
        return nil, util.error("storage", "Store returned invalid messages", "message " .. index .. ": " .. err)
      end
      normalized[index] = value
    end
    local accepted, err = self:append(normalized)
    if not accepted then
      return nil, util.error("storage", "Store returned invalid messages", err)
    end
    return true
  end
  if projection.type == "replace" then
    local normalized, err = tree.normalize_projection(projection.messages)
    if not normalized then
      return nil, util.error("storage", "Store returned invalid messages", err)
    end
    self:replace(normalized)
    return true
  end
  return nil, util.error("storage", "Store returned an unknown projection")
end

return M
