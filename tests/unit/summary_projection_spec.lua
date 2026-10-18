local assert = require("luassert")
local compaction = require("neoagent.compaction")
local fake_model = require("tests.helpers.fake_model")
local summary = require("neoagent.compaction.summary")

describe("Summary request projection", function()
  it("budgets shipped Pi environment context before dedicated summary inference", function()
    local prompt = require("neoagent.profiles.pi.prompt").prepare({
      workspace = { root = "/project", cwd = "/project" },
      prompt = "compact",
      tools = {},
      skills = {},
      agent_instructions = { { path = "/project/AGENTS.md", content = string.rep("trusted context ", 4000) } },
    })
    local model = fake_model.new({})
    model.context_window = 2000
    local run = compaction.run({
      model = model,
      system_prompt = prompt.system_prompt,
      prepare_request = prompt.prepare_request,
      preparation = {
        kind = "summary",
        split_turn = false,
        messages = { { role = "user", content = "short history" } },
        turn_prefix = {},
        first_kept_entry_id = "keep",
        tokens_before = 100,
        settings = compaction.settings({ reserve_tokens = 64 }),
      },
    })
    assert(vim.wait(1000, function()
      return run:is_done()
    end, 5))
    local result = assert(run:result())
    assert.is_false(result.ok)
    assert.matches("summary request exceeds the Model window", assert(result.error).message)
    assert.are.equal(0, #model.requests)
  end)

  it("projects both split-turn requests while retaining dedicated instructions", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "history summary" } }) },
      { result = fake_model.assistant({ { type = "text", text = "turn summary" } }) },
    })
    local projections = 0
    local run = compaction.run({
      model = model,
      preparation = {
        kind = "summary",
        split_turn = true,
        messages = { { role = "user", content = "old history" } },
        turn_prefix = { { role = "user", content = "current turn prefix" } },
        first_kept_entry_id = "keep",
        tokens_before = 100,
        settings = compaction.settings(),
      },
      prepare_request = function(request)
        projections = projections + 1
        assert.are.equal(summary.system_prompt, request.system_prompt)
        assert.are.same({}, request.tools)
        table.insert(request.messages, 1, { role = "developer", content = "trusted context" })
        return { messages = request.messages, system_prompt = request.system_prompt .. "\nProjected instructions" }
      end,
    })
    assert(vim.wait(1000, function()
      return run:is_done()
    end, 5))
    local result = run:result()
    assert(result)
    assert.is_true(result.ok)
    assert.are.equal(2, projections)
    assert.are.equal(2, #model.requests)
    for _, request in ipairs(model.requests) do
      assert.are.same({ role = "developer", content = "trusted context" }, request.messages[1])
      assert.are.equal(summary.system_prompt .. "\nProjected instructions", request.system_prompt)
      assert.are.same({}, request.tools)
    end
  end)

  it("rejects projected context that exceeds the generation window before inference", function()
    local model = fake_model.new({})
    model.context_window = 2000
    local run = compaction.run({
      model = model,
      preparation = {
        kind = "summary",
        split_turn = false,
        messages = { { role = "user", content = "short history" } },
        turn_prefix = {},
        first_kept_entry_id = "keep",
        tokens_before = 100,
        settings = compaction.settings({ reserve_tokens = 64 }),
      },
      prepare_request = function(request)
        table.insert(request.messages, 1, { role = "developer", content = string.rep("context ", 4000) })
        return { messages = request.messages, system_prompt = request.system_prompt }
      end,
    })
    assert(vim.wait(1000, function()
      return run:is_done()
    end, 5))
    local result = run:result()
    assert(result)
    assert.is_false(result.ok)
    assert.matches("summary request exceeds the Model window", assert(result.error).message)
    assert.are.equal(0, #model.requests)
  end)
end)
