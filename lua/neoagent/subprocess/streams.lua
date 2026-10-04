local async = require("neoagent.async")
local validate = require("neoagent.subprocess.validate")
local M = {}

---@class Neoagent.ProcessStreams
---@field pipe fun(): uv.uv_pipe_t
---@field own fun(resource: uv.uv_handle_t)
---@field close fun(resource?: uv.uv_handle_t)
---@field input fun(stream: uv.uv_pipe_t)
---@field read fun(stream: uv.uv_pipe_t, name: "stdout"|"stderr"|"pty")
---@field exited fun()
---@field dispose fun()
---@field write fun(bytes: string): true
---@field close_stdin fun(): true
---@field flush async fun(): true
---@field writable fun(): boolean
---@field delivery_delay_ns fun(now: number): number

-- Pipes and native PTYs share write completion and output backpressure. Each
-- output stream retains at most one editor delivery while native reads stop.
---@param callbacks Neoagent.SubprocessCallbacks
---@param input_limits? Neoagent.ProcessInputLimits
---@return Neoagent.ProcessStreams
function M.new(callbacks, input_limits)
  local uv = vim.uv
  input_limits = input_limits or { bytes = validate.PENDING_BYTES, writes = validate.PENDING_WRITES }
  ---@type table<uv.uv_handle_t, boolean>
  local resources = {}
  local exited, closed, disposed, released = false, false, false, false
  local deliveries = 0
  ---@type number
  local delivery_delay = 0
  ---@type number?
  local delivery_pending_at
  local pending_bytes, pending_writes = 0, 0
  local input_closed, shutdown_pending = true, false
  ---@type uv.uv_pipe_t?
  local stdin
  ---@type Neoagent.Error?
  local input_error
  ---@type table<Neoagent.AwaitCallbacks<true>, boolean>
  local waiters = {}

  local function settle_input()
    if not input_error and (pending_writes > 0 or shutdown_pending) then
      return
    end
    local current = waiters
    waiters = {}
    for waiter in pairs(current) do
      if input_error then
        waiter.reject(input_error)
      else
        waiter.resolve(true)
      end
    end
  end

  local function fail_input()
    input_closed = true
    local first = input_error == nil
    input_error = input_error or validate.error("stdin_closed", "Process stdin no longer accepts input")
    settle_input()
    if first and callbacks.input_failed then
      callbacks.input_failed()
    end
  end

  local function settled()
    if not next(resources) and deliveries == 0 then
      if exited and not closed then
        closed = true
        vim.schedule(callbacks.closed)
      end
      if disposed and not released then
        released = true
        vim.schedule(callbacks.released)
      end
    end
  end

  ---@param resource? uv.uv_handle_t
  local function close(resource)
    if resource and not resource:is_closing() then
      resource:close(function()
        resources[resource] = nil
        if resource == stdin then
          shutdown_pending = false
          settle_input()
        end
        settled()
      end)
    end
  end

  local function shutdown()
    if shutdown_pending and pending_writes == 0 then
      close(stdin)
    end
  end

  ---@param stream uv.uv_pipe_t
  ---@param name "stdout"|"stderr"|"pty"
  local function read(stream, name)
    ---@type fun(err?: string, bytes?: string)
    local receive
    local function resume()
      if stream:is_closing() then
        return
      end
      local ok, started = pcall(uv.read_start, stream, receive)
      if not ok or not started then
        close(stream)
        callbacks.failed("process_stream", "Could not read process " .. name)
      end
    end
    receive = function(err, bytes)
      uv.read_stop(stream)
      -- A Linux PTY master reports EIO once the last slave closes. This is
      -- terminal EOF, after previously returned bytes have been delivered.
      if name == "pty" and jit.os == "Linux" and err and err:match("^EIO") then
        err = nil
      end
      if err or bytes == nil then
        close(stream)
      end
      if deliveries == 0 then
        delivery_pending_at = uv.hrtime()
      end
      deliveries = deliveries + 1
      vim.schedule(function()
        if err then
          callbacks.failed("process_stream", "Could not read process " .. name)
        elseif bytes then
          callbacks.output(name, bytes)
          resume()
        end
        deliveries = deliveries - 1
        if deliveries == 0 then
          delivery_delay = delivery_delay + uv.hrtime() - assert(delivery_pending_at)
          delivery_pending_at = nil
        end
        settled()
      end)
    end
    resume()
  end

  return {
    pipe = function()
      local value = assert(uv.new_pipe(false))
      resources[value] = true
      return value
    end,
    own = function(resource)
      resources[resource] = true
    end,
    close = close,
    input = function(stream)
      stdin = stream
      input_closed = false
    end,
    read = read,
    exited = function()
      exited = true
      input_closed = true
      close(stdin)
      settled()
    end,
    dispose = function()
      disposed = true
      input_closed = true
      for resource in pairs(resources) do
        close(resource)
      end
      settled()
    end,
    write = function(bytes)
      local stream = assert(stdin)
      if pending_bytes + #bytes > input_limits.bytes or pending_writes >= input_limits.writes then
        error(validate.error("input_limit", "Process input queue is full; flush before retrying"), 0)
      end
      pending_bytes = pending_bytes + #bytes
      pending_writes = pending_writes + 1
      local ok, request = pcall(uv.write, stream, bytes, function(err)
        pending_bytes = pending_bytes - #bytes
        pending_writes = pending_writes - 1
        if err then
          fail_input()
        end
        shutdown()
        settle_input()
      end)
      if not ok or not request then
        pending_bytes = pending_bytes - #bytes
        pending_writes = pending_writes - 1
        fail_input()
        error(input_error, 0)
      end
      return true
    end,
    close_stdin = function()
      if input_closed then
        if input_error then
          error(input_error, 0)
        end
        return true
      end
      input_closed = true
      shutdown_pending = true
      shutdown()
      return true
    end,
    ---@async
    flush = function()
      return async.await(function(done)
        waiters[done] = true
        settle_input()
        return function()
          waiters[done] = nil
        end
      end)
    end,
    writable = function()
      return not input_closed and stdin ~= nil and not stdin:is_closing()
    end,
    delivery_delay_ns = function(now)
      return delivery_delay + (delivery_pending_at and now - delivery_pending_at or 0)
    end,
  }
end

return M
