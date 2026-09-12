local assert = require("luassert")
local async = require("neoagent.async")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end, 5))
  return (assert(run:result()))
end

describe("local browser authentication callback", function()
  ---@type Neoagent.TestCallbackNetwork
  local network
  ---@type Neoagent.CallbackListener<unknown>[]
  local servers = {}

  before_each(function()
    servers = {}
    network = require("tests.helpers.callback_connections").new()
  end)

  after_each(function()
    for _, server in ipairs(servers) do server.close() end
    network.close()
  end)

  ---@generic T
  ---@param opts Neoagent.CallbackOptions<T>
  ---@return Neoagent.CallbackListener<T>
  local function listen(opts)
    local server, err = network.listen(opts)
    assert(server, err)
    servers[#servers + 1] = server
    return server
  end

  it("accepts LF-framed requests and writes deterministic safe responses", function()
    local server = listen({
      handler = function(received)
        assert.are.equal("POST", received.method)
        assert.are.equal("/complete", received.target)
        assert.are.equal("body", received.body)
        return {
          status = 200,
          headers = {
            ["X-Zeta"] = "last",
            ["x-Alpha"] = "first",
            ["Unsafe Header"] = "discarded",
            ["X-Unsafe"] = "discarded\r\nInjected: true",
          },
          body = "done",
          done = true,
          value = "accepted",
        }
      end,
    })

    local response = network.request(server.port, table.concat({
      "POST /complete HTTP/1.1",
      "Host: 127.0.0.1",
      "Content-Length: 4",
      "",
      "body",
    }, "\n"))

    assert.matches("^HTTP/1%.1 200 OK\r\n", response)
    assert.is_truthy((response:find(
      "x-Alpha: first\r\nX-Zeta: last", 1, true)))
    assert.is_nil((response:find("Unsafe", 1, true)))
    assert.is_truthy((response:find(
      "Content-Type: text/plain; charset=utf-8", 1, true)))
    assert.are.equal("accepted", wait(async.run(function()
      return server.wait()
    end)))
    assert.is_false(server.close())
  end)

  it("rejects unsafe framing and contains callback failures", function()
    local server = listen({
      max_request_bytes = 1024,
      handler = function(received)
        if received.target == "/error" then error("handler exploded") end
        if received.target == "/invalid" then return false --[[@as Neoagent.CallbackResponse<unknown>]] end
        return { status = 204 }
      end,
    })

    local duplicate = network.request(server.port, table.concat({
      "GET / HTTP/1.1", "Host: one", "Host: two", "", "",
    }, "\r\n"))
    assert.matches("^HTTP/1%.1 400 Bad Request", duplicate)

    local malformed = network.request(server.port, "not HTTP\r\n\r\n")
    assert.matches("^HTTP/1%.1 400 Bad Request", malformed)

    local invalid_length = network.request(server.port, table.concat({
      "POST / HTTP/1.1", "Content-Length: invalid", "", "",
    }, "\r\n"))
    assert.matches("^HTTP/1%.1 400 Bad Request", invalid_length)

    local chunked = network.request(server.port, table.concat({
      "POST / HTTP/1.1", "Transfer-Encoding: chunked", "", "0", "", "",
    }, "\r\n"))
    assert.matches("^HTTP/1%.1 400 Bad Request", chunked)

    local large = network.request(server.port, table.concat({
      "POST / HTTP/1.1", "Content-Length: 2048", "", "",
    }, "\r\n"))
    assert.matches("^HTTP/1%.1 413 Payload Too Large", large)
    assert.is_truthy((large:find("request too large", 1, true)))

    local oversized_head = network.request(server.port, string.rep("x", 1025))
    assert.matches("^HTTP/1%.1 413 Payload Too Large", oversized_head)

    for _, target in ipairs({ "/error", "/invalid" }) do
      local response = network.request(server.port,
        "GET " .. target .. " HTTP/1.1\r\nHost: localhost\r\n\r\n")
      assert.matches("^HTTP/1%.1 500 Internal Server Error", response)
      assert.is_truthy((response:find("callback failed", 1, true)))
    end
  end)

  it("closes listeners that fail to bind, inspect, or listen", function()
    local callback = require("neoagent.auth.local_callback")
    for _, failure in ipairs({ "bind", "address", "listen" }) do
      local closed = false
      local connection = {
        is_closing = function() return closed end,
        close = function() closed = true end,
        bind = function()
          if failure == "bind" then return nil, "bind failed" end
          return true
        end,
        getsockname = function()
          if failure == "address" then return nil, "address failed" end
          return { port = 19000 }
        end,
        listen = function()
          if failure == "listen" then return nil, "listen failed" end
          return true
        end,
      }
      local listener, err = callback._listen({
        handler = function() return { status = 204 } end,
      }, function()
        return connection --[[@as Neoagent.CallbackConnection<unknown>]]
      end)
      assert.is_nil(listener)
      assert.are.equal(failure .. " failed", err)
      assert.is_true(closed)
    end
  end)

  it("contains failed accepts and closes active clients when waiting is cancelled", function()
    local server = listen({
      handler = function() return { status = 204 } end,
    })
    local listener = assert(network.listeners[server.port])
    local handles = #network.handles
    assert(listener.on_accept)("accept failed")
    assert.are.equal(handles, #network.handles)

    listener.pending = { response = "" }
    local accept = listener.accept
    listener.accept = function() return nil end
    assert(listener.on_accept)()
    listener.accept = accept
    assert.is_true(assert(network.handles[#network.handles]):is_closing())

    ---@type Neoagent.TestCallbackPeer
    local peer = { response = "" }
    listener.pending = peer
    assert(listener.on_accept)()
    local read = assert(assert(peer.handle).read)
    read(nil, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    read(nil, "late data")

    local run = async.run(function() return server.wait() end)
    run:cancel()
    local result = wait(run)
    assert.is_false(result.ok)
    assert.is_true(assert(peer.handle):is_closing())
  end)

  it("settles only once when concurrent callbacks complete", function()
    local call = 0
    local server = listen({ handler = function()
      call = call + 1
      return { status = 200, done = true, value = call }
    end })
    local listener = assert(network.listeners[server.port])
    ---@type Neoagent.TestCallbackPeer[]
    local peers = { { response = "" }, { response = "" } }
    local reads = {}
    for index, peer in ipairs(peers) do
      listener.pending = peer
      assert(listener.on_accept)()
      reads[index] = assert(assert(peer.handle).read)
    end
    for _, read in ipairs(reads) do
      read(nil, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    end
    local first = assert(peers[1])
    local second = assert(peers[2])
    assert(vim.wait(1000, function()
      return first.done and second.done
    end))
    assert.are.equal(1, wait(async.run(function() return server.wait() end)))
    assert.are.equal(2, call)
  end)

  it("closes a failed browser connection while allowing a later valid callback", function()
    local calls = 0
    local server = listen({ handler = function()
      calls = calls + 1
      return { status = 200, done = true, value = "accepted" }
    end })
    local listener = assert(network.listeners[server.port])
    ---@type Neoagent.TestCallbackPeer
    local peer = { response = "" }
    listener.pending = peer
    assert(listener.on_accept)()
    assert(assert(peer.handle).read)(nil, "GET / HTTP/1.1\r\nHost:")
    assert(assert(peer.handle).read)("connection reset")
    assert.is_true(assert(peer.handle):is_closing())
    assert.are.equal(0, calls)
    assert.are.equal("", peer.response)
    local run = async.run(function() return server.wait() end)
    assert.is_false(run:is_done())
    assert.matches("200 OK", network.request(server.port, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
    assert.are.equal("accepted", wait(run))
    assert.are.equal(1, calls)
  end)

  it("rejects a timed-out wait both before and after it is observed", function()
    local server = listen({
      timeout_ms = 5,
      handler = function() return { status = 204 } end,
    })
    local elapsed = false
    local marker = assert(vim.uv.new_timer())
    marker:start(20, 0, function()
      elapsed = true
      marker:stop()
      marker:close()
    end)
    assert(vim.wait(1000, function() return elapsed end, 5))
    assert.is_false(server.close())

    local result = wait(async.run(function()
      return server.wait()
    end, { error_kind = "auth" }))
    assert.is_false(result.ok)
    assert.are.equal("auth", assert(result.error).kind)
    assert.matches("timed out", assert(result.error).message)

    local observed = listen({
      timeout_ms = 5,
      handler = function() return { status = 204 } end,
    })
    result = wait(async.run(function()
      return observed.wait()
    end, { error_kind = "auth" }))
    assert.is_false(result.ok)
    assert.matches("timed out", assert(result.error).message)
  end)
end)
