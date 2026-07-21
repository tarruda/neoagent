local codex = require("neoagent.auth.openai_codex")
local mock_server = require("tests.helpers.mock_server")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return run:result()
end

describe("OpenAI Codex OAuth HTTP integration", function()
  local servers = {}

  after_each(function()
    for _, server in ipairs(servers) do server:stop() end
    servers = {}
  end)

  it("receives a browser callback and exchanges its code through curl", function()
    local server = mock_server.start("tests/fixtures/openai/codex_oauth.json")
    servers[#servers + 1] = server
    local callback
    local method = codex.new({ auth_base_url = "http://127.0.0.1:" .. server.port })
    local run = method.login({
      prompt = function(prompt, done)
        assert.are.equal("select", prompt.type)
        done.resolve("browser")
      end,
      notify = function(event)
        assert.are.equal("auth_url", event.type)
        local state = event.url:match("[?&]state=([^&]+)")
        local urls = {
          "http://127.0.0.1:1455/wrong",
          "http://127.0.0.1:1455/auth/callback?code=wrong&state=wrong",
          "http://127.0.0.1:1455/auth/callback?state=" .. state,
          "http://127.0.0.1:1455/auth/callback?code=integration-code&state=" .. state,
        }
        local function request(index)
          callback = vim.system({ "curl", "--silent", urls[index] }, function()
            if urls[index + 1] then vim.schedule(function() request(index + 1) end) end
          end)
        end
        request(1)
      end,
    })
    local result = wait(run)
    assert.is_true(result.ok)
    assert.are.equal("integration-account", result.credential.accountId)
    assert.are.equal(0, callback:wait().code)
    assert(vim.wait(1000, function() return #server.records >= 2 end))
    assert.are.equal("/oauth/token", server.records[2].path)
    assert.is_truthy(server.records[2].body.code_verifier)
  end)

  it("authenticates a Codex Responses request through the Model wrapper", function()
    local server = mock_server.start("tests/fixtures/openai/codex_stream.json")
    servers[#servers + 1] = server
    local credential = {
      access = "access-token",
      refresh = "refresh-token",
      expires = 9999999999999,
      accountId = "integration-account",
    }
    local store = {
      read = function() return credential end,
      write = function() return true end,
    }
    local manager = require("neoagent.auth").new({
      methods = { codex = codex.new() },
      store = store,
    })
    local model = require("neoagent.api.openai_codex_responses").new({
      provider = "openai-codex",
      model = "gpt-test",
      base_url = "http://127.0.0.1:" .. server.port .. "/backend-api",
    })
    local result = wait(manager:wrap(model, "codex"):stream({
      system_prompt = "Be useful.",
      messages = { { role = "user", content = "Hello" } },
    }))
    assert.is_true(result.ok)
    assert.are.equal("Codex works", result.text)
    assert(vim.wait(1000, function() return #server.records >= 2 end))
    assert.are.equal("/backend-api/codex/responses", server.records[2].path)
  end)

  it("reports curl failures from authentication requests", function()
    local result = wait(require("neoagent.transport.curl").fetch({
      request = { url = "http://127.0.0.1:1/token", body = "" },
    }))
    assert.is_false(result.ok)
    assert.are.equal("transport", result.error.kind)
  end)
end)
