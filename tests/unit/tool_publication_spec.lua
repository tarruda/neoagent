local assert = require("luassert")
local async = require("neoagent.async")
local loop = require("neoagent.agent_loop")
local fake_model = require("tests.helpers.fake_model")
local helper = require("tests.helpers.subprocess")
local result_receipt = require("neoagent.result_receipt")
local util = require("neoagent.util")

describe("Tool result publication", function()
  for _, failure in ipairs({ "executor", "validation", "recovery throws", "invalid recovery" }) do
    it("recovers operation facts before abandoning ownership after " .. failure, function()
      local events = {}
      ---@type Neoagent.Message?
      local observed
      local result = helper.wait(loop.run({
        model = fake_model.new({
          { result = fake_model.assistant({ { type = "toolCall", name = "publish", id = "p1", arguments = {} } }, "toolUse") },
          { result = fake_model.assistant({ { type = "text", text = "done" } }) },
        }),
        messages = {},
        tools = { {
          name = "publish", description = "", input_schema = { type = "object" },
          execute = function(_, ctx)
            assert(ctx.on_result)({
              finish = function(accepted)
                assert.is_nil(accepted)
                events[#events + 1] = "abandoned"
              end,
              recover = function(err)
                assert.are.equal("tool", err.kind)
                events[#events + 1] = "recovered"
                if failure == "recovery throws" then error("recovery failed") end
                if failure == "invalid recovery" then return {} --[[@as Neoagent.ToolResult]] end
                return { content = { { type = "text", text = "Known operation outcome" } }, isError = true }
              end,
            })
            return { content = { { type = "text", text = "original" } } }
          end,
        } },
        execute_tool = function(tool, args, ctx)
          tool.execute(args, ctx)
          if failure == "validation" then return {} --[[@as Neoagent.ToolResult]] end
          error("executor lost the result")
        end,
        commit_message = function(message)
          if message.role == "toolResult" then observed = message; events[#events + 1] = "stored" end
          return true
        end,
      }))
      if failure == "executor" or failure == "validation" then
        assert.is_true(result.ok)
        local message = assert(observed)
        assert.are.equal("Known operation outcome", require("neoagent.util").text_content(message.content))
        assert.are.same({ "recovered", "abandoned", "stored" }, events)
      else
        assert.is_false(result.ok)
        assert.is_nil(observed)
        assert.are.same({ "recovered", "abandoned" }, events)
      end
    end)
  end

  for _, accepted in ipairs({ true, false }) do
    it("keeps the storage decision observable when its acknowledgement fails: " .. tostring(accepted), function()
      local run = loop.run({
        model = fake_model.new({
          {
            result = fake_model.assistant(
              { {
                type = "toolCall",
                name = "publish",
                id = "p1",
                arguments = {},
              } },
              "toolUse"
            ),
          },
        }),
        messages = {},
        tools = {
          {
            name = "publish",
            description = "",
            input_schema = { type = "object" },
            execute = function(_, ctx)
              assert(ctx.on_result)({ finish = function(value)
                assert.are.equal(accepted, value ~= nil)
                error("resource acknowledgement failed")
              end })
              return { content = { { type = "text", text = "published" } } }
            end,
          },
        },
        commit_message = function(message)
          if message.role == "toolResult" and not accepted then
            return nil, { kind = "storage", message = "storage rejected publication" }
          end
          return true
        end,
      })
      local result = helper.wait(run)
      assert.is_false(result.ok)
      if accepted then
        assert.are.equal(2, #assert(result.new_messages))
        assert.matches("resource acknowledgement failed", assert(result.error).message, 1, true)
      else
        assert.are.equal("storage rejected publication", assert(result.error).message)
        local diagnostic = assert(run:diagnostics()[1])
        assert.are.equal("dispose", diagnostic.phase)
        assert.matches("resource acknowledgement failed", diagnostic.message, 1, true)
      end
    end)
  end

  for _, scenario in ipairs({
    "accepted",
    "rejected",
    "storage throws",
    "invalid",
    "execute throws",
    "cancel",
    "cancel during commit",
    "bad observation",
  }) do
    it("settles ownership once when " .. scenario, function()
      local decisions, order = {}, {}
      local model = fake_model.new({
        {
          result = fake_model.assistant(
            { { type = "toolCall", name = "publish", id = "p1", arguments = {} } },
            "toolUse"
          ),
        },
        { result = fake_model.assistant({ { type = "text", text = "done" } }) },
      })
      local result = helper.wait(loop.run({
        model = model,
        messages = {},
        tools = {
          {
            name = "publish",
            description = "",
            input_schema = { type = "object" },
            execute = function(_, ctx)
              assert(ctx.on_result)({ finish = function(accepted, receipt)
                decisions[#decisions + 1] = accepted ~= nil
                assert.are.same(accepted and { output = true } or nil, receipt)
                order[#order + 1] = "settled"
              end })
              if scenario == "execute throws" then
                error("execution failed")
              end
              if scenario == "cancel" then
                ctx.run:cancel()
                async.await(function() end)
              end
              if scenario == "invalid" then
                return {} --[[@as Neoagent.ToolResult]]
              end
              return result_receipt.bind({ content = { { type = "text", text = "retained" } } }, { output = true })
            end,
          },
        },
        commit_message = function(message)
          if message.role == "toolResult" then
            order[#order + 1] = "store"
            if scenario == "rejected" then
              return nil, { kind = "storage", message = "not accepted" }
            end
            if scenario == "storage throws" then
              error("storage failed")
            end
            if scenario == "cancel during commit" then
              assert(async.current()):cancel()
            end
            if scenario == "bad observation" then
              return true, nil, {} --[[@as Neoagent.ObservedMessage]]
            end
          end
          return true
        end,
      }))
      local accepted = scenario == "accepted" or scenario == "cancel during commit" or scenario == "bad observation"
      assert.are.same({ accepted }, decisions)
      if accepted then
        assert.are.same({ "store", "settled" }, order)
      end
      if scenario == "accepted" then
        assert.is_true(result.ok)
      end
    end)
  end

  for _, transformation in ipairs({
    "copy",
    "metadata",
    "notice",
    "cleanup",
    "rebind",
    "mutate",
    "replace",
    "stale notice",
    "stale cleanup",
  }) do
    it("delivers only the receipt bound to accepted content after " .. transformation, function()
      local sandbox_result = require("neoagent.sandbox.result")
      local model = fake_model.new({
        {
          result = fake_model.assistant(
            { { type = "toolCall", name = "publish", id = "p1", arguments = {} } },
            "toolUse"
          ),
        },
        { result = fake_model.assistant({ { type = "text", text = "done" } }) },
      })
      local finished = false
      local result = helper.wait(loop.run({
        model = model,
        messages = {},
        tools = {
          {
            name = "publish",
            description = "",
            input_schema = { type = "object" },
            execute = function(_, ctx)
              assert(ctx.on_result)({
                finish = function(accepted, receipt)
                  assert.is_not_nil(accepted)
                  finished = true
                  if
                    transformation == "mutate"
                    or transformation == "replace"
                    or transformation == "stale notice"
                    or transformation == "stale cleanup"
                  then
                    assert.is_nil(receipt)
                  else
                    assert.are.same({ output = transformation ~= "rebind" }, receipt)
                  end
                end,
              })
              local value = { content = { { type = "text", text = "original" } } }
              local receipt = { output = true }
              local bound = result_receipt.bind(value, receipt)
              value.content[1].text = "changed after binding"
              receipt.output = false
              return bound
            end,
          },
        },
        execute_tool = function(tool, args, ctx)
          local value = tool.execute(args, ctx)
          if transformation == "copy" then
            return util.copy(value)
          elseif transformation == "metadata" then
            return sandbox_result.annotate(value, { kind = "allowed" })
          elseif transformation == "notice" then
            return sandbox_result.append(value, "Policy notice")
          elseif transformation == "cleanup" then
            return sandbox_result.cleanup(value, "Cleanup notice")
          elseif transformation == "replace" then
            return { content = util.copy(value.content) }
          end
          value.content[1] = { type = "text", text = "edited" }
          if transformation == "rebind" then
            return result_receipt.bind(value, { output = false })
          elseif transformation == "stale notice" then
            return sandbox_result.append(value, "Policy notice")
          elseif transformation == "stale cleanup" then
            return sandbox_result.cleanup(value, "Cleanup notice")
          end
          return value
        end,
        commit_message = function(message)
          assert.is_nil(rawget(message, "receipt"))
          return true
        end,
      }))
      assert.is_true(result.ok, vim.inspect(result))
      assert.is_true(finished)
      for _, message in ipairs(assert(result.new_messages)) do
        assert.is_nil(rawget(message, "receipt"))
      end
      for _, message in ipairs(assert(model.requests[2]).messages) do
        assert.is_nil(rawget(message, "receipt"))
      end
    end)
  end

  for _, malformed in ipairs({
    false,
    { content = {}, value = {}, unexpected = true },
    { content = { { type = "thinking", thinking = "hidden" } }, value = {} },
    { content = {}, value = "invalid" },
    { content = {}, value = { invalid = function() end } },
  }) do
    it("abandons ownership when the returned receipt is malformed: " .. vim.inspect(malformed), function()
      local finished = false
      local result = helper.wait(loop.run({
        model = fake_model.new({
          {
            result = fake_model.assistant(
              { { type = "toolCall", name = "publish", id = "p1", arguments = {} } },
              "toolUse"
            ),
          },
          { result = fake_model.assistant({ { type = "text", text = "done" } }) },
        }),
        messages = {},
        tools = {
          {
            name = "publish",
            description = "",
            input_schema = { type = "object" },
            execute = function(_, ctx)
              assert(ctx.on_result)({
                finish = function(accepted, receipt)
                  assert.is_nil(accepted)
                  assert.is_nil(receipt)
                  finished = true
                end,
              })
              return { content = {}, receipt = malformed } --[[@as Neoagent.ToolResult]]
            end,
          },
        },
        commit_message = function(message)
          if message.role == "toolResult" then
            assert.is_true(message.isError)
          end
          return true
        end,
      }))
      assert.is_true(result.ok)
      assert.is_true(finished)
    end)
  end
end)
