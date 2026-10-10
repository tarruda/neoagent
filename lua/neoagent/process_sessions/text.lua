local util = require("neoagent.util")
local M = {}

-- Keep only a potentially valid unfinished UTF-8 sequence. Invalid bytes
-- are escaped by the ordinary text conversion; control bytes stay available
-- in the raw events returned alongside this text.
---@param value string
---@return string, string
local function split(value)
  for length = math.min(3, #value), 1, -1 do
    local tail = value:sub(-length)
    local first = assert(tail:byte(1))
    local needed = first >= 0xC2 and first <= 0xDF and 2
      or first >= 0xE0 and first <= 0xEF and 3
      or first >= 0xF0 and first <= 0xF4 and 4
      or 0
    if needed > length then
      local valid = true
      for index = 2, length do
        local byte = assert(tail:byte(index))
        valid = valid and byte >= 0x80 and byte <= 0xBF
      end
      local second = tail:byte(2)
      if second then
        valid = valid
          and not (
            first == 0xE0 and second < 0xA0
            or first == 0xED and second > 0x9F
            or first == 0xF0 and second < 0x90
            or first == 0xF4 and second > 0x8F
          )
      end
      if valid then
        return value:sub(1, #value - length), tail
      end
    end
  end
  return value, ""
end

---@return fun(events: Neoagent.SubprocessOutputEvent[], dropped: integer, done: boolean): string
function M.new()
  local pending = { stdout = "", stderr = "", pty = "" }
  return function(events, dropped, done)
    local parts = {}
    if dropped > 0 then
      -- Never join bytes across an output gap.
      for stream, bytes in pairs(pending) do
        parts[#parts + 1] = util.text_from_bytes(bytes)
        pending[stream] = ""
      end
    end
    for _, event in ipairs(events) do
      local complete, tail = split(pending[event.stream] .. event.data)
      pending[event.stream] = tail
      parts[#parts + 1] = util.text_from_bytes(complete)
    end
    if done then
      for _, stream in ipairs({ "stdout", "stderr", "pty" }) do
        parts[#parts + 1] = util.text_from_bytes(pending[stream])
        pending[stream] = ""
      end
    end
    return table.concat(parts)
  end
end

return M
