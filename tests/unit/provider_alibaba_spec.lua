local assert = require("luassert")
local alibaba = require("neoagent.providers.alibaba_token_plan")
local async = require("neoagent.async")
local provider_service = require("neoagent.provider_service")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end, 5))
  return (assert(run:result()))
end

local block = require("tests.helpers.provider_state").block

describe("Alibaba Cloud Token Plan provider service", function()
  it("identifies the Token Plan Personal endpoint", function()
    local calls = 0
    local client = {}
    ---@param ctx Neoagent.ProviderAuthContext
    ---@return Neoagent.Run<Neoagent.AlibabaQuotaSuccess|Neoagent.AsyncFailure, nil>
    function client:usage(ctx)
      calls = calls + 1
      assert.is_table(ctx)
      return async.run(function()
        return { ok = true, usage = {
          five_hour = { used = 0.2, resets_at = 1786000000 },
          seven_day = { used = 0.75, resets_at = 1786100000 },
        } }
      end)
    end
    local plan = alibaba.new(nil, { client = client })

    assert.are.equal("alibaba-token-plan", plan.id)
    assert.are.equal("Alibaba Cloud Token Plan Personal", plan.name)
    assert.are.equal("Refresh quotas", assert(plan.operations.refresh).label)
    assert.are.equal("dashboard", assert(plan.operations.refresh).auth_scope)
    assert.are.equal("Token Plan Personal",
      assert(block(plan:state(), "field", "Plan")).value)
    assert.are.equal(
      "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
      assert(block(plan:state(), "field", "Endpoint")).value)

    local updates = 0
    local unsubscribe = assert(plan.subscribe)(plan, function() updates = updates + 1 end)
    local result = wait((assert(provider_service.run(plan, "refresh"))))
    assert.is_true(result.ok)
    assert.are.equal(1, calls)
    assert.are.equal(0.8,
      assert(block(plan:state(), "limit", "5-hour quota")).remaining)
    assert.are.equal(1786000000,
      assert(block(plan:state(), "limit", "5-hour quota")).resets_at)
    assert.are.equal(0.25,
      assert(block(plan:state(), "limit", "7-day quota")).remaining)
    assert.are.equal(1, updates)
    unsubscribe()
    assert(plan.destroy)(plan)
    assert.are.same({}, plan:state().blocks)
    assert.is_true(wait((assert(provider_service.run(plan, "refresh")))).ok)
    assert.are.equal(2, calls)
    assert.are.same({}, plan:state().blocks)
    assert(plan.destroy)(plan)
  end)

  it("keeps inference usable when console quota authorization expires", function()
    local client = {}
    ---@param ctx Neoagent.ProviderAuthContext
    ---@return Neoagent.Run<Neoagent.AlibabaQuotaSuccess|Neoagent.AsyncFailure, nil>
    function client:usage(ctx)
      return async.run(function()
        error({
          kind = "auth",
          message = "Alibaba Cloud dashboard authorization expired",
        }, 0)
      end, { error_kind = "provider" })
    end
    local plan = alibaba.new(nil, { client = client })

    local result = wait((assert(provider_service.run(plan, "refresh"))))

    assert.is_true(result.ok)
    local status = block(plan:state(), "status")
    assert.are.equal("warn", assert(status).level)
    assert.matches("dashboard authorization", assert(status).text)
    assert.matches("Log in", assert(status).text)
    assert(plan.destroy)(plan)
  end)

  it("shows unlimited windows when the console omits usage", function()
    local client = {}
    ---@param ctx Neoagent.ProviderAuthContext
    ---@return Neoagent.Run<Neoagent.AlibabaQuotaSuccess|Neoagent.AsyncFailure, nil>
    function client:usage(ctx)
      return async.run(function()
        return { ok = true, usage = {} }
      end)
    end
    local plan = alibaba.new(nil, { client = client })

    assert.is_true(wait((assert(provider_service.run(plan, "refresh")))).ok)
    assert.are.equal("No limit reported",
      assert(block(plan:state(), "field", "5-hour quota")).value)
    assert.are.equal("No usage reported",
      assert(block(plan:state(), "field", "7-day quota")).value)
    assert(plan.destroy)(plan)
  end)

  it("warns on forbidden quota access and preserves other failures", function()
    local calls = 0
    local client = {}
    ---@param ctx Neoagent.ProviderAuthContext
    ---@return Neoagent.Run<Neoagent.AlibabaQuotaSuccess|Neoagent.AsyncFailure, nil>
    function client:usage(ctx)
      calls = calls + 1
      return async.run(function()
        if calls == 1 then
          return { ok = false, error = {
            kind = "provider",
            status = 403,
            message = "console denied quota access",
          } }
        end
        return { ok = false, error = {
          kind = "transport",
          message = "quota endpoint offline",
        } }
      end)
    end
    local plan = alibaba.new(nil, { client = client })

    local result = wait((assert(provider_service.run(plan, "refresh"))))
    assert.is_true(result.ok)
    assert.are.equal("warn", assert(block(plan:state(), "status")).level)

    result = wait((assert(provider_service.run(plan, "refresh"))))
    assert.is_false(result.ok)
    assert.matches("endpoint offline", assert(result.error).message)
    local status = block(plan:state(), "status")
    assert.are.equal("error", assert(status).level)
    assert.matches("Quota refresh failed", assert(status).text)
    assert.matches("endpoint offline", assert(status).text)
    assert(plan.destroy)(plan)
  end)

  it("rejects unsupported service options", function()
    assert.has_error(function()
      alibaba.new({ service_opts = { unsupported = true } })
    end)
  end)
end)
