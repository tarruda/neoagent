local assert = require("luassert")
local auth = require("neoagent.auth.qwencloud_usage")
local fake_transport = require("tests.helpers.fake_transport")
local util = require("neoagent.util")

local DEVICE_TOKEN = "synthetic+/%"
local ACTIVATE = "https://t.qwencloud.com/activate?token=synthetic"
local EXPIRY = 4070908800125

---@param overrides? Neoagent.JsonObject
---@return Neoagent.TestByteResponse
local function init(overrides)
  return {
    body = vim.json.encode({
      Success = true,
      Data = vim.tbl_extend("force", {
        Token = DEVICE_TOKEN,
        VerificationUrl = ACTIVATE,
        ExpiresIn = 15,
        Interval = 2,
      }, overrides or {}),
    }),
  }
end

---@param status string
---@param credentials? Neoagent.JsonObject
---@return Neoagent.TestByteResponse
local function poll(status, credentials)
  return { body = vim.json.encode({ Success = true, Data = { Status = status, Credentials = credentials } }) }
end

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(2000, function()
    return run:is_done()
  end))
  return (assert(run:result()))
end

---@return Neoagent.LoginInteraction
local function interaction()
  return {
    prompt = function()
      error("Usage login must not prompt for input")
    end,
    notify = function(event)
      assert.are.equal("auth_url", event.type)
      assert.are.equal(ACTIVATE, rawget(event, "url"))
    end,
  }
end

