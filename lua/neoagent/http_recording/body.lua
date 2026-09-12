local fs = require("neoagent.fs")

local M = {}
local MEMORY_LIMIT = 1024 * 1024

---@class Neoagent.RecordingBody
---@field path string
---@field sensitive boolean
---@field chunks string[]
---@field bytes integer
---@field count integer
---@field file? Neoagent.RegularFile
local Body = {}
Body.__index = Body

---@param path string
---@param sensitive boolean
---@return Neoagent.RecordingBody
function M.new(path, sensitive)
  return setmetatable({
    path = path,
    sensitive = sensitive,
    chunks = {},
    bytes = 0,
    count = 0,
  }, Body)
end

---@param chunk string
function Body:append(chunk)
  local offset = self.bytes
  self.bytes = offset + #chunk
  self.count = self.count + 1
  if not self.file and self.bytes <= MEMORY_LIMIT then
    self.chunks[#self.chunks + 1] = chunk
    if #self.chunks >= 256 then
      self.chunks = { table.concat(self.chunks) }
    end
    return
  end
  if not self.file then
    assert(not self.sensitive, "sensitive response exceeds recording memory limit")
    local created, identity = fs.atomic_replace(self.path, table.concat(self.chunks), { mode = 384 })
    assert(created, "failed to create recording body spool")
    local file = fs.open_regular(self.path, { identity = identity, mode = 384 })
    assert(file, "failed to open recording body spool")
    self.file = file
    self.chunks = {}
  end
  assert(self.file:append(chunk, offset), "failed to append recording body spool")
end

---@return string?
function Body:text()
  if self.file then
    return nil
  end
  return table.concat(self.chunks)
end

---@param write fun(data: string): boolean
---@return true?, string?
function Body:write_base64(write)
  local file = assert(self.file)
  local stat = file:verify_path()
  if not stat or stat.size ~= self.bytes then
    return nil, "recording body spool changed before serialization"
  end
  local carry = ""
  local read, read_err = file:read_chunks(function(chunk)
    local data = carry .. chunk
    local length = #data - #data % 3
    assert(write(vim.base64.encode(data:sub(1, length))), "failed to write recording body")
    carry = data:sub(length + 1)
  end)
  if not read then
    return nil, read_err
  end
  if carry ~= "" and not write(vim.base64.encode(carry)) then
    return nil, "failed to write recording body"
  end
  return true
end

---@param remove boolean
---@return true?, string?
function Body:close(remove)
  self.chunks = {}
  local file = self.file
  if not file then
    return true
  end
  local verified, verify_err = file:verify_path()
  local closed, close_err = file:close()
  if not closed then
    return nil, close_err
  end
  self.file = nil
  if not verified then
    return nil, verify_err
  end
  if remove then
    local removed, remove_err = vim.uv.fs_unlink(self.path)
    if not removed then
      return nil, remove_err
    end
  end
  return true
end

return M
