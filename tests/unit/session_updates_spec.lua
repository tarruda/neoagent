local assert = require("luassert")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local util = require("neoagent.util")

describe("Session context updates", function()
  local copy = util.copy
  ---@type string
  local directory

  before_each(function()
    directory = vim.fn.tempname()
  end)

  after_each(function()
    util.copy = copy
    vim.fn.delete(directory, "rf")
  end)

  for _, durable in ipairs({ false, true }) do
    it("projects " .. (durable and "durable" or "memory") .. " context without copying compacted messages", function()
      local session = assert(Session.new({
        store = durable and storage.new({ directory = directory, cwd = directory }) or nil,
      }))
      local _, _, retained = session:append({ role = "user", content = "Retain this instruction" })
      for _ = 1, 30 do
        assert(session:append({ role = "user", content = "historical" }))
      end
      assert(session:append_compaction({
        native = {
          role = "nativeCompaction",
          api = "openai-codex-responses",
          provider = "openai-codex",
          model = "synthetic",
          encrypted_content = "checkpoint",
        },
        retained_users = { { entry_id = assert(retained).id } },
        tokens_before = 1000,
      }))
      local historical_copies = 0
      util.copy = function(value, seen)
        if type(value) == "table" and value.content == "historical" then
          historical_copies = historical_copies + 1
        end
        return copy(value, seen)
      end
      local context = assert(session:context_messages())
      assert.are.equal(2, #context)
      assert.are.equal("nativeCompaction", assert(context[2]).role)
      assert(context[1]).content = "mutated"
      assert(session:append({ role = "user", content = "New instruction" }))
      context = assert(session:context_messages())
      assert.are.equal(3, #context)
      assert.are.equal("Retain this instruction", assert(context[1]).content)
      assert.are.equal("New instruction", assert(context[3]).content)
      assert.are.equal(0, historical_copies, "context refresh copied messages outside the active model context")
      util.copy = copy
      assert(session:append_compaction({
        native = {
          role = "nativeCompaction",
          api = "openai-codex-responses",
          provider = "openai-codex",
          model = "synthetic",
          encrypted_content = "replacement",
        },
        retained_users = { { entry_id = assert(retained).id } },
        tokens_before = 1000,
      }))
      assert.are.equal(2, #assert(session:context_messages()))
      assert(session:move_to(assert(retained).id))
      assert.are.same({ { role = "user", content = "Retain this instruction" } }, assert(session:context_messages()))
    end)
  end
end)
