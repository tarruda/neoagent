local assert = require("luassert")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")

---@param id string
---@return Neoagent.AssistantMessage
local function call(id)
  return { role = "assistant", content = {
    { type = "toolCall", id = id, name = "inspect", arguments = {} },
  } }
end

---@param id string
---@param name? string
---@return Neoagent.ToolResultMessage
local function result(id, name)
  return { role = "toolResult", toolCallId = id, toolName = name or "inspect", content = {} }
end

describe("Session tool linkage", function()
  ---@type string
  local directory
  before_each(function()
    directory = vim.fn.tempname()
  end)
  after_each(function()
    vim.fn.delete(directory, "rf")
  end)

  for _, durable in ipairs({ false, true }) do
    local mode = durable and "durable" or "memory"
    it("preserves " .. mode .. " linkage across failures, branches, and checkpoints", function()
      local store = durable and storage.new({ directory = directory, cwd = directory }) or nil
      local session = assert(Session.new({ store = store }))
      local _, _, user = session:append({ role = "user", content = "Inspect the synthetic project." })
      local _, _, first = session:append(call("same"))
      local accepted, err = session:append(result("same", "different"))
      assert.is_nil(accepted)
      assert.matches("toolName does not match", tostring(assert(err).detail))
      accepted = session:append(result("same"), { model = { provider = "", model = "invalid" } })
      assert.is_nil(accepted)
      assert(session:append(result("same")))
      accepted, err = session:append(result("same"))
      assert.is_nil(accepted)
      assert.matches("unknown toolCall", tostring(assert(err).detail))
      accepted, err = session:append(call("same"))
      assert.is_nil(accepted)
      assert.matches("duplicate conversation toolCall", tostring(assert(err).detail))

      assert(session:move_to(assert(first).id))
      assert(session:append(result("same")))
      accepted = session:append(call("fresh"), { model = { provider = "", model = "invalid" } })
      assert.is_nil(accepted)
      assert(session:append(call("fresh")))
      assert(session:append_compaction({
        native = {
          role = "nativeCompaction", api = "openai-codex-responses",
          provider = "openai-codex", model = "synthetic", encrypted_content = "synthetic-checkpoint",
        },
        retained_users = { { entry_id = assert(user).id } }, tokens_before = 100,
      }))
      accepted, err = session:append(result("fresh"))
      assert.is_nil(accepted)
      assert.matches("unknown toolCall", tostring(assert(err).detail))
      assert(session:append(call("same")))

      if store then
        session = assert(Session.new({ store = assert(storage.open(
          assert(store:metadata().path), store:workspace_storage()
        )) }))
      else
        session = assert(Session.new({ entries = session:entries() }))
      end
      assert(session:append(result("same")))
      assert(session:move_to(nil))
      accepted = session:append(result("same"))
      assert.is_nil(accepted)
      assert(session:append(call("same")))
    end)

    it("resets " .. mode .. " linkage after a local summary", function()
      local session = assert(Session.new({
        store = durable and storage.new({ directory = directory, cwd = directory }) or nil,
      }))
      assert(session:append(call("reused")))
      assert(session:append(result("reused")))
      assert(session:append_compaction({ summary = "Synthetic summary", tokens_before = 10 }))
      assert(session:append(call("reused")))
      assert(session:append(result("reused")))
    end)
  end

  it("keeps pending calls after a Store write fails", function()
    local fail = true
    local session = assert(Session.new({ store = {
      load = function()
        return { call("pending") }
      end,
      append = function(_, message)
        if fail then
          return nil, { kind = "storage", message = "synthetic failure" }
        end
        return true, nil, nil, { type = "append", messages = { message } }
      end,
    } }))
    assert.is_nil(session:append(result("pending")))
    fail = false
    assert(session:append(result("pending")))
    assert.is_nil(session:append(result("pending")))
  end)

  it("rejects a whole Store batch without publishing its calls or checkpoint reset", function()
    ---@type Neoagent.StoreProjection
    local projection = {
      type = "append",
      messages = {
        { role = "compactionCheckpoint", tokens_before = 10, created_at = 1 },
        call("rejected"),
        result("unknown"),
      },
    }
    local session = assert(Session.new({ store = {
      load = function()
        return { call("pending") }
      end,
      append = function()
        return true, nil, nil, projection
      end,
    } }))
    local before = session:messages()
    assert.is_nil(session:append({ role = "user", content = "Trigger rejected projection" }))
    assert.are.same(before, session:messages())
    projection = { type = "append", messages = { result("pending") } }
    assert(session:append({ role = "user", content = "Accept the actual result" }))
    projection = { type = "append", messages = { call("rejected") } }
    assert(session:append({ role = "user", content = "Accept the actual call" }))
    projection = { type = "append", messages = { result("rejected") } }
    assert(session:append({ role = "user", content = "Finish the actual call" }))
  end)

  it("validates calls created and answered within one accepted Store batch", function()
    ---@type Neoagent.StoreProjection
    local projection = { type = "append", messages = { call("answered"), result("answered"), call("pending") } }
    local session = assert(Session.new({ store = {
      load = function()
        return {}
      end,
      append = function()
        return true, nil, nil, projection
      end,
    } }))
    assert(session:append({ role = "user", content = "Accept the synthetic batch" }))
    assert.is_nil(session:append(call("answered")))
    assert.is_nil(session:append(result("answered")))
    projection = { type = "append", messages = { result("pending") } }
    assert(session:append(result("pending")))
  end)

  it("uses only an accepted replacement to rebuild linkage", function()
    ---@type Neoagent.StoreProjection
    local projection = { type = "replace", messages = { call("replacement"), result("unknown") } }
    local session = assert(Session.new({ store = {
      load = function()
        return { call("original") }
      end,
      append = function()
        return true, nil, nil, projection
      end,
    } }))
    assert.is_nil(session:append({ role = "user", content = "Reject replacement" }))
    projection = { type = "append", messages = { result("original") } }
    assert(session:append(result("original")))
    projection = { type = "replace", messages = { call("replacement") } }
    assert(session:append({ role = "user", content = "Accept replacement" }))
    assert.is_nil(session:append(result("original")))
    projection = { type = "append", messages = { result("replacement") } }
    assert(session:append(result("replacement")))
  end)
end)
