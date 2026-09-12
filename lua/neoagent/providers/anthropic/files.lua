local async = require("neoagent.async")
local files = require("neoagent.files")
local http = require("neoagent.transport.http")
local multipart = require("neoagent.transport.multipart")
local util = require("neoagent.util")
local M = {}
local URL = "https://api.anthropic.com/v1/files"
local extensions = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif", ["image/webp"] = "webp" }

---@param value unknown
---@return number?
local function deadline(value)
  if type(value) ~= "string" then
    return nil
  end
  local year, month, day, hour, minute, second, suffix =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
  if not year then
    return nil
  end
  local y, m, d = assert(tonumber(year)), assert(tonumber(month)), assert(tonumber(day))
  local h, min, sec = assert(tonumber(hour)), assert(tonumber(minute)), assert(tonumber(second))
  suffix = assert(suffix)
  local fraction, zone = suffix:match("^(%.%d+)(.*)$")
  zone = zone or suffix
  ---@type number
  local offset = 0
  if zone ~= "Z" then
    local sign, zh, zm = zone:match("^([+-])(%d%d):(%d%d)$")
    if not sign or assert(tonumber(zh)) > 23 or assert(tonumber(zm)) > 59 then
      return nil
    end
    offset = (assert(tonumber(zh)) * 60 + assert(tonumber(zm))) * 60 * (sign == "+" and 1 or -1)
  end
  local leap = y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
  local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if y < 1970 or m < 1 or m > 12 or d < 1 or d > days[m] or h > 23 or min > 59 or sec > 59 then
    return nil
  end
  -- Gregorian civil date to days since the Unix epoch, independent of host TZ.
  local civil_year = y - (m <= 2 and 1 or 0)
  local era = math.floor(civil_year / 400)
  local yo = civil_year - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local epoch_days = era * 146097 + yo * 365 + math.floor(yo / 4) - math.floor(yo / 100) + doy - 719468
  return (epoch_days * 86400 + h * 3600 + min * 60 + sec - offset + assert(tonumber(fraction or "0"))) * 1000
end

---@param result Neoagent.HttpResult
---@return number?
local function status(result)
  if result.ok then
    return result.status
  end
  local response = rawget(result.error, "response")
  return type(response) == "table" and response.status or nil
end

---@param result Neoagent.HttpResult
---@param asset? Neoagent.FileAsset
---@param previous? Neoagent.RemoteFile
---@return Neoagent.RemoteFile
local function metadata(result, asset, previous)
  local code = status(result)
  if not result.ok or not code or code < 200 or code >= 300 then
    error(util.error("files", "Anthropic Files request failed" .. (code and " (HTTP " .. code .. ")" or "")), 0)
  end
  local value = result.body
  if
    type(value) ~= "table"
    or value.type ~= "file"
    or type(value.id) ~= "string"
    or not value.id:match("^[%w_-]+$")
    or #value.id > 512
    or type(value.size_bytes) ~= "number"
    or value.size_bytes < 1
    or value.size_bytes % 1 ~= 0
    or not extensions[value.mime_type]
    or (asset and (value.size_bytes ~= asset.bytes or value.mime_type ~= asset.mime_type))
    or (previous and value.id ~= previous.locator)
  then
    error(util.error("files", "Anthropic Files response contains invalid image metadata"), 0)
  end
  local at = deadline(value.expires_at)
  if value.expires_at ~= nil and value.expires_at ~= vim.NIL and (not at or at <= 0) then
    error(util.error("files", "Anthropic Files response contains invalid expiration"), 0)
  end
  return {
    locator = value.id,
    state = "ready",
    lifetime = at and { kind = "deadline", at = at } or { kind = "until_deleted" },
  }
end

---@param opts {transport?: Neoagent.ByteBackend}
---@return Neoagent.FileBackend
function M.new(opts)
  local client = http.new(opts.transport)
  return {
    identity = URL .. ":image",
    upload = function(asset, access, timeout_ms)
      return async.run(function()
        local data, err = files.read(asset.source, asset.file_id, asset.bytes)
        if not data then
          error(err, 0)
        end
        if #data ~= asset.bytes then
          error(files.error("Attachment size does not match stored content"), 0)
        end
        local body, content_type = multipart.encode({
          {
            name = "file",
            value = data,
            filename = "image." .. assert(extensions[asset.mime_type], "unsupported image MIME type"),
            mime_type = asset.mime_type,
          },
        })
        local headers = util.copy(access.headers)
        headers["Content-Type"], headers["Content-Length"] = content_type, tostring(#body)
        local result = client
          .with_context({ origin = "file-upload" })
          .fetch({
            request = {
              method = "POST",
              url = URL,
              headers = headers,
              body = body,
              timeout_ms = timeout_ms,
              max_response_bytes = 65536,
            },
          })
          :await()
        return { ok = true, object = metadata(result, asset) }
      end, { error_kind = "files" })
    end,
    inspect = function(object, access, timeout_ms)
      return async.run(function()
        if not object.locator:match("^[%w_-]+$") then
          return { ok = true }
        end
        local result = client
          .fetch({
            request = {
              method = "GET",
              url = URL .. "/" .. object.locator,
              headers = util.copy(access.headers),
              timeout_ms = timeout_ms,
              max_response_bytes = 65536,
            },
          })
          :await()
        if status(result) == 404 then
          return { ok = true }
        end
        return { ok = true, object = metadata(result, nil, object) }
      end, { error_kind = "files" })
    end,
  }
end

return M
