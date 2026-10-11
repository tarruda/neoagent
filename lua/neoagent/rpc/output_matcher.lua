local util = require("neoagent.util")
local M = {}

---@param value unknown
---@return string[]
function M.keywords(value)
  if value == nil then
    return {}
  end
  assert(type(value) == "table" and util.is_list(value) and #value <= 32, "RPC output keywords must be a bounded list")
  local selected, total = {}, 0
  for index, keyword in ipairs(value) do
    assert(
      type(keyword) == "string" and keyword ~= "" and #keyword <= 128 and util.is_valid_utf8(keyword),
      "RPC output keyword must be bounded UTF-8 text"
    )
    total = total + #keyword
    assert(total <= 1024, "RPC output keywords exceed the aggregate limit")
    selected[index] = keyword
  end
  return selected
end

-- Retain a matched keyword and per-stream overlap, never diagnostic payloads.
-- The execution adapter observes bytes before its output buffer can evict them;
-- the parent still decides what that evidence means for the operation.
---@param keywords string[]
---@param on_match fun(keyword: string)
---@return fun(stream: string, bytes: string)
function M.new(keywords, on_match)
  local lowered, overlaps = {}, {}
  local overlap_bytes = 0
  for index, keyword in ipairs(keywords) do
    lowered[index] = keyword:lower()
    overlap_bytes = math.max(overlap_bytes, #keyword - 1)
  end
  local matched = false
  return function(stream, bytes)
    if matched or #keywords == 0 or bytes == "" then
      return
    end
    local text = ((overlaps[stream] or "") .. bytes):lower()
    for index, keyword in ipairs(lowered) do
      if text:find(keyword, 1, true) then
        matched = true
        on_match(assert(keywords[index]))
        return
      end
    end
    overlaps[stream] = overlap_bytes > 0 and text:sub(-overlap_bytes) or ""
  end
end

return M
