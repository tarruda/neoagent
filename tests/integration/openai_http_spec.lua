local mock_server = require("tests.helpers.mock_server")
local openai = require("neoagent.api.openai_completions")

local function model(server, key)
  return openai.new({
    provider = "mock",
    model = "test-model",
    base_url = "http://127.0.0.1:" .. server.port .. "/v1",
    api_key = key,
  })
end

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

describe("OpenAI-compatible HTTP integration", function()
  local servers = {}
  after_each(function()
    for _, server in ipairs(servers) do server:stop() end
    servers = {}
  end)

  it("streams real curl response chunks", function()
    local server = mock_server.start("tests/fixtures/openai/stream.json")
    servers[#servers + 1] = server
    local deltas = {}
    local result = wait(model(server, "test-key"):stream({
      messages = { { role = "user", content = "Hello" } },
      on_event = function(event) if event.type == "text_delta" then deltas[#deltas + 1] = event.text end end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("Hello", result.text)
    assert(vim.wait(1000, function() return #deltas == 2 end))
    assert.are.same({ "Hel", "lo" }, deltas)
    assert(vim.wait(1000, function() return #server.records >= 2 end))
    assert.are.equal("request", server.records[2].type)
  end)

  it("surfaces non-2xx bodies as transport errors", function()
    local server = mock_server.start("tests/fixtures/openai/error.json")
    servers[#servers + 1] = server
    local result = wait(model(server):stream({ messages = {} }))
    assert.is_false(result.ok)
    assert.are.equal("transport", result.error.kind)
    assert.matches("bad request", result.error.detail)
  end)

  it("cancels curl and preserves partial assistant output", function()
    local server = mock_server.start("tests/fixtures/openai/cancel.json")
    servers[#servers + 1] = server
    local saw_partial = false
    local run
    run = model(server):stream({
      messages = {},
      on_event = function(event)
        if event.type == "text_delta" then
          saw_partial = true
          run:cancel()
        end
      end,
    })
    local result = wait(run)
    assert.is_true(saw_partial)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.are.equal("partial", result.message.content[1].text)
    assert.are.equal("aborted", result.message.stopReason)
  end)
end)
