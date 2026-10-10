local M = {}

---@class Neoagent.NativeRelease
---@field retain fun(): fun()
---@field close fun()

-- A native owner closes admission after disposal. Every retained component
-- acknowledges actual release independently, including delayed child reaping
-- and console work that outlive a caller's cleanup observation.
---@param released fun()
---@return Neoagent.NativeRelease
function M.new(released)
  local pending = 1
  local closed = false
  local function release()
    pending = pending - 1
    if pending == 0 then
      released()
    end
  end
  return {
    retain = function()
      assert(not closed, "native ownership is closed")
      pending = pending + 1
      local held = true
      return function()
        if held then
          held = false
          release()
        end
      end
    end,
    close = function()
      if not closed then
        closed = true
        release()
      end
    end,
  }
end

return M
