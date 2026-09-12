local M = {}

---@class Neoagent.FileLifetime
---@field kind "deadline"|"until_deleted"|"unknown"
---@field at? number

---@class Neoagent.RemoteFile
---@field locator string Opaque backend-owned object identity, never an access URL.
---@field lifetime Neoagent.FileLifetime
---@field state "ready"|"processing"|"failed"

---@class Neoagent.FileAsset
---@field source Neoagent.FileSource
---@field file_id string SHA-256 of the immutable upload bytes.
---@field mime_type string
---@field bytes integer
---@field filename? string

---@class Neoagent.FileAccess
---@field storage_scope string Non-secret identity derived from the authorized request.
---@field headers table<string, string> Private immutable authorization snapshot.

---@class Neoagent.FileRecord
---@field format "neoagent-provider-file"
---@field key string
---@field generation string
---@field object Neoagent.RemoteFile

---@param value unknown
---@return TypeGuard<Neoagent.RemoteFile>
function M.valid(value)
  if
    type(value) ~= "table"
    or type(value.locator) ~= "string"
    or value.locator == ""
    or #value.locator > 512
    or value.locator:find("[%c%s]")
    or value.locator:find("://", 1, true)
    or type(value.lifetime) ~= "table"
  then
    return false
  end
  for key in pairs(value) do
    if key ~= "locator" and key ~= "lifetime" and key ~= "state" then
      return false
    end
  end
  for key in pairs(value.lifetime) do
    if key ~= "kind" and key ~= "at" then
      return false
    end
  end
  local lifetime = value.lifetime
  if lifetime.kind == "deadline" then
    if type(lifetime.at) ~= "number" or lifetime.at <= 0 or lifetime.at >= math.huge or lifetime.at ~= lifetime.at then
      return false
    end
  elseif (lifetime.kind ~= "until_deleted" and lifetime.kind ~= "unknown") or lifetime.at ~= nil then
    return false
  end
  return value.state == "ready" or value.state == "processing" or value.state == "failed"
end

---@param object Neoagent.RemoteFile
---@param now number
---@param margin number
---@return boolean
function M.usable(object, now, margin)
  -- Remote reuse policy belongs to the concrete backend; this checks only
  -- readiness and a known local deadline in UTC milliseconds.
  return object.state == "ready"
    and (
      object.lifetime.kind == "until_deleted"
      or object.lifetime.kind == "unknown"
      or object.lifetime.kind == "deadline" and assert(object.lifetime.at) > now + margin
    )
end

---@param value unknown
---@return boolean
function M.key(value)
  return type(value) == "string" and #value == 64 and value:match("^[a-f0-9]+$") ~= nil
end

---@param value unknown
---@return TypeGuard<string>
function M.cache_key(value)
  return type(value) == "string"
    and #value == 129
    and value:sub(65, 65) == "/"
    and M.key(value:sub(1, 64))
    and M.key(value:sub(66))
end

---@param value unknown
---@param key string
---@return TypeGuard<Neoagent.FileRecord>
function M.record(value, key)
  if
    type(value) ~= "table"
    or value.format ~= "neoagent-provider-file"
    or not M.cache_key(key)
    or value.key ~= key
    or not M.key(value.generation)
    or not M.valid(value.object)
  then
    return false
  end
  for name in pairs(value) do
    if name ~= "format" and name ~= "key" and name ~= "generation" and name ~= "object" then
      return false
    end
  end
  return true
end

return M
