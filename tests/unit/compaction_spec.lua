local assert = require("luassert")
local compaction = require("neoagent.compaction")
local fake_model = require("tests.helpers.fake_model")

---@param id string
---@param parent string?
---@param message Neoagent.Message
---@return Neoagent.MessageEntry
local function entry(id, parent, message)
  return {
    type = "message",
    id = id,
    parent_id = parent or vim.NIL,
    created_at = 1767225600000,
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
    assert.are.equal(1200, compaction.estimate_tokens({ role = "user", content = { { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" } } }))
    assert.are.equal(2, compaction.estimate_tokens({
      role = "assistant", content = { { type = "thinking", thinking = "12345678" } },
    }))
    assert.are.equal(2, compaction.estimate_tokens({
      role = "compactionSummary", summary = "12345678", tokens_before = 0, created_at = 1,
    }))
    assert.are.equal(0, compaction.estimate_tokens({ role = "unknown" } --[[@as Neoagent.ProjectionMessage]]))
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
    assert.is_nil((compaction.prepare({}, compaction.settings({ keep_recent_tokens = 20 }))))
    assert.are.same({ first_kept_index = 1, split_turn = false },
      compaction.find_cut_point({ { type = "leaf", id = "leaf", created_at = 1767225600000 } }, 1, 1, 1))
    local compacted = {
      type = "compaction", id = "c", parent_id = vim.NIL, created_at = 1767225600000,
      summary = "done", first_kept_entry_id = "u", tokens_before = 10,
    }
    assert.is_nil((compaction.prepare({ compacted }, compaction.settings({ keep_recent_tokens = 20 }))))

    ---@type Neoagent.JournalEntry[]
    local path = { entry("u", nil, { role = "user", content = "only recent context" }) }
    local prepared, err = compaction.prepare(path, compaction.settings({ keep_recent_tokens = 100 }))
    assert.is_nil(prepared)
    assert.matches("Nothing can be compacted", assert(err).message)

    path = {
      compacted,
      entry("u2", "c", { role = "user", content = string.rep("x", 80) }),
      entry("a2", "u2", { role = "assistant", content = { { type = "text", text = "recent" } } }),
    }
    local repeated = assert(compaction.prepare(path, compaction.settings({ keep_recent_tokens = 1 })))
    assert.are.equal("a2", repeated.first_kept_entry_id)
  end)

  it("retains non-message records adjacent to a selected cut point", function()
    ---@type Neoagent.JournalEntry[]
    local path = {
      entry("u", nil, { role = "user", content = "request" }),
      { type = "leaf", id = "leaf", created_at = 1767225600000 },
      { type = "leaf", id = "leaf", created_at = 1767225600000 },
      entry("a", "u", {
        role = "assistant",
        content = { { type = "text", text = "response" } },
      }),
    }

    assert.are.same({
      first_kept_index = 2,
      turn_start_index = 1,
      split_turn = true,
    }, compaction.find_cut_point(path, 1, #path, 1))
  end)

  it("keeps request state attached to the message selected for retention", function()
    local retained = entry("u2", "a1", {
      role = "user", content = string.rep("x", 40),
    })
    retained.request = {
      model = { provider = "fake", model = "test" },
      thinking_level = "high",
    }
    ---@type Neoagent.JournalEntry[]
    local path = {
      entry("u1", nil, { role = "user", content = "old request" }),
      entry("a1", "u1", {
        role = "assistant", content = { { type = "text", text = "old response" } },
      }),
      retained,
      entry("a2", "u2", {
        role = "assistant", content = { { type = "text", text = "done" } },
      }),
    }
    assert.are.same({
      first_kept_index = 3,
      split_turn = false,
    }, compaction.find_cut_point(path, 1, #path, 10))
    assert.are.same(retained.request, assert(path[3]).request)
  end)

  it("estimates trailing text and images after live provider usage", function()
    local context = require("neoagent.agent.context")
    local messages = {
      { role = "assistant", content = { { type = "text", text = "answer" } } },
      { role = "user", content = "follow-up" },
      { role = "toolResult", content = { {
        type = "image", mime_type = "image/png", file_id = string.rep("a", 64), bytes = 1800000,
      } } },
    }
    assert.are.equal(50 + 3 + 1200,
      context.tokens((assert(require("neoagent.session").new())), messages, { tokens = 50, message_count = 1 }))
  end)

  it("uses historical usage only when it belongs to the current compacted context", function()
    local context = require("neoagent.agent.context")
    local messages = {
      { role = "user", content = "12345678" },
      { role = "assistant", content = {}, usage = { totalTokens = 40 }, stopReason = "stop" },
    }
    local unavailable = {
      path = function() return nil, { kind = "session", message = "unavailable" } end,
    }
    assert.are.equal(2,
      context.tokens(unavailable --[[@as Neoagent.Session]], messages))

    local current = {
      path = function()
        return {
          { type = "compaction", id = "c", parent_id = vim.NIL,
            created_at = 1, summary = "old", first_kept_entry_id = "u",
            tokens_before = 30 },
          entry("a", "c", messages[2]),
        }
      end,
    }
    assert.are.equal(40,
      context.tokens(current --[[@as Neoagent.Session]], messages))
  end)

  it("selects turn boundaries and carries previous summaries forward", function()
    ---@type Neoagent.JournalEntry[]
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
      type = "compaction", id = "compact", parent_id = "a2", created_at = 1767225601000,
      summary = "Earlier work", first_kept_entry_id = "u2", tokens_before = 42,
    }
    path[#path + 1] = entry("u3", "compact", { role = "user", content = string.rep("c", 40) })
    path[#path + 1] = entry("a3", "u3", {
      role = "assistant", content = { { type = "text", text = string.rep("d", 40) } },
    })
    local repeated = assert(compaction.prepare(path, { auto = true, reserve_tokens = 10, keep_recent_tokens = 15 }))
    assert.are.equal("Earlier work", repeated.previous_summary)
    assert.are.equal("u3", repeated.first_kept_entry_id)
    assert.are.equal("next", assert(repeated.messages[1]).content)
  end)

  it("splits oversized turns without separating a tool result from its call", function()
    ---@type Neoagent.JournalEntry[]
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

  it("retains a trailing tool result with its call when it exceeds the token budget", function()
    ---@type Neoagent.JournalEntry[]
    local path = {
      entry("u1", nil, { role = "user", content = "Earlier request" }),
      entry("a1", "u1", { role = "assistant", content = { { type = "text", text = "Earlier work" } } }),
      entry("u2", "a1", { role = "user", content = "Current request" }),
      entry("a2", "u2", { role = "assistant", content = { {
        type = "toolCall", id = "call", name = "read_file", arguments = { path = "large" },
      } } }),
      entry("tool", "a2", {
        role = "toolResult", toolCallId = "call", toolName = "read_file",
        content = { { type = "text", text = string.rep("output ", 100) } },
      }),
    }
    local prepared, err = compaction.prepare(path, compaction.settings({ keep_recent_tokens = 1 }))
    assert.is_nil(err)
    assert.are.equal("a2", assert(prepared).first_kept_entry_id)
    assert.are.equal(2, #assert(prepared).messages)
    assert.are.same({ assert(path[3]).message }, assert(prepared).turn_prefix)
  end)

  it("generates cancellable structured summaries through an ordinary Model", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "  ## Goal\nFinish it  " } }),
    } })
    ---@type Neoagent.CompactionEvent[]
    local events = {}
    local run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep",
        messages = { { role = "user", content = "Please finish" } },
        turn_prefix = {}, split_turn = false, tokens_before = 100,
        settings = compaction.settings({ reserve_tokens = 20 }),
      },
      model = model,
      instructions = "Preserve tests",
      on_event = function(event) events[#events + 1] = event end,
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal("## Goal\nFinish it", assert(run:result()).summary)
    assert.are.equal("keep", assert(run:result()).first_kept_entry_id)
    assert.matches("%[User%]: Please finish", require("neoagent.util").text_content(assert(assert(model.requests[1]).messages[1]).content))
    assert.matches("Additional focus: Preserve tests", require("neoagent.util").text_content(assert(assert(model.requests[1]).messages[1]).content))
    assert.matches("context summarization assistant", (assert(assert(model.requests[1]).system_prompt)))
    assert.are.same({}, assert(model.requests[1]).tools)
    assert.are.same({}, events)
  end)

  it("forwards summary progress and returns model failures", function()
    local model = fake_model.new({ {
      events = {
        { type = "text_delta", text = "partial" },
        { type = "provider_status", text = "quota" },
        { type = "inference_stats", generation_tokens_per_second = 40 },
      },
      result = { ok = false, error = { kind = "http", message = "unavailable" } },
    } })
    ---@type Neoagent.CompactionEvent[]
    local events = {}
    local run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep", messages = { { role = "user", content = "old" } },
        turn_prefix = {}, split_turn = false, tokens_before = 50,
        settings = compaction.settings(),
      },
      model = model,
      on_event = function(event) events[#events + 1] = event end,
    })
    assert(vim.wait(1000, function() return run:is_done() and #events == 3 end))
    assert.is_false(assert(run:result()).ok)
    assert.are.equal("unavailable", assert(assert(run:result()).error).message)
    assert.are.same({ "compaction_delta", "provider_status", "inference_stats" },
      vim.tbl_map(function(event) return event.type end, events))

    model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "  " } }) } })
    run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep", messages = { { role = "user", content = "old" } },
        turn_prefix = {}, split_turn = false, tokens_before = 50,
        settings = compaction.settings(),
      },
      model = model,
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(assert(run:result()).ok)
    assert.matches("no text", assert(assert(run:result()).error).message)
  end)

  it("cancels the active summarization request", function()
    local cancelled = false
    local model = fake_model.new()
    function model:stream()
      return require("neoagent.async").run(function()
        return require("neoagent.async").await(function()
          return function() cancelled = true end
        end)
      end)
    end
    local run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep", messages = { { role = "user", content = "old" } },
        turn_prefix = {}, split_turn = false, tokens_before = 50,
        settings = compaction.settings(),
      },
      model = model,
    })
    run:cancel()
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(cancelled)
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
  end)

  it("retains the previous summary when recompacting within one turn", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Earlier requirements" }))
    assert(session:append({ role = "assistant", content = { { type = "text", text = "Earlier work" } } }))
    local _, _, retained = session:append({ role = "user", content = "Current task" })
    assert(session:append({ role = "assistant", content = { { type = "text", text = "Initial work" } } }))
    local previous = "Preserve the production database"
    assert(session:append_compaction({
      summary = previous, first_kept_entry_id = assert(retained).id, tokens_before = 1000,
    }))
    assert(session:append({ role = "assistant", content = {
      { type = "text", text = string.rep("Recent work. ", 40) },
    } }))
    local prepared = assert(compaction.prepare(assert(session:path()), compaction.settings({ keep_recent_tokens = 1 })))
    assert.is_true(prepared.split_turn)
    assert.are.equal(0, #prepared.messages)
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "Current work summary" } }),
    } })
    local run = compaction.run({ preparation = prepared, model = model })
    assert(vim.wait(1000, function() return run:is_done() end))
    local result = assert(run:result())
    assert(result.ok)
    assert.matches(previous, (assert(result.summary)), 1, true)
    assert.are.equal(1, #model.requests)
    assert(session:append_compaction({
      summary = assert(result.summary), first_kept_entry_id = assert(result.first_kept_entry_id),
      tokens_before = assert(result.tokens_before),
    }))
    assert.matches(previous, require("neoagent.util").text_content(assert(assert(session:context_messages())[1]).content), 1, true)
  end)

  it("persists compaction estimates from fractional provider usage", function()
    for _, usage in ipairs({
      { totalTokens = 42.5 },
      { input = 40.25, output = 2.25 },
    }) do
      local session = assert(require("neoagent.session").new())
      assert(session:append({ role = "user", content = "Earlier request" }))
      assert(session:append({ role = "assistant", content = {}, usage = usage }))
      assert(session:append({ role = "user", content = "next" }))
      local preparation = assert(compaction.prepare((assert(session:path())),
        compaction.settings({ keep_recent_tokens = 1 })))
      local model = fake_model.new({ {
        result = fake_model.assistant({ { type = "text", text = "Earlier work" } }),
      } })
      local run = compaction.run({ preparation = preparation, model = model })
      assert(vim.wait(1000, function() return run:is_done() end))
      local result = assert(run:result())
      assert(result.ok)
      local persisted, err = session:append_compaction({
        summary = result.summary, first_kept_entry_id = result.first_kept_entry_id,
        tokens_before = result.tokens_before,
      })
      assert(persisted, vim.inspect(err))
      assert.are.equal(44, result.tokens_before)
    end
  end)

  it("combines history and turn-prefix summaries", function()
    local history = fake_model.assistant({ { type = "text", text = "history" } })
    assert(history.message.usage).cacheWrite = 2
    assert(assert(history.message.usage).cost).total = 1.5
    local prefix = fake_model.assistant({ { type = "text", text = "prefix" } })
    assert(prefix.message.usage).cacheWrite = 3
    assert(assert(prefix.message.usage).cost).total = 2.5
    local model = fake_model.new({ { result = history }, { result = prefix } })
    local run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep",
        messages = { { role = "user", content = "old" } },
        turn_prefix = { { role = "user", content = "large turn" } },
        split_turn = true,
        tokens_before = 100,
        previous_summary = "previous",
        settings = compaction.settings({ reserve_tokens = 20 }),
      },
      model = model,
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.matches("history.-Turn Context %(split turn%):.-prefix", (assert(assert(run:result()).summary)))
    assert.are.equal(5, assert(assert(run:result()).usage).cacheWrite)
    assert.are.equal(4, assert(assert(assert(run:result()).usage).cost).total)
    local normalized, err = require("neoagent.semantic_message").normalize({
      role = "assistant", content = {}, usage = assert(run:result()).usage,
    })
    assert.is_nil(err)
    assert.are.same(assert(run:result()).usage, assert(normalized).usage)
    assert.matches("<previous%-summary>\nprevious", require("neoagent.util").text_content(assert(assert(model.requests[1]).messages[1]).content))
    assert.matches("PREFIX of a turn", require("neoagent.util").text_content(assert(assert(model.requests[2]).messages[1]).content))
  end)

  it("stops split-turn compaction when either dependent summary fails", function()
    local failure = { ok = false, error = { kind = "model", message = "summary failed" } }
    local preparation = {
      first_kept_entry_id = "keep",
      messages = { { role = "user", content = "history" } },
      turn_prefix = { { role = "user", content = "prefix" } },
      split_turn = true,
      tokens_before = 100,
      settings = compaction.settings(),
    }
    for _, responses in ipairs({
      { { result = failure } },
      { { result = fake_model.assistant({ { type = "text", text = "history" } }) },
        { result = failure } },
    }) do
      local model = fake_model.new(responses)
      local run = compaction.run({ preparation = preparation, model = model })
      assert(vim.wait(1000, function() return run:is_done() end))
      assert.is_false(assert(run:result()).ok)
      assert.are.equal("summary failed", assert(assert(run:result()).error).message)
    end
  end)

  it("retains history usage when a split-turn prefix reports none", function()
    local history = fake_model.assistant({ { type = "text", text = "history" } })
    local prefix = fake_model.assistant({ { type = "text", text = "prefix" } })
    prefix.message.usage = nil
    local run = compaction.run({
      preparation = {
        first_kept_entry_id = "keep",
        messages = { { role = "user", content = "history" } },
        turn_prefix = { { role = "user", content = "prefix" } },
        split_turn = true,
        tokens_before = 100,
        settings = compaction.settings(),
      },
      model = fake_model.new({ { result = history }, { result = prefix } }),
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.same(history.message.usage, assert(run:result()).usage)
  end)
end)
