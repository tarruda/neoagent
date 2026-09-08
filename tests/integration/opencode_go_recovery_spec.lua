local assert = require("luassert")
local auth = require("neoagent.auth")
local config = require("neoagent.config")
local replay = require("neoagent.http_replay")
local runtimes_api = require("neoagent.provider_runtimes")
local models = require("neoagent.models")

local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return run:result()
end

local thought = "I will inspect the example condition."

describe("OpenCode Go Qwen missing-tool recovery", function()
  local player, runtimes, directory
  before_each(function()
    config.setup({ providers = { ["opencode-go"] = { base_url = "https://api.test/v1" } } })
    directory = vim.fn.tempname()
  end)
  after_each(function()
    if runtimes then runtimes_api.destroy(runtimes); runtimes = nil end
    if player then player.close(); player = nil end
    vim.fn.delete(directory, "rf")
    config._reset()
  end)

  local function start(followup, finish)
    local exchanges = {
      { path = "tests/recordings/opencode-go/qwen-missing-tool.yaml", headers_subset = true, body_subset = true },
    }
    if followup ~= false then exchanges[#exchanges + 1] =
      { path = "tests/recordings/opencode-go/" .. (followup or "qwen-tool-followup") .. ".yaml",
        headers_subset = true, body_subset = true }
    end
    if finish then exchanges[#exchanges + 1] = {
      path = "tests/recordings/opencode-go/qwen-complete.yaml", headers_subset = true, body_subset = true,
    } end
    player = replay.new({ exchanges = exchanges })
    local manager = auth.new({ methods = config.get().auth.methods,
      store = require("neoagent.auth.store").new(directory .. "/credentials.json") })
    assert.is_true(wait(manager:login("opencode-go", {
      prompt = function(_, done) done.resolve("replay-key") end,
    })).ok)
    runtimes = assert(runtimes_api.compose(config.get(), { startup = false, transport = player, auth = manager }))
    return models.resolve("opencode-go", "qwen3.8-flash", config.get(), manager, runtimes,
      { session_id = "recovery-session" })
  end

  it("continues the recorded thinking-only tool-use response through authenticated requests", function()
    local model = start()
    local events, completed = {}, 0
    local messages = { { role = "user", content = "Inspect the condition." } }
    local result = wait(model:stream({ messages = messages,
      on_event = function(event) events[#events + 1] = event end,
      on_done = function() completed = completed + 1 end,
    }))
    assert.is_true(result.ok, vim.inspect(result.error))
    assert.are.equal("toolUse", result.message.stopReason)
    assert.are.equal(thought, result.message.content[1].thinking)
    assert.are.equal("I will inspect the condition.", result.message.content[2].thinking)
    assert.are.equal("inspect", result.message.content[3].name)
    assert.are.same({ path = "example.lua" }, result.message.content[3].arguments)
    assert.are.equal(3970, result.message.usage.input)
    assert.are.equal(365, result.message.usage.output)
    assert.are.equal(81920, result.message.usage.cacheRead)
    assert.are.equal("followup-response", result.message.responseId)
    assert.are.same({ { role = "user", content = "Inspect the condition." } }, messages)
    local second = vim.json.decode(player.requests[2].body)
    assert.are.equal(3, #second.messages)
    assert.are.equal("assistant", second.messages[2].role)
    assert.are.equal(thought, second.messages[2].content[1].text)
    assert.are.equal("user", second.messages[3].role)
    assert.matches("no tool call", second.messages[3].content)
    assert.are.equal("recovery-session", player.requests[2].headers["x-opencode-session"])
    local warnings = vim.tbl_filter(function(event) return event.type == "warning" end, events)
    assert.are.equal(1, #warnings)
    assert.matches("Provider bug", warnings[1].message)
    assert(vim.wait(1000, function() return completed == 1 end))
    player.assert_consumed()
  end)

  it("commits recovered output before executing its tool and continues normal conversation history", function()
    local model = start(nil, true)
    local committed, executed, warnings = {}, 0, 0
    local result = wait(require("neoagent.agent_loop").run({
      model = model, messages = { { role = "user", content = "Inspect the condition." } },
      tools = { { name = "inspect", description = "Inspect a path", input_schema = {
        type = "object", properties = { path = { type = "string" } }, required = { "path" },
      }, execute = function(arguments)
        assert.are.equal("example.lua", arguments.path)
        assert.are.equal(1, #committed)
        assert.are.equal("inspect-call", committed[1].content[3].id)
        executed = executed + 1
        return { content = { { type = "text", text = "Condition found." } } }
      end } },
      commit_message = function(message) committed[#committed + 1] = message; return true end,
      on_event = function(event) if event.type == "warning" then warnings = warnings + 1 end end,
    }))
    assert.is_true(result.ok, vim.inspect(result.error))
    assert.are.equal(1, executed)
    assert.are.equal(1, warnings)
    assert.are.equal(3, #committed)
    assert.are.equal("Recorded reply.", result.text)
    local next_request = vim.json.decode(player.requests[3].body)
    assert.are.equal(3, #next_request.messages)
    assert.are.equal("tool_result", next_request.messages[3].content[1].type)
    assert.are.equal("inspect-call", next_request.messages[3].content[1].tool_use_id)
    player.assert_consumed()
  end)

  it("stops after one unsuccessful follow-up and retains both responses", function()
    local model = start("qwen-missing-tool")
    local warnings = 0
    local result = wait(model:stream({ messages = {}, on_event = function(event)
      if event.type == "warning" then warnings = warnings + 1 end
    end }))
    assert.is_false(result.ok)
    assert.are.equal("missing_tool_call", result.error.code)
    assert.are.equal(2, #result.message.content)
    assert.are.equal(thought, result.message.content[1].thinking)
    assert.are.equal(thought, result.message.content[2].thinking)
    assert.are.equal(7900, result.message.usage.input)
    assert.are.equal(1, warnings)
    assert.are.equal(2, #player.requests)
    player.assert_consumed()
  end)

  for _, phase in ipairs({ "initial", "warning", "continuation" }) do
    it("cancels during " .. phase .. " without losing received thinking or starting another request", function()
      local model = start(phase == "continuation" and "qwen-tool-followup" or false)
      local run, completed
      completed = 0
      run = model:stream({ messages = {}, on_event = function(event)
        if phase == "initial" and event.type == "thinking_delta"
            or phase == "warning" and event.type == "warning"
            or phase == "continuation" and event.type == "thinking_delta" and event.index == 1 then
          run:cancel()
        end
      end, on_done = function() completed = completed + 1 end })
      local result = wait(run)
      assert.is_false(result.ok)
      assert.are.equal("cancelled", result.error.kind)
      assert.is_not_nil(result.message)
      assert.are.equal("aborted", result.message.stopReason)
      assert.are.equal(thought, result.message.content[1].thinking)
      if phase == "continuation" then
        assert.are.equal("I will inspect the condition.", result.message.content[2].thinking)
        assert.are.equal(2, #player.requests)
      else
        assert.are.equal(1, #player.requests)
      end
      assert(vim.wait(1000, function() return completed == 1 end))
      player.assert_consumed()
    end)
  end
end)
