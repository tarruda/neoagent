local plan_compaction = require("tests.helpers.compaction")
local it = require("tests.helpers.async_test")
local assert = require("luassert")
local prefix = require("neoagent.compaction.prefix").component
local fake_model = require("tests.helpers.fake_model")
local util = require("neoagent.util")

---@param model Neoagent.Model
---@param session Neoagent.Session
---@param instructions? string
---@return Neoagent.CompactionRunOptions
---@async
local function options(model, session, instructions)
  local system_prompt = "Inspect the workspace and explain the results."
  local tools = { { name = "inspect", description = "Inspect a file", input_schema = { type = "object" } } }
  local messages = assert(session:context_messages())
  local evaluation = plan_compaction(prefix, {
    model = model,
    path = assert(session:path()),
    messages = messages,
    system_prompt = system_prompt,
    tools = tools,
    force = true,
    configured = { keep_recent_tokens = 10, reserve_tokens = 4096 },
  })
  assert.is_nil(evaluation.error)
  return {
    model = model,
    reason = "manual",
    system_prompt = system_prompt,
    tools = tools,
    instructions = instructions,
    preparation = assert(evaluation.preparation),
  }
end

---@param run Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
---@return Neoagent.CompactionResult
local function result(run)
  assert(vim.wait(1000, function()
    return run:is_done()
  end))
  return (assert(run:result()))
end

