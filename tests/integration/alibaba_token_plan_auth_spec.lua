local dashboard = require("neoagent.auth.alibaba_dashboard")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end, 5))
  return run:result()
end

describe("Alibaba Cloud Token Plan browser authentication", function()
  it("keeps OAuth console access separate from Token Plan inference", function()
    local method = dashboard.new()
    local callback
    local run = method.login({
      prompt = function() error("dashboard login must not prompt for a key") end,
      notify = function(event)
        assert.is_nil(event.url:match("needapikey"))
        local port = assert(event.url:match(
          "notice=127%.0%.0%.1:(%d+)%?state="))
        local state = assert(event.url:match("%?state=([0-9a-f]+)"))
        assert.are.equal(32, #state)
        local target = "http://127.0.0.1:" .. port
          .. "/?state=" .. state
        local preflight = vim.system({
          "curl", "--silent", "--request", "OPTIONS", target,
        }, function()
          vim.schedule(function()
            callback = vim.system({
              "curl", "--silent", "--request", "POST",
              "--header", "Content-Type: application/json",
              "--data", '{"data":{"access_token":"console-token",'
                .. '"api_key":"sk-general-from-oauth"}}',
              target,
            })
          end)
        end)
        assert.is_table(preflight)
      end,
    })

    local result = wait(run)

    assert.is_true(result.ok)
    assert.are.equal("console-token", result.credential.key)
    assert.are.equal(0, callback:wait().code)
  end)

  it("rejects invalid callbacks before accepting a multipart console token", function()
    local method = dashboard.new({
      random_state = function() return "multipart-state" end,
    })
    local worker
    local run = method.login({
      prompt = function() error("dashboard login must not prompt for a key") end,
      notify = function(event)
        local port = assert(event.url:match(
          "notice=127%.0%.0%.1:(%d+)%?state="))
        worker = vim.system({
          "python3", "-c", [=[
import socket
import sys

port = int(sys.argv[1])

def send(payload):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
        connection.sendall(payload)
        connection.shutdown(socket.SHUT_WR)
        response = b""
        while True:
            chunk = connection.recv(4096)
            if not chunk:
                return response
            response += chunk

assert b"404 Not Found" in send(
    b"DELETE /?state=multipart-state HTTP/1.1\r\nHost: localhost\r\n\r\n")
assert b"400 Bad Request" in send(
    b"GET /?state=wrong HTTP/1.1\r\nHost: localhost\r\n\r\n")
assert b"Missing console access token" in send(
    b"GET /?state=multipart-state HTTP/1.1\r\nHost: localhost\r\n\r\n")
assert b"Missing console access token" in send(
    b"GET /?state=multipart-state&api_key=sk-general HTTP/1.1\r\n"
    b"Host: localhost\r\n\r\n")

body = (
    "--neo-boundary\r\n"
    "Content-Disposition: form-data; name=\"ignored\"\r\n\r\n"
    "discarded\r\n"
    "--neo-boundary\r\n"
    "Content-Disposition: form-data; name='accessToken'\r\n\r\n"
    "console-multipart\r\n"
    "--neo-boundary--\r\n"
).encode()
request = (
    "POST /?state=multipart-state HTTP/1.1\r\n"
    "Host: localhost\r\n"
    "Content-Type: multipart/form-data; boundary=neo-boundary\r\n"
    f"Content-Length: {len(body)}\r\n\r\n"
).encode() + body
assert b"200 OK" in send(request)
]=], tostring(port),
        })
      end,
    })

    local result = wait(run)

    assert.is_true(result.ok)
    assert.are.equal("console-multipart", result.credential.key)
    assert.is_table(worker)
    local completed = worker:wait()
    assert.are.equal(0, completed.code, completed.stderr)
  end)

  it("accepts a form-encoded console access token", function()
    local method = dashboard.new({
      random_state = function() return "form-state" end,
    })
    local callback
    local run = method.login({
      prompt = function() error("dashboard login must not prompt for a key") end,
      notify = function(event)
        local port = assert(event.url:match(
          "notice=127%.0%.0%.1:(%d+)%?state="))
        local target = "http://127.0.0.1:" .. port
          .. "/?state=form-state"
        callback = vim.system({
          "curl", "--silent", "--request", "POST",
          "--header", "Content-Type: application/x-www-form-urlencoded",
          "--data", "accessToken=console-form",
          target,
        })
      end,
    })

    local result = wait(run)

    assert.is_true(result.ok)
    assert.are.equal("console-form", result.credential.key)
    assert.is_table(callback)
    assert.are.equal(0, callback:wait().code)
  end)
end)
