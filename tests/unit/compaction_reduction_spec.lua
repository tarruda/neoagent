local it = require("tests.helpers.async_test")
local assert = require("luassert")
local plan_compaction = require("tests.helpers.compaction")
local async = require("neoagent.async")
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

describe("neoagent.compaction_reduction", function()
  it("combines reductions from several Tool results in native and prefix requests", function()
    for _, strategy in ipairs({ "codex", "prefix" }) do
      local session = assert(Session.new())
      assert(session:append({ role = "user", content = "Inspect both files" }))
      for index = 1, 2 do
        assert(session:append({
          role = "assistant",
          content = {
            {
              type = "toolCall",
              id = "inspect-" .. index,
              name = "inspect",
              arguments = {},
            },
          },
          stopReason = "toolUse",
        }))
        assert(session:append({
          role = "toolResult",
          toolCallId = "inspect-" .. index,
          content = { { type = "text", text = string.rep("evidence ", 500) } },
        }))
      end
      local before = assert(session:context_messages())
      local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "Checkpoint" } }) } })
      model.context_window = 1000
      model.api = "openai-codex-responses"
      model.compact = function(self, options)
        for _, message in ipairs(options.messages) do
          if message.role == "toolResult" then
            assert.matches("truncated", require("neoagent.util").text_content(message.content))
          end
        end
        return async.run(function()
          return {
            ok = true,
            item = {
              role = "nativeCompaction",
              api = self.api,
              provider = self.provider,
              model = self.id,
              encrypted_content = "synthetic-ciphertext",
            },
          }
        end)
      end
      local component = require("neoagent.compaction." .. strategy).component
      local evaluation = plan_compaction(component, {
        model = model,
        path = assert(session:path()),
        messages = before,
        configured = {},
        force = true,
      })
      assert.is_nil(evaluation.error)
      local result = finish(component.run({ model = model, preparation = assert(evaluation.preparation) }))
      assert.is_true(result.ok)
      assert.are.same(before, session:context_messages())
    end
  end)

  it("searches reduced requests with the Model tokenizer", function()
    local model = fake_model.new()
    model.estimate_request = function(_, options)
      return math.ceil(require("neoagent.api.request_estimate").messages(options.messages) / 2)
    end
    local original = {
      {
        role = "toolResult",
        toolCallId = "inspect",
        content = { { type = "text", text = string.rep("data", 1000) } },
      },
    }
    local reduced, err = require("neoagent.compaction.reduction").request(model, { messages = original }, 400)
    assert.is_nil(err)
    assert.is_not_nil(reduced)
    assert.is_true(model:estimate_request({ messages = assert(reduced) }) + 32 <= 400)
    assert.are.equal(string.rep("data", 1000), original[1].content[1].text)
  end)
end)