describe("prefix compaction", function()
  it("summarizes a contiguous request prefix once, including earlier history and split turns", function()
    for _, checkpoint in ipairs({ false, true }) do
      local session = assert(require("neoagent.session").new())
      assert(session:append({ role = "user", content = "Preserve the earlier requirements", timestamp = 1 }))
      local _, _, old = session:append({
        role = "assistant",
        content = { { type = "text", text = "Earlier progress" } },
        timestamp = 2,
      })
      if checkpoint then
        assert(session:append_compaction({
          summary = "## Goal\nPreserve earlier requirements",
          first_kept_entry_id = assert(old).id,
          tokens_before = 100,
        }))
      end
      assert(session:append({ role = "user", content = "Inspect the sample", timestamp = 3 }))
      assert(session:append({
        role = "assistant",
        content = {
          { type = "toolCall", id = "inspect-1", name = "inspect", arguments = {} },
        },
        timestamp = 4,
      }))
      assert(session:append({
        role = "toolResult",
        toolCallId = "inspect-1",
        toolName = "inspect",
        content = { { type = "text", text = string.rep("raw result ", 400) } },
        timestamp = 5,
      }))
      local _, _, recent = session:append({
        role = "assistant",
        content = {
          { type = "text", text = string.rep("Recent work ", 60) },
        },
        timestamp = 6,
      })
      local model =
        fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "New checkpoint" } }) } })
      model.context_window = 32768
      model.max_output_tokens = 512
      local opts = options(model, session, "Preserve file paths")
      opts.model_options = { request_opts = { body = { temperature = 0.2 } } }
      local original = util.copy(assert(session:context_messages()))
      local entries = util.copy(session:entries())
      local preparation = util.copy(opts.preparation)
      local compacted = result(prefix.run(opts))
      assert(compacted.ok)
      assert.are.equal(1, #model.requests)
      local request = assert(model.requests[1])
      assert.are.same(
        vim.list_slice(original, 1, #original - 1),
        vim.list_slice(request.messages, 1, #request.messages - 1)
      )
      assert.are.equal(opts.system_prompt, request.system_prompt)
      assert.are.same(opts.tools, request.tools)
      assert.are.same(opts.model_options.request_opts, request.request_opts)
      assert.are.equal(512, assert(request.max_output_tokens))
      local instruction = assert(request.messages[#request.messages])
      assert(instruction.role == "user")
      assert.matches("or call tools", util.text_content(instruction.content))
      assert.matches("Additional focus: Preserve file paths", util.text_content(instruction.content))
      assert.are.equal(assert(recent).id, compacted.first_kept_entry_id)
      assert.are.same(entries, session:entries())
      assert.are.same(original, session:context_messages())
      assert.are.same(preparation, opts.preparation)
      assert(session:append_compaction({
        summary = compacted.summary,
        first_kept_entry_id = compacted.first_kept_entry_id,
        tokens_before = assert(compacted.tokens_before),
      }))
      local projected = assert(session:context_messages())
      assert.are.equal(2, #projected)
      assert.are.same(original[#original], projected[2])
      assert.matches("New checkpoint", util.text_content(assert(projected[1]).content))
      assert.are.equal(#entries + 1, #session:entries())
    end
  end)

  it("keeps the complete Tool exchange on the retained side of a split", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Inspect the sample" }))
    local _, _, call = session:append({
      role = "assistant",
      content = {
        { type = "toolCall", id = "inspect-1", name = "inspect", arguments = {} },
      },
    })
    assert(session:append({
      role = "toolResult",
      toolCallId = "inspect-1",
      toolName = "inspect",
      content = { { type = "text", text = string.rep("Result ", 60) } },
    }))
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Checkpoint" } }) } })
    model.context_window = 32768
    local compacted = result(prefix.run(options(model, session)))
    assert(compacted.ok)
    assert.are.equal(assert(call).id, compacted.first_kept_entry_id)
    local messages = assert(model.requests[1]).messages
    assert.are.equal(2, #messages)
    assert.are.same(assert(session:context_messages())[1], messages[1])
  end)

  it("bounds an oversized Tool exchange in the summary request copy", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Inspect" }))
    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "inspect-1", name = "inspect", arguments = {},
    } }, stopReason = "toolUse" }))
    local output = string.rep("evidence ", 2000)
    assert(session:append({ role = "toolResult", toolCallId = "inspect-1", toolName = "inspect",
      content = { { type = "text", text = output } } }))
    local before = assert(session:context_messages())
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Checkpoint" } }) } })
    model.context_window = 1000
    local evaluation = plan_compaction(prefix, { model = model, path = assert(session:path()), messages = before,
      configured = { keep_recent_tokens = 50, reserve_tokens = 200 }, force = true })
    local prepared = assert(evaluation.preparation)
    assert.is_nil(prepared.first_kept_entry_id)
    local generated = result(prefix.run({ model = model, preparation = prepared }))
    assert.is_true(generated.ok)
    local sent = assert(model.requests[1]).messages
    assert.matches("truncated", util.text_content(assert(sent[3]).content))
    assert.matches("^evidence", util.text_content(assert(sent[3]).content))
    assert.are.same(before, assert(session:context_messages()))
  end)

  it("consumes a second oversized Tool exchange after a whole-context checkpoint", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Inspect" }))
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
    local opts = options(model, session)
    local prepared = opts.preparation --[[@as Neoagent.PrefixCompactionPreparation]]
    assert.is_nil(prepared.first_kept_entry_id)
    local compacted = result(prefix.run(opts))
    assert.is_true(compacted.ok)
    local request_message = assert(assert(model.requests[1]).messages[1])
    assert.matches("Previous checkpoint", util.text_content(request_message.content), 1, true)
  end)

  it("rejects an oversized original prefix or custom instruction before inference", function()
    for _, large_instruction in ipairs({ false, true }) do
      local session = assert(require("neoagent.session").new())
      assert(
        session:append({ role = "user", content = large_instruction and "Earlier work" or string.rep("x", 20000) })
      )
      assert(session:append({ role = "assistant", content = { { type = "text", text = string.rep("Recent ", 60) } } }))
      local model = fake_model.new()
      model.context_window = 4096
      local opts = options(model, session, large_instruction and string.rep("focus ", 4000) or nil)
      local entries = util.copy(session:entries())
      local failed = result(prefix.run(opts))
      assert.is_false(failed.ok)
      assert.matches("cannot be reduced below the Model window", assert(failed.error).message)
      assert.are.equal(0, #model.requests)
      assert.are.same(entries, session:entries())
    end
  end)

  it("requires text-only completion even though the original Tool schemas remain available", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Earlier work" }))
    assert(session:append({ role = "assistant", content = { { type = "text", text = string.rep("Recent ", 60) } } }))
    local model = fake_model.new({
      {
        result = fake_model.assistant({
          { type = "toolCall", id = "unwanted", name = "inspect", arguments = {} },
        }, "toolUse"),
      },
    })
    model.context_window = 32768
    local entries = util.copy(session:entries())
    local failed = result(prefix.run(options(model, session)))
    assert.is_false(failed.ok)
    assert.matches("returned a Tool call", assert(failed.error).message)
    assert.are.equal(1, #model.requests)
    assert.are.same(entries, session:entries())
  end)

  it("rejects encrypted context and incompatible native preparation before inference", function()
    local session = assert(require("neoagent.session").new())
    local _, _, earlier = session:append({ role = "user", content = "Earlier constraints" })
    assert(session:append_compaction({
      native = {
        role = "nativeCompaction",
        api = "openai-codex-responses",
        provider = "codex",
        model = "gpt-test",
        encrypted_content = "synthetic-ciphertext",
      },
      retained_users = { { entry_id = assert(earlier).id } },
      tokens_before = 500,
    }))
    assert(session:append({ role = "user", content = "Continue" }))
    local model = fake_model.new()
    model.context_window = 32768
    local entries = util.copy(session:entries())
    local evaluation = plan_compaction(prefix, {
      model = model,
      path = assert(session:path()),
      messages = assert(session:context_messages()),
      configured = {},
      force = true,
    })
    assert.is_nil(evaluation.preparation)
    assert.matches("encrypted checkpoint", assert(evaluation.error).message)
    local failed = result(prefix.run({
      model = model,
      reason = "manual",
      preparation = { kind = "native", source_messages = {}, request_messages = {}, retained_users = {},
        tokens_before = 500, settings = evaluation.settings },
    }))
    assert.is_false(failed.ok)
    assert.matches("requires prefix preparation", assert(failed.error).message)
    assert.are.same(entries, session:entries())
    assert.are.equal(0, #model.requests)
  end)

  it("inherits automatic thresholds without preparing or calling a Model below them", function()
    local model = fake_model.new()
    model.context_window = 32768
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "Small request" }))
    local evaluation = plan_compaction(prefix, {
      model = model,
      path = assert(session:path()),
      messages = assert(session:context_messages()),
      configured = {},
    })
    assert.is_false(evaluation.needed)
    assert.is_nil(evaluation.preparation)
    assert.are.equal(0, #model.requests)
  end)
  it("rejects prefix checkpoints when the Model cannot consume their images", function()
    local session = assert(require("neoagent.session").new())
    local attachments = require("tests.helpers.attachments").new(session:files())
    assert(session:append({ role = "user", content = { attachments.image("synthetic-image") } }))
    assert(session:append({ role = "assistant", content = { { type = "text", text = "Recent work" } } }))
    local model =
      fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Missing evidence" } }) } })
    model.context_window = 32768
    local component = require("neoagent.compaction.prefix").component
    local evaluation = plan_compaction(component, {
      model = model,
      path = assert(session:path()),
      messages = assert(session:context_messages()),
      configured = { keep_recent_tokens = 1 },
      force = true,
    })
    local result = component.run({
      model = model,
      preparation = assert(evaluation.preparation),
      model_options = { files = session:files() },
    }):await()
    assert.is_false(result.ok)
    assert.matches("cannot read consumed images", assert(result.error).message)
    assert.are.equal(0, #model.requests)
  end)

end)