---@param responses Neoagent.TestByteResponse[]
---@return Neoagent.AuthMethod<Neoagent.OAuthCredential>, Neoagent.TestByteBackend, integer[]
local function method(responses)
  local transport = fake_transport.new()
  transport.fetches = responses
  local now, sleeps = 0, {}
  local value = auth.new({
    transport = transport,
    clock = function()
      return now
    end,
    sleep = function(milliseconds)
      sleeps[#sleeps + 1] = milliseconds
      now = now + milliseconds
    end,
  })
  return value, transport, sleeps
end

describe("QwenCloud usage browser login", function()
  it("binds polling to the PKCE login and obeys the server's interval and slow-down response", function()
    local value, transport, sleeps = method({
      init(),
      poll("Authorization_Pending"),
      { status = 429, body = [[{"error":"slow_down"}]] },
      poll("Complete", { AccessToken = "synthetic-access-secret", ExpireTime = "2099-01-01T08:00:00.125+08:00" }),
    })
    local result = wait(value.login(interaction()))
    assert.is_true(result.ok, result.error and result.error.message)
    assert.are.same({ type = "oauth", access = "synthetic-access-secret", expires = EXPIRY }, result.credential)
    assert.are.same({ 2000, 2000, 7000 }, sleeps)
    local started, polled = assert(transport.fetch_requests[1]), assert(transport.fetch_requests[2])
    assert.are.equal("POST", started.method)
    assert.are.equal("POST", polled.method)
    assert.matches("^https://t%.qwencloud%.com/cli/device/code%?", started.url)
    assert.matches("^https://t%.qwencloud%.com/cli/device/token%?", polled.url)
    assert.matches("code_challenge_method=S256", started.url, 1, true)
    local client = assert(started.url:match("client_id=([0-9a-f%-]+)"))
    assert.are.equal(36, #client)
    assert.matches("^%x+%-%x+%-4%x+%-[89ab]%x+%-%x+$", client)
    assert.matches("client_id=" .. client, polled.url, 1, true)
    assert.matches("token=synthetic%2b%2f%25", polled.url:lower(), 1, true)
    local verifier = assert(polled.url:match("code_verifier=([%w_%-]+)"))
    assert.are.equal(43, #verifier)
    assert.is_nil((started.url:find(verifier, 1, true)))
    local digest = vim.fn.sha256(verifier):gsub("..", function(hex)
      return string.char((assert(tonumber(hex, 16))))
    end)
    local challenge = vim.base64.encode(digest):gsub("/", "_"):gsub("+", "-"):gsub("=$", "")
    assert.matches("code_challenge=" .. challenge .. "&", started.url, 1, true)
    assert.are.equal(4000, assert(transport.fetch_requests[4]).timeout_ms)
  end)

  it("bounds polling by the device expiry even when the next interval is longer", function()
    local value, transport, sleeps = method({ init({ ExpiresIn = 1 }) })
    local result = wait(value.login(interaction()))
    assert.is_false(result.ok)
    assert.matches("login expired", assert(result.error).message)
    assert.are.same({ 1000 }, sleeps)
    assert.are.equal(1, #transport.fetch_requests)
  end)

  it("cancels while waiting for the first poll", function()
    local transport = fake_transport.new()
    transport.fetches = { init({ Interval = 5 }) }
    local notified = false
    local browser = interaction()
    browser.notify = function()
      notified = true
    end
    local run = auth.new({ transport = transport }).login(browser)
    assert(vim.wait(1000, function()
      return notified
    end))
    run:cancel()
    assert.are.equal("cancelled", assert(wait(run).error).kind)
    assert.are.equal(1, #transport.fetch_requests)
  end)

  for _, case in ipairs({
    {
      name = "untrusted browser host",
      response = init({ VerificationUrl = "https://t.qwencloud.com@evil.example/activate" }),
      message = "invalid device authorization data",
    },
    {
      name = "account host with an unrelated suffix",
      response = init({ VerificationUrl = "https://account.qwencloud.com.example.test/activate" }),
      message = "invalid device authorization data",
    },
    {
      name = "account URL without TLS",
      response = init({ VerificationUrl = "http://account.qwencloud.com/activate" }),
      message = "invalid device authorization data",
    },
    {
      name = "account URL with a backslash",
      response = init({ VerificationUrl = "https://account.qwencloud.com/activate\\invalid" }),
      message = "invalid device authorization data",
    },
    { name = "invalid cadence", response = init({ Interval = 0 }), message = "invalid device authorization data" },
    {
      name = "HTTP failure",
      response = { status = 401, body = "private marker" },
      message = "could not start (HTTP 401)",
    },
    { name = "malformed JSON", response = { body = "private marker" }, message = "returned an invalid response" },
    {
      name = "transport failure",
      response = { error = util.error("transport", "private marker") },
      message = "request failed",
    },
  }) do
    it("rejects " .. case.name .. " before opening the browser", function()
      local value, transport = method({ case.response })
      local browser = interaction()
      browser.notify = function()
        error("invalid authorization must not open the browser")
      end
      local result = wait(value.login(browser))
      assert.are.equal("auth", assert(result.error).kind)
      assert.matches(case.message, assert(result.error).message, 1, true)
      assert.is_nil((vim.inspect(result):find("private marker", 1, true)))
      assert.are.equal(1, #transport.fetch_requests)
    end)
  end

  for _, case in ipairs({
    { response = poll("access_denied"), message = "was denied" },
    { response = { status = 400, body = [[{"Code":"expired_token"}]] }, message = "login expired" },
    { response = { status = 500, body = "private marker" }, message = "poll failed (HTTP 500)" },
    { response = poll("unknown"), message = "invalid device status" },
    {
      response = poll("complete", { AccessToken = "synthetic", ExpireTime = "2000-01-01T00:00:00Z" }),
      message = "invalid or expired access token",
    },
  }) do
    it("fails safely on a poll reporting " .. case.message, function()
      local value = method({ init(), case.response })
      local result = wait(value.login(interaction()))
      assert.are.equal("auth", assert(result.error).kind)
      assert.matches(case.message, assert(result.error).message, 1, true)
      assert.is_nil((vim.inspect(result):find("private marker", 1, true)))
    end)
  end

  it("rejects unsafe access token bytes and recording placeholders", function()
    for _, access in ipairs({
      "",
      "synthetic space",
      "synthetic\r\nheader",
      "synthetic\000token",
      "synthetic\127token",
      "synthetic\195\169",
      string.rep("a", 16385),
      "***",
      "[ReDaCtEd]",
      "<omitted>",
    }) do
      local value = method({
        init(),
        poll("complete", { AccessToken = access, ExpireTime = "2099-01-01T00:00:00Z" }),
      })
      local result = wait(value.login(interaction()))
      local err = assert(result.error)
      assert.are.equal("auth", err.kind)
      assert.are.equal("QwenCloud browser login returned an invalid or expired access token", err.message)
      assert.is_nil(result.credential)
    end
  end)

  it("preserves cancellation reported by the transport", function()
    local value = method({ { error = util.error("cancelled", "Cancelled") } })
    assert.are.equal("cancelled", assert(wait(value.login(interaction())).error).kind)
  end)
end)
