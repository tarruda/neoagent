local assert = require("luassert")
local async = require("neoagent.async")
local auth = require("neoagent.auth")
local fake_transport = require("tests.helpers.fake_transport")
local provider = require("neoagent.providers.qwencloud_token_plan")
local provider_service = require("neoagent.provider_service")

local block = require("tests.helpers.provider_state").block
local memory_store = require("tests.helpers.auth_manager").store

local GRAY = { body = [[{"code":"200","data":{"IsGray":true}}]] }
local SEATS_EMPTY = { body = [[{"code":"200","data":{"Success":true,"Data":{}}}]] }
local INSTANCES_EMPTY = { body = [[{"code":"200","data":{"Data":[]}}]] }
local ISSUED = { body = [[{"code":"200","successResponse":true,"data":{"cliAccessToken":"synthetic:derived"}}]] }
local EXPIRY = 4070908800000

---@param data? Neoagent.JsonValue
---@return Neoagent.TestByteResponse
local function individual_reply(data)
  return {
    body = vim.json.encode({
      code = "200",
      successResponse = true,
      data = {
        success = true,
        DataV2 = { ret = { "SUCCESS::ok" }, data = { code = "SUCCESS", success = true, data = data } },
      },
    }),
  }
end

local NO_INDIVIDUAL = individual_reply()
local INDIVIDUAL = individual_reply({
  status = "VALID",
  instanceCode = "synthetic-monthly-plan",
  specCode = "pro",
  startTime = 946684800000,
  endTime = EXPIRY,
})

---@param scope? string
---@return Neoagent.Run<Neoagent.AuthResolution, nil>
local function usage_auth(scope)
  assert.are.equal("usage", scope)
  return async.run(function()
    return {
      ok = true,
      configured = true,
      method = "synthetic-browser",
      credential_type = "oauth",
      request_opts = { headers = { Authorization = "Bearer synthetic-browser-token" } },
    }
  end)
end

---@param service Neoagent.ProviderService
---@param resolve_auth? fun(scope?: string): Neoagent.Run<Neoagent.AuthResolution, nil>
---@return Neoagent.ProviderOperationResult
local function refresh(service, resolve_auth)
  local run = assert((provider_service.run(service, "refresh", { resolve_auth = resolve_auth or usage_auth })))
  assert(vim.wait(2000, function()
    return run:is_done()
  end))
  return (assert(run:result()))
end

