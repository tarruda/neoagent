local assert = require("luassert")
local fs = require("neoagent.fs")
local http_replay = require("tests.helpers.http_replay")

describe("provider diagnostic privacy", function()
  ---@type Neoagent.TestHttpReplay[]
  local scenarios = {}
  ---@type string[]
  local directories = {}

  after_each(function()
    for _, scenario in ipairs(scenarios) do http_replay.finish(scenario) end
    for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
    scenarios, directories = {}, {}
  end)

  for _, case in ipairs({
    { fixture = "codex-diagnostic-http", status = 400, code = "invalid_request" },
    { fixture = "codex-diagnostic-sse", status = 200 },
  }) do
    it("excludes echoed content from " .. case.fixture .. " diagnostics", function()
      local scenario = http_replay.open({ {
        path = "tests/recordings/openai/" .. case.fixture .. ".yaml",
        headers_subset = true,
        body_subset = true,
      } })
      scenarios[#scenarios + 1] = scenario
      local directory = vim.fn.tempname()
      directories[#directories + 1] = directory
      local path = directory .. "/codex.log"
      local log = require("neoagent.provider_log").callback(path)
      local manager = require("neoagent.auth").new({
        methods = { codex = require("neoagent.auth.openai_codex").new() },
        store = require("tests.helpers.auth_manager").store({ codex = {
          access = "synthetic-diagnostic-access",
          refresh = "synthetic-diagnostic-refresh",
          expires = 9999999999999,
          accountId = "diagnostic-account",
        } }),
      })
      ---@type Neoagent.CodexRequestDiagnostic?
      local observed
      local model = require("neoagent.api.openai_codex_responses").new({
        provider = "openai-codex",
        model = "gpt-test",
        transport = scenario,
        base_url = scenario.url .. "/backend-api",
        request_max_retries = 0,
        on_diagnostic = function(event)
          observed = event
          log(event)
        end,
      })
      local run = manager:wrap(model, "codex"):stream({ messages = { {
        role = "user", content = "synthetic-private-prompt",
      } } })
      assert(vim.wait(3000, function() return run:is_done() end))
      local result = assert(run:result())
      assert.is_false(result.ok)
      assert.matches("synthetic%-private%-prompt", assert(result.error).message)
      local diagnostic = assert(observed)
      local raw = assert(fs.read(path))
      for _, content in ipairs({ "synthetic-private-prompt", "synthetic-diagnostic-access" }) do
        assert.is_nil((vim.inspect(diagnostic):find(content, 1, true)))
        assert.is_nil((raw:find(content, 1, true)))
      end
      assert.are.equal(case.status, diagnostic.status)
      assert.are.equal(case.code, diagnostic.code)
      assert.are.equal("req-diagnostic", diagnostic.request_id)
      assert.are.equal("request_failed", diagnostic.type)
      assert.is_true(diagnostic.authorization_error)
      assert.is_nil((diagnostic.message:find("synthetic", 1, true)))
    end)
  end
end)
