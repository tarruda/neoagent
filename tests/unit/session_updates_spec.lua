local assert = require("luassert")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local util = require("neoagent.util")
local semantic = require("neoagent.semantic_message")
local fs = require("neoagent.fs")

describe("Session context updates", function()
  local copy = util.copy
  local normalize = semantic.normalize
  ---@type string
  local directory

  before_each(function()
    directory = vim.fn.tempname()
  end)

  after_each(function()
    util.copy = copy
    semantic.normalize = normalize
    vim.fn.delete(directory, "rf")
  end)

  it("keeps one accepted durable projection across Session handles and Store writes", function()
    local store = storage.new({ directory = directory, cwd = directory })
    local first = assert(Session.new({ store = store }))
    local second = assert(Session.new({ store = store }))
    local _, _, request = store:append({ role = "user", content = "accepted request" })
    assert(request)
    assert.are.same(store:load(), first:messages())
    assert.are.same(first:messages(), second:messages())
    assert(first:append({ role = "assistant", content = { {
      type = "toolCall", id = "shared-call", name = "inspect", arguments = {},
    } } }))
    assert(second:append({
      role = "toolResult", toolCallId = "shared-call", toolName = "inspect", content = {},
    }))
    assert.are.same(first:messages(), second:messages())
    assert.is_nil(first:append({
      role = "toolResult", toolCallId = "shared-call", toolName = "inspect", content = {},
    }))
    local detached = second:messages()
    assert(detached[1]).content = "edited copy"
    assert.are.equal("accepted request", assert(first:messages()[1]).content)
    assert(first:move_to(request.id))
    assert.are.same({ { role = "user", content = "accepted request" } }, second:messages())
    assert(second:append({ role = "user", content = "new branch" }))
    assert.are.same(first:messages(), second:messages())
  end)

  it("normalizes stored history once and preserves independent copied projections", function()
    local seed = storage.new({ directory = directory, cwd = directory })
    local workspace = seed:workspace_storage()
    assert(workspace.prepare())
    assert(fs.ensure_private_directory(workspace.sessions_directory, 448))
    local metadata = seed:metadata()
    local records = { vim.json.encode({
      type = "session", format = "neoagent-session", id = metadata.id,
      cwd = directory, created_at = 1,
    }) }
    for index = 1, 40 do
      records[#records + 1] = vim.json.encode({
        type = "message", id = tostring(index), parent_id = index > 1 and tostring(index - 1) or vim.NIL,
        created_at = 1, message = { role = "user", content = { { type = "text", text = "history " .. index } } },
      })
    end
    assert(fs.atomic_replace(metadata.path, table.concat(records, "\n") .. "\n", { mode = 384 }))
    local normalizations = 0
    semantic.normalize = function(message)
      normalizations = normalizations + 1
      return normalize(message)
    end
    local store = assert(storage.open(metadata.path, workspace))
    local session = assert(Session.new({ store = store }))
    assert.are.equal(40, #session:messages())
    assert.are.equal(40, normalizations, "resume normalized the same durable history more than once")
    local loaded = store:load()
    assert(assert(assert(loaded[1]).content)[1]).text = "edited Store snapshot"
    assert.are.equal("history 1", assert(assert(assert(session:messages()[1]).content)[1]).text)
    assert.are.equal("history 1", assert(assert(assert(store:load()[1]).content)[1]).text)
  end)

  for _, durable in ipairs({ false, true }) do
    it("reads " .. (durable and "durable" or "memory") .. " checkpoint identity without copying messages", function()
      local store = durable and storage.new({ directory = directory, cwd = directory }) or nil
      local session = assert(Session.new({
        store = store,
      }))
      assert(session:append({ role = "user", content = "historical identity probe" }))
      assert(session:append_compaction({
        native = {
          role = "nativeCompaction", api = "openai-codex-responses",
          provider = "openai-codex", model = "synthetic", encrypted_content = "checkpoint",
        },
        retained_users = {}, tokens_before = 10,
      }))
      assert(session:append({ role = "user", content = "latest identity probe" }))
      local body_copies = 0
      util.copy = function(value, seen)
        if type(value) == "table" and type(value.content) == "string" and value.content:find("identity probe", 1, true) then
          body_copies = body_copies + 1
        end
        return copy(value, seen)
      end
      local identity = assert(session:checkpoint_identity())
      assert.are.same({
        api = "openai-codex-responses", provider = "openai-codex", model = "synthetic",
      }, identity)
      identity.provider = "changed"
      assert.are.equal("openai-codex", assert(session:checkpoint_identity()).provider)
      assert.are.equal(0, body_copies, "checkpoint lookup copied journal message bodies")
      if store then
        store._leaf_id = "missing"
        local missing, err = session:checkpoint_identity()
        assert.is_nil(missing)
        assert.matches("entry not found", tostring(assert(err).detail))
      end
    end)

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
