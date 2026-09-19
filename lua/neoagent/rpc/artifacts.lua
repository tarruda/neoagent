local digest = require("neoagent.files.digest")
local files = require("neoagent.files")
local limits = require("neoagent.rpc.limits")
local util = require("neoagent.util")

local M = {}

---@param send fun(message: table)
---@return Neoagent.ToolArtifactPublisher
function M.publisher(send)
  local sequence = 0
  local aggregate = 0
  return {
    ---@async
    put = function(data)
      assert(type(data) == "string", "artifact bytes must be a string")
      if #data == 0 or #data > limits.MAX_ARTIFACT_BYTES then
        return nil, require("neoagent.files").error("Tool artifact exceeds the byte limit")
      end
      if aggregate + #data > limits.MAX_ARTIFACTS_BYTES then
        return nil, require("neoagent.files").error("Tool artifacts exceed the aggregate byte limit")
      end
      aggregate = aggregate + #data
      sequence = sequence + 1
      local file_id = digest.sha256(data)
      send({
        type = "artifact_begin",
        artifact_id = sequence,
        file_id = file_id,
        bytes = #data,
      })
      local offset = 1
      while offset <= #data do
        send({
          type = "artifact_chunk",
          artifact_id = sequence,
          data = data:sub(offset, offset + limits.MAX_ARTIFACT_CHUNK_BYTES - 1),
        })
        offset = offset + limits.MAX_ARTIFACT_CHUNK_BYTES
      end
      send({
        type = "artifact_end",
        artifact_id = sequence,
      })
      return { file_id = file_id, bytes = #data }
    end,
  }
end

---@class Neoagent.RpcArtifact
---@field file_id string
---@field bytes integer
---@field chunks string[]
---@field received integer

---@class Neoagent.RpcArtifactImporter
---@field _call Neoagent.ToolOperationCall
---@field _active table<integer, Neoagent.RpcArtifact>
---@field _imported table<string, Neoagent.LocalFile>
---@field _aggregate integer
---@field _last_id integer
local Importer = {}
Importer.__index = Importer

---@param value unknown
---@param label string
---@return integer
local function positive_integer(value, label)
  assert(type(value) == "number" and value > 0 and value % 1 == 0, label .. " must be a positive integer")
  ---@cast value integer
  return value
end

---@param message table
---@param allowed table<string, boolean>
local function exact(message, allowed)
  assert(type(message) == "table" and not util.is_list(message), "RPC artifact event must be an object")
  for key in pairs(message) do
    assert(type(key) == "string" and allowed[key], "RPC artifact event has an unknown field")
  end
  for key in pairs(allowed) do
    assert(rawget(message, key) ~= nil, "RPC artifact event is missing " .. key)
  end
end

---@async
---@param message table
function Importer:accept(message)
  if message.type == "artifact_begin" then
    exact(message, { type = true, artifact_id = true, file_id = true, bytes = true })
    local artifact_id = positive_integer(message.artifact_id, "RPC artifact ID")
    assert(files.valid_id(message.file_id), "RPC artifact file ID is invalid")
    local bytes = positive_integer(message.bytes, "RPC artifact size")
    assert(bytes <= limits.MAX_ARTIFACT_BYTES, "RPC artifact exceeds the byte limit")
    if artifact_id ~= self._last_id + 1 or next(self._active) ~= nil then
      error("RPC artifact order is invalid", 0)
    end
    if self._active[artifact_id] or self._imported[message.file_id] then
      error("duplicate RPC artifact", 0)
    end
    if self._aggregate + bytes > limits.MAX_ARTIFACTS_BYTES then
      error("RPC artifacts exceed the aggregate byte limit", 0)
    end
    self._aggregate = self._aggregate + bytes
    self._last_id = artifact_id
    self._active[artifact_id] = {
      file_id = message.file_id,
      bytes = bytes,
      chunks = {},
      received = 0,
    }
    return
  end
  if message.type == "artifact_chunk" then
    exact(message, { type = true, artifact_id = true, data = true })
    assert(
      type(message.data) == "string"
        and message.data ~= ""
        and #message.data <= limits.MAX_ARTIFACT_CHUNK_BYTES,
      "RPC artifact chunk is invalid"
    )
  else
    assert(message.type == "artifact_end", "unexpected artifact event")
    exact(message, { type = true, artifact_id = true })
  end
  local artifact_id = positive_integer(message.artifact_id, "RPC artifact ID")
  local active = self._active[artifact_id]
  if not active then
    error("RPC artifact event has no active artifact", 0)
  end
  if message.type == "artifact_chunk" then
    if active.received + #message.data > active.bytes then
      error("RPC artifact contains excess bytes", 0)
    end
    active.chunks[#active.chunks + 1] = message.data
    active.received = active.received + #message.data
    return
  end
  self._active[artifact_id] = nil
  if active.received ~= active.bytes then
    error("RPC artifact is incomplete", 0)
  end
  local data = table.concat(active.chunks)
  if digest.sha256(data) ~= active.file_id then
    error("RPC artifact digest does not match its bytes", 0)
  end
  local publisher = self._call.artifacts
  if not publisher then
    error("Tool image result requires a writable attachment store", 0)
  end
  local stored, err = publisher.put(data)
  if not stored then
    error(err, 0)
  end
  if stored.file_id ~= active.file_id or stored.bytes ~= active.bytes then
    error("Parent attachment store changed the artifact identity", 0)
  end
  self._imported[stored.file_id] = stored
end

---@param result Neoagent.ToolResult
function Importer:check_result(result)
  if next(self._active) ~= nil then
    error("RPC result arrived before its artifacts completed", 0)
  end
  for _, block in ipairs(result.content) do
    if block.type == "image" then
      local imported = self._imported[block.file_id]
      if not imported or imported.bytes ~= block.bytes then
        error("RPC result references an unimported artifact", 0)
      end
    end
  end
end

function Importer:discard()
  self._active = {}
  self._imported = {}
end

---@param call Neoagent.ToolOperationCall
---@return Neoagent.RpcArtifactImporter
function M.importer(call)
  return setmetatable({
    _call = call,
    _active = {},
    _imported = {},
    _aggregate = 0,
    _last_id = 0,
  }, Importer)
end

return M
