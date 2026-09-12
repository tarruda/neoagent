local files = require("neoagent.files")
local M = {}

---@alias Neoagent.ImageEncoder async fun(image: Neoagent.ImageBlock): Neoagent.JsonObject

---@param api string
---@param file_id string
---@return Neoagent.JsonObject
function M.remote(api, file_id)
  if api == "openai-responses" or api == "openai-codex-responses" then
    return { type = "input_image", file_id = file_id, detail = "auto" }
  elseif api == "openai-completions" then
    return { type = "file", file_id = file_id }
  elseif api == "anthropic-messages" then
    return { type = "image", source = { type = "file", file_id = file_id } }
  end
  error("Unsupported image protocol: " .. api)
end

---@param api string
---@param storage? Neoagent.FileSource
---@return Neoagent.ImageEncoder
function M.inline(api, storage)
  ---@type table<string, {data: string, bytes: integer}>
  local prepared = {}
  ---@async
  return function(image)
    assert(files.valid(storage), "attachment file reader is required")
    local snapshot = prepared[image.file_id]
    if not snapshot then
      local bytes, err = files.read(storage, image.file_id, image.bytes)
      if not bytes then
        error(err, 0)
      end
      snapshot = { data = vim.base64.encode(bytes), bytes = #bytes }
      prepared[image.file_id] = snapshot
    end
    if snapshot.bytes ~= image.bytes then
      error(files.error("Attachment size does not match stored content"), 0)
    end
    local encoded = snapshot.data
    if api == "anthropic-messages" then
      return { type = "image", source = { type = "base64", media_type = image.mime_type, data = encoded } }
    end
    local url = "data:" .. image.mime_type .. ";base64," .. encoded
    if api == "openai-completions" then
      return { type = "image_url", image_url = { url = url } }
    end
    return { type = "input_image", image_url = url, detail = "auto" }
  end
end

return M
