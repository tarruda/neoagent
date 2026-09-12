local async = require("neoagent.async")
local http = require("neoagent.transport.http")
local util = require("neoagent.util")
local waiting = require("neoagent.files.wait")
local files = require("neoagent.files")
local M = {}

local ROOT = "https://chatgpt.com/backend-api/files"
local extensions = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif", ["image/webp"] = "webp" }

---@param value unknown
---@return TypeGuard<string>
local function file_id(value)
  return type(value) == "string" and #value > 0 and #value <= 512 and value:match("^[%w_-]+$") ~= nil
end

---@param value unknown
---@return TypeGuard<string>
local function storage_url(value)
  return type(value) == "string"
    and #value <= 16384
    and value:match("^https://[%w.-]+/[^%s#]*$") ~= nil
    and not value:find("[%c]")
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
---@return Neoagent.JsonValue?
local function checked(result)
  local code = status(result)
  if not result.ok or not code or code < 200 or code >= 300 then
    -- Raw transport errors may include signed URLs or provider response bodies.
    error(util.error("files", "Codex Files request failed" .. (code and " (HTTP " .. code .. ")" or "")), 0)
  end
  return result.body
end

---@param value unknown
---@param id string
---@param asset? Neoagent.FileAsset
---@return Neoagent.RemoteFile
local function metadata(value, id, asset)
  if
    type(value) ~= "table"
    or value.status ~= "success"
    or not storage_url(value.download_url)
    or value.file_size_bytes ~= nil and value.file_size_bytes ~= vim.NIL and (type(value.file_size_bytes) ~= "number" or value.file_size_bytes < 1 or value.file_size_bytes % 1 ~= 0 or asset and value.file_size_bytes ~= asset.bytes)
    or value.mime_type ~= nil
      and value.mime_type ~= vim.NIL
      and (not extensions[value.mime_type] or asset and value.mime_type ~= asset.mime_type)
  then
    error(util.error("files", "Codex Files response contains invalid image metadata"), 0)
  end
  -- This API supplies no object expiry. The signed download URL has a
  -- separate lifetime and is neither needed for inference nor cached.
  return { locator = id, state = "ready", lifetime = { kind = "unknown" } }
end

---@param opts {transport?: Neoagent.ByteBackend}
---@return Neoagent.FileBackend
function M.new(opts)
  local client = require("neoagent.auth.openai_codex")._files_http(opts.transport)
  local storage = http.new(opts.transport).with_context({ origin = "file-upload" })
  ---@param timeout_ms integer
  ---@return fun(): integer
  ---@return number
  local function budget(timeout_ms)
    local deadline = waiting.now() + timeout_ms
    return function()
      local remaining = math.floor(deadline - waiting.now())
      if remaining <= 0 then
        error(util.error("files", "Codex image preparation timed out"), 0)
      end
      return remaining
    end,
      deadline
  end
  ---@async
  ---@param method string
  ---@param path string
  ---@param access Neoagent.FileAccess
  ---@param remaining fun(): integer
  ---@param body? Neoagent.JsonObject
  ---@return Neoagent.HttpResult
  local function request(method, path, access, remaining, body)
    local headers = util.copy(access.headers)
    if body then
      headers["Content-Type"] = "application/json"
    end
    return client
      .fetch({
        request = {
          method = method,
          url = ROOT .. path,
          headers = headers,
          body = body and util.json_encode(body),
          timeout_ms = remaining(),
          max_response_bytes = 65536,
        },
      })
      :await()
  end
  return {
    identity = ROOT .. ":codex:image",
    upload = function(asset, access, timeout_ms)
      return async.run(function()
        local remaining, deadline = budget(timeout_ms)
        local data, read_err = files.read(asset.source, asset.file_id, asset.bytes)
        if not data then
          error(read_err, 0)
        end
        if #data ~= asset.bytes then
          error(files.error("Attachment size does not match stored content"), 0)
        end
        local extension = assert(extensions[asset.mime_type], "unsupported Codex image MIME type")
        local created = checked(request("POST", "", access, remaining, {
          file_name = "image." .. extension,
          file_size = asset.bytes,
          use_case = "codex",
        }))
        if
          type(created) ~= "table"
          or not file_id(created.file_id)
          or not storage_url(created.upload_url)
          or created.pdf_c2pa_reservation == true
        then
          error(util.error("files", "Codex Files response contains invalid upload metadata"), 0)
        end
        -- This request is authorized by the signed URL alone. Never forward
        -- the ChatGPT bearer token or account header to blob storage.
        checked(storage
          .fetch({
            response_type = "text",
            request = {
              method = "PUT",
              url = created.upload_url,
              body = data,
              headers = { ["x-ms-blob-type"] = "BlockBlob", ["Content-Length"] = tostring(asset.bytes) },
              timeout_ms = remaining(),
              max_response_bytes = 65536,
            },
          })
          :await())
        while true do
          local value =
            checked(request("POST", "/" .. created.file_id .. "/uploaded", access, remaining, vim.empty_dict()))
          if type(value) ~= "table" or value.status ~= "retry" then
            return { ok = true, object = metadata(value, created.file_id, asset) }
          end
          local next_poll = waiting.now() + 250
          waiting.until_ready(function()
            return waiting.now() >= next_poll
          end, deadline, waiting.now)
        end
      end, { error_kind = "files" })
    end,
    inspect = function(object, access, timeout_ms)
      return async.run(function()
        if not file_id(object.locator) then
          return { ok = true }
        end
        local remaining = budget(timeout_ms)
        local result = request("GET", "/" .. object.locator .. "/download", access, remaining)
        if status(result) == 404 then
          return { ok = true }
        end
        return { ok = true, object = metadata(checked(result), object.locator) }
      end, { error_kind = "files" })
    end,
  }
end

return M
