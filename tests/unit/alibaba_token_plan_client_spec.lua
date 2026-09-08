local assert = require("luassert")
local async = require("neoagent.async")
local client_module = require("neoagent.providers.alibaba_token_plan.client")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end, 5))
  return (assert(run:result()))
end

---@param responses Neoagent.ByteFetchResult[]
---@return Neoagent.TestAlibabaTransport
local function fake_transport(responses)
  ---@class Neoagent.TestAlibabaTransport: Neoagent.ByteBackend
  ---@field requests Neoagent.HttpRequest[]
  ---@field responses Neoagent.ByteFetchResult[]
  local value = { requests = {}, responses = responses }
  ---@param opts Neoagent.ByteFetchOptions
  ---@return Neoagent.Run<Neoagent.ByteFetchResult, nil>
  function value.fetch(opts)
    value.requests[#value.requests + 1] = opts.request
    return async.run(function()
      return (assert(table.remove(value.responses, 1)))
    end)
  end
  return value
end

---@param status integer
---@param value Neoagent.JsonValue
---@return Neoagent.ByteFetchSuccess
local function response(status, value)
  return { ok = true, headers = {}, status = status, body = vim.json.encode(value) }
end

---@param access? string
---@return fun(scope?: string): Neoagent.Run<Neoagent.AuthResolution, nil>
local function auth(access)
  return function(scope)
    assert.are.equal("dashboard", scope)
    return async.run(function()
      if not access then return { ok = true, configured = false } end
      return {
        ok = true,
        configured = true,
        method = "dashboard",
        credential_type = "api_key",
        request_opts = {
          headers = { Authorization = "Bearer " .. access },
        },
      }
    end)
  end
end

describe("Alibaba Cloud Token Plan console client", function()
  it("queries and unwraps the Personal plan usage gateway", function()
    local transport = fake_transport({ response(200, {
      data = { DataV2 = { data = { data = {
        per5HourPercentage = 0.25,
        per5HourResetTime = 1786000000000,
        per1WeekPercentage = 0.6,
        per1WeekResetTime = 1786100000000,
      } } } },
    }) })
    local client = client_module.new({ transport = transport })

    local result = wait(client:usage({ resolve_auth = auth("console-token") }))

    assert(result.ok)
    assert.are.same({
      five_hour = { used = 0.25, resets_at = 1786000000 },
      seven_day = { used = 0.6, resets_at = 1786100000 },
    }, result.usage)
    local request = assert(transport.requests[1])
    assert.are.equal("POST", request.method)
    assert.matches("^https://bailian%-singapore%-cs%.alibabacloud%.com/cli/api%.json%?",
      request.url)
    assert.is_truthy((request.url:find(
      "action=IntlBroadScopeAspnGateway", 1, true)))
    assert.is_truthy((request.url:find("product=sfm_bailian", 1, true)))
    assert.is_truthy((request.url:find(vim.uri_encode(
      "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage", "rfc2396"),
      1, true)))
    assert.are.equal("Bearer console-token", rawget(assert(request.headers), "Authorization"))
    assert.are.equal("application/x-www-form-urlencoded",
      rawget(assert(request.headers), "Content-Type"))
    assert.is_truthy((assert(request.body):find("region=ap%-southeast%-1")))
    local encoded_params = assert(request.body):match("params=([^&]+)")
    local params = vim.json.decode(vim.uri_decode((assert(encoded_params))))
    assert.are.equal(
      "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage", params.Api)
    assert.are.equal("V2", params.Data.cornerstoneParam.protocol)
    assert.are.equal("p_efm", params.Data.cornerstoneParam.productCode)
  end)

  it("accepts absent unlimited windows and rejects unsafe responses", function()
    local transport = fake_transport({
      response(200, { data = { data = vim.empty_dict() } }),
      response(200, { data = { data = { per1WeekPercentage = 2 } } }),
      response(200, { data = {
        success = false, errorCode = "NotLogined",
      } }),
      { ok = true, headers = {}, status = 200, body = "not json" },
      response(503, {}),
    })
    local client = client_module.new({ transport = transport })
    local ctx = { resolve_auth = auth("token") }

    local result = wait(client:usage(ctx))
    assert(result.ok)
    assert.are.same({}, result.usage)
    assert.matches("invalid usage", assert(wait(client:usage(ctx)).error).message)
    result = wait(client:usage(ctx))
    assert.are.equal("auth", assert(result.error).kind)
    assert.matches("expired", assert(result.error).message)
    assert.matches("invalid JSON", assert(wait(client:usage(ctx)).error).message)
    assert.matches("HTTP 503", assert(wait(client:usage(ctx)).error).message)

    result = wait(client:usage({ resolve_auth = auth(nil) }))
    assert.are.equal("auth", assert(result.error).kind)
    assert.matches("Provider Shell", assert(result.error).message)
  end)

  it("bounds authentication, transport, and gateway failure surfaces", function()
    local transport = fake_transport({
      { ok = false, error = { kind = "transport", message = "offline" } },
      { ok = true, headers = {}, body = "{}" },
      { ok = true, headers = {}, status = 200, body = {} --[[@as string]] },
      { ok = true, headers = {}, status = 200, body = string.rep("x", 1025) },
      response(200, { data = {
        success = false,
        errorCode = "PermissionDenied",
      } }),
    })
    local client = client_module.new({
      transport = transport,
      max_response_bytes = 1024,
    })
    ---@param value unknown
    ---@return fun(scope?: string): Neoagent.Run<Neoagent.AuthResolution, nil>
    local function resolved(value)
      return function(scope)
        assert.are.equal("dashboard", scope)
        return async.run(function() return value --[[@as Neoagent.AuthResolution]] end)
      end
    end

    local result = wait(client:usage({ resolve_auth = resolved({
      ok = false,
      error = { kind = "auth", message = "console login rejected" },
    }) }))
    assert.are.equal("auth", assert(result.error).kind)
    assert.matches("login rejected", assert(result.error).message)

    result = wait(client:usage({ resolve_auth = resolved("invalid") }))
    assert.are.equal("auth", assert(result.error).kind)
    assert.matches("authorization failed", assert(result.error).message)

    result = wait(client:usage({ resolve_auth = resolved({
      ok = true,
      configured = true,
        method = "dashboard",
        credential_type = "api_key",
      request_opts = { headers = { ["X-Key"] = "not-a-bearer" } },
    }) }))
    assert.are.equal("auth", assert(result.error).kind)
    assert.matches("no bearer token", assert(result.error).message)

    assert.matches("offline",
      assert(wait(client:usage({ resolve_auth = auth("token") })).error).message)
    assert.matches("no HTTP status",
      assert(wait(client:usage({ resolve_auth = auth("token") })).error).message)
    assert.matches("body must be text",
      assert(wait(client:usage({ resolve_auth = auth("token") })).error).message)
    assert.matches("exceeds 1024 bytes",
      assert(wait(client:usage({ resolve_auth = auth("token") })).error).message)
    assert.matches("gateway rejected",
      assert(wait(client:usage({ resolve_auth = auth("token") })).error).message)
  end)
end)
