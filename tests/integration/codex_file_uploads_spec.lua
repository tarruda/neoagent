local assert = require("luassert")
local chat = require("neoagent.chat")
local config = require("neoagent.config")
local fs = require("neoagent.fs")
local models = require("neoagent.models")
local replay = require("neoagent.http_replay")
local runtimes_module = require("neoagent.provider_runtimes")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local util = require("neoagent.util")

local PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII="

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe("Codex subscription file uploads", function()
  ---@type Neoagent.ProviderRuntimes?
  local runtimes
  ---@type Neoagent.HttpReplay?
  local scenario
  ---@type Neoagent.Recorder?
  local recorder
  ---@type string?
  local directory
  ---@type Neoagent.WorkspaceStorage?
  local workspace

  after_each(function()
    if runtimes then runtimes_module.destroy(runtimes); runtimes = nil end
    local completed = scenario
    if completed then completed.close(); scenario = nil end
    if recorder then recorder:destroy(); recorder = nil end
    if directory then vim.fn.delete(directory, "rf"); directory = nil end
    config._reset()
    if completed then completed.assert_consumed() end
  end)

  ---@param exchanges (string|Neoagent.ReplayEntryOptions)[]
  ---@param lite? boolean
  ---@param record? boolean
  ---@return Neoagent.Session
  ---@return fun(uploads?: boolean): Neoagent.Model
  ---@return string
  ---@return Neoagent.AuthManager
  local function conversation(exchanges, lite, record)
    local entries = {}
    for _, entry in ipairs(exchanges) do
      entries[#entries + 1] = type(entry) == "string"
        and { path = "tests/recordings/openai-codex/files/" .. entry .. ".yaml" } or entry
    end
    scenario = replay.new({ exchanges = entries })
    directory = vim.fn.tempname()
    local transport = scenario
    if record then
      recorder = assert(require("neoagent.http_recording").new({
        config = { enabled = true, retention = "all", format = "json" }, directory = directory .. "/recordings",
      }))
      transport = recorder:transport(scenario)
    end
    local configured = config.setup({ default_registry = false, providers = { ["openai-codex"] = {
      api = "openai-codex-responses", base_url = "https://chatgpt.com/backend-api", auth = "openai-codex",
      models = { ["gpt-5.6-sol"] = { input = { "text", "image" }, responses_lite = lite } },
    } } })
    local auth = require("tests.helpers.auth_manager").new(configured.auth.methods)
    assert(auth.store:write("openai-codex", { type = "oauth", access = "upload-replay-key", refresh = "unused-refresh",
      accountId = "account-replay", expires = util.now_ms() + 3600000 }))
    local function start(uploads)
      if uploads ~= nil then configured.providers["openai-codex"].file_uploads = uploads end
      if runtimes then runtimes_module.destroy(runtimes) end
      runtimes = assert(runtimes_module.compose(configured, { auth = auth, transport = transport, startup = false,
      }))
      return models.resolve("openai-codex", "gpt-5.6-sol", configured, auth, runtimes)
    end
    local store = storage.new({ directory = directory .. "/sessions", cwd = vim.fn.getcwd() })
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
    return session, start, assert(store:metadata().path), auth
  end

  ---@param session Neoagent.Session
  ---@param model Neoagent.Model
  ---@param prompt string
  local function send(session, model, prompt)
    local result = wait(chat.send(session, prompt, { model = model }))
    assert.is_true(result.ok, vim.inspect(result.error))
    assert.are.equal("One pixel.", result.text)
    assert.are.equal(50, assert(assert(result.message).usage).input)
  end

  for _, missing in ipairs({ false, true }) do
    it("resumes retained tool images with " .. (missing and "replacement of a deleted upload" or "fresh remote verification"), function()
      local exchanges = { "create", "put", "finalize", "conversation", "inspect", "reuse",
        missing and "inspect-missing" or "inspect" }
      if missing then vim.list_extend(exchanges, { "create-replacement", "put-replacement", "finalize-replacement" }) end
      exchanges[#exchanges + 1] = missing and "resume-replacement" or "resume"
      local session, start, path = conversation(exchanges)
      local model = start()
      send(session, model, "Describe the tile.")
      send(session, model, "Describe it again.")
      assert.are.equal(6, #assert(scenario).requests)
      local retained = session:messages()
      local resumed = assert(Session.new({ store = assert(storage.open(path, assert(workspace))) }))
      assert.are.same(retained, resumed:messages())
      send(resumed, start(), "Continue.")
      assert.are.equal(missing and 11 or 8, #assert(scenario).requests)
      for index, message in ipairs(retained) do assert.are.same(message, resumed:messages()[index]) end
      local cache_paths = vim.fn.globpath(assert(workspace).directory .. "/provider-cache", "*/*.json", false, true)
      assert.are.equal(1, #cache_paths)
      local cached = assert(fs.read(assert(cache_paths[1])))
      assert.is_nil((cached:find("upload-replay-key", 1, true)))
      assert.is_nil((cached:find("https://", 1, true)))
      assert.is_nil((cached:find(PNG, 1, true)))
    end)
  end

  it("prepares uploaded tool images for Responses Lite", function()
    local session, start = conversation({ "create", "put", "finalize", "conversation-lite" }, true)
    send(session, start(), "Describe the tile.")
  end)

  it("inlines stored images when uploads are disabled even after remote reuse was cached", function()
    local exchange = replay.read("tests/recordings/openai-codex/files/reuse.yaml")
    ---@param value unknown
    local function inline(value)
      if type(value) ~= "table" then return end
      if value.type == "input_image" then
        value.file_id = nil
        value.image_url = "data:image/png;base64," .. PNG
      else
        for _, child in pairs(value) do inline(child) end
      end
    end
    local body = vim.json.decode((assert(exchange.request.body)))
    inline(body)
    exchange.request.body = util.json_encode(body)
    local session, start = conversation({ "create", "put", "finalize", "conversation", { exchange = exchange } })
    send(session, start(), "Describe the tile.")
    local before = session:messages()
    send(session, start(false), "Describe it again.")
    assert.is_nil(assert(runtimes)["openai-codex"].files)
    assert.are.equal(5, #assert(scenario).requests)
    for index, message in ipairs(before) do assert.are.same(message, session:messages()[index]) end
    assert.are.equal(1, #vim.fn.globpath(assert(workspace).directory .. "/provider-cache", "*/*.json", false, true))
  end)

  it("reuses files across token rotation and separates ChatGPT accounts", function()
    ---@param name string
    ---@param account string
    ---@return Neoagent.ReplayEntryOptions
    local function rotated(name, account)
      local exchange = replay.read("tests/recordings/openai-codex/files/" .. name .. ".yaml")
      local headers = assert(exchange.request.headers)
      if rawget(headers, "Authorization") then
        rawset(headers, "Authorization", "Bearer rotated-replay-key")
        rawset(headers, "chatgpt-account-id", account)
      end
      return { exchange = exchange }
    end
    local session, start, _, auth = conversation({ "create", "put", "finalize", "conversation",
      rotated("inspect", "account-replay"), rotated("reuse", "account-replay"),
      rotated("create-replacement", "account-second"), rotated("put-replacement", "account-second"),
      rotated("finalize-replacement", "account-second"), rotated("resume-replacement", "account-second"),
    })
    local model = start()
    send(session, model, "Describe the tile.")
    assert(auth.store:write("openai-codex", { type = "oauth", access = "rotated-replay-key", refresh = "unused-refresh",
      accountId = "account-replay", expires = util.now_ms() + 3600000 }))
    send(session, model, "Describe it again.")
    assert.are.equal(6, #assert(scenario).requests)
    assert(auth.store:write("openai-codex", { type = "oauth", access = "rotated-replay-key", refresh = "unused-refresh",
      accountId = "account-second", expires = util.now_ms() + 3600000 }))
    send(session, model, "Continue.")
    assert.are.equal(10, #assert(scenario).requests)
    assert.are.equal(2, #vim.fn.globpath(assert(workspace).directory .. "/provider-cache", "*/*.json", false, true))
  end)

  it("waits for file finalization before inference", function()
    local session, start = conversation({ "create", "put", "finalize-retry", "finalize", "conversation" })
    send(session, start(), "Describe the tile.")
    assert.are.equal(5, #assert(scenario).requests)
  end)

  for _, stage in ipairs({ "upload", "inspection" }) do
    for _, ending in ipairs({ "failure", "cancellation" }) do
      it("isolates rotated credentials from overlapping " .. stage .. " " .. ending, function()
        local denied = replay.read("tests/recordings/openai-codex/validation/upload-denied.yaml")
        denied.request = replay.read("tests/recordings/openai-codex/files/"
          .. (stage == "upload" and "create" or "inspect") .. ".yaml").request
        ---@type (string|Neoagent.ReplayEntryOptions)[]
        local exchanges = stage == "inspection" and { "create", "put", "finalize", "conversation" } or {}
        exchanges[#exchanges + 1] = { exchange = denied, finish_after = { "release-old-credential" } }
        local names = stage == "upload" and { "create", "put", "finalize", "conversation" }
          or { "inspect", "reuse" }
        for _, name in ipairs(names) do
          local exchange = replay.read("tests/recordings/openai-codex/files/" .. name .. ".yaml")
          local headers = assert(exchange.request.headers)
          if rawget(headers, "Authorization") then rawset(headers, "Authorization", "Bearer rotated-replay-key") end
          exchanges[#exchanges + 1] = { exchange = exchange }
        end
        local session, start, _, auth = conversation(exchanges)
        local model = start()
        if stage == "inspection" then send(session, model, "Describe the tile.") end
        assert(session:append({ role = "user", content = stage == "upload" and "Describe the tile." or "Describe it again." }))
        local retained = session:messages()
        local options = { messages = assert(session:context_messages()), files = session:files(), file_cache = session:file_cache() }
        local first = model:stream(options)
        local started = stage == "upload" and 1 or 5
        assert(vim.wait(1000, function() return #assert(scenario).requests == started end))
        assert(auth.store:write("openai-codex", { type = "oauth", access = "rotated-replay-key", refresh = "unused-refresh",
          accountId = "account-replay", expires = util.now_ms() + 3600000 }))
        local second = model:stream(options)
        local independent = vim.wait(1000, function() return #assert(scenario).requests > started end)
        if ending == "cancellation" then first:cancel() end
        assert(scenario).release("release-old-credential")
        local old, current = wait(first), wait(second)
        assert.is_false(old.ok)
        assert.are.equal(ending == "cancellation" and "cancelled" or "files", assert(old.error).kind)
        assert.is_true(current.ok, "rotated credential inherited the old preparation: " .. vim.inspect(current.error))
        assert.is_true(independent, "rotated credential must prepare while the old operation is pending")
        assert.are.equal("One pixel.", current.text)
        assert.are.same(retained, session:messages())
        assert.are.equal(1, #vim.fn.globpath(assert(workspace).directory .. "/provider-cache", "*/*.json", false, true))
        assert.is_true(require("neoagent.provider_service").operation_enabled(
          assert(assert(runtimes)["openai-codex"]).service, { mutating = true }))
      end)
    end
  end

  for _, stage in ipairs({ "create", "put" }) do
    it("surfaces " .. stage .. " failures without dispatching or retrying inference", function()
      local session, start = conversation(stage == "create" and { "create-error" } or { "create", "put-error" })
      local result = wait(chat.send(session, "Describe the tile.", { model = start() }))
      assert.is_false(result.ok)
      assert.are.equal("files", assert(result.error).kind)
      assert.matches("Codex Files request failed", assert(result.error).message)
      assert.is_nil((assert(result.error).message:find("signature", 1, true)))
      assert.are.equal(stage == "create" and 1 or 2, #assert(scenario).requests)
      assert.are.equal(4, #session:messages())
    end)
  end

  it("records upload bytes while masking credentials and signed capability responses", function()
    local session, start = conversation({ "create", "put", "finalize", "conversation" }, false, true)
    send(session, start(), "Describe the tile.")
    assert(recorder):destroy()
    local paths = vim.fn.globpath(assert(directory) .. "/recordings", "**/*.jsonl", false, true)
    assert.are.equal(4, #paths)
    local masked, uploads, inference = 0, 0, 0
    for _, path in ipairs(paths) do
      local content = assert(fs.read(path))
      for _, secret in ipairs({ "upload-replay-key", "synthetic-upload-signature", "synthetic-download-signature" }) do
        assert.is_nil((content:find(secret, 1, true)))
      end
      ---@type Neoagent.RecordedEvent[]
      local events = {}
      for line in content:gmatch("[^\n]+") do events[#events + 1] = vim.json.decode(line) end
      local first = assert(events[1])
      assert(first.type == "exchange")
      local request = first.request
      for _, event in ipairs(events) do
        if event.type == "response_body" and event.redacted then
          masked = masked + 1
          assert.are.equal("*", event.body)
        end
      end
      if request.method == "PUT" then
        uploads = uploads + 1
        assert.are.equal(PNG, request.body)
        assert.are.equal("base64", request.body_encoding)
        assert.is_nil(assert(request.headers).Authorization)
        assert.is_nil(assert(request.headers)["chatgpt-account-id"])
      elseif request.url:match("/responses$") then
        inference = inference + 1
        assert(type(request.body) == "string")
        assert.matches("file%-tile", request.body)
        assert.matches("One pixel", content)
      end
    end
    assert.are.equal(2, masked)
    assert.are.equal(1, uploads)
    assert.are.equal(1, inference)
  end)
end)
