local ffi = require("ffi")
local M = {}

---@class Neoagent.WindowsWideString: ffi.cdata*
---@field [integer] integer UTF-16 code units, indexed from zero.

-- Windows/libuv strings use WTF-8: ordinary UTF-8 plus encoded unpaired
-- UTF-16 surrogates. Win32's strict UTF-8 converter rejects those surrogates.
-- Keep this boundary shared by executable selection, launch, and environment
-- normalization. Lengths are explicit so environment blocks retain their NULs.
---@param text string
---@return Neoagent.WindowsWideString?, integer?
function M.wide(text)
  ---@type Neoagent.WindowsWideString
  local value = ffi.new("unsigned short[?]", #text + 1)
  local offset, length = 1, 0
  while offset <= #text do
    local first = assert(text:byte(offset))
    local count, point = 1, first
    if first >= 0xc2 and first <= 0xdf then
      count, point = 2, first - 0xc0
    elseif first >= 0xe0 and first <= 0xef then
      count, point = 3, first - 0xe0
    elseif first >= 0xf0 and first <= 0xf4 then
      count, point = 4, first - 0xf0
    elseif first >= 0x80 then
      return nil
    end
    for index = 1, count - 1 do
      local byte = text:byte(offset + index)
      if not byte or byte < 0x80 or byte > 0xbf then
        return nil
      end
      point = point * 64 + byte - 0x80
    end
    if count == 3 and point < 0x800 or count == 4 and (point < 0x10000 or point > 0x10ffff) then
      return nil
    end
    if point >= 0x10000 then
      value[length] = 0xd800 + math.floor((point - 0x10000) / 1024)
      value[length + 1] = 0xdc00 + (point - 0x10000) % 1024
      length = length + 2
    else
      value[length] = point
      length = length + 1
    end
    offset = offset + count
  end
  return value, length
end

---@param value Neoagent.WindowsWideString
---@param length integer
---@return string
function M.narrow(value, length)
  local parts = {}
  local index = 0
  while index < length do
    local point = value[index]
    index = index + 1
    if point >= 0xd800 and point <= 0xdbff and index < length then
      local low = value[index]
      if low >= 0xdc00 and low <= 0xdfff then
        point = 0x10000 + (point - 0xd800) * 1024 + low - 0xdc00
        index = index + 1
      end
    end
    if point < 0x80 then
      parts[#parts + 1] = string.char(point)
    elseif point < 0x800 then
      parts[#parts + 1] = string.char(0xc0 + math.floor(point / 64), 0x80 + point % 64)
    elseif point < 0x10000 then
      parts[#parts + 1] =
        string.char(0xe0 + math.floor(point / 4096), 0x80 + math.floor(point / 64) % 64, 0x80 + point % 64)
    else
      parts[#parts + 1] = string.char(
        0xf0 + math.floor(point / 262144),
        0x80 + math.floor(point / 4096) % 64,
        0x80 + math.floor(point / 64) % 64,
        0x80 + point % 64
      )
    end
  end
  return table.concat(parts)
end

return M
