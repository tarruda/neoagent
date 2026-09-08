local assert = require("luassert")
local anthropic = require("neoagent.api.anthropic_messages")
local http_replay = require("tests.helpers.http_replay")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@param scenario Neoagent.TestHttpReplay
---@param max_output_tokens? integer
---@return Neoagent.AnthropicModel
local function model(scenario, max_output_tokens)
  return anthropic.new({
    provider = "anthropic-test",
    model = "claude-test",
    transport = scenario,
    base_url = scenario.url,
    api_key = "anthropic-key",
    max_output_tokens = max_output_tokens or 128,
  })
end

describe("Anthropic Messages HTTP integration", function()
  ---@type Neoagent.TestHttpReplay[]
  local scenarios = {}

  after_each(function()
    for _, scenario in ipairs(scenarios) do http_replay.finish(scenario) end
    scenarios = {}
  end)

  it("streams reasoning and tools through recorded HTTP and replays the turn", function()
    local scenario = http_replay.open({
      { path = "tests/recordings/anthropic/stream-01.yaml", body_subset = false, headers_subset = true },
      { path = "tests/recordings/anthropic/stream-02.yaml", body_subset = false, headers_subset = true },
    })
    scenarios[#scenarios + 1] = scenario
    local anthropic_model = model(scenario)
    ---@type Neoagent.ToolDefinition[]
    local tools = { {
      name = "inspect",
      description = "Inspect a path",
      input_schema = {
        type = "object",
        properties = { path = { type = "string" } },
        required = { "path" },
      },
    } }
    local request_opts = {
      body = { thinking = { type = "enabled", budget_tokens = 32 } },
    }
    local user = { role = "user", content = "Inspect it" }
    local first = wait(anthropic_model:stream({
      messages = { user },
      system_prompt = "Be concise",
      tools = tools,
      request_opts = request_opts,
    }))

    assert(first.ok)
    assert.are.equal("toolUse", first.message.stopReason)
    assert.are.equal("sig-1", assert(first.message.content[1]).thinkingSignature)
    assert.are.same({ path = "x.lua" }, assert(first.message.content[2]).arguments)
    assert.are.equal(4, assert(first.message.usage).cacheRead)
    assert.are.equal(26, assert(first.message.usage).totalTokens)

    local second = wait(anthropic_model:stream({
      messages = {
        user,
        first.message,
        { role = "toolResult", toolCallId = "call-1", content = {
          { type = "text", text = "return true" },
        } },
      },
      system_prompt = "Be concise",
      tools = tools,
      request_opts = request_opts,
    }))

    assert(second.ok)
    assert.are.equal("Looks good.", second.text)
    assert.are.equal("stop", second.message.stopReason)
    assert(vim.wait(1000, function() return #scenario.requests >= 2 end))
  end)

  it("cancels playback and preserves partial Anthropic output", function()
    local scenario = http_replay.open({
      { path = "tests/recordings/anthropic/cancel-01.yaml", body_subset = false, headers_subset = true },
    })
    scenarios[#scenarios + 1] = scenario
    ---@type Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>?
    local run
    run = model(scenario, 64):stream({
      messages = {},
      on_event = function(event)
        if event.type == "text_delta" then assert(run):cancel() end
      end,
    })
    local result = wait(run)

    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal("partial", assert(assert(result.message).content[1]).text)
    assert.are.equal("aborted", assert(result.message).stopReason)
  end)
end)
