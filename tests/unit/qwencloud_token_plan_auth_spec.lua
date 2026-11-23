local assert = require("luassert")
local token_plan = require("neoagent.auth.qwencloud_token_plan")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function()
    return run:is_done()
  end, 5))
  return (assert(run:result()))
end

---@param answers (string|fun(prompt: Neoagent.LoginPrompt): string)[]
---@return Neoagent.LoginInteraction
local function interaction(answers)
  return {
    prompt = function(prompt, done)
      local answer = table.remove(answers, 1)
      if type(answer) == "function" then
        answer = answer(prompt)
      end
      done.resolve(answer)
    end,
    notify = function() end,
  }
end

describe("QwenCloud Token Plan authentication", function()
  it("accepts only dedicated Token Plan API keys", function()
    local method = token_plan.new()
    local result = wait(method.login(interaction({
      function(prompt)
        assert.are.equal("secret", prompt.type)
        assert.are.equal("Enter QwenCloud Token Plan API key:", prompt.message)
        return "  sk-sp-inference  "
      end,
    })))

    assert(result.ok)
    assert.are.same({
      type = "api_key",
      key = "sk-sp-inference",
    }, result.credential)
    assert.are.equal("QwenCloud Token Plan API key", method.name)
    assert.are.equal(
      "Bearer sk-sp-inference",
      rawget(assert(method.request_opts(result.credential).headers), "Authorization")
    )
    assert.are.equal("sk-sp-inference", assert(method.cache_identity)(result.credential))
    assert.are.equal("Login", method.login_label)
    assert.are.equal("Logout", method.logout_label)
    assert.is_true(assert(method.validate_credential)(result.credential))
    assert.is_false(assert(method.validate_credential)({
      type = "api_key",
      key = "sk-general",
    }))

    result = wait(method.login(interaction({ " " })))
    assert.is_false(result.ok)
    assert.matches("API key is required", assert(result.error).message)

    result = wait(method.login(interaction({ "sk-general" })))
    assert.is_false(result.ok)
    assert.matches("QwenCloud Token Plan API keys must start with sk%-sp%-", assert(result.error).message)

    local ok, err = pcall(method.request_opts, {
      type = "api_key",
      key = "sk-general",
    })
    assert.is_false(ok)
    assert.matches("QwenCloud Token Plan API keys must start with sk%-sp%-", (err --[[@as Neoagent.Error]]).message)
  end)
end)
