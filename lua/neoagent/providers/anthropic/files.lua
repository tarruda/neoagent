local async = require("neoagent.async")
local files = require("neoagent.files")
local http = require("neoagent.transport.http")
local multipart = require("neoagent.transport.multipart")
local util = require("neoagent.util")
local file_http = require("neoagent.files.http")
local M = {}
local URL = "https://api.anthropic.com/v1/files"
local extensions = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif", ["image/webp"] = "webp" }

---@param result Neoagent.HttpResult
---@param asset? Neoagent.FileAsset
---@param previous? Neoagent.RemoteFile
---@return Neoagent.RemoteFile
local function metadata(result, asset, previous)
  local value = file_http.checked(result, "Anthropic Files", previous ~= nil)
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
  local at = util.parse_rfc3339_ms(value.expires_at)
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
        local result = file_http.get(client, {
          method = "GET",
          url = URL .. "/" .. object.locator,
          headers = util.copy(access.headers),
          max_response_bytes = 65536,
        }, timeout_ms)
        if file_http.status(result) == 404 then
          return { ok = true }
        end
        return { ok = true, object = metadata(result, nil, object) }
      end, { error_kind = "files" })
    end,
  }
end

return M
