local it = require("tests.helpers.async_test")
local assert = require("luassert")
local plan_compaction = require("tests.helpers.compaction")
local Session = require("neoagent.session")
local compaction = require("neoagent.compaction")
local fake_model = require("tests.helpers.fake_model")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function finish(run)
  assert(vim.wait(1000, function()
    return run:is_done()
  end))
  return (assert(run:result()))
end

describe("neoagent.compaction_planning", function()
  it("retains the first fitting suffix with a non-monotonic Model estimate", function()
    for _, component in ipairs({ compaction.local_component, require("neoagent.compaction.prefix").component }) do
      local session = assert(Session.new())
      for index = 1, 8 do
        assert(session:append(index % 2 == 1
          and { role = "user", content = string.rep("u", 400) }
          or { role = "assistant", content = { { type = "text", text = string.rep("a", 400) } } }))
      end
      local before = session:entries()
      local measured = {}
      local model = fake_model.new()
      model.context_window = 2000
      function model:estimate_request(options)
        local count = #options.messages
        measured[#measured + 1] = count
        -- A smaller request can cost more after arbitrary Model shaping.
        return count == 6 and 1700 or count <= 4 and 100 or 3000
      end
      local planned = plan_compaction(component, { model = model, path = assert(session:path()),
        messages = assert(session:context_messages()), configured = { reserve_tokens = 100, keep_recent_tokens = 600 } })
      local preparation = assert(planned.preparation)
      assert.are.equal(assert(before[4]).id, preparation.first_kept_entry_id)
      assert.are.same({ 8, 7, 6 }, measured)
      assert.are.same(before, session:entries())
      assert.are.equal(0, #model.requests)
    end
  end)

  it("preserves turn boundaries and propagates local checkpoint projection errors", function()
    local tree = require("neoagent.session_tree")
    local session = assert(Session.new())
    assert(session:append({ role = "user", content = "Earlier request" }))
    assert(session:append(fake_model.assistant({ { type = "text", text = "Answer" } }).message))
    assert(session:append({ role = "user", content = "Continue" }))
    local path = assert(session:path())
    local selected = assert(plan_compaction(compaction.local_component, { model = fake_model.new(), path = path,
      messages = assert(session:context_messages()), configured = { keep_recent_tokens = 3 }, force = true }).preparation)
    assert.are.equal("summary", selected.kind)
    ---@cast selected Neoagent.CompactionPreparation
    assert.is_true(selected.split_turn)
    assert.are.equal("Earlier request", assert(selected.turn_prefix[1]).content)
    assert.are.equal(assert(path[2]).id, selected.first_kept_entry_id)
    local project = tree.compaction_projector
    local failure = { kind = "session", message = "Projection unavailable" }
    tree.compaction_projector = function() return function() return nil, failure end end
    local ok, result = pcall(plan_compaction, compaction.local_component, { model = fake_model.new(), path = path,
      messages = assert(session:context_messages()), configured = { keep_recent_tokens = 1 }, force = true })
    tree.compaction_projector = project
    assert(ok, result)
    assert.is_nil(result.preparation)
    assert.are.equal(failure, result.error)
  end)

  it("replaces older checkpoints when retaining a suffix across them", function()
    for _, component in ipairs({ compaction.local_component, require("neoagent.compaction.prefix").component }) do
      local session = assert(Session.new())
      assert(session:append({ role = "user", content = "Original history" }))
      local _, _, user = session:append({ role = "user", content = string.rep("u", 400) })
      local _, _, answer = session:append({ role = "assistant",
        content = { { type = "text", text = string.rep("a", 800) } } })
      assert(session:append_compaction({ summary = "Earlier checkpoint", tokens_before = 1000,
        first_kept_entry_id = assert(user).id }))
      assert(session:append({ role = "user", content = string.rep("b", 400) }))
      local before = session:entries()
      local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Updated checkpoint" } }) } })
      model.context_window = 3584
      function model:estimate_request(options) return 1000 * #options.messages end
      local evaluation = plan_compaction(component, { model = model, path = assert(session:path()),
        messages = assert(session:context_messages()), configured = { reserve_tokens = 100, keep_recent_tokens = 250 }, force = true })
      local preparation = assert(evaluation.preparation)
      assert.are.equal(assert(answer).id, preparation.first_kept_entry_id)
      local generated = finish(component.run({ model = model, preparation = preparation }))
      assert(generated.ok)
      ---@cast generated Neoagent.CompactionSuccess
      local checkpoint = require("neoagent.compaction.checkpoint")
      local accepted = assert(checkpoint.accept(generated, { model = model, settings = preparation.settings,
        project = function(payload) return session:preview_compaction(payload) end }))
      assert.are.equal(3000, accepted.estimated_tokens_after)
      local payload = checkpoint.payload(accepted)
      local preview = assert(session:preview_compaction(payload))
      assert.are.equal(3, #preview)
      assert.are.equal(string.rep("a", 800), require("neoagent.util").text_content(assert(preview[2]).content))
      assert.are.equal(string.rep("b", 400), assert(preview[3]).content)
      assert.are.same(before, session:entries())
      assert(session:append_compaction(payload))
      local published = assert(session:context_messages())
      assert.are.same(assert(preview[1]).content, assert(published[1]).content)
      assert.are.same(vim.list_slice(preview, 2), vim.list_slice(published, 2))
      assert.are.equal(#before + 1, #session:entries())
    end
  end)

  it("recompacts only active local context with a smaller output allowance", function()
    for _, component in ipairs({ compaction.local_component, require("neoagent.compaction.prefix").component }) do
      for _, retain in ipairs({ false, true }) do
        local session = assert(Session.new())
        assert(session:append({ role = "user", content = "Consumed original history" }))
        local _, _, recent = session:append({ role = "user", content = "Retained request" })
        assert(session:append_compaction({ summary = string.rep("Previous summary ", 50), tokens_before = 2000,
          first_kept_entry_id = retain and assert(recent).id or nil }))
        local before = session:entries()
        local messages = assert(session:context_messages())
        local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Short checkpoint" } }) } })
        model.context_window = 32768
        local evaluation = plan_compaction(component, { model = model, path = assert(session:path()), messages = messages,
          configured = {}, force = true })
        assert.is_nil(evaluation.error)
        local preparation = assert(evaluation.preparation)
        assert.is_nil(preparation.first_kept_entry_id)
        local generated = finish(component.run({ model = model, preparation = preparation }))
        assert.is_true(generated.ok)
        ---@cast generated Neoagent.CompactionSuccess
        local request = assert(model.requests[1])
        assert.is_true(assert(request.max_output_tokens)
          <= math.floor(require("neoagent.api.request_estimate").messages(messages) / 2))
        local text = {}
        for _, message in ipairs(request.messages) do
          assert(message.role ~= "nativeCompaction")
          text[#text + 1] = require("neoagent.util").text_content(message.content)
        end
        local input = table.concat(text, "\n")
        assert.matches("Previous summary", input, 1, true)
        assert.is_nil((input:find("Consumed original history", 1, true)))
        assert.are.equal(retain, input:find("Retained request", 1, true) ~= nil)
        assert.are.same(before, session:entries())
        local accepted = assert(require("neoagent.compaction.checkpoint").accept(generated, {
          model = model, settings = preparation.settings,
          project = function(payload) return session:preview_compaction(payload) end,
        }))
        assert(session:append_compaction(require("neoagent.compaction.checkpoint").payload(accepted)))
        assert.are.equal(#before + 1, #session:entries())
        assert.are.equal(1, #assert(session:context_messages()))
      end
    end
  end)

  it("retains a smaller fitting suffix instead of consuming the whole history", function()
    local session = assert(Session.new())
    for _ = 1, 5 do
      assert(session:append({ role = "user", content = string.rep("u", 1600) }))
      assert(session:append({ role = "assistant", content = { { type = "text", text = string.rep("a", 1600) } } }))
    end
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Checkpoint" } }) } })
    model.context_window = 4096
    local evaluation = plan_compaction(compaction.local_component, {
      model = model, path = assert(session:path()), messages = assert(session:context_messages()),
      system_prompt = string.rep("s", 7800), configured = { reserve_tokens = 1024, keep_recent_tokens = 1200 },
    })
    local preparation = assert(evaluation.preparation)
    assert.is_not_nil(preparation.first_kept_entry_id)
    local generated = finish(compaction.run({ model = model, preparation = preparation }))
    assert(generated.ok)
    assert(session:append_compaction({ summary = generated.summary, tokens_before = assert(generated.tokens_before),
      first_kept_entry_id = generated.first_kept_entry_id }))
    assert.are.equal(3, #assert(session:context_messages()))
  end)

  it("budgets checkpoint candidates using the Model tokenizer", function()
    local session = assert(Session.new())
    for _ = 1, 4 do
      assert(session:append({ role = "user", content = string.rep("data", 200) }))
      assert(session:append(fake_model.assistant({ { type = "text", text = string.rep("answer", 100) } }).message))
    end
    local model = fake_model.new()
    model.context_window = 4096
    model.estimate_request = function(_, options)
      return require("neoagent.api.request_estimate").messages(options.messages) * 5
    end
    local evaluation = plan_compaction(compaction.local_component, {
      model = model,
      path = assert(session:path()),
      messages = assert(session:context_messages()),
      configured = { keep_recent_tokens = 100 },
    })
    assert.is_true(evaluation.needed)
    assert.is_nil(evaluation.error)
    assert.is_not_nil(evaluation.preparation)
  end)

  it("uses the Model estimate when no provider usage has been observed", function()
    local session = assert(Session.new())
    assert(session:append({ role = "user", content = string.rep("data", 1000) }))
    local model = fake_model.new()
    model.context_window = 1000
    model.estimate_request = function()
      return 500
    end
    local evaluation = plan_compaction(compaction.local_component, {
      model = model,
      messages = assert(session:context_messages()),
      path = assert(session:path()),
      configured = {},
    })
    assert.is_false(evaluation.needed)
    assert.are.equal(500, evaluation.tokens)
  end)
  it("includes shaped instructions and inserted messages in the request gate budget", function()
    local model = require("neoagent.api.openai_responses").new({
      provider = "test",
      model = "test",
      base_url = "https://example.test",
      context_window = 1000,
      request_opts = function(context)
        local messages = context.messages
        table.insert(messages, 1, { role = "user", content = string.rep("context ", 200) })
        return { body = { instructions = string.rep("instruction ", 200) }, messages = messages }
      end,
    })
    local session = assert(Session.new())
    assert(session:append({ role = "user", content = "Continue" }))
    local evaluation = plan_compaction(compaction.local_component, {
      model = model,
      path = assert(session:path()),
      messages = assert(session:context_messages()),
      configured = {},
    })
    assert.is_true(evaluation.needed)
    assert.matches("leave no room", assert(evaluation.error).message)
  end)

end)
