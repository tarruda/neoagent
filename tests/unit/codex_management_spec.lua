local async = require("neoagent.async")
local management = require("neoagent.providers.codex_management")
local fake_transport = require("tests.helpers.fake_transport")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function context(overrides)
  local resolved = vim.tbl_deep_extend("force", {
    ok = true,
    configured = true,
    credential_type = "oauth",
    request_opts = { headers = {
      Authorization = "Bearer secret-token",
      ["chatgpt-account-id"] = "secret-account",
    } },
    metadata = { email = "account@example.com", plan = "Plus" },
  }, overrides or {})
  return {
    resolve_auth = function()
      return async.run(function() return resolved end)
    end,
  }
end

describe("neoagent Codex management client", function()
  it("requests every bounded account endpoint with resolved OAuth headers", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = [[{"plan_type":"plus"}]] },
      { body = [[{"stats":{}}]] },
      { body = [[{"accounts":[]}]] },
      { body = [[{"available_count":0,"credits":[]}]] },
      { body = [[{"code":"reset","windows_reset":2}]] },
    }
    local client = management.new({
      base_url = "https://chatgpt.com/backend-api/codex/responses/",
      transport = transport,
      timeout_ms = 3210,
      max_response_bytes = 1024,
    })
    local ctx = context()
    assert.is_true(wait(client:usage(ctx)).ok)
    assert.is_true(wait(client:activity(ctx)).ok)
    assert.is_true(wait(client:accounts(ctx)).ok)
    assert.is_true(wait(client:reset_credits(ctx)).ok)
    assert.is_true(wait(client:redeem(ctx, "stable-request", "credit-1")).ok)

    assert.are.same({
      "/wham/usage",
      "/wham/profiles/me",
      "/wham/accounts/check",
      "/wham/rate-limit-reset-credits",
      "/wham/rate-limit-reset-credits/consume",
    }, vim.tbl_map(function(request)
      return request.url:match("(/wham/.*)$")
    end, transport.fetch_requests))
    for _, request in ipairs(transport.fetch_requests) do
      assert.are.equal("Bearer secret-token", request.headers.Authorization)
      assert.are.equal("secret-account",
        request.headers["chatgpt-account-id"])
      assert.are.equal(3210, request.timeout_ms)
      assert.are.equal(1024, request.max_response_bytes)
    end
    assert.are.equal("GET", transport.fetch_requests[1].method)
    assert.are.equal("POST", transport.fetch_requests[5].method)
    assert.are.same({
      redeem_request_id = "stable-request",
      credit_id = "credit-1",
    }, vim.json.decode(transport.fetch_requests[5].body))
  end)

  it("reports authentication and HTTP failures without secret or body data", function()
    local function request(resolved, response)
      local transport = fake_transport.new()
      transport.fetches = { response or { body = "{}" } }
      local result = wait(management.new({
        base_url = "https://example.test/backend-api",
        transport = transport,
      }):usage(context(resolved)))
      return result, transport
    end

    local result, transport = request({ configured = false })
    assert.is_false(result.ok)
    assert.matches("Sign in with ChatGPT", result.error.message)
    assert.are.equal(0, #transport.fetch_requests)

    result = request({ credential_type = "api_key" })
    assert.is_false(result.ok)
    assert.matches("API key authentication", result.error.message)

    for _, status in ipairs({ 401, 403, 500 }) do
      result = request({}, {
        status = status,
        body = [[{"error":"secret response contents"}]],
      })
      assert.is_false(result.ok)
      assert.are.equal(status, result.error.status)
      assert.is_nil(result.error.message:find("secret", 1, true))
      assert.is_nil(result.error.detail)
    end

    local missing_status = {
      fetch = function()
        return async.run(function()
          return { ok = true, body = "{}" }
        end)
      end,
    }
    result = wait(management.new({
      base_url = "https://example.test/backend-api",
      transport = missing_status,
    }):usage(context()))
    assert.is_false(result.ok)
    assert.matches("HTTP status", result.error.message)

    result = request({}, { body = "not-json" })
    assert.is_false(result.ok)
    assert.matches("invalid JSON", result.error.message)

    result = request({}, { body = "[]" })
    assert.is_false(result.ok)
    assert.matches("invalid JSON", result.error.message)

    result = request({}, { body = {} })
    assert.is_false(result.ok)
    assert.matches("body must be text", result.error.message)

    local oversized_transport = fake_transport.new()
    oversized_transport.fetches = { { body = string.rep("x", 1025) } }
    result = wait(management.new({
      base_url = "https://example.test/backend-api",
      transport = oversized_transport,
      max_response_bytes = 1024,
    }):usage(context()))
    assert.is_false(result.ok)
    assert.matches("exceeds 1024 bytes", result.error.message)
    assert.is_nil(result.error.detail)
  end)

  it("normalizes transport errors and cancels pending fetches", function()
    local transport = fake_transport.new()
    transport.fetches = { { error = {
      kind = "transport", message = "network unavailable",
    } } }
    local client = management.new({
      base_url = "https://example.test/backend-api",
      transport = transport,
    })
    local result = wait(client:usage(context()))
    assert.is_false(result.ok)
    assert.matches("network unavailable", result.error.message)

    local cancelled = false
    local started = false
    transport = {
      fetch = function()
        started = true
        return async.run(function(run)
          return async.await(function(done)
            run:on_cancel(function()
              cancelled = true
              done.reject({ kind = "cancelled", message = "cancelled" })
            end)
            return function() end
          end)
        end)
      end,
    }
    client = management.new({
      base_url = "https://example.test/backend-api",
      transport = transport,
    })
    local run = client:usage(context())
    assert(vim.wait(1000, function() return started end))
    run:cancel()
    result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.is_true(cancelled)
  end)

  it("validates construction and redemption identifiers", function()
    assert.has_error(function() management.new() end)
    assert.has_error(function()
      management.new({ base_url = "x", transport = {} })
    end)
    assert.has_error(function()
      management.new({ base_url = "x", max_response_bytes = 1 })
    end)
    assert.has_error(function()
      management.new({ base_url = "x", timeout_ms = 0 })
    end)
    local client = management.new({ base_url = "x" })
    assert.has_error(function() client:redeem(context(), "") end)
    assert.has_error(function()
      client:redeem(context(), "request", "")
    end)
  end)
end)
