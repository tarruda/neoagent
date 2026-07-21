local compaction = require("neoagent.compaction")
local fake_model = require("tests.helpers.fake_model")

local function entry(id, parent, message)
  return {
    type = "message",
    id = id,
    parentId = parent or vim.NIL,
    timestamp = "2026-01-01T00:00:00.000Z",
    message = message,
  }
end

describe("neoagent.compaction", function()
  it("estimates provider context usage and applies safe small-window defaults", function()
    local messages = {
      { role = "user", content = string.rep("a", 40) },
      { role = "assistant", content = {}, usage = { totalTokens = 100 }, stopReason = "stop" },
      { role = "user", content = string.rep("b", 20) },
    }
    assert.are.same({ tokens = 105, usage_tokens = 100, trailing_tokens = 5, last_usage_index = 2 },
      compaction.estimate_context(messages))
    messages[2].stopReason = "error"
    assert.are.equal(15, compaction.estimate_context(messages).tokens)
    local settings = compaction.settings(nil, 32000)
    assert.are.same({ auto = true, reserve_tokens = 8000, keep_recent_tokens = 12000 }, settings)
    assert.is_true(compaction.should_compact(24001, 32000, settings))
    assert.is_false(compaction.should_compact(24000, 32000, settings))
    assert.are.equal(1200, compaction.estimate_tokens({ role = "user", content = { { type = "image" } } }))
    assert.are.equal(2, compaction.estimate_tokens({
      role = "assistant", content = { { type = "thinking", thinking = "12345678" } },
    }))
    assert.are.equal(2, compaction.estimate_tokens({ role = "bashExecution", command = "abcd", output = "efgh" }))
    assert.are.equal(2, compaction.estimate_tokens({ role = "branchSummary", summary = "12345678" }))
    assert.are.equal(0, compaction.estimate_tokens({ role = "unknown" }))
  end)

  it("serializes assistant work and bounded tool output for a summary", function()
    local serialized = compaction.serialize({
      { role = "assistant", content = {
        { type = "thinking", thinking = "inspect first" },
        { type = "text", text = "I found it" },
        { type = "toolCall", name = "read_file", arguments = { path = "README.md", line = 3 } },
      } },
      { role = "toolResult", content = { { type = "text", text = string.rep("x", 2100) } } },
    })
    assert.matches("%[Assistant thinking%]: inspect first", serialized)
    assert.matches("%[Assistant%]: I found it", serialized)
    assert.matches('read_file%(line=3, path="README.md"%)', serialized)
    assert.matches("100 more characters truncated", serialized)
    assert.is_true(vim.fn.strchars(serialized) < 2300)
  end)

  it("reports session histories that have no compactable prefix", function()
    assert.is_nil(compaction.prepare({}, { keep_recent_tokens = 20 }))
    local compacted = {
      type = "compaction", id = "c", parentId = vim.NIL, timestamp = "t",
      summary = "done", firstKeptEntryId = "u", tokensBefore = 10,
    }
    assert.is_nil(compaction.prepare({ compacted }, { keep_recent_tokens = 20 }))

    local path = { entry("u", nil, { role = "user", content = "only recent context" }) }
    local prepared, err = compaction.prepare(path, { keep_recent_tokens = 100 })
    assert.is_nil(prepared)
    assert.matches("Nothing can be compacted", err.message)

    path = {
      compacted,
      entry("u2", "c", { role = "user", content = string.rep("x", 80) }),
      entry("a2", "u2", { role = "assistant", content = { { type = "text", text = "recent" } } }),
    }
    local repeated = assert(compaction.prepare(path, { keep_recent_tokens = 1 }))
    assert.are.equal("a2", repeated.first_kept_entry_id)
  end)

  it("selects turn boundaries and carries previous summaries forward", function()
    local path = {
      entry("u1", nil, { role = "user", content = string.rep("a", 80) }),
      entry("a1", "u1", { role = "assistant", content = { { type = "text", text = string.rep("b", 80) } } }),
      entry("u2", "a1", { role = "user", content = "next" }),
      entry("a2", "u2", { role = "assistant", content = { { type = "text", text = "done" } } }),
    }
    local prepared = assert(compaction.prepare(path, { auto = true, reserve_tokens = 10, keep_recent_tokens = 2 }))
    assert.are.equal("u2", prepared.first_kept_entry_id)
    assert.is_false(prepared.split_turn)
    assert.are.equal(2, #prepared.messages)

    path[#path + 1] = {
      type = "compaction", id = "compact", parentId = "a2", timestamp = "2026-01-01T00:00:01.000Z",
      summary = "Earlier work", firstKeptEntryId = "u2", tokensBefore = 42,
    }
    path[#path + 1] = entry("u3", "compact", { role = "user", content = string.rep("c", 40) })
    path[#path + 1] = entry("a3", "u3", {
      role = "assistant", content = { { type = "text", text = string.rep("d", 40) } },
    })
    local repeated = assert(compaction.prepare(path, { auto = true, reserve_tokens = 10, keep_recent_tokens = 15 }))
    assert.are.equal("Earlier work", repeated.previous_summary)
    assert.are.equal("u3", repeated.first_kept_entry_id)
    assert.are.equal("next", repeated.messages[1].content)
  end)

  it("splits oversized turns without separating a tool result from its call", function()
    local path = {
      entry("u", nil, { role = "user", content = "do work" }),
      entry("a1", "u", { role = "assistant", content = { {
        type = "toolCall", id = "call", name = "read_file", arguments = { path = "large" },
      } } }),
      entry("tool", "a1", {
        role = "toolResult", toolCallId = "call", toolName = "read_file",
        content = { { type = "text", text = string.rep("x", 100) } },
      }),
      entry("a2", "tool", { role = "assistant", content = { { type = "text", text = string.rep("y", 100) } } }),
    }
    local prepared = assert(compaction.prepare(path, {
      auto = true, reserve_tokens = 10, keep_recent_tokens = 20,
    }))
    assert.is_true(prepared.split_turn)
    assert.are.equal("a2", prepared.first_kept_entry_id)
    assert.are.same({ "user", "assistant", "toolResult" }, vim.tbl_map(function(message)
      return message.role
    end, prepared.turn_prefix))
  end)

  it("generates cancellable structured summaries through an ordinary Model", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "  ## Goal\nFinish it  " } }),
    } })
    local events = {}
    local run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep",
        messages = { { role = "user", content = "Please finish" } },
        turn_prefix = {}, split_turn = false, tokens_before = 100,
        settings = { reserve_tokens = 20 },
      },
      model = model,
      instructions = "Preserve tests",
      on_event = function(event) events[#events + 1] = event end,
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(run:result().ok)
    assert.are.equal("## Goal\nFinish it", run:result().summary)
    assert.are.equal("keep", run:result().first_kept_entry_id)
    assert.matches("%[User%]: Please finish", model.requests[1].messages[1].content[1].text)
    assert.matches("Additional focus: Preserve tests", model.requests[1].messages[1].content[1].text)
    assert.matches("context summarization assistant", model.requests[1].system_prompt)
    assert.are.same({}, model.requests[1].tools)
    assert.are.same({}, events)
  end)

  it("forwards summary progress and returns model failures", function()
    local model = fake_model.new({ {
      events = {
        { type = "text_delta", text = "partial" },
        { type = "provider_status", text = "quota" },
      },
      result = { ok = false, error = { kind = "http", message = "unavailable" } },
    } })
    local events = {}
    local run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep", messages = { { role = "user", content = "old" } },
        turn_prefix = {}, split_turn = false, tokens_before = 50,
      },
      model = model,
      on_event = function(event) events[#events + 1] = event end,
    })
    assert(vim.wait(1000, function() return run:is_done() and #events == 2 end))
    assert.is_false(run:result().ok)
    assert.are.equal("unavailable", run:result().error.message)
    assert.are.same({ "compaction_delta", "provider_status" }, vim.tbl_map(function(event) return event.type end, events))

    model = fake_model.new({ { result = { ok = true, text = "  " } } })
    run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep", messages = { { role = "user", content = "old" } },
        turn_prefix = {}, split_turn = false, tokens_before = 50,
      },
      model = model,
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(run:result().ok)
    assert.matches("no text", run:result().error.message)
  end)

  it("cancels the active summarization request", function()
    local cancelled = false
    local model = {
      stream = function()
        return require("neoagent.async").run(function()
          require("neoagent.async").await(function()
            return function() cancelled = true end
          end)
        end)
      end,
    }
    local run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep", messages = { { role = "user", content = "old" } },
        turn_prefix = {}, split_turn = false, tokens_before = 50,
      },
      model = model,
    })
    run:cancel()
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(cancelled)
    assert.are.equal("cancelled", run:result().error.kind)
  end)

  it("combines history and turn-prefix summaries", function()
    local history = fake_model.assistant({ { type = "text", text = "history" } })
    history.message.usage.cacheWrite1h = 2
    history.message.usage.cost.total = 1.5
    local prefix = fake_model.assistant({ { type = "text", text = "prefix" } })
    prefix.message.usage.cacheWrite1h = 3
    prefix.message.usage.cost.total = 2.5
    local model = fake_model.new({ { result = history }, { result = prefix } })
    local run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep",
        messages = { { role = "user", content = "old" } },
        turn_prefix = { { role = "user", content = "large turn" } },
        split_turn = true,
        tokens_before = 100,
        previous_summary = "previous",
        settings = { reserve_tokens = 20 },
      },
      model = model,
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.matches("history.-Turn Context %(split turn%):.-prefix", run:result().summary)
    assert.are.equal(5, run:result().usage.cacheWrite1h)
    assert.are.equal(4, run:result().usage.cost.total)
    assert.matches("<previous%-summary>\nprevious", model.requests[1].messages[1].content[1].text)
    assert.matches("PREFIX of a turn", model.requests[2].messages[1].content[1].text)
  end)
end)
