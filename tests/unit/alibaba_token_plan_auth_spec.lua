local dashboard = require("neoagent.auth.alibaba_dashboard")
local token_plan = require("neoagent.auth.alibaba_token_plan")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end, 5))
  return run:result()
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

describe("Alibaba Cloud Token Plan authentication", function()
  it("accepts only dedicated Token Plan inference keys", function()
    local method = token_plan.new()
    local result = wait(method.login(interaction({ function(prompt)
      assert.are.equal("secret", prompt.type)
      assert.matches("Token Plan", prompt.message)
      return "  sk-sp-inference  "
    end }, {})))

    assert.is_true(result.ok)
    assert.are.same({
      type = "api_key",
      key = "sk-sp-inference",
    }, result.credential)
    assert.are.equal("Bearer sk-sp-inference",
      method.request_opts(result.credential).headers.Authorization)
    assert.are.equal("sk-sp-inference",
      method.cache_identity(result.credential))
    assert.are.equal("Login", method.login_label)
    assert.are.equal("Logout", method.logout_label)
    assert.is_true(method.validate_credential(result.credential))
    assert.is_false(method.validate_credential({
      type = "api_key", key = "sk-general",
    }))

    result = wait(method.login(interaction({ " " }, {})))
    assert.is_false(result.ok)
    assert.matches("API key is required", result.error.message)

    result = wait(method.login(interaction({ "sk-general" }, {})))
    assert.is_false(result.ok)
    assert.matches("must start with sk%-sp%-", result.error.message)

    local ok, err = pcall(method.request_opts, {
      type = "api_key", key = "sk-general",
    })
    assert.is_false(ok)
    assert.matches("must start with sk%-sp%-", err.message)
  end)

  it("stores dashboard authorization independently", function()
    local closed = false
    local method = dashboard.new({
      random_state = function() return "fixed-state" end,
      start_callback_server = function(state, host)
        assert.are.equal("fixed-state", state)
        assert.are.equal("127.0.0.1", host)
        return {
          port = 43210,
          wait = function() return " console-access " end,
          close = function() closed = true end,
        }
      end,
    })
    local events = {}
    local result = wait(method.login(interaction({}, events)))

    assert.is_true(result.ok)
    assert.is_true(closed)
    assert.are.same({
      type = "api_key",
      key = "console-access",
    }, result.credential)
    assert.are.equal("Login to dashboard (optional to see quotas)",
      method.login_label)
    assert.are.equal("Logout from dashboard", method.logout_label)
    assert.are.equal("auth_url", events[1].type)
    assert.matches("modelstudio%.console%.alibabacloud%.com/console%-login",
      events[1].url)
    assert.matches("notice=127%.0%.0%.1:43210%?state=fixed%-state",
      events[1].url)
    assert.is_nil(events[1].url:find("needapikey", 1, true))
    assert.are.equal("Bearer console-access",
      method.request_opts(result.credential).headers.Authorization)
  end)

  it("contains dashboard callback failures and invalid credentials", function()
    local method = dashboard.new({
      random_state = function() return "manual-state" end,
      start_callback_server = function() return nil, "address denied" end,
    })
    local result = wait(method.login(interaction({}, {})))
    assert.is_false(result.ok)
    assert.matches("Could not start", result.error.message)
    assert.are.equal("address denied", result.error.detail)

    method = dashboard.new({ random_state = function() return nil end })
    result = wait(method.login(interaction({}, {})))
    assert.is_false(result.ok)
    assert.matches("create console login state", result.error.message)

    local closed = 0
    method = dashboard.new({
      random_state = function() return "state" end,
      start_callback_server = function()
        return {
          port = 1,
          wait = function()
            error({ kind = "auth", message = "callback rejected" }, 0)
          end,
          close = function() closed = closed + 1 end,
        }
      end,
    })
    result = wait(method.login(interaction({}, {})))
    assert.is_false(result.ok)
    assert.matches("callback rejected", result.error.message)
    assert.are.equal(1, closed)

    method = dashboard.new({
      random_state = function() return "state" end,
      start_callback_server = function()
        return {
          port = 1,
          wait = function() return {} end,
          close = function() closed = closed + 1 end,
        }
      end,
    })
    result = wait(method.login(interaction({}, {})))
    assert.is_false(result.ok)
    assert.matches("returned no access token", result.error.message)
    assert.are.equal(2, closed)

    local ok, err = pcall(method.request_opts, {
      type = "api_key", key = " ",
    })
    assert.is_false(ok)
    assert.matches("authorization is unavailable", err.message)
  end)
end)
