local callback = require("neoagent.auth.local_callback")
local M = {}

function M.new()
  local network = { listeners = {}, handles = {} }
  local next_port = 16000
  local function connection()
    local handle = { closed = false }
    network.handles[#network.handles + 1] = handle
    function handle:is_closing() return self.closed end
    function handle:close()
      self.closed = true
      if self.port then network.listeners[self.port] = nil end
    end
    function handle:bind(_, port)
      if port == 0 then next_port = next_port + 1; port = next_port end
      self.port = port
      network.listeners[port] = self
      return true
    end
    function handle:getsockname() return { port = self.port } end
    function handle:listen(_, accept) self.on_accept = accept; return true end
    function handle:accept(client)
      client.peer = assert(self.pending)
      self.pending = nil
      client.peer.handle = client
      return true
    end
    function handle:read_start(read) self.read = read end
    function handle:read_stop() self.read = nil end
    function handle:write(data, done)
      self.peer.response = self.peer.response .. data
      vim.schedule(function() done(); self.peer.done = true end)
      return true
    end
    return handle
  end
  function network.listen(opts) return callback._listen(opts, connection) end
  function network.request(port, payload)
    local listener = assert(network.listeners[tonumber(port)], "Callback listener is not open")
    local peer = { response = "" }
    listener.pending = peer
    listener.on_accept()
    local chunks = type(payload) == "table" and payload or { payload }
    for _, chunk in ipairs(chunks) do
      if peer.handle.read then peer.handle.read(nil, chunk) end
    end
    if peer.handle.read then peer.handle.read(nil, nil) end
    assert(vim.wait(1000, function() return peer.done end), "Callback response did not settle")
    return peer.response
  end
  function network.close()
    for _, handle in ipairs(network.handles) do handle:close() end
  end
  return network
end

-- Bind only the connection boundary; authentication still constructs its real
-- browser callback handler and validates its own random state and PKCE fields.
function M.install()
  local network = M.new()
  local original = callback.listen
  callback.listen = network.listen
  function network.restore() callback.listen = original; network.close() end
  return network
end
return M
