local files = require("neoagent.files")
local digest = require("neoagent.files.digest")
local M = {}
local sequence = 0

---@return Neoagent.Files
function M.new()
  ---@type table<string, string>
  local blobs = {}
  sequence = sequence + 1
  local identity = "memory:" .. sequence
  ---@param id string
  ---@return Neoagent.LocalFile?, Neoagent.Error?
  local function inspect(id)
    assert(files.valid_id(id), "attachment file ID must be a SHA-256 digest")
    local data = blobs[id]
    if not data then
      return nil, files.error("Attachment is missing: " .. id)
    end
    return { file_id = id, bytes = #data }
  end
  return {
    identity = identity,
    inspect = inspect,
    ---@async
    put = function(data)
      assert(type(data) == "string", "attachment bytes must be a string")
      local id = digest.sha256(data)
      blobs[id] = data
      return { file_id = id, bytes = #data }
    end,
    open = function(id, maximum)
      files.check_limit(maximum)
      local file, err = inspect(id)
      if not file then
        return nil, err
      end
      if file.bytes > maximum then
        return nil, files.error("Attachment exceeds the byte limit")
      end
      return files.reader(file, maximum, function()
        return blobs[id]
      end, function()
        return true
      end)
    end,
  }
end

return M
