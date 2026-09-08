local assert = require("luassert")
local dashboard = require("neoagent.auth.alibaba_dashboard")
local token_plan = require("neoagent.auth.alibaba_token_plan")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end, 5))
  return (assert(run:result()))
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

describe("Alibaba Cloud Token Plan authentication", function()
  it("accepts only dedicated Token Plan inference keys", function()
    local method = token_plan.new()
    local result = wait(method.login(interaction({ function(prompt)
      assert.are.equal("secret", prompt.type)
      assert.matches("Token Plan", (assert(prompt.message)))
      return "  sk-sp-inference  "
    end }, {})))

    assert(result.ok)
    assert.are.same({
      type = "api_key",
      key = "sk-sp-inference",
    }, result.credential)
    assert.are.equal("Bearer sk-sp-inference",
      rawget(assert(method.request_opts(result.credential).headers), "Authorization"))
    assert.are.equal("sk-sp-inference",
      assert(method.cache_identity)(result.credential))
    assert.are.equal("Login", method.login_label)
    assert.are.equal("Logout", method.logout_label)
    assert.is_true(assert(method.validate_credential)(result.credential))
    assert.is_false(assert(method.validate_credential)({
      type = "api_key", key = "sk-general",
    }))

    result = wait(method.login(interaction({ " " }, {})))
    assert.is_false(result.ok)
    assert.matches("API key is required", assert(result.error).message)

    result = wait(method.login(interaction({ "sk-general" }, {})))
    assert.is_false(result.ok)
    assert.matches("must start with sk%-sp%-", assert(result.error).message)

    local ok, err = pcall(method.request_opts, {
      type = "api_key", key = "sk-general",
    })
    assert.is_false(ok)
    assert.matches("must start with sk%-sp%-", (err --[[@as Neoagent.Error]]).message)
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
          close = function() closed = true return true end,
        }
      end,
    })
    ---@type Neoagent.AuthEvent[]
    local events = {}
    local result = wait(method.login(interaction({}, events)))

    assert(result.ok)
    assert.is_true(closed)
    assert.are.same({
      type = "api_key",
      key = "console-access",
    }, result.credential)
    assert.are.equal("Login to dashboard (optional to see quotas)",
      method.login_label)
    assert.are.equal("Logout from dashboard", method.logout_label)
    assert.are.equal("auth_url", assert(events[1]).type)
    local url_event = assert(events[1])
    assert(url_event.type == "auth_url")
    assert.matches("modelstudio%.console%.alibabacloud%.com/console%-login",
      url_event.url)
    assert.matches("notice=127%.0%.0%.1:43210%?state=fixed%-state",
      url_event.url)
    assert.is_nil((url_event.url:find("needapikey", 1, true)))
    assert.are.equal("Bearer console-access",
      rawget(assert(method.request_opts(result.credential).headers), "Authorization"))
  end)

  it("contains dashboard callback failures and invalid credentials", function()
    local method = dashboard.new({
      random_state = function() return "manual-state" end,
      start_callback_server = function() return nil, "address denied" end,
    })
    local result = wait(method.login(interaction({}, {})))
    assert.is_false(result.ok)
    assert.matches("Could not start", assert(result.error).message)
    assert.are.equal("address denied", assert(result.error).detail)

    method = dashboard.new({ random_state = function() return nil --[[@as string]] end })
    result = wait(method.login(interaction({}, {})))
    assert.is_false(result.ok)
    assert.matches("create console login state", assert(result.error).message)

    local closed = 0
    method = dashboard.new({
      random_state = function() return "state" end,
      start_callback_server = function()
        return {
          port = 1,
          wait = function()
            error({ kind = "auth", message = "callback rejected" }, 0)
          end,
          close = function() closed = closed + 1 return true end,
        }
      end,
    })
    result = wait(method.login(interaction({}, {})))
    assert.is_false(result.ok)
    assert.matches("callback rejected", assert(result.error).message)
    assert.are.equal(1, closed)

    method = dashboard.new({
      random_state = function() return "state" end,
      start_callback_server = function()
        return {
          port = 1,
          wait = function() return {} --[[@as string]] end,
          close = function() closed = closed + 1 return true end,
        }
      end,
    })
    result = wait(method.login(interaction({}, {})))
    assert.is_false(result.ok)
    assert.matches("returned no access token", assert(result.error).message)
    assert.are.equal(2, closed)

    local ok, err = pcall(method.request_opts, {
      type = "api_key", key = " ",
    })
    assert.is_false(ok)
    assert.matches("authorization is unavailable", (err --[[@as Neoagent.Error]]).message)
  end)
end)
