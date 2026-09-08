local assert = require("luassert")
local async = require("neoagent.async")
local management = require("neoagent.providers.codex_management")
local http_replay = require("tests.helpers.http_replay")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe("Codex management HTTP integration", function()
  ---@type Neoagent.TestHttpReplay?
  local scenario

  after_each(function()
    if scenario then http_replay.finish(scenario) scenario = nil end
  end)

  it("loads usage through recorded HTTP with resolved subscription headers", function()
    scenario = http_replay.open({
      { path = "tests/recordings/openai/codex_usage-01.yaml", body_subset = true, headers_subset = true },
    })
    local client = management.new({
      transport = scenario,
      base_url = scenario.url .. "/backend-api",
    })
    local result = wait(client:usage({
      resolve_auth = function()
        return async.run(function()
          return {
            ok = true,
            configured = true,
            method = "test",
            credential_type = "oauth",
            request_opts = { headers = {
              Authorization = "Bearer integration-secret",
              ["chatgpt-account-id"] = "integration-account",
            } },
            metadata = {
              email = "account@example.com",
              plan = "Plus",
            },
          }
        end)
      end,
    }))
    assert(result.ok)
    assert.are.equal("plus", result.value.plan_type)
    assert.are.equal(25,
      assert(assert(result.value.rate_limit).primary_window).used_percent)
    assert.are.same({
      email = "account@example.com", plan = "Plus",
    }, result.metadata)
    assert(vim.wait(1000, function() return #scenario.requests >= 1 end))
    assert.are.equal("GET", assert(scenario.requests[1]).method)
    assert.are.equal(scenario.url .. "/backend-api/wham/usage", assert(scenario.requests[1]).url)
  end)
end)
