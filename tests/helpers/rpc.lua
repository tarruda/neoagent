local assert = require("luassert")
local async = require("neoagent.async")
local protocol = require("neoagent.rpc.protocol")

local M = {}

---@generic T
---@param run Neoagent.Run<T, unknown>
---@param timeout? integer
---@return Neoagent.RunResult<T>
function M.wait(run, timeout)
  assert(vim.wait(timeout or 3000, function() return run:is_done() end), "RPC Run did not settle")
  return (assert(run:result()))
end

---@param remote Neoagent.RpcConnection
---@param handle? fun(message: table, emit: fun(message: table))
---@return Neoagent.WorkerLease, table
function M.transport(remote, handle)
  ---@type {closed_stdin: boolean, terminated: boolean|string, closed: boolean, messages: string[]}
  local state = {
    closed_stdin = false,
    terminated = false,
    closed = false,
    messages = {},
  }
  local function emit(message)
    remote:feed(protocol.encode(message))
  end
  local decoder = protocol.decoder(function(message)
    state.messages[#state.messages + 1] = message.type
    if handle then
      handle(message, emit)
    end
  end)
  ---@type Neoagent.WorkerLease
  local child = {
    write = function(_, bytes)
      decoder:feed(bytes)
      return true
    end,
    close_stdin = function()
      state.closed_stdin = true
      return true
    end,
    terminate = function(_, reason)
      state.terminated = reason or true
    end,
    wait = function()
      return { code = 0, signal = 0, stderr = "" }
    end,
    dispose = function()
      state.closed = true
    end,
  }
  return child, state
end

---@param handle? fun(message: table, emit: fun(message: table))
---@param opts? Neoagent.RpcConnectionOptions
---@return Neoagent.RpcConnection, Neoagent.WorkerLease, table
function M.open(handle, opts)
  local connection = require("neoagent.rpc.connection").new(opts)
  local transport, state = M.transport(connection, function(message, emit)
    if message.type == "open" then
      emit({ type = "opened", call_id = message.call_id })
    elseif handle then
      handle(message, emit)
    end
  end)
  connection:attach(transport)
  connection:feed(protocol.encode({ type = "ready", marker = protocol.MARKER }))
  assert.is_true(M.wait(async.run(function() connection:open({}) return true end)))
  return connection, transport, state
end

return M
