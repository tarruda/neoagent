local assert = require("luassert")
local replay = require("neoagent.http_replay")
local registry = require("neoagent.registry")
local providers = {
  {
    provider = "alibaba-token-plan",
    model = "deepseek-v4-flash-0731",
    expected_text = "Recorded reply.",
    path = "alibaba-token-plan.yaml",
    expected_usage = { input = 8, output = 261, totalTokens = 269, cacheRead = 0, cacheWrite = 0 },
  },
  {
    provider = "deepseek",
    model = "deepseek-v4-flash",
    expected_text = "Recorded reply.",
    path = "deepseek.yaml",
    expected_usage = { input = 128101, output = 1606, totalTokens = 129707, cacheRead = 128000, cacheWrite = 0 },
  },
  {
    provider = "llama.cpp",
    model = "deepseek-v4-flash-vision-exp",
    expected_text = "Recorded reply.",
    path = "llama.cpp.yaml",
    expected_usage = { input = 8, output = 214, totalTokens = 222, cacheRead = 0, cacheWrite = 0 },
  },
  {
    provider = "opencode-go",
    model = "deepseek-v4-flash-vision-exp",
    expected_text = "Recorded reply.",
    path = "opencode-go.yaml",
    expected_usage = { input = 7741, output = 515, totalTokens = 8256, cacheRead = 6656, cacheWrite = 0 },
  },
  {
    provider = "zai-coding-plan",
    model = "glm-5.3",
    expected_text = "Recorded reply.",
    path = "zai-coding-plan.yaml",
    expected_usage = { input = 74254, output = 50, totalTokens = 74304, cacheRead = 74112, cacheWrite = 0 },
  },
}
---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  local result = assert(run:result())
  assert(result.ok, (vim.inspect(result.error)))
  return result
end

describe("minimized real provider recordings", function()
  ---@type Neoagent.HttpReplay?
  local scenario
  ---@type string?
  local directory
  after_each(function()
    if scenario then scenario.close(); scenario.assert_consumed(); scenario = nil end
    if directory then vim.fn.delete(directory, "rf"); directory = nil end
  end)
  for _, capture in ipairs(providers) do
    it("decodes recorded " .. capture.provider .. " response shapes through its request policy", function()
      scenario = replay.new({ exchanges = { { path = "tests/recordings/real/" .. capture.path, headers_subset = true } } })
      ---@type Neoagent.Model
      local model = require("neoagent.api.openai_completions").new({
        provider = capture.provider, model = capture.model, base_url = "https://api.test/v1",
        api_key = "replay-key", transport = scenario,
        request_context = { session_id = "recorded-session" },
        request_opts = assert(registry.defaults()[capture.provider]).request_opts,
      })
      if capture.provider ~= "llama.cpp" then
        local method_id = capture.provider == "zai-coding-plan" and "zai" or capture.provider
        directory = vim.fn.tempname()
        local manager = require("neoagent.auth").new({
          methods = { provider = require("neoagent.config").get().auth.methods[method_id] },
          store = require("neoagent.auth.store").new(directory .. "/credentials.json"),
        })
        local key = capture.provider == "alibaba-token-plan" and "sk-sp-replay-key" or "replay-key"
        wait(manager:login("provider", { prompt = function(_, done) done.resolve(key) end }))
        model = manager:wrap(model, "provider")
      end
      local result = wait(model:stream({ messages = { { role = "user", content = "Hello" } } }))
      assert.are.equal(capture.expected_text, result.text)
      assert.are.equal("stop", assert(result.message).stopReason)
      for field, expected in pairs(capture.expected_usage) do
        assert.are.equal(expected, assert(assert(result.message).usage)[field])
      end
      if capture.provider == "opencode-go" then
        assert.are.equal("recorded-session", rawget(assert(assert(scenario.requests[1]).headers), "x-opencode-session"))
      end
    end)
  end
end)

describe("OpenCode Go API routing and authentication", function()
  ---@type Neoagent.HttpReplay?
  local scenario
  ---@type string?
  local directory
  after_each(function()
    if scenario then scenario.close(); scenario.assert_consumed(); scenario = nil end
    if directory then vim.fn.delete(directory, "rf"); directory = nil end
  end)
  for _, case in ipairs({
    { "gpt-5.6-luna", "responses", "openai_responses", "Hello" },
    { "minimax-m3", "messages", "anthropic_messages", "Recorded reply." },
  }) do
    it("uses the catalog's " .. case[2] .. " protocol and shared credential for " .. case[1], function()
      local definition = assert(registry.defaults()["opencode-go"])
      local source = { id = case[1] }
      local selected = assert(assert(definition.catalog).transform_model)(source, {
        provider_id = "opencode-go", source_model = source,
      })
      assert(selected)
      assert.are.equal(case[3]:gsub("_", "-"), selected.api)
      scenario = replay.new({ exchanges = { { path = "tests/recordings/opencode-go/" .. case[2] .. ".yaml", headers_subset = true } } })
      directory = vim.fn.tempname()
      local manager = require("neoagent.auth").new({
        methods = { go = require("neoagent.config").get().auth.methods["opencode-go"] },
        store = require("neoagent.auth.store").new(directory .. "/credentials.json"),
      })
      wait(manager:login("go", { prompt = function(_, done) done.resolve("replay-key") end }))
      local api = require("neoagent.api." .. case[3]) --[[@as {new: fun(opts: Neoagent.ApiModelOptions): Neoagent.Model}]]
      local model = api.new({
        provider = "opencode-go", model = case[1], base_url = "https://api.test/v1",
        transport = scenario, max_output_tokens = case[2] == "messages" and 128 or nil,
        request_context = { session_id = "recorded-session" }, request_opts = definition.request_opts,
      })
      local result = wait(manager:wrap(model, "go"):stream({ messages = { { role = "user", content = "Hello" } } }))
      assert.are.equal(case[4], result.text)
      local headers = assert(assert(scenario.requests[1]).headers)
      assert.are.equal("Bearer replay-key", rawget(headers, "Authorization"))
      assert.are.equal("replay-key", rawget(headers, "x-api-key"))
      assert.are.equal("recorded-session", rawget(headers, "x-opencode-session"))
    end)
  end
end)
