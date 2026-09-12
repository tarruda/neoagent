local async = require("neoagent.async")
local files = require("neoagent.files")
local util = require("neoagent.util")
local M = {}

---@generic T
---@param operation async fun(): T
---@param timeout? integer
---@return T
local function completed(operation, timeout)
  local run = async.run(operation)
  if not vim.wait(timeout or 5000, function() return run:is_done() end) then
    run:cancel()
    error("Attachment operation exceeded its test deadline")
  end
  local result = assert(run:result())
  if result.ok == false then error(vim.inspect(result.error), 0) end
  return result
end

---@class Neoagent.AttachmentFixture
---@field files Neoagent.Files
---@field image fun(data: string, mime_type?: string, fields?: {filename?: string, id?: string, revision?: string|number}): Neoagent.ImageBlock
---@field read fun(image: Neoagent.ImageBlock, timeout?: integer): string

---@param storage? Neoagent.Files
---@return Neoagent.AttachmentFixture
function M.new(storage)
  storage = storage or require("neoagent.files.memory").new()
  return {
    files = storage,
    image = function(data, mime_type, fields)
      local result = completed(function()
        local file, err = storage.put(data)
        if not file then error(err, 0) end
        return { ok = true, file = file }
      end)
      return vim.tbl_extend("force", util.copy(fields or {}), {
        type = "image", file_id = result.file.file_id, bytes = result.file.bytes,
        mime_type = mime_type or "image/png",
      })
    end,
    read = function(image, timeout)
      local result = completed(function()
        local data, err = files.read(storage, image.file_id, image.bytes)
        if not data then error(err, 0) end
        return { ok = true, data = data }
      end, timeout)
      return result.data
    end,
  }
end

return M
