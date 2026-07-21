local async = require("neoagent.async")
local codex = require("neoagent.auth.openai_codex")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function token(account)
  local payload = vim.base64.encode(vim.json.encode({
    ["https://api.openai.com/auth"] = { chatgpt_account_id = account },
  })):gsub("+", "-"):gsub("/", "_"):gsub("=+$", "")
  return "header." .. payload .. ".signature"
end

local function fake_http(responses)
  local value = { requests = {}, responses = responses }
  function value.fetch(opts)
    value.requests[#value.requests + 1] = opts.request
    local response = table.remove(value.responses, 1)
    return async.run(function() return response end)
  end
  return value
end

local function json(status, value)
  return { ok = true, status = status, body = vim.json.encode(value) }
end

local function interaction(answers, events)
  return {
    prompt = function(prompt, done)
      local answer = table.remove(answers, 1)
      if type(answer) == "function" then answer = answer(prompt) end
      done.resolve(answer)
    end,
    notify = function(event) events[#events + 1] = event end,
  }
end

describe("OpenAI Codex subscription authentication", function()
  it("logs in through the browser PKCE flow and derives Codex headers", function()
    local http = fake_http({ json(200, {
      access_token = token("acct"), refresh_token = "refresh", expires_in = 60,
    }) })
    local closed = false
    local method = codex.new({
      http = http,
      now = function() return 1000 end,
      auth_base_url = "https://auth.test",
      start_callback_server = function(state, host)
        assert.is_truthy(state)
        assert.are.equal("127.0.0.1", host)
        return { wait = function() return "browser-code" end, close = function() closed = true end }
      end,
    })
    local events = {}
    local result = wait(method.login(interaction({ "browser" }, events)))
    assert.is_true(result.ok)
    assert.is_true(closed)
    assert.are.equal("acct", result.credential.accountId)
    assert.are.equal(61000, result.credential.expires)
    assert.matches("originator=neoagent", events[1].url)
    assert.matches("code_challenge_method=S256", events[1].url)
    assert.are.equal("https://auth.test/oauth/token", http.requests[1].url)
    assert.matches("code=browser%-code", http.requests[1].body)
    local headers = method.request_opts(result.credential).headers
    assert.are.equal("Bearer " .. result.credential.access, headers.Authorization)
    assert.are.equal("acct", headers["chatgpt-account-id"])
    assert.are.equal("responses=experimental", headers["OpenAI-Beta"])
  end)

  it("falls back to a pasted redirect URL and refreshes tokens", function()
    local http = fake_http({
      json(200, { access_token = token("first"), refresh_token = "r1", expires_in = 1 }),
      json(200, { access_token = token("second"), refresh_token = "r2", expires_in = 2 }),
    })
    local state
    local events = {}
    local method = codex.new({
      http = http,
      now = function() return 10 end,
      auth_base_url = "https://auth.test",
      start_callback_server = function() return nil end,
    })
    local result = wait(method.login(interaction({
      "browser",
      function(prompt)
        assert.are.equal("manual_code", prompt.type)
        state = events[1].url:match("[?&]state=([^&]+)")
        return "http://localhost:1455/auth/callback?code=pasted&state=" .. state
      end,
    }, events)))
    assert.is_true(result.ok)
    assert.are.equal("first", result.credential.accountId)
    result = wait(method.refresh(result.credential))
    assert.is_true(result.ok)
    assert.are.equal("second", result.credential.accountId)
    assert.matches("grant_type=refresh_token", http.requests[2].body)
    assert.matches("refresh_token=r1", http.requests[2].body)
  end)

  it("supports headless device-code authorization with pending polls", function()
    local http = fake_http({
      json(200, { device_auth_id = "device", user_code = "ABCD", interval = 0 }),
      json(403, { error = "pending" }),
      json(400, { error = { code = "deviceauth_authorization_pending" } }),
      json(400, { error = "slow_down" }),
      json(200, { authorization_code = "authorization", code_verifier = "verifier" }),
      json(200, { access_token = token("device-account"), refresh_token = "refresh", expires_in = 5 }),
    })
    local events = {}
    local sleeps = {}
    local method = codex.new({
      http = http,
      now = function() return 0 end,
      auth_base_url = "https://auth.test",
      sleep = function(milliseconds) sleeps[#sleeps + 1] = milliseconds end,
    })
    local result = wait(method.login(interaction({ "device_code" }, events)))
    assert.is_true(result.ok)
    assert.are.equal("device-account", result.credential.accountId)
    assert.are.equal("device_code", events[1].type)
    assert.are.equal("ABCD", events[1].userCode)
    assert.are.equal(6, #http.requests)
    assert.are.same({ 0, 0, 0, 5000 }, sleeps)
    assert.is_truthy(http.requests[6].body:find(
      "redirect_uri=https%3a%2f%2fauth.openai.com%2fdeviceauth%2fcallback", 1, true))
  end)

  it("accepts Pi-compatible manual authorization code formats", function()
    for _, format in ipairs({ "hash", "fields", "raw" }) do
      local http = fake_http({ json(200, {
        access_token = token("manual"), refresh_token = "refresh", expires_in = 1,
      }) })
      local events = {}
      local method = codex.new({
        http = http,
        auth_base_url = "https://auth.test",
        start_callback_server = function() return nil end,
      })
      local result = wait(method.login(interaction({
        "browser",
        function()
          local state = events[1].url:match("[?&]state=([^&]+)")
          if format == "hash" then return "manual-code#" .. state end
          if format == "fields" then return "code=manual-code&state=" .. state end
          return "manual-code"
        end,
      }, events)))
      assert.is_true(result.ok)
      assert.matches("code=manual%-code", http.requests[1].body)
    end
  end)

  it("uses a cancellable timer while polling device authorization", function()
    local http = fake_http({
      json(200, { device_auth_id = "device", user_code = "CODE", interval = 0 }),
      json(200, { authorization_code = "authorization", code_verifier = "verifier" }),
      json(200, { access_token = token("timer"), refresh_token = "refresh", expires_in = 1 }),
    })
    local method = codex.new({
      http = http, now = function() return 0 end, auth_base_url = "https://auth.test",
    })
    local result = wait(method.login(interaction({ "device_code" }, {})))
    assert.is_true(result.ok)
  end)

  it("reports provider, selection, token, and credential failures", function()
    local function login_with(responses, choice)
      local method = codex.new({
        http = fake_http(responses), auth_base_url = "https://auth.test",
        start_callback_server = function() return { wait = function() return "code" end, close = function() end } end,
      })
      return method, wait(method.login(interaction({ choice }, {})))
    end
    local _, result = login_with({}, "unknown")
    assert.matches("Unknown", result.error.message)
    _, result = login_with({ json(401, { error = { message = "denied" } }) }, "browser")
    assert.matches("HTTP 401", result.error.message)
    _, result = login_with({ json(200, { access_token = "bad", refresh_token = "r", expires_in = 1 }) }, "browser")
    assert.matches("accountId", result.error.message)
    _, result = login_with({ { ok = true, status = 200, body = "not-json" } }, "browser")
    assert.matches("invalid JSON", result.error.message)
    _, result = login_with({ json(200, { access_token = token("account") }) }, "browser")
    assert.matches("missing fields", result.error.message)

    local function device_failure(responses, now)
      local selected = codex.new({
        http = fake_http(responses),
        now = now or function() return 0 end,
        sleep = function() end,
        auth_base_url = "https://auth.test",
      })
      return wait(selected.login(interaction({ "device_code" }, {})))
    end
    result = device_failure({ json(200, {}) })
    assert.matches("device code", result.error.message)
    result = device_failure({
      json(200, { device_auth_id = "device", user_code = "CODE", interval = 0 }),
      json(200, {}),
    })
    assert.matches("authorization response", result.error.message)
    result = device_failure({
      json(200, { device_auth_id = "device", user_code = "CODE", interval = 0 }),
      json(500, { error = "failed" }),
    })
    assert.matches("HTTP 500", result.error.message)
    local times = { 0, 1000000 }
    result = device_failure({
      json(200, { device_auth_id = "device", user_code = "CODE", interval = 0 }),
    }, function() return table.remove(times, 1) end)
    assert.matches("timed out", result.error.message)

    local method = codex.new()
    local ok, err = pcall(method.request_opts, { access = "token" })
    assert.is_false(ok)
    assert.are.equal("auth", err.kind)
  end)
end)
