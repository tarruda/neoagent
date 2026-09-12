local async = require("neoagent.async")
local files = require("neoagent.files")
local util = require("neoagent.util")
local M = {}

---@alias Neoagent.ImageSourceFactory fun(image: Neoagent.ImageBlock): Applet.ImageSource

---@param storage? Neoagent.FileSource
---@return Neoagent.ImageSourceFactory?
---@return Applet.ImageResourceReader?
function M.new(storage)
  if storage == nil then
    return nil
  end
  assert(files.valid(storage), "View attachment file reader is incomplete")
  storage = util.copy(storage)
  local prefix = storage.identity .. ":"
  ---@param image Neoagent.ImageBlock
  local function resource(image)
    return {
      kind = "png_resource",
      id = prefix .. image.file_id,
      revision = image.bytes,
    }
  end
  ---@param source Applet.PngResource
  ---@param maximum integer
  ---@param done fun(data?: string, error?: string)
  local function read(source, maximum, done)
    local run = async.run(function()
      assert(source.id:sub(1, #prefix) == prefix, "Attachment belongs to a different file store")
      local id, bytes = source.id:sub(#prefix + 1), source.revision
      assert(files.valid_id(id), "Attachment resource requires a file ID")
      assert(type(bytes) == "number" and bytes > 0 and bytes % 1 == 0, "Attachment resource requires a byte count")
      ---@cast bytes integer
      local data, err = files.read(storage, id, bytes < maximum and bytes or maximum)
      if not data then
        error(err, 0)
      end
      if #data ~= bytes then
        error(files.error("Attachment size does not match stored content"), 0)
      end
      return { ok = true, data = data }
    end, {
      error_kind = "attachment",
      on_done = function(result)
        if result.ok then
          done(result.data)
        elseif result.error.kind ~= "cancelled" then
          done(nil, result.error.message)
        end
      end,
    })
    return function()
      run:cancel()
    end
  end
  return resource, read
end

return M
