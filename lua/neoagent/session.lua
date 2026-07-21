local util = require("neoagent.util")

local M = {}
local Session = {}
Session.__index = Session

function Session:append(message)
  assert(type(message) == "table", "message must be a table")
  local copy = util.copy(message)
  if self._store then
    local ok, err = self._store:append(copy)
    if not ok then
      return nil, util.normalize_error(err, "storage")
    end
  end
  self._messages[#self._messages + 1] = copy
  return true
end

function Session:messages()
  return util.copy(self._messages)
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
  end
  return setmetatable({ _messages = messages, _store = opts.store }, Session)
end

return M
