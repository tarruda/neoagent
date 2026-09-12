local async = require("neoagent.async")
local digest = require("neoagent.files.digest")
local util = require("neoagent.util")
local M = {}

---@class Neoagent.LocalFile
---@field file_id string
---@field bytes integer

---@class Neoagent.FileReader
---@field read async fun(): string?, Neoagent.Error?
---@field close fun(): true?, Neoagent.Error?

---@class Neoagent.FileSource
---@field identity string Stable storage identity; copies of a capability retain it.
---@field inspect fun(file_id: string): Neoagent.LocalFile?, Neoagent.Error?
---@field open fun(file_id: string, max_bytes: integer): Neoagent.FileReader?, Neoagent.Error?

---@class Neoagent.Files: Neoagent.FileSource
---@field put async fun(data: string): Neoagent.LocalFile?, Neoagent.Error?

---@param value unknown
---@return TypeGuard<string>
function M.valid_id(value)
  return type(value) == "string" and #value == 64 and value:find("[^0-9a-f]") == nil
end

---@param message string
---@param detail? unknown
---@return Neoagent.Error
function M.error(message, detail)
  return util.error("attachment", message, detail)
end

---@param value unknown
---@return TypeGuard<Neoagent.FileSource>
function M.valid(value)
  return type(value) == "table"
    and type(value.identity) == "string"
    and value.identity ~= ""
    and type(value.inspect) == "function"
    and type(value.open) == "function"
end

---@param value unknown
---@return TypeGuard<Neoagent.Files>
function M.writable(value)
  return M.valid(value) and type(rawget(value, "put")) == "function"
end

---@param maximum integer
function M.check_limit(maximum)
  assert(
    type(maximum) == "number" and maximum >= 0 and maximum % 1 == 0 and maximum < math.huge,
    "attachment byte limit must be a non-negative integer"
  )
end

-- Readers own their resources until close, including cancellation during hashing.
-- No bytes escape before the complete snapshot has passed integrity validation.
---@param file Neoagent.LocalFile
---@param maximum integer
---@param read async fun(maximum: integer): string?, Neoagent.Error?
---@param close fun(): true?, Neoagent.Error?
---@return Neoagent.FileReader
function M.reader(file, maximum, read, close)
  M.check_limit(maximum)
  local closed = false
  ---@type Neoagent.Error?
  local close_error
  ---@type Neoagent.CancelSubscription?
  local unsubscribe
  local function finish()
    if not closed then
      closed = true
      if unsubscribe then
        unsubscribe()
        unsubscribe = nil
      end
      local ok, err = close()
      if not ok then
        close_error = err or M.error("Could not close attachment")
      end
    end
    if close_error then
      return nil, close_error
    end
    return true
  end
  local run = async.current()
  if run then
    unsubscribe = run:on_cancel(finish)
  end
  return {
    close = finish,
    ---@async
    read = function()
      if closed then
        return nil, close_error or M.error("Attachment reader is closed")
      end
      if file.bytes > maximum then
        return nil, M.error("Attachment exceeds the byte limit")
      end
      local data, err = read(maximum)
      if not data then
        return nil, err
      end
      if #data ~= file.bytes or #data > maximum or digest.sha256(data) ~= file.file_id then
        return nil, M.error("Attachment content does not match its file ID")
      end
      return data
    end,
  }
end

---@async
---@param storage Neoagent.FileSource
---@param file_id string
---@param maximum integer
---@return string?, Neoagent.Error?
function M.read(storage, file_id, maximum)
  assert(M.valid(storage), "attachment file reader is required")
  local reader, open_err = storage.open(file_id, maximum)
  if not reader then
    return nil, open_err
  end
  local ok, data, read_err = pcall(reader.read)
  local closed, close_err = reader.close()
  if not ok then
    error(data, 0)
  end
  if not closed then
    return nil, close_err
  end
  return data, read_err
end

---@param storage? Neoagent.FileSource
---@param messages Neoagent.Message[]
---@return true?, Neoagent.Error?
function M.check_messages(storage, messages)
  for _, message in ipairs(messages) do
    if type(message.content) == "table" then
      for _, block in ipairs(message.content) do
        if block.type == "image" then
          if not M.valid(storage) then
            return nil, M.error("Attachment file reader is required")
          end
          local file, err = storage.inspect(block.file_id)
          if not file then
            return nil, err
          end
          if file.bytes ~= block.bytes then
            return nil, M.error("Attachment size does not match stored content")
          end
        end
      end
    end
  end
  return true
end

---@async
---@param source Neoagent.FileSource
---@param destination Neoagent.Files
---@param messages Neoagent.Message[]
---@return true?, Neoagent.Error?
function M.import(source, destination, messages)
  assert(M.valid(source) and M.writable(destination), "source and destination file stores are required")
  local seen = {}
  for _, message in ipairs(messages) do
    if type(message.content) == "table" then
      for _, block in ipairs(message.content) do
        if block.type == "image" and not seen[block.file_id] then
          seen[block.file_id] = true
          if source.identity ~= destination.identity then
            local data, err = M.read(source, block.file_id, block.bytes)
            if not data then
              return nil, err
            end
            local stored, store_err = destination.put(data)
            if not stored then
              return nil, store_err
            end
          end
        end
      end
    end
  end
  return M.check_messages(destination, messages)
end

return M
