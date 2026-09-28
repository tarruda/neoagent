local assert = require("luassert")
local auth = require("neoagent.auth")
local config = require("neoagent.config")
local replay = require("neoagent.http_replay")
local runtimes_api = require("neoagent.provider_runtimes")
local models = require("neoagent.models")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return (assert(run:result()))
end

local thought = "I will inspect the example condition."

describe("OpenCode Go Qwen missing-tool recovery", function()
  ---@type Neoagent.HttpReplay?
  local player
  ---@type Neoagent.ProviderRuntimes?
  local runtimes
  ---@type string?
  local directory
  before_each(function()
    config.setup({ providers = { ["opencode-go"] = { base_url = "https://api.test/v1" } } })
    directory = vim.fn.tempname()
  end)
  after_each(function()
    if runtimes then runtimes_api.destroy(runtimes); runtimes = nil end
    if player then player.close(); player = nil end
    vim.fn.delete(assert(directory), "rf")
    config._reset()
  end)

  ---@param followup? string|false
  ---@param finish? boolean
  ---@return Neoagent.Model
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
      store = require("neoagent.auth.store").new(assert(directory) .. "/credentials.json") })
    assert.is_true(wait(manager:login("opencode-go", {
      prompt = function(_, done) done.resolve("replay-key") end,
    })).ok)
    runtimes = assert(runtimes_api.compose(config.get(), { startup = false, transport = player, auth = manager }))
    return models.resolve("opencode-go", "qwen3.8-flash", config.get(), manager, runtimes,
      { session_id = "recovery-session" })
  end

  it("classifies the recorded failure without issuing an uncommitted follow-up", function()
    local model = start(false)
    local completed = 0
    local result = wait(model:stream({ messages = { { role = "user", content = "Inspect the condition." } },
      on_done = function() completed = completed + 1 end,
    }))
    assert.is_false(result.ok)
    assert.are.equal("missing_tool_call", assert(result.error).code)
    assert.are.equal(thought, assert(assert(result.message).content[1]).thinking)
    assert.matches("no tool call", require("neoagent.util").text_content(assert(result.recovery).message.content))
    assert.are.equal(1, #assert(player).requests)
    assert(vim.wait(1000, function() return completed == 1 end))
    assert(player).assert_consumed()
  end)

  it("commits recovered output before executing its tool and continues normal conversation history", function()
    local model = start(nil, true)
    local committed, executed, warnings, gates = {}, 0, 0, 0
    local result = wait(require("neoagent.agent_loop").run({
      model = model, messages = { { role = "user", content = "Inspect the condition." } },
      tools = { { name = "inspect", description = "Inspect a path", input_schema = {
        type = "object", properties = { path = { type = "string" } }, required = { "path" },
      }, execute = function(arguments)
        assert.are.equal("example.lua", arguments.path)
        assert.are.equal(3, #committed)
        assert.are.equal("inspect-call", committed[3].content[2].id)
        executed = executed + 1
        return { content = { { type = "text", text = "Condition found." } } }
      end } },
      commit_message = function(message) committed[#committed + 1] = message; return true end,
      prepare_request_messages = function(messages, options)
        gates = gates + 1
        assert.are.equal(#committed + 1, #messages)
        if gates == 2 then
          assert.are.equal(thought, committed[1].content[1].thinking)
          assert.matches("no tool call", committed[2].content)
        end
        require("neoagent.api.request_estimate").request(model, options)
        return messages
      end,
      on_event = function(event) if event.type == "warning" then warnings = warnings + 1 end end,
    }))
    assert(result.ok, (vim.inspect(result)))
    assert.are.equal(1, executed)
    assert.are.equal(1, warnings)
    assert.are.equal(5, #committed)
    assert.are.equal(3, gates)
    assert.are.equal("Recorded reply.", result.text)
    local next_request = vim.json.decode((assert(assert(assert(player).requests[3]).body)))
    assert.are.equal(5, #next_request.messages)
    assert.are.equal("tool_result", next_request.messages[5].content[1].type)
    assert.are.equal("inspect-call", next_request.messages[5].content[1].tool_use_id)
    assert(player).assert_consumed()
  end)

  it("stops after one unsuccessful follow-up and retains both responses", function()
    local model = start("qwen-missing-tool")
    local warnings, committed = 0, {}
    local result = wait(require("neoagent.agent_loop").run({ model = model, messages = {}, tools = {},
      commit_message = function(message) committed[#committed + 1] = message return true end,
      on_event = function(event) if event.type == "warning" then warnings = warnings + 1 end end,
    }))
    assert.is_false(result.ok)
    assert.are.equal("missing_tool_call", rawget(assert(result.error), "code"))
    assert.are.equal(3, #committed)
    assert.are.equal(thought, committed[1].content[1].thinking)
    assert.are.equal(thought, committed[3].content[1].thinking)
    assert.are.equal(3950, committed[1].usage.input)
    assert.are.equal(3950, committed[3].usage.input)
    assert.are.equal(1, warnings)
    assert.are.equal(2, #assert(player).requests)
    assert(player).assert_consumed()
  end)

  for _, phase in ipairs({ "initial", "warning", "continuation" }) do
    it("cancels during " .. phase .. " without starting another request", function()
      local model = start(phase == "continuation" and "qwen-tool-followup" or false)
      ---@type Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>?
      local run
      local completed, gates, committed = 0, 0, {}
      run = require("neoagent.agent_loop").run({ model = model, messages = {}, tools = {},
        commit_message = function(message) committed[#committed + 1] = message return true end,
        prepare_request_messages = function(messages) gates = gates + 1 return messages end,
        on_event = function(event)
          if phase == "initial" and event.type == "thinking_delta"
              or phase == "warning" and event.type == "warning"
              or phase == "continuation" and event.type == "thinking_delta" and gates == 2 then
            assert(run):cancel()
          end
        end,
        on_done = function() completed = completed + 1 end,
      })
      local result = wait(run)
      assert.is_false(result.ok)
      assert.are.equal("cancelled", assert(result.error).kind)
      assert.are.equal(thought, committed[1].content[1].thinking)
      if phase == "continuation" then
        assert.are.equal("I will inspect the condition.", committed[3].content[1].thinking)
        assert.are.equal("aborted", committed[3].stopReason)
      elseif phase == "initial" then
        assert.are.equal("aborted", committed[1].stopReason)
      end
      assert.are.equal(phase == "continuation" and 2 or 1, #assert(player).requests)
      assert(vim.wait(1000, function() return completed == 1 end))
      assert(player).assert_consumed()
    end)
  end
end)
