local anthropic_auth = require("neoagent.auth.anthropic")
local mock_server = require("tests.helpers.mock_server")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return run:result()
end

local function query_value(url, name)
  local query = url:match("%?(.+)$") or ""
  for pair in query:gmatch("[^&]+") do
    local key, value = pair:match("^([^=]+)=?(.*)$")
    if vim.uri_decode(key) == name then return vim.uri_decode(value:gsub("+", " ")) end
  end
end

describe("Anthropic OAuth HTTP integration", function()
  local servers = {}

  after_each(function()
    for _, server in ipairs(servers) do server:stop() end
    servers = {}
  end)

  it("receives a browser callback and exchanges and refreshes through curl", function()
    local server = mock_server.start("tests/fixtures/anthropic/oauth.json")
    servers[#servers + 1] = server
    local method = anthropic_auth.new({
      token_url = "http://127.0.0.1:" .. server.port .. "/v1/oauth/token",
      now = function() return 1000000 end,
    })
    local callback_result
    local login = method.login({
      prompt = function(prompt, done)
        assert.are.equal("select", prompt.type)
        done.resolve("browser")
      end,
      notify = function(event)
        if event.type ~= "auth_url" then return end
        local state = assert(query_value(event.url, "state"))
        vim.system({
          "curl", "--silent", "--show-error",
          "http://127.0.0.1:53692/callback?code=callback-code&state=" .. vim.uri_encode(state),
        }, { text = true }, function(result) callback_result = result end)
      end,
    })
    local logged_in = wait(login)

    assert.is_true(logged_in.ok)
    assert.are.equal("access-1", logged_in.credential.access)
    assert(vim.wait(1000, function() return callback_result ~= nil end))
    assert.are.equal(0, callback_result.code)
    local refreshed = wait(method.refresh(logged_in.credential))
    assert.is_true(refreshed.ok)
    assert.are.equal("access-2", refreshed.credential.access)
    assert(vim.wait(1000, function() return #server.records >= 3 end))
    local exchange = server.records[2].body
    assert.are.equal(exchange.state, exchange.code_verifier)
  end)
end)
