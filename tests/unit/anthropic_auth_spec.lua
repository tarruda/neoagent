local anthropic_auth = require("neoagent.auth.anthropic")
local async = require("neoagent.async")

local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return run:result()
end

local function fake_http(responses)
  local fake = { requests = {}, responses = responses or {} }
  function fake.fetch(opts)
    fake.requests[#fake.requests + 1] = opts.request
    local response = table.remove(fake.responses, 1) or {}
    return async.run(function()
      if response.error then return { ok = false, error = response.error } end
      return {
        ok = true,
        status = response.status or 200,
        body = type(response.body) == "string" and response.body or vim.json.encode(response.body or {}),
      }
    end)
  end
  return fake
end

local function query_value(url, name)
  local query = url:match("%?(.+)$") or ""
  for pair in query:gmatch("[^&]+") do
    local key, value = pair:match("^([^=]+)=?(.*)$")
    if vim.uri_decode(key) == name then return vim.uri_decode(value:gsub("+", " ")) end
  end
end

describe("neoagent.auth.anthropic", function()
  it("logs in manually, refreshes, and derives the Claude plan request profile", function()
    local http = fake_http({
      { body = {
        access_token = "access-1",
        refresh_token = "refresh-1",
        expires_in = 3600,
      } },
      { body = {
        access_token = "access-2",
        refresh_token = "refresh-2",
        expires_in = 7200,
      } },
    })
    local method = anthropic_auth.new({
      http = http,
      now = function() return 1000000 end,
      authorize_url = "https://auth.test/authorize",
      token_url = "https://auth.test/token",
      redirect_uri = "http://localhost:53692/callback",
    })
    local auth_url
    local prompts = {}
    local interaction = {
      notify = function(event)
        if event.type == "auth_url" then auth_url = event.url end
      end,
      prompt = function(prompt, done)
        prompts[#prompts + 1] = prompt
        if prompt.type == "select" then
          done.resolve("manual")
        else
          local state = assert(query_value(auth_url, "state"))
          done.resolve("http://localhost:53692/callback?code=code-1&state=" .. vim.uri_encode(state))
        end
      end,
    }

    local login = wait(method.login(interaction))
    assert.is_true(login.ok)
    assert.are.same({ "select", "manual_code" }, vim.tbl_map(function(value) return value.type end, prompts))
    assert.are.equal("oauth", login.credential.type)
    assert.are.equal("access-1", login.credential.access)
    assert.are.equal("refresh-1", login.credential.refresh)
    assert.are.equal(4300000, login.credential.expires)
    assert.are.equal("https://auth.test/token", http.requests[1].url)
    local exchange = vim.json.decode(http.requests[1].body)
    assert.are.equal("authorization_code", exchange.grant_type)
    assert.are.equal("code-1", exchange.code)
    assert.are.equal(query_value(auth_url, "state"), exchange.state)
    assert.are.equal(exchange.state, exchange.code_verifier)
    assert.are.equal("S256", query_value(auth_url, "code_challenge_method"))

    local refreshed = wait(method.refresh(login.credential))
    assert.is_true(refreshed.ok)
    assert.are.equal("access-2", refreshed.credential.access)
    assert.are.equal("refresh-2", refreshed.credential.refresh)
    assert.are.equal(7900000, refreshed.credential.expires)
    local refresh = vim.json.decode(http.requests[2].body)
    assert.are.equal("refresh_token", refresh.grant_type)
    assert.are.equal("refresh-1", refresh.refresh_token)

    local request_opts = method.request_opts(refreshed.credential)
    assert.are.equal("Bearer access-2", request_opts.headers.Authorization)
    assert.matches("claude%-code", request_opts.headers["anthropic-beta"])
    assert.are.equal("cli", request_opts.headers["x-app"])
  end)

  it("cancels a pending callback login and closes its server", function()
    local closed = false
    local waiting = false
    local method = anthropic_auth.new({
      start_callback_server = function()
        return {
          wait = function()
            waiting = true
            return async.await(function() return function() end end)
          end,
          close = function() closed = true end,
        }
      end,
    })
    local run = method.login({
      notify = function() end,
      prompt = function(prompt, done)
        assert.are.equal("select", prompt.type)
        done.resolve("browser")
      end,
    })
    assert(vim.wait(1000, function() return waiting end))
    run:cancel()
    local result = wait(run)

    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.is_true(closed)
  end)

  it("rejects state mismatches and malformed token responses", function()
    local cases = {
      {
        http = fake_http(),
        manual = function() return "code#wrong-state" end,
        message = "state mismatch",
        requests = 0,
      },
      {
        http = fake_http({ { body = { access_token = "missing-fields" } } }),
        manual = function(url)
          local state = assert(query_value(url, "state"))
          return "code#" .. state
        end,
        message = "missing fields",
        requests = 1,
      },
      {
        http = fake_http({ { body = "not-json" } }),
        manual = function(url)
          local state = assert(query_value(url, "state"))
          return "code=" .. vim.uri_encode("code") .. "&state=" .. vim.uri_encode(state)
        end,
        message = "invalid JSON",
        requests = 1,
      },
      {
        http = fake_http(),
        manual = function() return "" end,
        message = "Missing authorization code",
        requests = 0,
      },
      {
        http = fake_http({ { status = 400, body = { error = { message = "invalid grant" } } } }),
        manual = function(url)
          local state = assert(query_value(url, "state"))
          return "code#" .. state
        end,
        message = "HTTP 400",
        requests = 1,
      },
    }

    for _, case in ipairs(cases) do
      local auth_url
      local method = anthropic_auth.new({
        http = case.http,
        authorize_url = "https://auth.test/authorize",
        token_url = "https://auth.test/token",
      })
      local result = wait(method.login({
        notify = function(event)
          if event.type == "auth_url" then auth_url = event.url end
        end,
        prompt = function(prompt, done)
          if prompt.type == "select" then done.resolve("manual")
          else done.resolve(case.manual(auth_url)) end
        end,
      }))
      assert.is_false(result.ok)
      assert.are.equal("auth", result.error.kind)
      assert.matches(case.message, result.error.message)
      assert.are.equal(case.requests, #case.http.requests)
    end
  end)

  it("rejects unknown login modes and callback setup failures", function()
    local unknown = anthropic_auth.new()
    local result = wait(unknown.login({
      notify = function() end,
      prompt = function(_, done) done.resolve("unknown") end,
    }))
    assert.is_false(result.ok)
    assert.matches("Unknown Anthropic login method", result.error.message)

    local unavailable = anthropic_auth.new({
      start_callback_server = function() return nil, "address in use" end,
    })
    result = wait(unavailable.login({
      notify = function() end,
      prompt = function(_, done) done.resolve("browser") end,
    }))
    assert.is_false(result.ok)
    assert.matches("callback server", result.error.message)
  end)
end)
