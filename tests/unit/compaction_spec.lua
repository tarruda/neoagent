local plan_compaction = require("tests.helpers.compaction")
local it = require("tests.helpers.async_test")
local assert = require("luassert")
local compaction = require("neoagent.compaction")
local fake_model = require("tests.helpers.fake_model")

---@async
---@param path Neoagent.JournalEntry[]
---@param settings Neoagent.CompactionSettings
---@return Neoagent.CompactionPreparation?, Neoagent.Error?
local function prepare(path, settings)
  local evaluation = plan_compaction(compaction.local_component, {
    path = path, messages = require("neoagent.session_tree").context_messages(path),
    configured = settings, model = fake_model.new(), force = true,
  })
  return evaluation.preparation --[[@as Neoagent.CompactionPreparation?]], evaluation.error
end

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
    assert.are.equal(300, compaction.estimate_tokens({ role = "nativeCompaction", api = "openai-codex-responses",
      provider = "codex", model = "gpt-test", encrypted_content = string.rep("A", 1600) }))
    assert.are.equal(0, compaction.estimate_tokens({ role = "compactionCheckpoint", tokens_before = 100, created_at = 1 }))
    assert.are.equal(0, compaction.estimate_tokens({ role = "unknown" } --[[@as Neoagent.ProjectionMessage]]))
  end)

  it("includes semantic request ingredients without counting them twice", function()
    local model = fake_model.new()
    model.context_window = 1000
    ---@type Neoagent.RequestMessage[]
    local messages = { { role = "user", content = "short" } }
    ---@async
    local function evaluate(system_prompt, tools)
      return plan_compaction(compaction.local_component, {
        configured = { reserve_tokens = 100 }, model = model, messages = messages,
        path = {}, system_prompt = system_prompt, tools = tools,
      })
    end
    assert.is_false(evaluate("brief", {}).needed)
    assert.is_true(evaluate(string.rep("x", 3600), {}).needed)
    assert.is_true(evaluate("brief", { {
      name = "inspect", description = string.rep("x", 3600), input_schema = { type = "object" },
    } }).needed)
    messages[#messages + 1] = { role = "assistant", content = {}, usage = { totalTokens = 500 } }
    assert.is_false(evaluate("brief", {}).needed)
    assert.is_true(evaluate(string.rep("x", 3600), {}).needed)
  end)

  it("estimates request ingredients for any Model", function()
    local path = { entry("user", nil, { role = "user", content = "short" }) }
    local model = fake_model.new()
    model.context_window = 1000
    local evaluation = plan_compaction(compaction.local_component, {
      configured = { reserve_tokens = 100 }, model = model,
      messages = { { role = "user", content = "short" } }, path = path,
      system_prompt = string.rep("instruction ", 400), tools = {},
    })
    assert.is_true(evaluation.needed)
    assert.is_nil(evaluation.preparation)
    assert.matches("leave no room", assert(evaluation.error).message)
  end)

  it("budgets the retained history against fixed request overhead", function()
    local session = assert(require("neoagent.session").new())
    local _, _, old = session:append({ role = "user", content = string.rep("a", 8000) })
    assert(session:append({ role = "assistant", content = { { type = "text", text = string.rep("b", 8000) } } }))
    assert(session:append({ role = "user", content = string.rep("c", 4000) }))
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Earlier work" } }) } })
    model.context_window = 32768
    local evaluation = plan_compaction(compaction.local_component, {
      configured = {}, model = model, path = assert(session:path()),
      messages = assert(session:context_messages()), system_prompt = string.rep("x", 80000), tools = {},
    })
    assert.is_true(evaluation.needed)
    assert.is_nil(evaluation.error)
    local preparation = assert(evaluation.preparation) --[[@as Neoagent.CompactionPreparation]]
    assert.are_not.equal(assert(old).id, preparation.first_kept_entry_id)
    assert.are.equal(24576, evaluation.input_limit)
    local run = compaction.run({ model = model, preparation = preparation })
    assert(vim.wait(1000, function() return run:is_done() end))
    local result = assert(run:result())
    assert(result.ok)
    assert(session:append_compaction({ summary = result.summary, tokens_before = result.tokens_before,
      first_kept_entry_id = result.first_kept_entry_id }))
    assert.is_true(require("neoagent.api.request_estimate").request(model, { messages = assert(session:context_messages()),
      system_prompt = string.rep("x", 80000), tools = {} }) < evaluation.input_limit)
  end)

  it("budgets every part of an assembled split-turn checkpoint", function()
    for _, previous_summary in ipairs({ false, string.rep("s", 400) }) do
      local session = assert(require("neoagent.session").new())
      assert(session:append({ role = "user", content = "Earlier request" }))
      assert(session:append({ role = "assistant", content = { { type = "text", text = "Earlier answer" } } }))
      local _, _, current = session:append({ role = "user", content = "Current request" })
      if previous_summary then
        assert(session:append_compaction({
          summary = previous_summary,
          first_kept_entry_id = assert(current).id,
          tokens_before = 1000,
        }))
      end
      assert(session:append({
        role = "assistant",
        content = { { type = "text", text = string.rep("x", 3360) } },
      }))
      local model = fake_model.new()
      model.context_window = 1200
      local evaluation = plan_compaction(compaction.local_component, {
        configured = { reserve_tokens = 200, keep_recent_tokens = 500 },
        model = model,
        path = assert(session:path()),
        messages = assert(session:context_messages()),
        force = true,
      })
      assert.is_nil(evaluation.error)
      local prepared = assert(evaluation.preparation)
      assert.is_nil(prepared.first_kept_entry_id)
      assert.is_false(prepared.split_turn)
    end
  end)

  it("reports when fixed instructions alone leave no room for compacted context", function()
    local model = fake_model.new()
    model.context_window = 1000
    local path = { entry("user", nil, { role = "user", content = "Continue" }) }
    local evaluation = plan_compaction(compaction.local_component, {
      configured = {}, model = model, path = path, messages = require("neoagent.session_tree").context_messages(path),
      system_prompt = string.rep("instructions ", 400), tools = {},
    })
    assert.is_true(evaluation.needed)
    assert.is_nil(evaluation.preparation)
    assert.matches("leave no room", assert(evaluation.error).message)
  end)

  it("respects the Model output ceiling when generating local summaries", function()
    for _, limit in ipairs({ 4096, 8 }) do
      local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Summary" } }) } })
      model.context_window = 128000
      model.max_output_tokens = limit
      local run = compaction.run({ model = model, preparation = {
        max_output_tokens = 8192,
        first_kept_entry_id = "recent", messages = { { role = "user", content = "Earlier work" } },
        kind = "summary", turn_prefix = {}, split_turn = false, tokens_before = 100,
        settings = compaction.settings(nil, model.context_window),
      } })
      assert(vim.wait(1000, function() return run:is_done() end))
      assert.is_true(assert(run:result()).ok)
      assert.are.equal(limit, assert(model.requests[1]).max_output_tokens)
    end
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

  it("preserves user text and image blocks in a local summary request", function()
    local image = { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" }
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Visual summary" } }) } })
    model.input = { "text", "image" }
    local run = compaction.run({ model = model, preparation = { kind = "summary",
      messages = { { role = "user", content = { { type = "text", text = "Inspect this" }, image } } },
      turn_prefix = {}, split_turn = false, tokens_before = 1100, settings = compaction.settings({}),
    } })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).ok)
    local content = assert(assert(assert(model.requests[1]).messages[1]).content)
    assert(type(content) == "table")
    assert.matches("%[User%]: Inspect this", require("neoagent.util").text_content(content))
    assert.are.same({ image }, vim.tbl_filter(function(block) return block.type == "image" end, content))
  end)

  it("passes consumed images to the summarizing Model", function()
    local image = {
      type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png",
    }
    local second = vim.tbl_extend("force", {}, image, { file_id = string.rep("b", 64) })
    ---@type Neoagent.JournalEntry[]
    local path = {
      entry("user", nil, { role = "user", content = "Inspect this image" }),
      entry("call", "user", { role = "assistant", content = { {
        type = "toolCall", id = "inspect-1", name = "inspect", arguments = {},
      } }, stopReason = "toolUse" }),
      entry("result", "call", { role = "toolResult", toolCallId = "inspect-1", toolName = "inspect",
        content = { { type = "text", text = "Visual evidence" }, image, second } }),
    }
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Visual summary" } }) } })
    model.context_window = 3000
    model.input = { "text", "image" }
    local evaluation = plan_compaction(compaction.local_component, {
      configured = { reserve_tokens = 500, keep_recent_tokens = 1 }, model = model,
      path = path, messages = require("neoagent.session_tree").context_messages(path), force = true,
    })
    local preparation = assert(evaluation.preparation)
    assert.is_nil(preparation.first_kept_entry_id)
    local run = compaction.run({ model = model, preparation = preparation })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).ok)
    local request = assert(model.requests[1])
    local content = assert(assert(request.messages[1]).content)
    assert(type(content) == "table")
    local images = vim.tbl_filter(function(block)
      return block.type == "image"
    end, content)
    assert.are.same({ image, second }, images)
  end)

  it("rejects oversized summary input before calling the Model", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Summarize the work" }))
    assert(session:append({ role = "assistant", content = { {
      type = "text", text = string.rep("unbounded answer ", 2000),
    } } }))
    local model = fake_model.new()
    model.context_window = 1000
    local evaluation = plan_compaction(compaction.local_component, {
      configured = { reserve_tokens = 200, keep_recent_tokens = 1 }, model = model,
      path = assert(session:path()), messages = assert(session:context_messages()), force = true,
    })
    local run = compaction.run({ model = model, preparation = assert(evaluation.preparation) })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(assert(run:result()).ok)
    assert.matches("summary request exceeds the Model window", assert(assert(run:result()).error).message)
    assert.are.equal(0, #model.requests)
  end)

  it("reports session histories that have no compactable prefix", function()
    assert.is_nil((prepare({}, compaction.settings({ keep_recent_tokens = 20 }))))
    assert.are.same({ first_kept_index = 1, split_turn = false },
      compaction.find_cut_point({ { type = "leaf", id = "leaf", created_at = 1767225600000 } }, 1, 1, 1))
    local compacted = {
      type = "compaction", id = "c", parent_id = vim.NIL, created_at = 1767225600000,
      summary = "done", first_kept_entry_id = "u", tokens_before = 10,
    }
    ---@type Neoagent.JournalEntry[]
    local path = { entry("u", nil, { role = "user", content = "only recent context" }) }
    local prepared, err = prepare(path, compaction.settings({ keep_recent_tokens = 100 }))
    assert.is_nil(prepared)
    assert.matches("Nothing can be compacted", assert(err).message)

    path = {
      compacted,
      entry("u2", "c", { role = "user", content = string.rep("x", 80) }),
      entry("a2", "u2", { role = "assistant", content = { { type = "text", text = "recent" } } }),
    }
    local repeated = assert(prepare(path, compaction.settings({ keep_recent_tokens = 1 })))
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
    local prepared = assert(prepare(path, { auto = true, reserve_tokens = 10, keep_recent_tokens = 2 }))
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
    local repeated = assert(prepare(path, { auto = true, reserve_tokens = 10, keep_recent_tokens = 15 }))
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
    local prepared = assert(prepare(path, {
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
    local prepared, err = prepare(path, compaction.settings({ keep_recent_tokens = 1 }))
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
        kind = "summary", turn_prefix = {}, split_turn = false, tokens_before = 100,
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
        kind = "summary", turn_prefix = {}, split_turn = false, tokens_before = 50,
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
        kind = "summary", turn_prefix = {}, split_turn = false, tokens_before = 50,
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
        kind = "summary", turn_prefix = {}, split_turn = false, tokens_before = 50,
        settings = compaction.settings(),
      },
      model = model,
    })
    run:cancel()
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(cancelled)
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
  end)

  it("bounds summary output and rejects truncated or Tool-call responses", function()
    local preparation = {
      first_kept_entry_id = "keep",
      messages = { { role = "user", content = "old" } },
      kind = "summary", turn_prefix = {}, split_turn = false, tokens_before = 50,
      settings = compaction.settings(nil, 32000),
    }
    for _, response in ipairs({
      fake_model.assistant({ { type = "text", text = "partial" } }, "length"),
      fake_model.assistant({ { type = "toolCall", id = "call", name = "read", arguments = {} } }, "toolUse"),
      fake_model.assistant({ { type = "text", text = "summary" },
        { type = "toolCall", id = "call", name = "read", arguments = {} } }),
    }) do
      local model = fake_model.new({ { result = response } })
      model.context_window = 32000
      local run = compaction.run({ preparation = preparation, model = model })
      assert(vim.wait(1000, function() return run:is_done() end))
      assert.is_false(assert(run:result()).ok)
      assert.are.equal(2000, assert(model.requests[1]).max_output_tokens)
    end
  end)

  it("retries a retryable summary failure once", function()
    local preparation = {
      first_kept_entry_id = "keep",
      messages = { { role = "user", content = "old" } },
      kind = "summary", turn_prefix = {}, split_turn = false, tokens_before = 50,
      settings = compaction.settings(),
    }
    local failure = { ok = false, error = { kind = "http", message = "busy", retryable = true } }
    local model = fake_model.new({
      { result = failure },
      { result = fake_model.assistant({ { type = "text", text = "summary" } }) },
    })
    local run = compaction.run({ preparation = preparation, model = model })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal(2, #model.requests)

    model = fake_model.new({ { result = failure }, { result = failure } })
    run = compaction.run({ preparation = preparation, model = model })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(assert(run:result()).ok)
    assert.are.equal(2, #model.requests)
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
    local prepared = assert(prepare(assert(session:path()), compaction.settings({ keep_recent_tokens = 1 })))
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

  it("rejects local replacement of an encrypted checkpoint", function()
    local session = assert(require("neoagent.session").new())
    local _, _, earlier = session:append({ role = "user", content = "Earlier constraints" })
    assert(session:append({ role = "assistant", content = { { type = "text", text = "Earlier work" } } }))
    assert(session:append_compaction({
      native = {
        role = "nativeCompaction", api = "openai-codex-responses", provider = "codex", model = "gpt-test",
        encrypted_content = "synthetic-ciphertext",
      },
      retained_users = { { entry_id = assert(earlier).id } },
      tokens_before = 500,
    }))
    assert(session:append({ role = "user", content = "Continue" }))
    local prepared, err = prepare(assert(session:path()), compaction.settings({ keep_recent_tokens = 1 }))
    assert.is_nil(prepared)
    assert.matches("encrypted checkpoint", assert(err).message)
    assert.are.equal("nativeCompaction", assert(assert(session:context_messages())[2]).role)
  end)

  it("ignores aborted usage after a checkpoint when deciding to compact", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Earlier request" }))
    local _, _, retained = session:append({
      role = "assistant", content = { { type = "text", text = "Earlier answer" } },
      stopReason = "stop", usage = { totalTokens = 950 },
    })
    assert(session:append_compaction({
      summary = "Small summary", first_kept_entry_id = assert(retained).id, tokens_before = 950,
    }))
    assert(session:append({
      role = "assistant", content = {}, stopReason = "aborted", usage = { totalTokens = 960 },
    }))
    local model = fake_model.new()
    model.context_window = 1000
    assert.is_false(plan_compaction(compaction.local_component, {
      messages = assert(session:context_messages()), model = model, configured = { reserve_tokens = 200 },
      path = assert(session:path()),
    }).needed)
  end)

  it("trims oversized Tool output only in the native compaction request", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Inspect the file" }))
    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "inspect-1", name = "inspect", arguments = {},
    } }, stopReason = "toolUse" }))
    local large = string.rep("large output ", 600)
    assert(session:append({
      role = "toolResult", toolCallId = "inspect-1", toolName = "inspect",
      content = { { type = "text", text = large } },
    }))
    local model = fake_model.new()
    model.api = "openai-codex-responses"
    model.context_window = 1000
    ---@type Neoagent.RequestMessage[]?
    local sent
    model.compact = function(self, options)
      sent = options.messages
      return require("neoagent.async").run(function()
        return { ok = true, item = {
          role = "nativeCompaction", api = self.api, provider = self.provider, model = self.id,
          encrypted_content = "synthetic-ciphertext",
        } }
      end)
    end
    local codex = require("neoagent.compaction.codex").component
    local prepared = assert(plan_compaction(codex, { path = assert(session:path()), messages = assert(session:context_messages()),
      model = model, configured = { keep_recent_tokens = 10 }, force = true,
      system_prompt = "Inspect safely", tools = {}, }).preparation)
    local run = codex.run({
      preparation = prepared, model = model,
      system_prompt = "Inspect safely", tools = {}, reason = "overflow",
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).ok)
    local sent_tool = assert(sent and sent[3])
    assert.matches("truncated", require("neoagent.util").text_content(sent_tool.content))
    assert.matches("^large output", require("neoagent.util").text_content(sent_tool.content))
    assert.are.equal(large, require("neoagent.util").text_content(assert(assert(session:context_messages())[3]).content))

    model.context_window = 10000
    sent = nil
    prepared = assert(plan_compaction(codex, { path = assert(session:path()), messages = assert(session:context_messages()),
      model = model, configured = { keep_recent_tokens = 10 }, force = true,
      system_prompt = "Inspect safely", tools = {}, }).preparation)
    local overflow = codex.run({
      preparation = prepared, model = model,
      system_prompt = "Inspect safely", tools = {}, reason = "overflow",
    })
    assert(vim.wait(1000, function() return overflow:is_done() end))
    assert.is_true(assert(overflow:result()).ok)
    local retried_tool = sent and sent[3]
    assert.is_not_nil(retried_tool)
    if retried_tool then
      assert.are.equal(large, require("neoagent.util").text_content(retried_tool.content))
    end
  end)

  it("trims Tool output before a later user message in a native recovery request", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Inspect" }))
    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "inspect-1", name = "inspect", arguments = {},
    } } }))
    local output = string.rep("large output ", 600)
    assert(session:append({ role = "toolResult", toolCallId = "inspect-1",
      content = { { type = "text", text = output } } }))
    assert(session:append({ role = "user", content = "Use that evidence" }))
    local model = fake_model.new()
    model.api, model.context_window = "openai-codex-responses", 1000
    ---@type Neoagent.RequestMessage[]?
    local sent
    model.compact = function(self, options)
      sent = options.messages
      return require("neoagent.async").run(function()
        return { ok = true, item = { role = "nativeCompaction", api = self.api,
          provider = self.provider, model = self.id, encrypted_content = "synthetic-ciphertext" } }
      end)
    end
    local component = require("neoagent.compaction.codex").component
    local prepared = assert(plan_compaction(component, { path = assert(session:path()), messages = assert(session:context_messages()),
      model = model, configured = {}, force = true }).preparation)
    local run = component.run({ preparation = prepared, model = model,
      system_prompt = "", tools = {},
      reason = "overflow" })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).ok)
    assert.matches("truncated", require("neoagent.util").text_content(assert(sent and sent[3]).content))
    assert.are.equal("Use that evidence", assert(sent and sent[4]).content)
    assert.are.equal(output, require("neoagent.util").text_content(assert(assert(session:context_messages())[3]).content))
  end)

  it("keeps images and a marked text excerpt in a reduced native request", function()
    local image = { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" }
    local original = { { type = "text", text = string.rep("evidence ", 500) }, image }
    local path = { entry("request", nil, { role = "user", content = original }) }
    local model = fake_model.new()
    model.api = "openai-codex-responses"
    model.input = { "text", "image" }
    model.context_window = 1700
    local component = require("neoagent.compaction.codex").component
    local prepared = assert(plan_compaction(component, {
      path = path, messages = require("neoagent.session_tree").context_messages(path),
      model = model, configured = {}, force = true,
    }).preparation)
    assert.are.equal("native", prepared.kind)
    ---@cast prepared Neoagent.NativeCompactionPreparation
    local reduced = assert(prepared.request_messages[1])
    assert.are.equal("user", reduced.role)
    assert(type(reduced.content) == "table")
    assert.are.same(image, reduced.content[2])
    local reduced_text = require("neoagent.util").text_content(reduced.content)
    assert.matches("^evidence ", reduced_text)
    assert.matches("characters truncated for compaction", reduced_text)
    assert.are.same(original, assert(path[1]).message.content)
  end)

  it("rejects an oversized image-only native request without dropping the image", function()
    local image = { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" }
    local path = { entry("request", nil, { role = "user", content = { image } }) }
    local model = fake_model.new()
    model.api = "openai-codex-responses"
    model.input = { "text", "image" }
    model.context_window = 1000
    local evaluation = plan_compaction(require("neoagent.compaction.codex").component, {
      path = path, messages = require("neoagent.session_tree").context_messages(path),
      model = model, configured = {}, force = true,
    })
    assert.is_nil(evaluation.preparation)
    assert.matches("cannot be reduced below the Model window", assert(evaluation.error).message)
    assert.are.same({ image }, assert(path[1]).message.content)
  end)

  it("rejects a native request when fixed overhead exceeds the Model window", function()
    local session = assert(require("neoagent.session").new())
    local prompt = "x"
    assert(session:append({ role = "user", content = prompt }))
    local model = fake_model.new()
    model.api = "openai-codex-responses"
    model.context_window = 1000
    local calls = 0
    model.compact = function()
      calls = calls + 1
      error("oversized request reached Model")
    end
    local codex = require("neoagent.compaction.codex").component
    local evaluation = plan_compaction(codex, { path = assert(session:path()), messages = assert(session:context_messages()),
      model = model, configured = { keep_recent_tokens = 1 }, force = true,
      system_prompt = string.rep("instruction ", 600), tools = {}, })
    assert.is_nil(evaluation.preparation)
    assert.matches("cannot be reduced below the Model window", assert(evaluation.error).message)
    assert.are.equal(0, calls)
    assert.are.equal(prompt, assert(assert(session:context_messages())[1]).content)
  end)

  it("retains the newest oversized user request before older requests and preserves the journal", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Old" }))
    local text = string.rep("é", 84)
    local _, _, recent = session:append({ role = "user", content = text })
    local model = fake_model.new()
    model.api = "openai-codex-responses"
    model.context_window = 1000
    local component = require("neoagent.compaction.codex").component
    local prepared = assert(plan_compaction(component, {
      path = assert(session:path()), messages = assert(session:context_messages()),
      model = model, configured = { keep_recent_tokens = 20 }, force = true,
    }).preparation) --[[@as Neoagent.NativeCompactionPreparation]]
    assert.are.same({ { entry_id = assert(recent).id, text_chars = 80 } }, prepared.retained_users)
    assert(session:append_compaction({
      tokens_before = prepared.tokens_before, retained_users = prepared.retained_users,
      native = { role = "nativeCompaction", api = model.api, provider = model.provider, model = model.id,
        encrypted_content = "synthetic-checkpoint" },
    }))
    assert.are.equal(string.rep("é", 80), assert(assert(session:context_messages())[1]).content)
    assert.are.equal(text, assert(session:messages()[2]).content)
    local reopened = assert(require("neoagent.session").new({ entries = session:entries() }))
    assert.are.same(assert(session:context_messages()), assert(reopened:context_messages()))
    assert(reopened:append({ role = "assistant", content = { { type = "text", text = "Continuing" } } }))
    local repeated = assert(plan_compaction(component, {
      path = assert(reopened:path()), messages = assert(reopened:context_messages()), model = model,
      configured = { keep_recent_tokens = 100 }, force = true,
    }).preparation) --[[@as Neoagent.NativeCompactionPreparation]]
    assert.are.same(prepared.retained_users, repeated.retained_users)
  end)

  it("consumes an oversized completed Tool exchange into a local checkpoint", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Earlier work" }))
    assert(session:append({ role = "assistant", content = { { type = "text", text = "Earlier answer" } } }))
    assert(session:append({ role = "user", content = "Inspect this" }))
    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "inspect-1", name = "inspect", arguments = {},
    } }, stopReason = "toolUse" }))
    assert(session:append({ role = "toolResult", toolCallId = "inspect-1", toolName = "inspect",
      content = { { type = "text", text = string.rep("evidence ", 2000) } } }))
    local journal = assert(session:path())
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Checkpoint" } }) } })
    model.context_window = 1000
    local evaluation = plan_compaction(compaction.local_component, {
      configured = { reserve_tokens = 200, keep_recent_tokens = 50 }, model = model,
      path = journal, messages = assert(session:context_messages()), force = true,
    })
    local prepared = assert(evaluation.preparation)
    assert.is_nil(prepared.first_kept_entry_id)
    local run = compaction.run({ model = model, preparation = prepared })
    assert(vim.wait(1000, function() return run:is_done() end))
    local result = assert(run:result())
    assert.is_true(result.ok)
    assert(session:append_compaction({ summary = result.summary, tokens_before = assert(result.tokens_before) }))
    local projected = assert(session:context_messages())
    assert.are.equal(1, #projected)
    assert.are.equal("user", assert(projected[1]).role)
    assert.matches("Checkpoint", assert(assert(assert(assert(projected[1]).content)[1]).text))
    assert.are.equal(#journal + 1, #assert(session:path()))
  end)

  it("consumes a second oversized Tool exchange after a whole-context checkpoint", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Inspect this" }))
    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "inspect-1", name = "inspect", arguments = {},
    } }, stopReason = "toolUse" }))
    assert(session:append({
      role = "toolResult",
      toolCallId = "inspect-1",
      toolName = "inspect",
      content = { { type = "text", text = string.rep("first evidence ", 2000) } },
    }))
    assert(session:append_compaction({ summary = "Previous checkpoint", tokens_before = 1000 }))
    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "inspect-2", name = "inspect", arguments = {},
    } }, stopReason = "toolUse" }))
    assert(session:append({
      role = "toolResult",
      toolCallId = "inspect-2",
      toolName = "inspect",
      content = { { type = "text", text = string.rep("second evidence ", 2000) } },
    }))
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "Updated checkpoint" } }),
    } })
    model.context_window = 1000
    local evaluation = plan_compaction(compaction.local_component, {
      configured = { reserve_tokens = 200, keep_recent_tokens = 50 },
      model = model,
      path = assert(session:path()),
      messages = assert(session:context_messages()),
      force = true,
    })
    assert.is_nil(evaluation.error)
    local prepared = assert(evaluation.preparation)
    assert.is_nil(prepared.first_kept_entry_id)
    assert.are.equal("Previous checkpoint", prepared.previous_summary)
    local run = compaction.run({ model = model, preparation = prepared })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).ok)
    local request_message = assert(assert(model.requests[1]).messages[1])
    assert.matches("Previous checkpoint", require("neoagent.util").text_content(request_message.content), 1, true)
  end)

  it("bounds retained user text across blocks and stops at oversized images", function()
    local image = { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" }
    ---@type Neoagent.JournalEntry[]
    local path = {
      entry("old", nil, { role = "user", content = "Older text" }),
      entry("new", "old", { role = "user", content = {
        { type = "text", text = "first" }, image, { type = "text", text = "second" },
      } }),
    }
    local tree = require("neoagent.session_tree")
    local model = fake_model.new()
    model.context_window = 10000
    local component = require("neoagent.compaction.codex").component
    local small = assert(plan_compaction(component, { path = path, messages = tree.context_messages(path),
      model = model, configured = { keep_recent_tokens = 1200 }, force = true }).preparation)
    assert.are.same({ { entry_id = "new", text_chars = 0 } }, small.retained_users)
    local omitted = assert(plan_compaction(component, { path = path, messages = tree.context_messages(path),
      model = model, configured = { keep_recent_tokens = 1199 }, force = true }).preparation)
    assert.are.same({}, omitted.retained_users)
    local bounded = assert(plan_compaction(component, { path = path, messages = tree.context_messages(path),
      model = model, configured = { keep_recent_tokens = 1202 }, force = true }).preparation)
    assert.are.same({ { entry_id = "new", text_chars = 8 } }, bounded.retained_users)
    path[#path + 1] = {
      type = "compaction", id = "checkpoint", parent_id = "new", created_at = 1,
      tokens_before = 1205, retained_users = bounded.retained_users,
      native = { role = "nativeCompaction", api = "openai-codex-responses", provider = model.provider, model = model.id,
        encrypted_content = "synthetic-ciphertext" },
    }
    assert.are.same({ { type = "text", text = "first" }, image, { type = "text", text = "sec" } },
      assert(tree.context_messages(path)[1]).content)
    local transcript = assert(tree.transcript_entries(path)[2]) --[[@as Neoagent.MessageEntry]]
    assert.are.same(assert(path[2]).message, transcript.message)
  end)

  it("can reconsider a native checkpoint after immediate inference overflow", function()
    local session = assert(require("neoagent.session").new())
    local _, _, user = session:append({ role = "user", content = "Keep this request" })
    local model = fake_model.new()
    model.api = "openai-codex-responses"
    model.context_window = 10000
    assert(session:append_compaction({
      native = { role = "nativeCompaction", api = model.api, provider = model.provider,
        model = model.id, encrypted_content = "synthetic-ciphertext" },
      retained_users = { { entry_id = assert(user).id } }, tokens_before = 9000,
    }))
    local component = require("neoagent.compaction.codex").component
    local evaluation = plan_compaction(component, {
      path = assert(session:path()), messages = assert(session:context_messages()),
      model = model, configured = { keep_recent_tokens = 100 }, force = true,
    })
    local prepared = assert(evaluation.preparation)
    assert.are.same({}, prepared.retained_users)
    assert.are.equal("native", prepared.kind)
  end)

  it("preserves historical Tool evidence while trimming only the native request copy", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Inspect" }))
    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "inspect-1", name = "inspect", arguments = {},
    } }, stopReason = "toolUse" }))
    assert(session:append({ role = "toolResult", toolCallId = "inspect-1", toolName = "inspect",
      content = { { type = "text", text = string.rep("evidence ", 1000) } } }))
    assert(session:append({ role = "user", content = "Act on that evidence" }))
    local before = assert(session:context_messages())
    local model = fake_model.new()
    model.api, model.context_window = "openai-codex-responses", 1000
    ---@type Neoagent.RequestMessage[]?
    local sent
    model.compact = function(self, options)
      sent = options.messages
      return require("neoagent.async").run(function()
        return { ok = true, item = { role = "nativeCompaction", api = self.api,
          provider = self.provider, model = self.id, encrypted_content = "synthetic-ciphertext" } }
      end)
    end
    local component = require("neoagent.compaction.codex").component
    local prepared = assert(plan_compaction(component, { path = assert(session:path()), messages = before,
      model = model, configured = {}, force = true }).preparation)
    for _, instructions in ipairs({ "", "Preserve exact paths" }) do
      local run = component.run({ preparation = prepared, model = model,
        system_prompt = "", tools = {}, reason = "manual", instructions = instructions })
      assert(vim.wait(1000, function() return run:is_done() end))
      if instructions == "" then
        assert.is_true(assert(run:result()).ok)
        assert.matches("truncated", require("neoagent.util").text_content(assert(sent and sent[3]).content))
        assert.are.equal("Act on that evidence", assert(sent and sent[4]).content)
      else
        assert.is_false(assert(run:result()).ok)
        assert.matches("does not support custom instructions", assert(assert(run:result()).error).message)
      end
      assert.are.same(before, assert(session:context_messages()))
    end
  end)

  it("reduces a native request after provider overflow despite a fitting local estimate", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Inspect" }))
    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "inspect-1", name = "inspect", arguments = {},
    } }, stopReason = "toolUse" }))
    assert(session:append({ role = "toolResult", toolCallId = "inspect-1", toolName = "inspect",
      content = { { type = "text", text = string.rep("é", 300) } } }))
    local before = assert(session:context_messages())
    local model = fake_model.new()
    model.api, model.context_window = "openai-codex-responses", 1000
    local calls = {}
    model.compact = function(self, options)
      calls[#calls + 1] = options.messages
      return require("neoagent.async").run(function()
        if #calls == 1 then
          return { ok = false, error = { kind = "model", code = "context_length_exceeded",
            message = "Input exceeds the context window" } }
        end
        return { ok = true, item = { role = "nativeCompaction", api = self.api,
          provider = self.provider, model = self.id, encrypted_content = "synthetic-ciphertext" } }
      end)
    end
    local component = require("neoagent.compaction.codex").component
    local prepared = assert(plan_compaction(component, { path = assert(session:path()), messages = before,
      model = model, configured = {}, force = true }).preparation)
    local run = component.run({ preparation = prepared, model = model,
      system_prompt = "", tools = {}, reason = "overflow" })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal(2, #calls)
    assert.are_not.same(calls[1], calls[2])
    assert.are.same(before, assert(session:context_messages()))
  end)

  it("reduces enough eligible native text to reach a later oversized message", function()
    local session = assert(require("neoagent.session").new())
    for _ = 1, 3 do
      assert(session:append({ role = "user", content = string.rep("a", 1000) }))
    end
    assert(session:append({ role = "user", content = string.rep("b", 4000) }))
    local before = assert(session:context_messages())
    local model = fake_model.new()
    model.api, model.context_window = "openai-codex-responses", 1000
    ---@type Neoagent.RequestMessage[]?
    local sent
    model.compact = function(self, options)
      sent = options.messages
      return require("neoagent.async").run(function()
        return { ok = true, item = {
          role = "nativeCompaction",
          api = self.api,
          provider = self.provider,
          model = self.id,
          encrypted_content = "synthetic-ciphertext",
        } }
      end)
    end
    local component = require("neoagent.compaction.codex").component
    local prepared = assert(plan_compaction(component, {
      path = assert(session:path()),
      messages = before,
      model = model,
      configured = {},
      force = true,
    }).preparation)
    local run = component.run({ preparation = prepared, model = model })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).ok)
    assert.is_not_nil(sent)
    local reduced = assert(assert(sent)[4])
    assert(type(reduced.content) == "string")
    assert.is_true(vim.fn.strchars(reduced.content) < 4000)
    assert.are.same(before, assert(session:context_messages()))
  end)

  it("bounds repeated native overflow recovery and preserves the journal", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = string.rep("é", 200) }))
    local before = assert(session:context_messages())
    local model = fake_model.new()
    model.api, model.context_window = "openai-codex-responses", 1000
    ---@type Neoagent.RequestMessage[][]
    local calls = {}
    model.compact = function(_, options)
      calls[#calls + 1] = options.messages
      return require("neoagent.async").run(function()
        return { ok = false, error = { kind = "model", code = "context_length_exceeded",
          message = "Input exceeds the context window" } }
      end)
    end
    local component = require("neoagent.compaction.codex").component
    local prepared = assert(plan_compaction(component, { path = assert(session:path()), messages = before,
      model = model, configured = {}, force = true }).preparation)
    local run = component.run({ preparation = prepared, model = model })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(assert(run:result()).ok)
    assert.are.equal(3, #calls)
    assert.are_not.same(calls[1], calls[2])
    assert.are_not.same(calls[2], calls[3])
    local final = calls[3]
    if not final or not final[1] then error("Expected a third native request") end
    local last = final[1].content
    if type(last) ~= "string" then error("Expected a reduced text request") end
    local marker = assert((last:find("\n[... ", 1, true)))
    local omitted = assert(tonumber(last:match("(%d+) characters truncated for compaction%]$")))
    assert.are.equal(200, vim.fn.strchars(last:sub(1, marker - 1)) + omitted)
    assert.are.same(before, assert(session:context_messages()))
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
      local preparation = assert(prepare((assert(session:path())),
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
        kind = "summary", split_turn = true,
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
      kind = "summary", split_turn = true,
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
        kind = "summary", split_turn = true,
        tokens_before = 100,
        settings = compaction.settings(),
      },
      model = fake_model.new({ { result = history }, { result = prefix } }),
    })
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.same(history.message.usage, assert(run:result()).usage)
  end)
end)
