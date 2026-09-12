local callback = require("neoagent.auth.local_callback")
---@class Neoagent.TestCallbackPeer
---@field response string
---@field done? boolean
---@field handle? Neoagent.TestCallbackConnection

---@class Neoagent.TestCallbackNetwork
---@field listeners table<integer, Neoagent.TestCallbackConnection>
---@field handles Neoagent.TestCallbackConnection[]
---@field listen fun<T>(opts: Neoagent.CallbackOptions<T>): Neoagent.CallbackListener<T>?, string?
---@field request fun(port: integer|string, payload: string|string[]): string
---@field close fun()
---@field restore? fun()

local M = {}

---@return Neoagent.TestCallbackNetwork
function M.new()
  ---@type table<integer, Neoagent.TestCallbackConnection>
  local listeners = {}
  ---@type Neoagent.TestCallbackConnection[]
  local handles = {}
  local network = { listeners = listeners, handles = handles }
  local next_port = 16000
  ---@return Neoagent.TestCallbackConnection
  local function connection()
    ---@class Neoagent.TestCallbackConnection
    ---@field closed boolean
    ---@field port? integer
    ---@field on_accept? fun(err?: string)
    ---@field pending? Neoagent.TestCallbackPeer
    ---@field peer? Neoagent.TestCallbackPeer
    ---@field read? fun(err?: string, chunk?: string)
    ---@field is_closing fun(self: Neoagent.TestCallbackConnection): boolean
    ---@field close fun(self: Neoagent.TestCallbackConnection)
    ---@field bind fun(self: Neoagent.TestCallbackConnection, host: string, port: integer): true
    ---@field getsockname fun(self: Neoagent.TestCallbackConnection): {port: integer}
    ---@field listen fun(self: Neoagent.TestCallbackConnection, backlog: integer, accept: fun(err?: string)): true
    ---@field accept fun(self: Neoagent.TestCallbackConnection, client: Neoagent.TestCallbackConnection): 0|true|nil, string?
    ---@field read_start fun(self: Neoagent.TestCallbackConnection, read: fun(err?: string, chunk?: string))
    ---@field read_stop fun(self: Neoagent.TestCallbackConnection)
    ---@field write fun(self: Neoagent.TestCallbackConnection, data: string, done: fun(err?: string)): true
    local handle = { closed = false }
    network.handles[#network.handles + 1] = handle
    ---@return boolean
    function handle:is_closing() return self.closed end
    function handle:close()
      self.closed = true
      if self.port then network.listeners[self.port] = nil end
    end
    ---@param _ string
    ---@param port integer
    ---@return true
    function handle:bind(_, port)
      if port == 0 then next_port = next_port + 1; port = next_port end
      self.port = port
      network.listeners[port] = self
      return true
    end
    ---@return {port: integer}
    function handle:getsockname() return { port = assert(self.port) } end
    ---@param _ integer
    ---@param accept fun(err?: string)
    ---@return true
    function handle:listen(_, accept) self.on_accept = accept; return true end
    ---@param client Neoagent.TestCallbackConnection
    ---@return true
    function handle:accept(client)
      local peer = assert(self.pending)
      client.peer = peer
      self.pending = nil
      peer.handle = client
      return true
    end
    ---@param read fun(err?: string, chunk?: string)
    function handle:read_start(read) self.read = read end
    function handle:read_stop() self.read = nil end
    ---@param data string
    ---@param done fun(err?: string)
    ---@return true
    function handle:write(data, done)
      local peer = assert(self.peer)
      peer.response = peer.response .. data
      vim.schedule(function() done(); peer.done = true end)
      return true
    end
    return handle
  end
  ---@generic T
  ---@param opts Neoagent.CallbackOptions<T>
  ---@return Neoagent.CallbackListener<T>?, string?
  function network.listen(opts) return callback._listen(opts, connection) end
  ---@param port integer|string
  ---@param payload string|string[]
  ---@return string
  function network.request(port, payload)
    local port_number = assert(tonumber(port), "Callback port must be numeric")
    assert(port_number % 1 == 0, "Callback port must be an integer")
    ---@cast port_number integer
    local listener = assert(network.listeners[port_number], "Callback listener is not open")
    ---@type Neoagent.TestCallbackPeer
    local peer = { response = "" }
    listener.pending = peer
    assert(listener.on_accept)()
    local handle = assert(peer.handle)
    local chunks = type(payload) == "table" and payload or { payload }
    for _, chunk in ipairs(chunks) do
      if handle.read then handle.read(nil, chunk) end
    end
    if handle.read then handle.read(nil, nil) end
    assert(vim.wait(1000, function() return peer.done == true end), "Callback response did not settle")
    return peer.response
  end
  function network.close()
    for _, handle in ipairs(network.handles) do handle:close() end
  end
  return network
end

-- Bind only the connection boundary; authentication still constructs its real
-- browser callback handler and validates its own random state and PKCE fields.
---@return Neoagent.TestCallbackNetwork & {restore: fun()}
function M.install()
  local network = M.new()
  local original = callback.listen
  callback.listen = network.listen
  function network.restore() callback.listen = original; network.close() end
  ---@cast network Neoagent.TestCallbackNetwork & {restore: fun()}
  return network
end
return M
