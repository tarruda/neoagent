local async = require("neoagent.async")
local local_callback = require("neoagent.auth.local_callback")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end, 5))
  return run:result()
end

local function close(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function request(port, payload)
  local client = vim.uv.new_tcp()
  local response = ""
  local finished = false
  local failure
  client:connect("127.0.0.1", port, function(connect_err)
    if connect_err then
      failure = connect_err
      finished = true
      close(client)
      return
    end
    client:read_start(function(read_err, chunk)
      if read_err then failure = read_err end
      if chunk then
        response = response .. chunk
      else
        finished = true
        close(client)
      end
    end)
    client:write(payload)
  end)
  assert(vim.wait(5000, function() return finished end, 5))
  assert.is_nil(failure)
  return response
end

describe("local browser authentication callback", function()
  local servers

  before_each(function() servers = {} end)

  after_each(function()
    for _, server in ipairs(servers) do server.close() end
  end)

  local function listen(opts)
    local server, err = local_callback.listen(opts)
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

    local response = request(server.port, table.concat({
      "POST /complete HTTP/1.1",
      "Host: 127.0.0.1",
      "Content-Length: 4",
      "",
      "body",
    }, "\n"))

    assert.matches("^HTTP/1%.1 200 OK\r\n", response)
    assert.is_truthy(response:find(
      "x-Alpha: first\r\nX-Zeta: last", 1, true))
    assert.is_nil(response:find("Unsafe", 1, true))
    assert.is_truthy(response:find(
      "Content-Type: text/plain; charset=utf-8", 1, true))
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
        if received.target == "/invalid" then return false end
        return { status = 204 }
      end,
    })

    local duplicate = request(server.port, table.concat({
      "GET / HTTP/1.1", "Host: one", "Host: two", "", "",
    }, "\r\n"))
    assert.matches("^HTTP/1%.1 400 Bad Request", duplicate)

    local chunked = request(server.port, table.concat({
      "POST / HTTP/1.1", "Transfer-Encoding: chunked", "", "0", "", "",
    }, "\r\n"))
    assert.matches("^HTTP/1%.1 400 Bad Request", chunked)

    local large = request(server.port, table.concat({
      "POST / HTTP/1.1", "Content-Length: 2048", "", "",
    }, "\r\n"))
    assert.matches("^HTTP/1%.1 413 Payload Too Large", large)
    assert.is_truthy(large:find("request too large", 1, true))

    for _, target in ipairs({ "/error", "/invalid" }) do
      local response = request(server.port,
        "GET " .. target .. " HTTP/1.1\r\nHost: localhost\r\n\r\n")
      assert.matches("^HTTP/1%.1 500 Internal Server Error", response)
      assert.is_truthy(response:find("callback failed", 1, true))
    end
  end)

  it("rejects a timed-out wait both before and after it is observed", function()
    local server = listen({
      timeout_ms = 5,
      handler = function() return { status = 204 } end,
    })
    local elapsed = false
    local marker = vim.uv.new_timer()
    marker:start(20, 0, function()
      elapsed = true
      marker:stop()
      close(marker)
    end)
    assert(vim.wait(1000, function() return elapsed end, 5))
    assert.is_false(server.close())

    local result = wait(async.run(function()
      return server.wait()
    end, { error_kind = "auth" }))
    assert.is_false(result.ok)
    assert.are.equal("auth", result.error.kind)
    assert.matches("timed out", result.error.message)

    local observed = listen({
      timeout_ms = 5,
      handler = function() return { status = 204 } end,
    })
    result = wait(async.run(function()
      return observed.wait()
    end, { error_kind = "auth" }))
    assert.is_false(result.ok)
    assert.matches("timed out", result.error.message)
  end)
end)
