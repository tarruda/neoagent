local assert = require("luassert")
local dashboard = require("neoagent.auth.alibaba_dashboard")
local connections = require("tests.helpers.callback_connections")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe("Alibaba Cloud Token Plan browser authentication", function()
  ---@type Neoagent.TestCallbackNetwork & { restore: fun() }
  local network
  before_each(function() network = connections.install() end)
  after_each(function() network.restore() end)

  ---@param port string
  ---@param method string
  ---@param target string
  ---@param body? string
  ---@param content_type? string
  ---@return string
  local function send(port, method, target, body, content_type)
    body = body or ""
    return network.request(port, { method .. " " .. target .. " HTTP/1.1\r\n"
      .. "Host: localhost\r\nContent-Type: " .. (content_type or "text/plain")
      .. "\r\nContent-Length: " .. #body .. "\r\n\r\n", body })
  end

  ---@param opts Neoagent.AlibabaDashboardAuthOptions
  ---@param interact fun(port: string, state: string)
  ---@return Neoagent.CredentialResult<Neoagent.ApiKeyCredential>
  local function login(opts, interact)
    return wait(dashboard.new(opts).login({
      prompt = function() error("dashboard login must not prompt for a key") end,
      notify = function(event)
        assert(event.type == "auth_url")
        local url = assert(event.url)
        assert.is_nil(url:match("needapikey"))
        local port = assert(url:match("notice=127%.0%.0%.1:(%d+)%?state="))
        local state = assert(url:match("%?state=([^&]+)"))
        interact(port, state)
      end,
    }))
  end

  it("keeps console access separate from Token Plan inference", function()
    local result = login({}, function(port, state)
      assert.are.equal(32, #state)
      local target = "/?state=" .. state
      assert.matches("204 No Content", send(port, "OPTIONS", target))
      assert.matches("200 OK", send(port, "POST", target,
        '{"data":{"access_token":"console-token","api_key":"sk-general-from-oauth"}}',
        "application/json"))
    end)
    assert(result.ok)
    assert.are.equal("console-token", assert(result.credential).key)
  end)

  it("rejects invalid callbacks before accepting a multipart console token", function()
    local result = login({ random_state = function() return "multipart-state" end }, function(port)
      assert.matches("404 Not Found", send(port, "DELETE", "/?state=multipart-state"))
      assert.matches("400 Bad Request", send(port, "GET", "/?state=wrong"))
      for _, target in ipairs({ "/?state=multipart-state", "/?state=multipart-state&api_key=sk-general" }) do
        assert.matches("Missing console access token", send(port, "GET", target))
      end
      assert.matches("Missing console access token", send(port, "POST",
        "/?state=multipart-state", "malformed multipart", "multipart/form-data"))
      local body = '--neo-boundary\r\nContent-Disposition: form-data; name="ignored"\r\n\r\n'
        .. 'discarded\r\n--neo-boundary\r\nContent-Disposition: form-data; name=\'accessToken\'\r\n\r\n'
        .. 'console-multipart\r\n--neo-boundary--\r\n'
      assert.matches("200 OK", send(port, "POST", "/?state=multipart-state", body,
        "multipart/form-data; boundary=neo-boundary"))
    end)
    assert(result.ok)
    assert.are.equal("console-multipart", assert(result.credential).key)
  end)

  it("accepts a form-encoded console access token", function()
    local result = login({ random_state = function() return "form-state" end }, function(port)
      assert.matches("200 OK", send(port, "POST", "/?state=form-state",
        "accessToken=console-form", "application/x-www-form-urlencoded"))
    end)
    assert(result.ok)
    assert.are.equal("console-form", assert(result.credential).key)
  end)
end)
