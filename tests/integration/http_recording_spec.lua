local fs = require("neoagent.fs")
local mock_server = require("tests.helpers.mock_server")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function records(path)
  local result = {}
  for line in assert(fs.read(path)):gmatch("[^\n]+") do
    result[#result + 1] = vim.json.decode(line)
  end
  return result
end

describe("HTTP recording integration", function()
  local directories = {}
  local servers = {}

  after_each(function()
    for _, server in ipairs(servers) do server:stop() end
    for _, path in ipairs(directories) do vim.fn.delete(path, "rf") end
    servers, directories = {}, {}
  end)

  it("records a real curl model stream after provider decoding", function()
    local directory = vim.fn.tempname()
    local workspace = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    assert.are.equal(1, vim.fn.mkdir(workspace, "p"))
    directory = assert(vim.uv.fs_realpath(directory))
    workspace = assert(vim.uv.fs_realpath(workspace))
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local server = mock_server.start("tests/fixtures/openai/stream.json")
    servers[#servers + 1] = server
    local recorder = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
    }))
    local transport = recorder:transport(
      require("neoagent.transport.curl"), {
        workspace = workspace,
        provider = "mock",
        model = "test-model",
        origin = "model",
        agent_id = "agent-integration",
        session_id = "session-integration",
      })
    local model = require("neoagent.api.openai_completions").new({
      provider = "mock",
      model = "test-model",
      base_url = "http://127.0.0.1:" .. server.port .. "/v1",
      api_key = "test-key",
      transport = transport,
    })

    local result = wait(model:stream({
      messages = { { role = "user", content = "Hello" } },
    }))
    assert(result.ok, vim.inspect(result))
    assert.are.equal("Hello", result.text)
    recorder:destroy()

    local paths = vim.fn.globpath(directory, "**/*.jsonl", false, true)
    assert.are.equal(1, #paths)
    local content = assert(fs.read(paths[1]))
    assert.is_nil(content:find("test-key", 1, true))
    assert.matches('"session_id":"session%-integration"', content)
    assert.matches('"status":200', content)
    assert.matches('"type":"response_chunk"', content)
    assert.matches('"type":"response_body"', content)
    assert.matches("Hel", content)
    assert.matches("lo", content)
    assert.matches('"type":"complete"', content)
  end)

  it("replaces a real OAuth credential response classified by its adapter", function()
    local directory = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    directory = assert(vim.uv.fs_realpath(directory))
    directories[#directories + 1] = directory
    local server = mock_server.start("tests/fixtures/openai/codex_oauth.json")
    servers[#servers + 1] = server
    local recorder = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
    }))
    local http = recorder:transport(require("neoagent.transport.curl"), {
      origin = "authentication",
      auth_method = "openai-codex",
    })
    local method = require("neoagent.auth.openai_codex").new({
      auth_base_url = "http://127.0.0.1:" .. server.port,
      http = http,
      start_callback_server = function()
        return {
          wait = function() return "integration-code" end,
          close = function() end,
        }
      end,
    })

    local result = wait(method.login({
      prompt = function(prompt, done)
        assert.are.equal("select", prompt.type)
        done.resolve("browser")
      end,
      notify = function(event)
        assert.are.equal("auth_url", event.type)
      end,
    }))
    assert.is_true(result.ok)
    recorder:destroy()

    local paths = vim.fn.globpath(directory, "**/*.jsonl", false, true)
    assert.are.equal(1, #paths)
    assert.matches("/provider/recordings/openai%-codex/", paths[1])
    local content = assert(fs.read(paths[1]))
    assert.is_nil(content:find("integration-refresh", 1, true))
    assert.is_nil(content:find("integration-code", 1, true))
    local parsed = records(paths[1])
    assert.is_nil(parsed[1].workspace)
    assert.are.equal("authentication", parsed[1].context.origin)
    assert.are.equal("openai-codex", parsed[1].context.auth_method)
    assert.matches("client_id=%*", parsed[1].request.body)
    assert.matches("code=%*", parsed[1].request.body)
    assert.matches("code_verifier=%*", parsed[1].request.body)
    assert.are.equal("*", parsed[3].body)
    assert.is_true(parsed[3].redacted)
  end)
end)
