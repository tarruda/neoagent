local assert = require("luassert")
local fake_transport = require("tests.helpers.fake_transport")

local constructors = {
  completions = require("neoagent.api.openai_completions").new,
  responses = require("neoagent.api.openai_responses").new,
  anthropic = require("neoagent.api.anthropic_messages").new,
  codex = require("neoagent.api.openai_codex_responses").new,
}

---@param run Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
---@return Neoagent.ModelResult
local function wait(run)
  assert(vim.wait(1000, function() return run:is_done() end))
  return (assert(run:result()))
end

for name, new in pairs(constructors) do
  describe(name .. " timeout contract", function()
    for _, case in ipairs({
      { name = "inherits the constructor deadline", default = 1234, expected = 1234 },
      { name = "overrides the constructor deadline", default = 1234, override = 5678, expected = 5678 },
      { name = "disables the constructor deadline", default = 1234, override = false, expected = false },
      { name = "leaves an unspecified deadline absent" },
    }) do
      it(case.name .. " through Authentication and HTTP", function()
        local transport = fake_transport.new({ {
          status = 400,
          chunks = { '{"error":{"message":"invalid request"}}' },
        } })
        local model = new({
          provider = "test", model = "test", base_url = "https://example.test",
          timeout_ms = case.default, transport = transport,
        })
        local manager = require("neoagent.auth").new({
          methods = { test = require("neoagent.auth.api_key").new({ name = "Test" }) },
          store = require("tests.helpers.auth_manager").store({
            test = { type = "api_key", key = "synthetic-timeout-key" },
          }),
        })
        local wrapped = manager:wrap(model, "test")
        local result = wait(wrapped:stream({ messages = {}, timeout_ms = case.override }))
        assert.is_false(result.ok)
        assert.are.equal(case.expected, assert(transport.requests[1]).timeout_ms)
        assert.are.equal(case.default, model.timeout_ms)
        assert.are.equal(case.default, wrapped.timeout_ms)
      end)
    end

    it("rejects invalid deadlines before starting a request", function()
      local transport = fake_transport.new()
      local model = new({
        provider = "test", model = "test", base_url = "https://example.test",
        transport = transport, request_max_retries = 0,
      })
      for _, invalid in ipairs({ 0, -1, 1.5, math.huge, 0 / 0, false, "slow" }) do
        -- Exercise runtime validation beyond the typed caller contract.
        local timeout_ms = invalid --[[@as integer]]
        assert.has_error(function()
          new({ provider = "test", model = "test", base_url = "https://example.test",
            timeout_ms = timeout_ms })
        end, "timeout_ms must be a positive integer")
        if invalid ~= false then
          local result = wait(model:stream({ messages = {}, timeout_ms = timeout_ms }))
          assert.is_false(result.ok)
          assert.matches("timeout_ms must be a positive integer", assert(result.error).message)
        end
      end
      assert.are.equal(0, #transport.requests)
    end)
  end)
end
