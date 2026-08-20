local async = require("neoagent.async")
local management = require("neoagent.providers.codex_management")
local mock_server = require("tests.helpers.mock_server")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return run:result()
end

describe("Codex management HTTP integration", function()
  local server

  after_each(function()
    if server then server:stop() server = nil end
  end)

  it("loads usage through curl with resolved subscription headers", function()
    server = mock_server.start("tests/fixtures/openai/codex_usage.json")
    local client = management.new({
      base_url = "http://127.0.0.1:" .. server.port .. "/backend-api",
    })
    local result = wait(client:usage({
      resolve_auth = function()
        return async.run(function()
          return {
            ok = true,
            configured = true,
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
    assert.is_true(result.ok)
    assert.are.equal("plus", result.value.plan_type)
    assert.are.equal(25,
      result.value.rate_limit.primary_window.used_percent)
    assert.are.same({
      email = "account@example.com", plan = "Plus",
    }, result.metadata)
    assert(vim.wait(1000, function() return #server.records >= 2 end))
    assert.are.equal("GET", server.records[2].method)
    assert.are.equal("/backend-api/wham/usage", server.records[2].path)
  end)
end)
