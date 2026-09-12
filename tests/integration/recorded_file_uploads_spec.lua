local assert = require("luassert")
local async = require("neoagent.async")
local chat = require("neoagent.chat")
local config = require("neoagent.config")
local fs = require("neoagent.fs")
local models = require("neoagent.models")
local replay = require("neoagent.http_replay")
local runtimes_module = require("neoagent.provider_runtimes")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local test_auth = require("tests.helpers.auth_manager")
local manager_module = require("neoagent.files.manager")
local original_manager_new = manager_module.new
local original_replace = fs.atomic_replace
local util = require("neoagent.util")

local PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII="
local CREATED_AT = 1700000000

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe("recorded conversations with uploaded images", function()
  ---@type Neoagent.ProviderRuntimes?
  local runtimes
  ---@type Neoagent.HttpReplay?
  local scenario
  ---@type string?
  local directory
  local now = CREATED_AT
  ---@type Neoagent.WorkspaceStorage?
  local workspace

  after_each(function()
    manager_module.new = original_manager_new
    fs.atomic_replace = original_replace
    if runtimes then runtimes_module.destroy(runtimes); runtimes = nil end
    local completed = scenario
    if completed then completed.close(); scenario = nil end
    if directory then vim.fn.delete(directory, "rf"); directory = nil end
    config._reset()
    if completed then completed.assert_consumed() end
  end)

  ---@param provider string
  ---@param exchanges (string|Neoagent.ReplayEntryOptions)[]
  ---@return Neoagent.Session
  ---@return fun(): Neoagent.Model
  ---@return string
  local function conversation(provider, exchanges)
    local entries = {}
    for _, name in ipairs(exchanges) do
      entries[#entries + 1] = type(name) == "string" and { path = "tests/recordings/" .. provider .. "/files/" .. name .. ".yaml" } or name
    end
    scenario = replay.new({ exchanges = entries })
    directory, now = vim.fn.tempname(), CREATED_AT
    local model_id = provider == "deepseek" and "deepseek-v4.1-flash-expires-on-0910" or "gpt-4.1"
    local configured = config.setup({ default_registry = false, providers = { [provider] = {
      api = provider == "deepseek" and "openai-completions" or "openai-responses",
      base_url = provider == "deepseek" and "https://api.deepseek.com" or "https://api.openai.com/v1",
      auth = provider,
      models = { [model_id] = { input = { "text", "image" } } },
    } } })
    local auth = test_auth.new(configured.auth.methods)
    assert.is_true(wait(auth:login(provider, { prompt = function(_, done) done.resolve("upload-replay-key") end })).ok)
    manager_module.new = function(options)
      options.now = function() return now * 1000 end
      return original_manager_new(options)
    end
    local function start()
      if runtimes then runtimes_module.destroy(runtimes) end
      runtimes = assert(runtimes_module.compose(configured, { auth = auth, transport = scenario, startup = false,
      }))
      -- Recorded object lifetimes use this fixed wall clock; preparation
      -- deadlines and asynchronous replay still use the real monotonic clock.
      return models.resolve(provider, model_id, configured, auth, runtimes)
    end
    local store = storage.new({ directory = assert(directory) .. "/sessions", cwd = vim.fn.getcwd() })
    workspace = store:workspace_storage()
    local session = assert(Session.new({ store = store }))
    local image = require("tests.helpers.attachments").new(session:files()).image(vim.base64.decode(PNG))
    assert(session:append({ role = "user", content = "Inspect the sample tile." }))
    assert(session:append({ role = "assistant", content = {
      { type = "toolCall", id = "call-tile", name = "sample_tile", arguments = vim.empty_dict() },
    } }))
    assert(session:append({ role = "toolResult", toolCallId = "call-tile", toolName = "sample_tile", content = {
      { type = "text", text = "Generated tile." },
      image,
      image,
    } }))
    return session, start, (assert(store:metadata().path))
  end

  ---@param session Neoagent.Session
  ---@param model Neoagent.Model
  ---@param prompt string
  local function send(session, model, prompt)
    local result = wait(chat.send(session, prompt, { model = model }))
    assert.is_true(result.ok, vim.inspect(result.error))
    assert.are.equal("One pixel.", result.text)
    assert.are.equal("stop", assert(result.message).stopReason)
    assert.are.equal(50, assert(assert(result.message).usage).input)
  end

  it("preserves received DeepSeek reasoning when an uploaded-image conversation is cancelled", function()
    local exchange = replay.read("tests/recordings/deepseek/files/conversation.yaml")
    -- Keep the captured protocol body; split playback after its reasoning
    -- event so cancellation happens before the text and completion arrive.
    local prefix = assert(exchange.body:match("^(.-\n\n.-\n\n)"))
    local remainder = exchange.body:sub(#prefix + 1)
    exchange.chunks = {
      { data = prefix, bytes = #prefix, at_us = 1000 },
      { data = remainder, bytes = #remainder, at_us = 1000000 },
    }
    local session, start = conversation("deepseek", { "upload", {
      exchange = exchange, gates = { ["2"] = { "release-after-cancellation" } },
    } })
    assert(session:append({ role = "user", content = "Describe the tile." }))
    local retained = session:messages()
    ---@type Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>?
    local run
    run = start():stream({ files = session:files(), messages = assert(session:context_messages()),
      on_event = function(event)
        if event.type == "thinking_delta" then assert(run):cancel() end
      end,
    })
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal("aborted", assert(result.message).stopReason)
    assert.are.same({ { type = "thinking", thinking = "I will inspect the tile.",
      thinkingSignature = "reasoning_content" } }, assert(result.message).content)
    assert.are.same(retained, session:messages())
    assert.are.equal(2, #assert(scenario).requests)
    assert.is_true(require("neoagent.provider_service").operation_enabled(
      assert(assert(runtimes).deepseek).service, { mutating = true }))
  end)

  for _, provider in ipairs({ "deepseek", "openai" }) do
    it("keeps the Session cache blocked through copied " .. provider .. " Model calls", function()
      local session, start = conversation(provider, {
        "upload", "conversation", "upload-after-expiry", "reuse-replacement",
      })
      local writes = 0
      local cache_path
      fs.atomic_replace = function(path, data, policy)
        local saved, identity, stage = original_replace(path, data, policy)
        if path:find("/provider-cache/", 1, true) then
          assert(saved)
          writes = writes + 1
          cache_path = path
          if writes == 1 then return nil, "synthetic uncertain cache publication", "sync" end
        end
        return saved, identity, stage
      end
      local first = wait(chat.run(session, "Describe the tile.", { model = start() }))
      assert.is_true(first.ok, vim.inspect(first.error))
      local original = vim.json.decode((assert(fs.read(assert(cache_path)))))
      local replacement = util.copy(original)
      replacement.generation = string.rep("b", 64)
      local cache = assert(session:file_cache())
      local owner = wait(async.run(function()
        return { ok = true, saved = cache:publish(replacement, original.generation) }
      end))

      now = CREATED_AT + 86400
      local second = wait(chat.run(session, "Describe it again.", { model = start() }))
      assert.is_true(second.ok, vim.inspect(second.error))
      assert.is_false(owner.saved, "the Session's cache must share the failed publication state")
      assert.are.equal(1, writes, "a new Model runtime must not bypass the blocked cache")
      assert.are.same(original, cache:read(original.key))
      assert.are.equal(4, #assert(scenario).requests)
    end)

    for _, missing in ipairs({ false, true }) do
      it("resumes " .. provider .. " tool images with " .. (missing and "a replacement for a missing file" or "a verified cached file"), function()
        ---@type (string|Neoagent.ReplayEntryOptions)[]
        local exchanges = { "upload", "conversation", "reuse" }
        if provider == "deepseek" then
          exchanges[#exchanges + 1] = missing and "inspect-missing" or "inspect"
        elseif missing then
          local rejected = replay.read("tests/recordings/openai/files/inference-missing.yaml")
          rejected.request = replay.read("tests/recordings/openai/files/resume.yaml").request
          exchanges[#exchanges + 1] = { exchange = rejected }
          exchanges[#exchanges + 1] = "inspect-missing"
        end
        if missing then exchanges[#exchanges + 1] = "upload-replacement" end
        exchanges[#exchanges + 1] = missing and "resume-replacement" or "resume"
        local session, start, path = conversation(provider, exchanges)
        local model = start()
        local retained = session:messages()
        send(session, model, "Describe the tile.")
        send(session, model, "Describe it again.")
        assert.are.equal(3, #assert(scenario).requests, "duplicate images and the next turn must reuse one upload")

        local original = session:messages()
        local resumed = assert(Session.new({ store = assert(storage.open(path, assert(workspace))) }))
        assert.are.same(original, resumed:messages())
        model = start()
        send(resumed, model, "Continue.")
        assert.are.equal(provider == "openai" and (missing and 7 or 4) or (missing and 6 or 5), #assert(scenario).requests)
        for index, message in ipairs(retained) do
          assert.are.same(message, resumed:messages()[index], "remote references must never replace local Session file IDs")
        end
      end)
    end

    it("reuploads expired " .. provider .. " images from the retained transcript", function()
      local session, start = conversation(provider, { "upload", "conversation", "upload-after-expiry", "reuse-replacement" })
      local model = start()
      send(session, model, "Describe the tile.")
      now = CREATED_AT + 86400
      send(session, model, "Describe it again.")
      assert.are.equal(4, #assert(scenario).requests)
    end)

    it("surfaces a recorded " .. provider .. " upload failure before inference", function()
      local session, start = conversation(provider, { "upload-error" })
      local result = wait(chat.send(session, "Describe the tile.", { model = start() }))
      assert.is_false(result.ok)
      assert.are.equal("files", assert(result.error).kind)
      assert.matches("HTTP 503", assert(result.error).message)
      assert.are.equal(1, #assert(scenario).requests)
      assert.are.equal(4, #session:messages(), "the accepted prompt must remain available for retry")
    end)
  end

  it("repairs an explicit OpenAI missing-image rejection through the HTTP decoder", function()
    local session, start = conversation("openai", {
      "upload", "conversation", "inference-missing", "inspect-missing", "upload-replacement", "reuse-replacement",
    })
    local model = start()
    send(session, model, "Describe the tile.")
    send(session, model, "Describe it again.")
    assert.are.equal(6, #assert(scenario).requests)
    assert.are.equal(7, #session:messages(), "the failed inference must not commit a duplicate assistant reply")
  end)

  it("replaces a deleted DeepSeek upload after frequent warm requests", function()
    local session, start = conversation("deepseek", {
      "upload", "conversation", "reuse", "inspect-missing", "upload-replacement", "resume-replacement",
    })
    local construct = manager_module.new
    manager_module.new = function(options)
      options.monotonic = function()
        return require("neoagent.files.wait").now() + (now - CREATED_AT) * 1000
      end
      return construct(options)
    end
    local model = start()
    send(session, model, "Describe the tile.")
    now = CREATED_AT + 240
    send(session, model, "Describe it again.")
    now = CREATED_AT + 480
    send(session, model, "Continue.")
    assert.are.equal(6, #assert(scenario).requests)
  end)

  it("stops missing-file recovery when the recorded OpenAI inspection is unauthorized", function()
    local session, start = conversation("openai", {
      "upload", "conversation", "inference-missing",
      { path = "tests/recordings/openai/validation/inspect-denied.yaml" },
    })
    local model = start()
    send(session, model, "Describe the tile.")
    local result = wait(chat.send(session, "Describe it again.", { model = model }))
    assert.is_false(result.ok)
    assert.matches("HTTP 401", assert(result.error).message)
    assert.are.equal(4, #assert(scenario).requests)
    assert.are.equal(6, #session:messages())
    local runtime = assert(assert(runtimes).openai)
    assert.is_true(require("neoagent.provider_service").operation_enabled(runtime.service, { mutating = true }))
  end)

  it("rejects unrepresentable expiry metadata during recorded missing-file recovery", function()
    local inspection = replay.read("tests/recordings/openai/files/inspect.yaml")
    local body = vim.json.decode(inspection.body)
    -- Negative adaptation: a finite JSON number whose millisecond epoch
    -- overflows must not make a remote reference usable indefinitely.
    body.expires_at = 1e308
    inspection.body = vim.json.encode(body)
    inspection.chunks = {{ data = inspection.body, bytes = #inspection.body, at_us = 1000 }}
    local session, start = conversation("openai", {
      "upload", "conversation", "inference-missing", { exchange = inspection },
    })
    local model = start()
    send(session, model, "Describe the tile.")
    local result = wait(chat.send(session, "Describe it again.", { model = model }))
    assert.is_false(result.ok)
    assert.are.equal("Invalid file inspection metadata", assert(result.error).message)
    assert.are.equal(4, #assert(scenario).requests)
    assert.are.equal(6, #session:messages())
    local runtime = assert(assert(runtimes).openai)
    assert.is_true(require("neoagent.provider_service").operation_enabled(runtime.service, { mutating = true }))
  end)

  for _, changed in ipairs({"status", "code", "type", "message"}) do
    it("does not replace DeepSeek files for a different inspection " .. changed, function()
      -- Deliberate negative variants of the captured missing-file response.
      local rejected = replay.read("tests/recordings/deepseek/files/inspect-missing.yaml")
      local body = vim.json.decode(rejected.body)
      if changed == "status" then rejected.response.status = 503
      else body.error[changed] = "synthetic unrelated inspection failure" end
      rejected.body = vim.json.encode(body)
      rejected.chunks = {{data = rejected.body, bytes = #rejected.body, at_us = 1000}}
      local session, start = conversation("deepseek", {"upload", "conversation", {exchange = rejected}})
      send(session, start(), "Describe the tile.")
      local result = wait(chat.send(session, "Continue.", {model = start()}))
      assert.is_false(result.ok)
      assert.matches("HTTP " .. (changed == "status" and "503" or "400"), assert(result.error).message)
      assert.are.equal(3, #assert(scenario).requests, "inspection errors must not trigger another upload or inference")
    end)
  end
end)
