local anthropic = require("neoagent.api.anthropic_messages")
local mock_server = require("tests.helpers.mock_server")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return run:result()
end

local function model(server, max_output_tokens)
  return anthropic.new({
    provider = "anthropic-test",
    model = "claude-test",
    base_url = "http://127.0.0.1:" .. server.port,
    api_key = "anthropic-key",
    max_output_tokens = max_output_tokens or 128,
  })
end

describe("Anthropic Messages HTTP integration", function()
  local servers = {}

  after_each(function()
    for _, server in ipairs(servers) do server:stop() end
    servers = {}
  end)

  it("streams reasoning and tools through real curl and replays the turn", function()
    local server = mock_server.start("tests/fixtures/anthropic/stream.json")
    servers[#servers + 1] = server
    local anthropic_model = model(server)
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

    assert.is_true(first.ok)
    assert.are.equal("toolUse", first.message.stopReason)
    assert.are.equal("sig-1", first.message.content[1].thinkingSignature)
    assert.are.same({ path = "x.lua" }, first.message.content[2].arguments)
    assert.are.equal(4, first.message.usage.cacheRead)
    assert.are.equal(26, first.message.usage.totalTokens)

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

    assert.is_true(second.ok)
    assert.are.equal("Looks good.", second.text)
    assert.are.equal("stop", second.message.stopReason)
    assert(vim.wait(1000, function() return #server.records >= 3 end))
  end)

  it("cancels curl and preserves partial Anthropic output", function()
    local server = mock_server.start("tests/fixtures/anthropic/cancel.json")
    servers[#servers + 1] = server
    local run
    run = model(server, 64):stream({
      messages = {},
      on_event = function(event)
        if event.type == "text_delta" then run:cancel() end
      end,
    })
    local result = wait(run)

    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.are.equal("partial", result.message.content[1].text)
    assert.are.equal("aborted", result.message.stopReason)
  end)
end)
