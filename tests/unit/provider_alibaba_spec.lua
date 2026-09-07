local alibaba = require("neoagent.providers.alibaba_token_plan")
local async = require("neoagent.async")
local provider_service = require("neoagent.provider_service")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end, 5))
  return run:result()
end

local function block(snapshot, block_type, label)
  for _, candidate in ipairs(snapshot.blocks or {}) do
    if candidate.type == block_type and candidate.label == label then
      return candidate
    end
  end
end

describe("Alibaba Cloud Token Plan provider service", function()
  it("identifies the Token Plan Personal endpoint", function()
    local calls = 0
    local plan = alibaba.new(nil, { client = {
      usage = function(_, ctx)
        calls = calls + 1
        assert.is_table(ctx)
        return async.run(function()
          return { ok = true, usage = {
            five_hour = { used = 0.2, resets_at = 1786000000 },
            seven_day = { used = 0.75, resets_at = 1786100000 },
          } }
        end)
      end,
    } })

    assert.are.equal("alibaba-token-plan", plan.id)
    assert.are.equal("Alibaba Cloud Token Plan Personal", plan.name)
    assert.are.equal("Refresh quotas", plan.operations.refresh.label)
    assert.are.equal("dashboard", plan.operations.refresh.auth_scope)
    assert.are.equal("Token Plan Personal",
      block(plan:state(), "field", "Plan").value)
    assert.are.equal(
      "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
      block(plan:state(), "field", "Endpoint").value)

    local updates = 0
    local unsubscribe = plan:subscribe(function() updates = updates + 1 end)
    local result = wait(provider_service.run(plan, "refresh"))
    assert.is_true(result.ok)
    assert.are.equal(1, calls)
    assert.are.equal(0.8,
      block(plan:state(), "limit", "5-hour quota").remaining)
    assert.are.equal(1786000000,
      block(plan:state(), "limit", "5-hour quota").resets_at)
    assert.are.equal(0.25,
      block(plan:state(), "limit", "7-day quota").remaining)
    assert.are.equal(1, updates)
    unsubscribe()
    plan:destroy()
    assert.are.same({}, plan:state().blocks)
    assert.is_true(wait(provider_service.run(plan, "refresh")).ok)
    assert.are.equal(2, calls)
    assert.are.same({}, plan:state().blocks)
    plan:destroy()
  end)

  it("keeps inference usable when console quota authorization expires", function()
    local plan = alibaba.new(nil, { client = {
      usage = function()
        return async.run(function()
          error({
            kind = "auth",
            message = "Alibaba Cloud dashboard authorization expired",
          }, 0)
        end, { error_kind = "provider" })
      end,
    } })

    local result = wait(provider_service.run(plan, "refresh"))

    assert.is_true(result.ok)
    local status = block(plan:state(), "status")
    assert.are.equal("warn", status.level)
    assert.matches("dashboard authorization", status.text)
    assert.matches("Log in", status.text)
    plan:destroy()
  end)

  it("shows unlimited windows when the console omits usage", function()
    local plan = alibaba.new(nil, { client = {
      usage = function()
        return async.run(function()
          return { ok = true, usage = {} }
        end)
      end,
    } })

    assert.is_true(wait(provider_service.run(plan, "refresh")).ok)
    assert.are.equal("No limit reported",
      block(plan:state(), "field", "5-hour quota").value)
    assert.are.equal("No usage reported",
      block(plan:state(), "field", "7-day quota").value)
    plan:destroy()
  end)

  it("warns on forbidden quota access and preserves other failures", function()
    local calls = 0
    local plan = alibaba.new(nil, { client = {
      usage = function()
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
      end,
    } })

    local result = wait(provider_service.run(plan, "refresh"))
    assert.is_true(result.ok)
    assert.are.equal("warn", block(plan:state(), "status").level)

    result = wait(provider_service.run(plan, "refresh"))
    assert.is_false(result.ok)
    assert.matches("endpoint offline", result.error.message)
    local status = block(plan:state(), "status")
    assert.are.equal("error", status.level)
    assert.matches("Quota refresh failed", status.text)
    assert.matches("endpoint offline", status.text)
    plan:destroy()
  end)

  it("rejects unsupported service options", function()
    assert.has_error(function()
      alibaba.new({ service_opts = { unsupported = true } })
    end)
  end)
end)
