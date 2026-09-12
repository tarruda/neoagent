local async = require("neoagent.async")
local util = require("neoagent.util")
local M = {}

---@return number
function M.now()
  return vim.uv.hrtime() / 1000000
end

---@async
---@param predicate fun(): boolean
---@param deadline number
---@param now? fun(): number
function M.until_ready(predicate, deadline, now)
  now = now or M.now
  async.await(function(done)
    local timer = assert(vim.uv.new_timer(), "could not create file preparation timer")
    local closed = false
    local function close()
      if closed then
        return
      end
      closed = true
      timer:stop()
      timer:close()
    end
    ---@type fun()
    local check
    check = function()
      if closed then
        return
      end
      local ok, ready = pcall(predicate)
      local remaining = deadline - now()
      if not ok or remaining <= 0 then
        close()
        done.reject(not ok and ready or util.error("files", "Image preparation timed out"))
      elseif ready then
        close()
        done.resolve(true)
      else
        timer:start(math.min(25, math.max(1, math.floor(remaining))), 0, vim.schedule_wrap(check))
      end
    end
    check()
    return close
  end)
end

-- Subscribe without adopting the producer as a child Run: another request
-- may still need it after this waiter cancels or reaches its own deadline.
---@async
---@generic T, E
---@param run Neoagent.Run<T, E>
---@param deadline number
---@param now fun(): number
---@return Neoagent.RunResult<T>
function M.completed(run, deadline, now)
  if deadline <= now() then
    error(util.error("files", "Image preparation timed out"), 0)
  end
  if run:is_done() then
    return assert(run:result())
  end
  return async.await(function(done)
    local timer = assert(vim.uv.new_timer())
    ---@type Neoagent.AwaitCallbacks<Neoagent.RunResult<T>>?
    local pending = done
    local function close()
      pending = nil
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    timer:start(
      math.max(1, math.ceil(deadline - now())),
      0,
      vim.schedule_wrap(function()
        local current = pending
        close()
        if current then
          current.reject(util.error("files", "Image preparation timed out"))
        end
      end)
    )
    run:_listen(function(result)
      local current = pending
      close()
      if current then
        if deadline <= now() then
          current.reject(util.error("files", "Image preparation timed out"))
        else
          current.resolve(result)
        end
      end
    end)
    return close
  end)
end

return M
