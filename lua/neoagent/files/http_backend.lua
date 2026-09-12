local async = require("neoagent.async")
local http = require("neoagent.transport.http")
local multipart = require("neoagent.transport.multipart")
local util = require("neoagent.util")
local files = require("neoagent.files")
local M = {}
local extensions = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif", ["image/webp"] = "webp" }

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
---@param purpose string
---@param bytes? integer
---@param previous? Neoagent.RemoteFile
---@return Neoagent.RemoteFile
local function metadata(result, purpose, bytes, previous)
  local code = status(result)
  if not result.ok or not code or code < 200 or code >= 300 then
    error(util.error("files", "Files request failed" .. (code and " (HTTP " .. code .. ")" or "")), 0)
  end
  local value = result.body
  if
    type(value) ~= "table"
    or value.object ~= "file"
    or type(value.id) ~= "string"
    or not value.id:match("^[%w_-]+$")
    or #value.id > 512
    or value.purpose ~= purpose
    or type(value.bytes) ~= "number"
    or value.bytes < 1
    or value.bytes % 1 ~= 0
    or (bytes and value.bytes ~= bytes)
    or (previous and value.id ~= previous.locator)
    or type(value.expires_at) ~= "number"
    or value.expires_at <= 0
    or value.expires_at >= math.huge
    or value.expires_at ~= value.expires_at
  then
    error(util.error("files", "Files response contains invalid image metadata"), 0)
  end
  return { locator = value.id, state = "ready", lifetime = { kind = "deadline", at = value.expires_at * 1000 } }
end

---@class Neoagent.FilesHttpOptions
---@field url string
---@field purpose string
---@field missing? fun(result: Neoagent.HttpResult): boolean
---@field transport? Neoagent.ByteBackend

---@param opts Neoagent.FilesHttpOptions
---@return Neoagent.FileBackend
function M.new(opts)
  assert(type(opts.url) == "string" and type(opts.purpose) == "string", "Files endpoint and purpose are required")
  local client = http.new(opts.transport)
  return {
    identity = opts.url .. ":" .. opts.purpose .. ":image",
    upload = function(asset, access, timeout_ms)
      return async.run(function()
        local data, read_err = files.read(asset.source, asset.file_id, asset.bytes)
        if not data then
          error(read_err, 0)
        end
        if #data ~= asset.bytes then
          error(files.error("Attachment size does not match stored content"), 0)
        end
        local body, content_type = multipart.encode({
          { name = "purpose", value = opts.purpose },
          { name = "expires_after[anchor]", value = "created_at" },
          { name = "expires_after[seconds]", value = "86400" },
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
              url = opts.url,
              headers = headers,
              body = body,
              timeout_ms = timeout_ms,
              max_response_bytes = 65536,
            },
          })
          :await()
        return { ok = true, object = metadata(result, opts.purpose, asset.bytes) }
      end, { error_kind = "files" })
    end,
    inspect = function(object, access, timeout_ms)
      return async.run(function()
        -- Cache candidates must satisfy this endpoint's identifier contract
        -- before being interpolated into an authenticated request path.
        if not object.locator:match("^[%w_-]+$") then
          return { ok = true }
        end
        local result = client
          .fetch({
            request = {
              method = "GET",
              url = opts.url .. "/" .. object.locator,
              headers = util.copy(access.headers),
              timeout_ms = timeout_ms,
              max_response_bytes = 65536,
            },
          })
          :await()
        if status(result) == 404 or opts.missing and opts.missing(result) then
          return { ok = true }
        end
        return { ok = true, object = metadata(result, opts.purpose, nil, object) }
      end, { error_kind = "files" })
    end,
  }
end

return M
