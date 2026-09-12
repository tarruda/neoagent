local assert = require("luassert")
local async = require("neoagent.async")
local codex = require("neoagent.auth.openai_codex")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@param account string
---@param claims? { email?: string, profile_email?: string, plan?: string }
---@return string
local function token(account, claims)
  claims = claims or {}
  local payload = vim.base64.encode(vim.json.encode({
    email = claims.email,
    ["https://api.openai.com/profile"] = claims.profile_email and {
      email = claims.profile_email,
    } or nil,
    ["https://api.openai.com/auth"] = {
      chatgpt_account_id = account,
      chatgpt_plan_type = claims.plan,
    },
  })):gsub("+", "-"):gsub("/", "_"):gsub("=+$", "")
  return "header." .. payload .. ".signature"
end

---@param responses Neoagent.ByteFetchResult[]
---@return Neoagent.TestCodexAuthHttp
local function fake_http(responses)
  ---@class Neoagent.TestCodexAuthHttp: Neoagent.ByteBackend
  ---@field requests Neoagent.HttpRequest[]
  ---@field responses Neoagent.ByteFetchResult[]
  local value = { requests = {}, responses = responses }
  ---@param opts Neoagent.ByteFetchOptions
  ---@return Neoagent.Run<Neoagent.ByteFetchResult, nil>
  function value.fetch(opts)
    value.requests[#value.requests + 1] = opts.request
    local response = assert(table.remove(value.responses, 1))
    return async.run(function() return response end)
  end
  return value
end

---@param status integer
---@param value Neoagent.JsonValue
---@return Neoagent.ByteFetchSuccess
local function json(status, value)
  return { ok = true, headers = {}, status = status, body = vim.json.encode(value) }
end

---@param answers (string|fun(prompt: Neoagent.LoginPrompt): string)[]
---@param events Neoagent.AuthEvent[]
---@return Neoagent.LoginInteraction
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
      access_token = token("acct", {
        email = "account@example.com",
        plan = "self_serve_business_usage_based",
      }),
      refresh_token = "refresh", expires_in = 60,
    }) })
    local closed = false
    local method = codex.new({
      http = http,
      now = function() return 1000 end,
      auth_base_url = "https://auth.test",
      start_callback_server = function(state, host)
        assert.is_truthy(state)
        assert.are.equal("127.0.0.1", host)
        return { port = 1455, wait = function() return "browser-code" end, close = function() closed = true return true end }
      end,
    })
    ---@type Neoagent.AuthEvent[]
    local events = {}
    local result = wait(method.login(interaction({ "browser" }, events)))
    assert(result.ok)
    assert.is_true(closed)
    assert.are.equal("acct", result.credential.accountId)
    assert.are.equal(61000, result.credential.expires)
    assert.matches("originator=neoagent", assert(assert(events[1]).url))
    assert.matches("code_challenge_method=S256", assert(assert(events[1]).url))
    assert.are.equal("https://auth.test/oauth/token", assert(http.requests[1]).url)
    assert.are.equal(30000, assert(http.requests[1]).timeout_ms)
    assert.are.equal(1024 * 1024,
      assert(http.requests[1]).max_response_bytes)
    assert.matches("code=browser%-code", assert(assert(http.requests[1]).body))
    local headers = assert(method.request_opts(result.credential).headers)
    assert.are.equal("Bearer " .. result.credential.access, rawget(headers, "Authorization"))
    assert.are.equal("acct", rawget(headers, "chatgpt-account-id"))
    assert.are.equal("responses=experimental", rawget(headers, "OpenAI-Beta"))
    assert.are.same({
      email = "account@example.com",
      plan = "Business",
    }, assert(method.public_metadata)(result.credential))
    assert.is_nil(rawget(assert(assert(method.public_metadata)(result.credential)), "accountId"))
  end)

  it("bounds safe public account metadata and normalizes plan labels", function()
    local method = codex.new()
    -- Exercise defensive metadata extraction from incomplete credentials.
    local metadata = assert(method.public_metadata) --[[@as fun(credential: table<string, unknown>): table<string, string>]]
    local cache_identity = assert(method.cache_identity) --[[@as fun(credential: table<string, unknown>): string?]]
    assert.are.same({ plan = "Enterprise" }, metadata({
      plan = "enterprise_cbp_usage_based",
      email = "bad\nemail@example.com",
    }))
    assert.are.same({ email = "member@example.com", plan = "Pro Lite" },
      metadata({
        email = "member@example.com",
        plan = "prolite",
      }))
    assert.are.same({ account = "ChatGPT" }, metadata({
      email = string.rep("a", 255),
      plan = string.rep("p", 65),
    }))
    assert.are.same({ email = "token@example.com", plan = "Pro" },
      metadata({ access = token("acct", {
        profile_email = "token@example.com",
        plan = "pro",
      }) }))
    assert.are.equal("explicit", cache_identity({
      accountId = "explicit", access = token("fallback"),
    }))
    assert.are.equal("fallback", cache_identity({
      access = token("fallback"),
    }))
    assert.is_nil(cache_identity({}))
    assert.are.same({ account = "ChatGPT" }, metadata({
      access = "header." .. vim.base64.encode("not-json") .. ".signature",
    }))
  end)

  it("extracts account display metadata from the OAuth ID token", function()
    local http = fake_http({ json(200, {
      access_token = token("acct"),
      id_token = token("acct", {
        profile_email = "profile@example.com",
        plan = "plus",
      }),
      refresh_token = "refresh",
      expires_in = 60,
    }) })
    local method = codex.new({
      http = http,
      auth_base_url = "https://auth.test",
      start_callback_server = function()
        return { port = 1455, wait = function() return "browser-code" end, close = function() return true end }
      end,
    })
    local result = wait(method.login(interaction({ "browser" }, {})))

    assert(result.ok)
    assert.are.equal("profile@example.com", result.credential.email)
    assert.are.equal("plus", result.credential.plan)
    assert.are.same({
      email = "profile@example.com",
      plan = "Plus",
    }, assert(method.public_metadata)(result.credential))
  end)

  it("falls back to a pasted redirect URL and refreshes tokens", function()
    local http = fake_http({
      json(200, {
        access_token = token("first"),
        id_token = token("first", {
          profile_email = "account@example.com",
          plan = "plus",
        }),
        refresh_token = "r1",
        expires_in = 1,
      }),
      json(200, { access_token = token("second"), refresh_token = "r2", expires_in = 2 }),
    })
    ---@type string?
    local state
    ---@type Neoagent.AuthEvent[]
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
        state = assert(assert(events[1]).url):match("[?&]state=([^&]+)")
        return "http://localhost:1455/auth/callback?code=pasted&state=" .. assert(state)
      end,
    }, events)))
    assert(result.ok)
    assert.are.equal("first", result.credential.accountId)
    result = wait(assert(method.refresh)(result.credential))
    assert(result.ok)
    assert.are.equal("second", result.credential.accountId)
    assert.are.equal("account@example.com", result.credential.email)
    assert.are.equal("plus", result.credential.plan)
    assert.matches("grant_type=refresh_token", assert(assert(http.requests[2]).body))
    assert.matches("refresh_token=r1", assert(assert(http.requests[2]).body))
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
    ---@type Neoagent.AuthEvent[]
    local events = {}
    ---@type number[]
    local sleeps = {}
    local method = codex.new({
      http = http,
      now = function() return 0 end,
      auth_base_url = "https://auth.test",
      sleep = function(milliseconds) sleeps[#sleeps + 1] = milliseconds end,
    })
    local result = wait(method.login(interaction({ "device_code" }, events)))
    assert(result.ok)
    assert.are.equal("device-account", result.credential.accountId)
    assert.are.equal("device_code", assert(events[1]).type)
    assert.are.equal("ABCD", assert(events[1]).userCode)
    assert.are.equal(6, #http.requests)
    assert.are.same({ 0, 0, 0, 5000 }, sleeps)
    assert.is_truthy((assert(assert(http.requests[6]).body):find(
      "redirect_uri=https%3a%2f%2fauth.openai.com%2fdeviceauth%2fcallback", 1, true)))
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
    assert(result.ok)

    local pending_http = fake_http({
      json(200, {
        device_auth_id = "pending", user_code = "WAIT", interval = 60,
      }),
    })
    method = codex.new({
      http = pending_http,
      auth_base_url = "https://auth.test",
    })
    local run = method.login(interaction({ "device_code" }, {}))
    assert(vim.wait(1000, function()
      return #pending_http.requests == 1 and not run:is_done()
    end))
    run:cancel()
    result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)

    local original_new_timer = vim.uv.new_timer
    local started, stopped, closed = false, false, false
    local patched, patch_err = pcall(function()
      vim.uv.new_timer = function()
        return {
          start = function() started = true end,
          stop = function() stopped = true end,
          is_closing = function() return closed end,
          close = function() closed = true end,
        } --[[@as uv.uv_timer_t]]
      end
      pending_http = fake_http({
        json(200, {
          device_auth_id = "pending", user_code = "WAIT", interval = 60,
        }),
      })
      method = codex.new({
        http = pending_http,
        auth_base_url = "https://auth.test",
      })
      run = method.login(interaction({ "device_code" }, {}))
      assert(vim.wait(1000, function() return started end))
      run:cancel()
      result = wait(run)
      assert.is_false(result.ok)
      assert.are.equal("cancelled", assert(result.error).kind)
      assert.is_true(stopped)
      assert.is_true(closed)
    end)
    vim.uv.new_timer = original_new_timer
    assert(patched, patch_err)
  end)

  it("bounds stalled and oversized authentication responses", function()
    local stalled_timeout
    ---@type Neoagent.ByteBackend
    local stalled = {
      fetch = function(opts)
        stalled_timeout = opts.request.timeout_ms
        return async.run(function()
          return async.await(function(done)
            local timer = assert(vim.uv.new_timer())
            local request_timeout = opts.request.timeout_ms
            if type(request_timeout) ~= "number" then
              error("expected a request timeout")
            end
            timer:start(math.floor(request_timeout), 0, function()
              timer:stop()
              timer:close()
              done.resolve({
                ok = false,
                error = { kind = "transport", message = "request timed out" },
              })
            end)
            return function()
              timer:stop()
              if not timer:is_closing() then
                timer:close()
              end
            end
          end)
        end)
      end,
    }
    local method = codex.new({
      http = stalled,
      timeout_ms = 5,
      auth_base_url = "https://auth.test",
      start_callback_server = function()
        return {
          port = 1455,
          wait = function() return "code" end,
          close = function() return true end,
        }
      end,
    })
    local result = wait(method.login(interaction({ "browser" }, {})))
    assert.is_false(result.ok)
    assert.matches("timed out", assert(result.error).message)
    assert.are.equal(5, stalled_timeout)

    method = codex.new({
      http = fake_http({ {
        ok = true,
        headers = {},
        status = 200,
        body = string.rep("x", 33),
      } }),
      max_response_bytes = 32,
      auth_base_url = "https://auth.test",
      start_callback_server = function()
        return {
          port = 1455,
          wait = function() return "code" end,
          close = function() return true end,
        }
      end,
    })
    result = wait(method.login(interaction({ "browser" }, {})))
    assert.is_false(result.ok)
    assert.matches("exceeds 32 bytes", assert(result.error).message)
  end)

  it("bounds device polling by the remaining workflow deadline", function()
    local http = fake_http({
      json(200, {
        device_auth_id = "device",
        user_code = "CODE",
        interval = 0,
      }),
      json(200, {
        authorization_code = "authorization",
        code_verifier = "verifier",
      }),
      json(200, {
        access_token = token("account"),
        refresh_token = "refresh",
        expires_in = 1,
      }),
    })
    local times = { 0, 899990, 899995, 899996 }
    local method = codex.new({
      http = http,
      timeout_ms = 20,
      now = function()
        return table.remove(times, 1) or 899996
      end,
      sleep = function() end,
      auth_base_url = "https://auth.test",
    })
    local result = wait(method.login(interaction({ "device_code" }, {})))
    assert(result.ok)
    assert.are.equal(5, assert(http.requests[2]).timeout_ms)
    assert.are.equal(20, assert(http.requests[3]).timeout_ms)
  end)

  it("reports provider, selection, token, and credential failures", function()
    ---@param responses Neoagent.ByteFetchResult[]
    ---@param choice string
    ---@return Neoagent.AuthMethod<Neoagent.CodexCredential>, Neoagent.CredentialResult<Neoagent.CodexCredential>
    local function login_with(responses, choice)
      local method = codex.new({
        http = fake_http(responses), auth_base_url = "https://auth.test",
        start_callback_server = function() return { port = 1455, wait = function() return "code" end, close = function() return true end } end,
      })
      return method, wait(method.login(interaction({ choice }, {})))
    end
    local _, result = login_with({}, "unknown")
    assert.matches("Unknown", assert(result.error).message)
    _, result = login_with({ json(401, { error = { message = "denied" } }) }, "browser")
    assert.matches("HTTP 401", assert(result.error).message)
    _, result = login_with({ json(200, { access_token = "bad", refresh_token = "r", expires_in = 1 }) }, "browser")
    assert.matches("accountId", assert(result.error).message)
    _, result = login_with({ { ok = true, headers = {}, status = 200, body = "not-json" } }, "browser")
    assert.matches("invalid JSON", assert(result.error).message)
    _, result = login_with({ json(200, "not-json") }, "browser")
    assert.matches("invalid JSON", assert(result.error).message)
    _, result = login_with({ json(200, { access_token = token("account") }) }, "browser")
    assert.matches("missing fields", assert(result.error).message)

    ---@param responses Neoagent.ByteFetchResult[]
    ---@param now? fun(): number
    ---@return Neoagent.CredentialResult<Neoagent.CodexCredential>
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
    assert.matches("device code", assert(result.error).message)
    result = device_failure({
      json(200, { device_auth_id = "device", user_code = "CODE", interval = 0 }),
      json(200, {}),
    })
    assert.matches("authorization response", assert(result.error).message)
    result = device_failure({
      json(200, { device_auth_id = "device", user_code = "CODE", interval = 0 }),
      json(500, { error = "failed" }),
    })
    assert.matches("HTTP 500", assert(result.error).message)
    result = device_failure({
      json(200, { device_auth_id = "device", user_code = "CODE", interval = 0 }),
      { ok = false, error = { kind = "http", message = "poll transport failed" } },
    })
    assert.matches("poll transport failed", assert(result.error).message)
    local times = { 0, 1000000 }
    result = device_failure({
      json(200, { device_auth_id = "device", user_code = "CODE", interval = 0 }),
    }, function() return (assert(table.remove(times, 1))) end)
    assert.matches("timed out", assert(result.error).message)

    local method = codex.new()
    local incomplete = { access = "token" }
    local ok, err = pcall(method.request_opts,
      incomplete --[[@as Neoagent.CodexCredential]])
    assert.is_false(ok)
    assert.are.equal("auth", (err --[[@as Neoagent.Error]]).kind)
  end)

  it("reports browser callback and pasted redirect failures", function()
    local method = codex.new({
      http = fake_http({}),
      auth_base_url = "https://auth.test",
      start_callback_server = function()
        return {
          port = 1455,
          wait = function() error("callback wait failed") end,
          close = function() return true end,
        }
      end,
    })
    local result = wait(method.login(interaction({ "browser" }, {})))
    assert.is_false(result.ok)
    assert.matches("callback wait failed", assert(result.error).message)

    method = codex.new({
      http = fake_http({}),
      auth_base_url = "https://auth.test",
      start_callback_server = function() return nil end,
    })
    result = wait(method.login(interaction({ "browser", "http://localhost/callback?code=value&state=wrong" }, {})))
    assert.is_false(result.ok)
    assert.matches("state mismatch", assert(result.error).message)

    result = wait(method.login(interaction({ "browser", "" }, {})))
    assert.is_false(result.ok)
    assert.matches("Missing authorization code", assert(result.error).message)
  end)
end)