describe("QwenCloud Token Plan provider service", function()
  it("exposes the QwenCloud endpoint without quota actions when usage auth isn't configured", function()
    local service = provider.new(nil, { provider_id = "qwencloud-token-plan" })

    assert.are.equal("qwencloud-token-plan", service.id)
    assert.are.equal("QwenCloud Token Plan", service.name)
    assert.are.same({}, service.operations)
    assert.are.equal(
      "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1",
      assert(block(service:state(), "field", "Endpoint")).value
    )

    local custom = provider.new({ base_url = "https://example.test/v1/" })
    assert.are.equal("https://example.test/v1", assert(block(custom:state(), "field", "Endpoint")).value)
    assert(service.destroy)(service)
    assert.are.same({}, service:state().blocks)
    assert(service.destroy)(service)
  end)

  it("rejects unsupported service options", function()
    assert.has_error(function()
      provider.new({ service_opts = { unsupported = true } })
    end)
    assert.has_error(function()
      provider.new({ service_opts = { timeout_ms = 0 } })
    end)
  end)

  describe("scoped quota reporting", function()
    ---@type Neoagent.TestByteBackend
    local transport
    ---@type Neoagent.ProviderService
    local service
    ---@type Neoagent.AuthManager
    local manager
    ---@type Neoagent.ProviderOperationRun?
    local pending_refresh
    ---@type number
    local now

    before_each(function()
      transport = fake_transport.new()
      now = EXPIRY - 1000
      manager = auth.new({
        methods = { ["synthetic-browser"] = require("neoagent.auth.qwencloud_usage").new() },
        store = memory_store({
          ["synthetic-browser"] = { type = "oauth", access = "synthetic-access-token", expires = EXPIRY },
        }),
        now = function()
          return now
        end,
      })
      service = provider.new({
        auth_scopes = { usage = "synthetic-browser" },
        base_url = "https://inference.example.test/v1",
        service_opts = { timeout_ms = 4444, max_response_bytes = 8192 },
      }, { transport = transport, auth = manager })
    end)

    after_each(function()
      if pending_refresh then
        pending_refresh:cancel()
        pending_refresh = nil
      end
      assert(service.destroy)(service)
    end)

    it("uses a Personal Plan's monthly balance after the seat eligibility check fails", function()
      transport.fetches = {
        { body = [[{"code":"unavailable","message":"private gateway response"}]] },
        { body = [[{"code":"200","data":{"Data":[{"Status":"expired"}]}}]] },
        {
          body = [[{"code":"200","data":{"Data":[{
          "Status":"valid","TemplateName":"Personal plan","InitCapacityBaseValue":"100",
          "CurrCapacityBaseValue":"35","periodCapacityBaseValue":"15","CapacityTypeCode":"periodMonthlyShift",
          "EndTime":1798761600000
        }]}}]],
        },
        {
          body = [[{"code":"200","data":{"Data":[
          {"Status":"expired","CurrCapacityBaseValue":"80"},
          {"Status":"valid","CurrCapacityBaseValue":"1.5"},
          {"Status":{"Code":"valid"},"CurrCapacityBaseValue":"2.75"}
        ]}}]],
        },
      }
      local result = refresh(service)
      assert.is_true(result.ok, result.error and result.error.message)
      local state = service:state()
      local limit = assert(block(state, "limit", "Monthly Credits"))
      assert.are.equal(0.15, limit.remaining)
      assert.are.equal("warn", limit.level)
      assert.are.equal("15 of 100 Credits remaining", limit.detail)
      assert.is_nil(limit.resets_at)
      assert.are.equal("Personal plan", assert(block(state, "field", "Plan")).value)
      assert.are.equal("4.25", assert(block(state, "field", "Add-on Credits remaining")).value)
      local personal = assert(transport.fetch_requests[3])
      assert.are.equal(4444, personal.timeout_ms)
      assert.are.equal(8192, personal.max_response_bytes)
      assert.are.equal("https://cli.qwencloud.com/data/v2/api.json", personal.url)
      assert.are.same({
        product = "BssOpenAPI-V3",
        region = "ap-southeast-1",
        action = "DescribeFrInstances",
        params = {
          Group = "tokenPlan",
          CommodityCode = "sfm_tokenplanpersonal_dp_intl",
          PageNum = "1",
          PageSize = "10",
        },
      }, vim.json.decode((assert(personal.body))))
    end)

    it("sums seat groups and reads the monthly reset from a timestamp with an offset", function()
      transport.fetches = {
        GRAY,
        {
          body = [[{"code":"200","data":{"SubscriptionGroupList":[
        {"NextCycleFlushTime":"2027-01-01T08:00:00+08:00","TotalValue":"25","SurplusValue":"0","EquityList":[]},
        {"EquityList":[{"EquityCode":"credit_value","TotalValue":"75","SurplusValue":"0"}]}
      ]}}]],
        },
        INSTANCES_EMPTY,
      }
      assert.is_true(refresh(service).ok)
      local state = service:state()
      local limit = assert(block(state, "limit", "Monthly Credits"))
      assert.are.equal("Token Plan", assert(block(state, "field", "Plan")).value)
      assert.are.equal("0 of 100 Credits remaining", limit.detail)
      assert.are.equal("error", limit.level)
      assert.are.equal(1798761600, limit.resets_at)
      assert.is_nil(block(state, "field", "Add-on Credits remaining"))
    end)

    it("reads the credit equity by code when it follows another equity", function()
      transport.fetches = {
        GRAY,
        {
          body = [[{"code":"200","data":{"SubscriptionGroupList":[{"EquityList":[
            {"EquityCode":"seat_count","TotalValue":"5","SurplusValue":"2"},
            {"EquityCode":"credit_value","TotalValue":"25000","SurplusValue":"6374"}
          ]}]}}]],
        },
        INSTANCES_EMPTY,
      }
      assert.is_true(refresh(service).ok)
      local limit = assert(block(service:state(), "limit", "Monthly Credits"))
      assert.are.equal("6374 of 25000 Credits remaining", limit.detail)
    end)

    for _, summary in ipairs({
      { name = "an empty group list", body = [[{"code":"200","data":{"SubscriptionGroupList":[]}}]] },
      { name = "an empty successful summary", body = [[{"code":"200","data":{"Success":true,"Data":{}}}]] },
    }) do
      it("loads Individual Credits when the Team lookup returns " .. summary.name, function()
        transport.fetches = {
          GRAY,
          { body = summary.body },
          {
            body = [[{"code":"200","data":{"Data":[{"Status":"valid","TemplateName":"Individual",
              "InitCapacityBaseValue":"100","CurrCapacityBaseValue":"35"}]}}]],
          },
          INSTANCES_EMPTY,
        }
        local result = refresh(service)
        assert.is_true(result.ok, result.error and result.error.message)
        local state = service:state()
        assert.are.equal("Individual", assert(block(state, "field", "Plan")).value)
        assert.are.equal(0.35, assert(block(state, "limit", "Monthly Credits")).remaining)
        assert.are.equal(4, #transport.fetch_requests)
        local personal = assert(transport.fetch_requests[3])
        local request = vim.json.decode((assert(personal.body)))
        assert.are.equal("DescribeFrInstances", request.action)
        assert.are.equal("sfm_tokenplanpersonal_dp_intl", request.params.CommodityCode)
      end)
    end

    it("reports Individual Credits when the earlier quota services are temporarily unavailable", function()
      transport.fetches = {
        GRAY,
        { status = 503, body = "private Team gateway response" },
        { status = 429, body = "private Personal gateway response" },
        ISSUED,
        INDIVIDUAL,
        individual_reply({ per1WeekPercentage = 0.25 }),
        INSTANCES_EMPTY,
      }

      local result = refresh(service)
      assert.is_true(result.ok, result.error and result.error.message)
      local state = service:state()
      assert.are.equal("Individual Pro", assert(block(state, "field", "Plan")).value)
      assert.are.equal(0.75, assert(block(state, "limit", "Weekly Credits")).remaining)
      assert.are.equal(7, #transport.fetch_requests)
    end)

    it("retains the first temporary quota error when no lookup confirms a balance", function()
      transport.fetches = {
        { body = [[{"code":"200","data":{"IsGray":false}}]] },
        { status = 503, body = "private Team gateway response" },
        { error = { kind = "transport", message = "Personal gateway was unreachable" } },
        ISSUED,
        NO_INDIVIDUAL,
      }

      local result = refresh(service)
      assert.matches("HTTP 503", assert(result.error).message, 1, true)
      assert.are.equal(5, #transport.fetch_requests)
      assert.matches("Quota refresh failed", assert(block(service:state(), "status")).text, 1, true)
    end)

    it("distinguishes an account without an active plan from a failed quota lookup", function()
      transport.fetches = {
        { body = [[{"code":"200","data":{"IsGray":false}}]] },
        INSTANCES_EMPTY,
        INSTANCES_EMPTY,
        ISSUED,
        NO_INDIVIDUAL,
        INSTANCES_EMPTY,
        { status = 502, body = "private gateway response" },
        INSTANCES_EMPTY,
        INSTANCES_EMPTY,
        ISSUED,
        NO_INDIVIDUAL,
      }
      assert.is_true(refresh(service).ok)
      assert.matches("No active QwenCloud Token Plan", assert(block(service:state(), "status")).text, 1, true)
      local result = refresh(service)
      assert.is_false(result.ok)
      local status = assert(block(service:state(), "status"))
      assert.matches("HTTP 502", status.text, 1, true)
      assert.is_nil((status.text:find("private gateway response", 1, true)))
      assert.is_nil((vim.inspect(service:state()):find("No active", 1, true)))
    end)

    it("reports the Individual monthly percentage when no weekly window is returned", function()
      transport.fetches = {
        GRAY,
        SEATS_EMPTY,
        INSTANCES_EMPTY,
        ISSUED,
        INDIVIDUAL,
        individual_reply({ per1WeekPercentage = vim.NIL, per1MonthPercentage = 0.625 }),
        INSTANCES_EMPTY,
      }
      local result = refresh(service)
      assert.is_true(result.ok, result.error and result.error.message)
      local state = service:state()
      assert.are.equal("Individual Pro", assert(block(state, "field", "Plan")).value)
      local limit = assert(block(state, "limit", "Monthly Credits"))
      assert.are.equal(0.375, limit.remaining)
      assert.is_nil(limit.resets_at)
      assert.is_nil(block(state, "limit", "Weekly Credits"))
      assert.are.equal(7, #transport.fetch_requests)
    end)

    for _, example in ipairs({
      {
        issue = [[{"code":"200","successResponse":false,"data":{"cliAccessToken":"synthetic:derived"}}]],
        name = "an issuance that did not succeed",
      },
      {
        issue = [[{"code":"200","successResponse":true,"data":{"cliAccessToken":"synthetic-browser-token"}}]],
        name = "a returned copy of the browser credential",
      },
    }) do
      it("stops before the Individual gateway after " .. example.name, function()
        transport.fetches = { GRAY, SEATS_EMPTY, INSTANCES_EMPTY, { body = example.issue } }
        local result = refresh(service)
        assert.matches("invalid Individual gateway credential", assert(result.error).message, 1, true)
        assert.are.equal(4, #transport.fetch_requests)
      end)
    end

    it("treats Individual gateway authentication rejection as a usage login problem", function()
      transport.fetches = {
        GRAY,
        SEATS_EMPTY,
        INSTANCES_EMPTY,
        ISSUED,
        {
          body = [[{"code":"200","successResponse":true,"data":{
            "success":false,"errorCode":"BailianGateway.Login.NotLogined"
          }}]],
        },
      }
      local result = refresh(service)
      assert.are.equal("auth", assert(result.error).kind)
      assert.are.equal(5, #transport.fetch_requests)
    end)

    for _, example in ipairs({
      {
        requests = { { body = [[{"code":"200","successResponse":true,"data":[]}]] } },
        error = "Individual subscription gateway response",
      },
      {
        requests = {
          { body = [[{"code":"200","successResponse":true,"data":{"success":true,"errorCode":"not-empty"}}]] },
        },
        error = "Individual subscription gateway result",
      },
      {
        requests = {
          {
            body = [[{"code":"200","successResponse":true,"data":{"success":true,
              "DataV2":{"ret":["PRIVATE::private marker"],"data":{"code":"SUCCESS","success":true}}
            }}]],
          },
        },
        error = "Individual subscription result",
      },
      {
        requests = { individual_reply(vim.empty_dict()) },
        error = "Individual subscription",
      },
      {
        requests = { individual_reply(vim.NIL) },
        error = "Individual subscription",
        name = "a null Individual subscription",
      },
      {
        requests = { INDIVIDUAL, NO_INDIVIDUAL },
        error = "Individual usage",
      },
      {
        requests = { INDIVIDUAL, individual_reply({ per1WeekPercentage = 1.1, per1MonthPercentage = 0.4 }) },
        error = "Individual usage percentage",
      },
      {
        requests = { INDIVIDUAL, individual_reply({ per1WeekPercentage = 0.6, per1WeekResetTime = "unknown" }) },
        error = "Individual reset time",
      },
    }) do
      it("rejects " .. (example.name or "invalid " .. example.error) .. " without confirming plan absence", function()
        transport.fetches = { GRAY, SEATS_EMPTY, INSTANCES_EMPTY, ISSUED }
        vim.list_extend(transport.fetches, example.requests)
        local result = refresh(service)
        assert.are.equal("QwenCloud quota response contains invalid " .. example.error, assert(result.error).message)
        local status = assert(block(service:state(), "status"))
        assert.matches("Quota refresh failed", status.text, 1, true)
        assert.is_nil((status.text:find("private marker", 1, true)))
      end)
    end

    it("publishes a fresh monthly balance when the add-on request fails", function()
      transport.fetches = {
        GRAY,
        { body = [[{"code":"200","data":{"SubscriptionGroupList":[{"TotalValue":"100","SurplusValue":"75"}]}}]] },
        { status = 503, body = "private gateway response" },
      }
      local result = refresh(service)
      assert.is_true(result.ok, result.error and result.error.message)
      local state = service:state()
      assert.are.equal(0.75, assert(block(state, "limit", "Monthly Credits")).remaining)
      assert.matches("Add-on Credits unavailable", assert(block(state, "status")).text, 1, true)
      assert.is_nil(block(state, "field", "Add-on Credits remaining"))
    end)

    it("reports add-on credits even when QwenCloud confirms there are no active seats", function()
      transport.fetches = {
        GRAY,
        SEATS_EMPTY,
        INSTANCES_EMPTY,
        ISSUED,
        NO_INDIVIDUAL,
        { body = [[{"code":"200","data":{"Data":[{"Status":"valid","CurrCapacityBaseValue":"15"}]}}]] },
      }
      assert.is_true(refresh(service).ok)
      assert.is_nil(block(service:state(), "limit", "Monthly Credits"))
      assert.are.equal("15", assert(block(service:state(), "field", "Add-on Credits remaining")).value)
    end)

    it("requires scoped OAuth instead of falling back to an inference credential", function()
      local result = refresh(service, function()
        return async.run(function()
          return {
            ok = true,
            configured = true,
            credential_type = "api_key",
            method = "inference",
            request_opts = { headers = { Authorization = "Bearer sk-sp-synthetic" } },
          }
        end)
      end)
      assert.are.equal("auth", assert(result.error).kind)
      assert.are.equal(0, #transport.fetch_requests)
    end)

    it("asks for another browser login when the stored usage authorization expires", function()
      now = EXPIRY
      local result = refresh(service, function(scope)
        return manager:resolve("synthetic-browser", { scope = scope })
      end)
      assert.are.equal("auth", assert(result.error).kind)
      assert.matches("OAuth authorization expired", assert(block(service:state(), "status")).text, 1, true)
      assert.are.equal(0, #transport.fetch_requests)
    end)

    it("ignores quota data returned after the usage credential is removed", function()
      transport.fetches = {
        GRAY,
        { body = [[{"code":"200","data":{"SubscriptionGroupList":[{"TotalValue":"100","SurplusValue":"80"}]}}]] },
      }
      ---@type Neoagent.AwaitCallbacks<Neoagent.ByteFetchResult>?
      local pending
      local fetch = assert(transport.fetch)
      transport.fetch = function(opts)
        if #transport.fetch_requests < 2 then
          return fetch(opts)
        end
        return async.run(function()
          return async.await(function(done)
            pending = done
          end)
        end)
      end
      local run =
        assert((provider_service.run(service, "refresh", { auth = manager, auth_method = "synthetic-browser" })))
      pending_refresh = run
      assert(vim.wait(2000, function()
        return pending ~= nil
      end))
      local logout = manager:logout("synthetic-browser")
      assert(vim.wait(2000, function()
        return logout:is_done()
      end))
      assert.is_true(assert(logout:result()).ok)
      assert(pending).resolve({ ok = true, status = 200, headers = {}, body = assert(INSTANCES_EMPTY.body) })
      assert(vim.wait(2000, function()
        return run:is_done()
      end))
      assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
      assert.is_nil(block(service:state(), "limit", "Monthly Credits"))
    end)

    for _, denied in ipairs({
      { status = 403, body = "private quota error" },
      { body = [[{"code":"401","message":"private quota error"}]] },
    }) do
      it("clears a displayed balance when QwenCloud rejects usage authorization", function()
        transport.fetches = {
          GRAY,
          { body = [[{"code":"200","data":{"SubscriptionGroupList":[{"TotalValue":"100","SurplusValue":"80"}]}}]] },
          INSTANCES_EMPTY,
          denied,
        }
        assert.is_true(refresh(service).ok)
        assert.is_not_nil(block(service:state(), "limit", "Monthly Credits"))
        local result = refresh(service)
        assert.are.equal("auth", assert(result.error).kind)
        local status = assert(block(service:state(), "status"))
        assert.matches("Log out of usage and log in again", status.text, 1, true)
        assert.is_nil((status.text:find("private quota error", 1, true)))
        assert.is_nil(block(service:state(), "limit", "Monthly Credits"))
        assert.are.equal(4, #transport.fetch_requests)
      end)
    end

    for _, case in ipairs({
      { "a non-object response", "[]" },
      { "failed call", [[{"code":"200","data":{"Success":false}}]] },
      { "failed seat summary", [[{"code":"200","data":{"Data":{"Success":false}}}]] },
      { "unconfirmed empty summary", [[{"code":"200","data":{"Data":{}}}]] },
      { "missing group list", [[{"code":"200","data":{"Success":true,"Data":{"PlanName":"Team"}}}]] },
      { "invalid group list", [[{"code":"200","data":{"SubscriptionGroupList":{}}}]] },
      { "invalid row", [[{"code":"200","data":{"SubscriptionGroupList":[42]}}]] },
      {
        "missing credit equity",
        [[{"code":"200","data":{"SubscriptionGroupList":[
          {"EquityList":[{"EquityCode":"seat_count","TotalValue":"5","SurplusValue":"2"}]}
        ]}}]],
      },
      {
        "invalid credits",
        [[{"code":"200","data":{"SubscriptionGroupList":[{"TotalValue":"bad","SurplusValue":"75"}]}}]],
      },
    }) do
      it("rejects seat data with " .. case[1] .. " rather than inventing a credit balance", function()
        transport.fetches = { GRAY, { body = case[2] } }
        local result = refresh(service)
        assert.matches("response contains invalid", assert(result.error).message, 1, true)
        assert.is_nil(block(service:state(), "limit", "Monthly Credits"))
      end)
    end

    it("does not treat an add-on with missing status as an active grant", function()
      transport.fetches = {
        GRAY,
        SEATS_EMPTY,
        INSTANCES_EMPTY,
        ISSUED,
        NO_INDIVIDUAL,
        { body = [[{"code":"200","data":{"Data":[{"CurrCapacityBaseValue":"15"}]}}]] },
      }
      assert.is_true(refresh(service).ok)
      assert.matches("Add-on Credits unavailable", vim.inspect(service:state()), 1, true)
      assert.is_nil(block(service:state(), "field", "Add-on Credits remaining"))
    end)

    it("does not publish a partial balance after the add-on request is cancelled", function()
      transport.fetches = {
        GRAY,
        { body = [[{"code":"200","data":{"SubscriptionGroupList":[{"TotalValue":"100","SurplusValue":"75"}]}}]] },
        { error = async.cancelled_error },
      }
      assert.are.equal("cancelled", assert(refresh(service).error).kind)
      assert.is_nil(block(service:state(), "limit", "Monthly Credits"))
    end)
  end)
end)
