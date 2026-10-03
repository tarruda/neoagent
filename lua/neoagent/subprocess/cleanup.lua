local M = {}

---@class Neoagent.ProcessCleanupDeadline
---@field start fun(timeout_ms: integer, delivery_delay_ns?: fun(now_ns: number): number)
---@field close fun() Release the reserved timer once when its owner finishes.

-- Reserve the timer before native startup. Both process owners use the same
-- drain clock; their escalation and final error publication remain separate.
---@param force fun()
---@param expired fun()
---@return Neoagent.ProcessCleanupDeadline
function M.new(force, expired)
  local timer = assert(vim.uv.new_timer())
  local started, closed = false, false
  return {
    start = function(timeout_ms, delivery_delay_ns)
      if started or closed then
        return
      end
      started = true
      vim.schedule(function()
        if closed then
          return
        end
        local beginning = vim.uv.hrtime()
        local initial_delay = delivery_delay_ns and delivery_delay_ns(beginning) or 0
        local extended = false
        local function arm(remaining_ms)
          vim.uv.update_time()
          timer:start(math.ceil(remaining_ms), 0, function()
            -- Request termination before queuing cleanup observation. Drivers
            -- retain their own control-context requirements.
            force()
            vim.schedule(function()
              if closed then
                return
              end
              local now = vim.uv.hrtime()
              local delayed = delivery_delay_ns and delivery_delay_ns(now) - initial_delay or 0
              local remaining = timeout_ms - (now - beginning - delayed) / 1000000
              if remaining > 0 and not extended then
                -- Give output delayed by the editor one final drain window.
                -- Later deliveries cannot keep replenishing cleanup's budget.
                extended = true
                arm(math.min(remaining, timeout_ms))
              else
                expired()
              end
            end)
          end)
        end
        arm(timeout_ms)
      end)
    end,
    close = function()
      closed = true
      timer:stop()
      timer:close()
    end,
  }
end

return M
