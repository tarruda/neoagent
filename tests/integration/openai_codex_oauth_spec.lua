local assert = require("luassert")
local codex = require("neoagent.auth.openai_codex")
local http_replay = require("tests.helpers.http_replay")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return run:result()
end

describe("OpenAI Codex OAuth HTTP integration", function()
  local scenarios = {}
  local network
  before_each(function() network = require("tests.helpers.callback_connections").install() end)

  after_each(function()
    for _, scenario in ipairs(scenarios) do http_replay.finish(scenario) end
    scenarios = {}
    network.restore()
  end)

  it("receives a browser callback and exchanges its code through recorded HTTP", function()
    local scenario = http_replay.open({
      { path = "tests/recordings/openai/codex_oauth-01.yaml", body_subset = true, headers_subset = true },
    })
    scenarios[#scenarios + 1] = scenario
    local callback, challenge
    local method = codex.new({ auth_base_url = scenario.url, http = scenario })
    local run = method.login({
      prompt = function(prompt, done)
        assert.are.equal("select", prompt.type)
        done.resolve("browser")
      end,
      notify = function(event)
        assert.are.equal("auth_url", event.type)
        challenge = event.url:match("[?&]code_challenge=([^&]+)")
        assert.matches("code_challenge_method=S256", event.url)
        local state = event.url:match("[?&]state=([^&]+)")
        for _, target in ipairs({
          "/wrong", "/auth/callback?code=wrong&state=wrong",
          "/auth/callback?state=" .. state,
          "/auth/callback?code=integration-code&state=" .. state,
        }) do
          callback = network.request(1455, "GET " .. target .. " HTTP/1.1\r\nHost: localhost\r\n\r\n")
        end
      end,
    })
    local result = wait(run)
    assert.is_true(result.ok)
    assert.are.equal("integration-account", result.credential.accountId)
    assert.matches("200 OK", callback)
    assert(vim.wait(1000, function() return #scenario.requests >= 1 end))
    assert.are.equal(scenario.url .. "/oauth/token", scenario.requests[1].url)
    local verifier = assert(scenario.requests[1].body:match("code_verifier=([^&]+)"))
    local hash = vim.fn.sha256(vim.uri_decode(verifier)):gsub("..", function(hex) return string.char(tonumber(hex, 16)) end)
    assert.are.equal(challenge, (vim.base64.encode(hash):gsub("+", "-"):gsub("/", "_"):gsub("=+$", "")))
  end)

  it("exchanges a pasted redirect when the browser callback port is unavailable", function()
    local scenario = http_replay.open({
      { path = "tests/recordings/openai/codex_oauth-01.yaml", body_subset = true, headers_subset = true },
    })
    scenarios[#scenarios + 1] = scenario
    require("neoagent.auth.local_callback").listen = function() return nil, "address in use" end
    local state
    local result = wait(codex.new({ auth_base_url = scenario.url, http = scenario }).login({
      notify = function(event) state = assert(event.url:match("[?&]state=([^&]+)")) end,
      prompt = function(prompt, done)
        if prompt.type == "select" then done.resolve("browser") else
          assert.are.equal("manual_code", prompt.type)
          done.resolve("http://localhost:1455/auth/callback?code=integration-code&state=" .. state)
        end
      end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("integration-account", result.credential.accountId)
  end)

  it("authenticates a Codex Responses request through the Model wrapper", function()
    local scenario = http_replay.open({
      { path = "tests/recordings/openai/codex_stream-01.yaml", body_subset = true, headers_subset = true },
    })
    scenarios[#scenarios + 1] = scenario
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
      transport = scenario,
      base_url = scenario.url .. "/backend-api",
    })
    local provider_status
    local result = wait(manager:wrap(model, "codex"):stream({
      system_prompt = "Be useful.",
      messages = { { role = "user", content = "Hello" } },
      on_event = function(event)
        if event.type == "provider_status" then provider_status = event.text end
      end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("Codex works", result.text)
    assert.are.equal("5h 75% left · weekly 50% left", provider_status)
    assert(vim.wait(1000, function() return #scenario.requests >= 1 end))
    assert.are.equal(scenario.url .. "/backend-api/codex/responses", scenario.requests[1].url)
  end)

  it("reports connection failures from authentication requests", function()
    local replay = http_replay.open({
      { path = "tests/recordings/openai/connection-failure-01.yaml", headers_subset = true },
    })
    scenarios[#scenarios + 1] = replay
    local result = wait(require("neoagent.transport.http").new(replay).fetch({
      request = { url = replay.url .. "/oauth/token" },
    }))
    assert.is_false(result.ok)
    assert.are.equal("transport", result.error.kind)
    replay.assert_consumed()
    replay.close()
  end)
end)
