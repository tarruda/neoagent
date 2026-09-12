local assert = require("luassert")
local async_test = require("tests.helpers.async_test")
local fs = require("neoagent.fs")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")

describe("durable Session validation", function()
  local directory
  after_each(function()
    if directory then vim.fn.delete(directory, "rf"); directory = nil end
  end)

  for _, initial in ipairs({ "absent", "empty", "initialized" }) do
    async_test("keeps " .. initial .. " workspace storage writable after opening a missing Session", function()
      directory = vim.fn.tempname()
      local store = storage.new({ directory = directory, cwd = directory })
      local workspace = store:workspace_storage()
      if initial == "empty" then
        assert(fs.ensure_private_directory(workspace.directory, 448))
      elseif initial == "initialized" then
        assert(workspace.prepare())
      end
      local existed = vim.uv.fs_lstat(workspace.directory) ~= nil
      local contents = vim.fn.globpath(workspace.directory, "**", false, true)

      local opened, err = storage.open(store:metadata().path, workspace)

      assert.is_nil(opened)
      assert.matches("Failed to read session", assert(err).message)
      assert.are.equal(existed, vim.uv.fs_lstat(workspace.directory) ~= nil)
      assert.are.same(contents, vim.fn.globpath(workspace.directory, "**", false, true))
      assert(workspace.validate())
      local session = assert(Session.new({ store = store }))
      assert(session:append({ role = "user", content = "First accepted message." }))
      local reopened = assert(storage.open(store:metadata().path, workspace))
      assert.are.same(session:messages(), reopened:load())
    end)
  end

  async_test("rejects malformed messages without changing the journal or blocking later commits", function()
    directory = vim.fn.tempname()
    local store = storage.new({ directory = directory, cwd = directory })
    local session = assert(Session.new({ store = store }))
    assert(session:append({ role = "user", content = "Start." }))
    local journal = assert(fs.read(store:metadata().path))
    local retained = session:messages()
    local nested = {}
    local cursor = nested
    for _ = 1, 33 do cursor.child = {}; cursor = cursor.child end
    local wide = {}
    for index = 1, 10001 do wide[index] = {} end
    local cases = {
      { message = { role = "assistant", content = { false } }, error = "content block must be an object" },
      { message = { role = "assistant", content = {}, usage = false }, error = "usage must be an object" },
      { message = { role = "assistant", content = {}, usage = { cost = { unknown = 1 } } }, error = "unsupported field" },
      { message = { role = "assistant", content = {}, provider = false }, error = "assistant provider" },
      { message = { role = "toolResult", content = {}, toolCallId = "call", toolName = false }, error = "toolResult toolName" },
      { message = { role = "toolResult", content = {}, toolCallId = "call", usage = false }, error = "usage must be an object" },
    }
    for _, case in ipairs({
      { block = { type = "text", text = "answer", textSignature = false }, error = "text block signature" },
      { block = { type = "text", text = "answer", phase = false }, error = "text block phase" },
      { block = { type = "thinking", thinking = "reason", index = -1 }, error = "thinking block index" },
      { block = { type = "thinking", thinking = "reason", thinkingSignature = false }, error = "thinking block signature" },
      { block = { type = "toolCall", id = "call", name = false, arguments = {} }, error = "toolCall name" },
      { block = { type = "toolCall", id = "call", name = "read", arguments = {}, argumentsError = false }, error = "toolCall argumentsError" },
      { block = { type = "toolCall", id = "call", name = "read", arguments = {}, index = -1 }, error = "toolCall index" },
    }) do
      cases[#cases + 1] = { message = { role = "assistant", content = { case.block } }, error = case.error }
    end
    for _, case in ipairs({
      { value = { number = math.huge }, error = "must be finite" },
      { value = { callback = function() end }, error = "must contain JSON values" },
      { value = nested, error = "nesting limit" },
      { value = wide, error = "value limit" },
      { value = { { invalid = math.huge } }, error = "must be finite" },
    }) do
      cases[#cases + 1] = { message = { role = "assistant", content = { {
        type = "toolCall", id = "call", name = "read", arguments = { value = case.value },
      } } }, error = case.error }
    end
    for _, case in ipairs(cases) do
      local accepted, err = session:append(case.message --[[@as Neoagent.Message]])
      assert.is_nil(accepted)
      assert.are.equal("session", assert(err).kind)
      assert.matches(case.error, tostring(assert(err).detail))
      assert.are.same(retained, session:messages())
      assert.are.equal(journal, assert(fs.read(store:metadata().path)))
    end
    assert(session:append({ role = "user", content = "Still usable." }))
    local reopened = assert(Session.new({ store = assert(storage.open(store:metadata().path, store:workspace_storage())) }))
    assert.are.same(session:messages(), reopened:messages())
    assert.are.equal(2, #reopened:messages())
  end)
end)
