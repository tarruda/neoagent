local M = {}

---@class Neoagent.ProcessOutputBuffer
---@field append fun(event: Neoagent.SubprocessOutputEvent)
---@field take fun(): Neoagent.SubprocessOutputEvent[], integer
---@field snapshot fun(): Neoagent.SubprocessOutputEvent[]
---@field empty fun(): boolean

-- Bound event overhead as well as bytes. Dropping old output never stops
-- native reads; the next consumer receives an exact discarded-byte count.
---@param maximum integer
---@return Neoagent.ProcessOutputBuffer
function M.new(maximum)
  ---@type Neoagent.SubprocessOutputEvent[]
  local events = {}
  local bytes, dropped = 0, 0
  return {
    append = function(event)
      if event.data == "" then
        return
      end
      local data = event.data
      if #data > maximum then
        dropped = dropped + #data - maximum
        data = data:sub(-maximum)
      end
      while #events > 0 and (#events >= 128 or bytes + #data > maximum) do
        local first = assert(events[1])
        local remove = #events >= 128 and #first.data or math.min(#first.data, bytes + #data - maximum)
        bytes, dropped = bytes - remove, dropped + remove
        if remove == #first.data then
          table.remove(events, 1)
        else
          first.data = first.data:sub(remove + 1)
        end
      end
      events[#events + 1] = { stream = event.stream, data = data }
      bytes = bytes + #data
    end,
    take = function()
      local current, lost = events, dropped
      events, bytes, dropped = {}, 0, 0
      return current, lost
    end,
    snapshot = function()
      return require("neoagent.util").copy(events)
    end,
    empty = function()
      return #events == 0
    end,
  }
end

return M
