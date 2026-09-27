local it = require("tests.helpers.async_test")
local assert = require("luassert")
local plan_compaction = require("tests.helpers.compaction")
local Session = require("neoagent.session")
local compaction = require("neoagent.compaction")
local fake_model = require("tests.helpers.fake_model")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function finish(run)
  assert(vim.wait(1000, function()
    return run:is_done()
  end))
  return (assert(run:result()))
end

describe("neoagent.compaction_summary", function()
  it("selects summary thinking without raising a lower inherited effort", function()
    for _, component in ipairs({ compaction.local_component }) do
      for _, case in ipairs({
        { selected = "off", expected = "off", levels = { off = {}, low = {}, high = {} } },
        { selected = "minimal", expected = "minimal", levels = { minimal = {}, low = {}, high = {} } },
        { selected = "high", expected = "low", levels = { minimal = {}, low = {}, high = {} } },
        { selected = "high", expected = "minimal", levels = { minimal = {}, high = {} } },
      }) do
        local session = assert(Session.new())
        assert(session:append({ role = "user", content = string.rep("earlier ", 100) }))
        assert(session:append({ role = "user", content = "Continue" }))
        local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Summary" } }) } })
        model.context_window, model.thinking = 32768, case.levels
        local evaluation = plan_compaction(component, { model = model, path = assert(session:path()),
          messages = assert(session:context_messages()), configured = { keep_recent_tokens = 1 }, force = true })
        local options = { thinking_level = case.selected }
        local result = finish(component.run({ model = model, preparation = assert(evaluation.preparation), model_options = options }))
        assert.is_true(result.ok)
        assert.are.equal(case.expected, assert(model.requests[1]).thinking_level)
        assert.are.equal(1024, assert(model.requests[1]).max_thinking_tokens)
        assert.are.equal(case.selected, options.thinking_level)
      end
    end
  end)

  it("preserves explicitly disabled thinking with inherited effort fields", function()
    local model = require("neoagent.api.openai_completions").new({
      provider = "test",
      model = "test",
      base_url = "https://example.test",
      request_opts = { body = { enable_thinking = false, reasoning_effort = "high" } },
      thinking = {
        off = { body = { enable_thinking = false } },
        low = { body = { enable_thinking = true, reasoning_effort = "low" } },
      },
    })
    local request = model:_request(require("neoagent.compaction.summary").generation_options(model, {
      messages = {}, thinking_level = "off",
    }, 2048))
    assert.is_false(assert(request.request.body).enable_thinking)
  end)

  it("applies declared nested thinking mappings for summaries", function()
    local model = require("neoagent.api.openai_completions").new({
      provider = "test",
      model = "test",
      base_url = "https://example.test",
      request_opts = { body = { chat_template_kwargs = { thinking = "high" } } },
      thinking = {
        low = { body = { chat_template_kwargs = { thinking = "low" } } },
        high = { body = { chat_template_kwargs = { thinking = "high" } } },
      },
    })
    local request = model:_request(require("neoagent.compaction.summary").generation_options(model, {
      messages = {}, thinking_level = "high",
    }, 2048))
    assert.are.equal("low", assert(request.request.body).chat_template_kwargs.thinking)
  end)

  it("does not repeat exhausted provider retries during summary generation", function()
    local transport = require("tests.helpers.fake_transport").new({
      { error = { kind = "transport", message = "connection reset" } },
      { error = { kind = "transport", message = "connection reset" } },
      { error = { kind = "transport", message = "connection reset" } },
      { error = { kind = "transport", message = "connection reset" } },
    })
    local model = require("neoagent.api.openai_codex_responses").new({
      provider = "openai-codex",
      model = "test",
      base_url = "https://example.test",
      transport = transport,
      request_max_retries = 1,
      sleep = function() end,
    })
    local result = finish(compaction.run({
      model = model,
      preparation = {
        kind = "summary",
        messages = { { role = "user", content = "Summarize" } },
        turn_prefix = {},
        split_turn = false,
        tokens_before = 10,
        settings = compaction.settings({}),
      },
    }))
    assert.is_false(result.ok)
    assert.are.equal(2, #transport.requests)
    assert.are.equal("request", assert(result.error).retry_exhausted)
  end)
  it("resolves function-valued summary thinking layers using request identity", function()
    for _, api in ipairs({ "openai_completions", "openai_responses", "anthropic_messages" }) do
      local function effort(value)
        if api == "openai_completions" then
          return { reasoning_effort = value }
        end
        if api == "openai_responses" then
          return { reasoning = { effort = value } }
        end
        return { output_config = { effort = value } }
      end
      local model = require("neoagent.api." .. api).new({
        provider = "test",
        model = "test",
        base_url = "https://example.test",
        request_context = { session_id = "synthetic-session" },
        request_opts = { body = effort("high") },
        thinking = {
          low = function(context)
            assert.are.equal("synthetic-session", assert(context.request_context).session_id)
            return { body = effort("minimal") }
          end,
        },
      })
      local request = model:_request(require("neoagent.compaction.summary").generation_options(model, {
        messages = {}, thinking_level = "high",
      }, 2048))
      local body = assert(request.request.body)
      local selected = api == "openai_completions" and body.reasoning_effort
        or api == "openai_responses" and assert(body.reasoning).effort
        or assert(body.output_config).effort
      assert.are.equal("minimal", selected)
    end
  end)

end)
