local assert = require("luassert")
local async = require("neoagent.async")
local chat = require("neoagent.chat")
local config = require("neoagent.config")
local managers = require("neoagent.files.manager")
local models = require("neoagent.models")
local replay = require("neoagent.http_replay")
local runtimes_module = require("neoagent.provider_runtimes")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local util = require("neoagent.util")

local PNG = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAIAAAD4YuoOAAAAIklEQVR4nGP4z8BAEiJR+X9SlY9aMGrBqAWjFoxaMCAWAABQpv4QX+h4RQAAAABJRU5ErkJggg=="

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  if not vim.wait(10000, function() return run:is_done() end) then
    run:cancel()
    error("Recorded conversation did not complete")
  end
  return (assert(run:result()))
end

describe("captured managed-file conversations", function()
  local original_new = managers.new
  ---@type Neoagent.ProviderRuntimes?
  local runtimes
  ---@type Neoagent.HttpReplay?
  local scenario
  ---@type string?
  local directory
  ---@type Neoagent.Agent?
  local agent
  after_each(function()
    managers.new = original_new
    if agent then agent:destroy(); agent = nil end
    if runtimes then runtimes_module.destroy(runtimes); runtimes = nil end
    local completed = scenario
    if completed then completed.close(); scenario = nil end
    if directory then vim.fn.delete(directory, "rf"); directory = nil end
    config._reset()
    if completed then completed.assert_consumed() end
  end)

  ---@param entries (string|Neoagent.ReplayEntryOptions)[]
  ---@param uploads? boolean
  ---@return Neoagent.Model
  local function codex(entries, uploads)
    scenario = replay.new({ exchanges = entries })
    directory = vim.fn.tempname()
    local configured = config.setup({ default_registry = false, providers = { ["openai-codex"] = {
      api = "openai-codex-responses", base_url = "https://chatgpt.com/backend-api", auth = "openai-codex",
      file_uploads = uploads, models = { ["gpt-5.6-luna"] = { input = { "text", "image" }, responses_lite = true } },
    } } })
    local auth = require("tests.helpers.auth_manager").new(configured.auth.methods)
    assert(auth.store:write("openai-codex", { type = "oauth", access = "upload-replay-key", refresh = "unused",
      accountId = "account-replay", expires = util.now_ms() + 3600000 }))
    runtimes = assert(runtimes_module.compose(configured, { auth = auth, transport = scenario, startup = false }))
    return models.resolve("openai-codex", "gpt-5.6-luna", configured, auth, runtimes)
  end

  for _, failure in ipairs({ "missing content", "corrupt content", "inconsistent size" }) do
    it("rejects inline " .. failure .. " before sending a stored Codex conversation", function()
      local model = codex({}, false)
      local store = storage.new({ directory = assert(directory), cwd = vim.fn.getcwd() })
      local session = assert(Session.new({ store = store }))
      local image = require("tests.helpers.attachments").new(session:files()).image(vim.base64.decode(PNG))
      assert(session:append({ role = "user", content = { image } }))
      local retained = session:messages()
      local second = util.copy(image)
      if failure == "missing content" then
        assert.are.equal(0, vim.fn.delete(store:workspace_storage().directory .. "/files/" .. image.file_id .. "/content"))
      elseif failure == "corrupt content" then
        assert(require("neoagent.fs").write_all(
          store:workspace_storage().directory .. "/files/" .. image.file_id .. "/content", string.rep("x", image.bytes)))
      else
        second.bytes = second.bytes + 1
      end
      local result = wait(model:stream({ files = session:files(),
        messages = { { role = "user", content = { image, second } } } }))
      assert.is_false(result.ok)
      assert.matches(failure == "missing content" and "Attachment is missing"
        or failure == "corrupt content" and "content does not match" or "size does not match", assert(result.error).message)
      assert.are.same({}, assert(scenario).requests)
      assert.are.same(retained, session:messages())
    end)
  end

  for _, failure in ipairs({ "startup exception", "cancellation before await" }) do
    it("owns the file-capable Codex service through " .. failure, function()
      local cancelled = failure == "cancellation before await"
      local model = codex({})
      local owner = assert(assert(runtimes)["openai-codex"]).service
      local services = require("neoagent.provider_service")
      local underlying = require("neoagent.model").assert(rawget(model, "_model"))
      local original = underlying.stream
      ---@type Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>?
      local child
      underlying.stream = function(self, options)
        if not cancelled then error("synthetic Model startup failure") end
        child = original(self, options)
        assert(async.current()):cancel()
        return child
      end
      local run = model:stream({
        messages = { { role = "user", content = "Continue." } },
      })
      underlying.stream = original
      assert.is_true(run:is_done())
      local result = assert(run:result())
      assert.is_false(result.ok)
      if cancelled then
        assert.are.equal("cancelled", assert(result.error).kind)
        assert.is_false(assert(child):is_done())
        assert.is_false(services.operation_enabled(owner, { mutating = true }))
        assert.is_false(wait(assert(child)).ok)
      else
        assert.matches("synthetic Model startup failure", assert(result.error).message)
      end
      assert.are.same({}, assert(scenario).requests)
      assert.is_true(services.operation_enabled(owner, { mutating = true }))
    end)
  end

  it("commits an Agent's Codex tool attachment before uploading it and reuses it after restart", function()
    local entries = {}
    for index = 1, 7 do entries[index] = ("tests/recordings/openai-codex/tool-loop/%02d.yaml"):format(index) end
    scenario = replay.new({exchanges = entries})
    directory = vim.fn.tempname()
    local workspace = directory .. "/workspace"
    vim.fn.mkdir(workspace, "p")
    local store = storage.new({directory = directory, cwd = workspace})
    local session = assert(Session.new({store = store}))
    local reads = 0
    ---@type string?
    local file_id
    ---@async
    ---@param _ Neoagent.JsonObject
    ---@param ctx Neoagent.ToolContext<Neoagent.AgentToolEnvironment>
    local function read_tile(_, ctx)
      reads = reads + 1
      local files = assert(ctx.context).files
      assert.are.equal(session:files(), files)
      assert.are.equal(2, #session:messages())
      assert.are.equal("assistant", assert(session:messages()[2]).role)
      local file = assert(files.put(vim.base64.decode(PNG)))
      file_id = file.file_id
      assert.are.equal(1, #scenario.requests)
      return {content = {{type = "image", file_id = file.file_id, bytes = file.bytes,
        mime_type = "image/png", filename = "tile.png"}}}
    end
    ---@type Neoagent.Tool<Neoagent.AgentToolEnvironment>
    local tool = {name = "read_tile", description = "Read a generated image tile.",
      input_schema = {type = "object", properties = vim.empty_dict()},
      execute = read_tile}
    local configured = config.setup({
      default_registry = false, default_model = { provider = "openai-codex", model = "gpt-5.6-luna" },
      workspace_trust = false, sandbox = { enabled = false },
      persistence = { directory = directory, workspace_settings = false },
      agent_instructions = false, skills = false, compaction = false,
      tools = { tool }, system_prompt = "Inspect generated images using the provided tool.",
      providers = {["openai-codex"] = {
        api = "openai-codex-responses", base_url = "https://chatgpt.com/backend-api", auth = "openai-codex",
        models = {["gpt-5.6-luna"] = {input = {"text", "image"}, responses_lite = true}},
      }},
    })
    local auth = require("neoagent.auth").new({ methods = configured.auth.methods,
      store = require("neoagent.auth.store").new(directory .. "/credentials.json") })
    assert(auth.store:write("openai-codex", {type = "oauth", access = "upload-replay-key", refresh = "unused",
      accountId = "account-replay", expires = util.now_ms() + 3600000}))
    local function start()
      if agent then agent:destroy() end
      if runtimes then runtimes_module.destroy(runtimes) end
      runtimes = assert(runtimes_module.compose(configured, {auth = auth, transport = scenario, startup = false}))
      agent = require("neoagent.agent").from_config(configured, { auth = auth, runtimes = runtimes, session = session })
      return agent
    end
    local current = start()
    for index, prompt in ipairs({
      "Call read_tile once, then name the two colors from left to right. Reply with two words.",
      "Without calling tools again, name the two colors from the retained image. Reply with two words.",
    }) do
      if index == 2 then
        session = assert(Session.new({store = assert(storage.open(store:metadata().path, store:workspace_storage()))}))
        current = start()
      end
      local accepted, finished = 0, 0
      local unsubscribe = current:subscribe(function(publication)
        if publication.type == "submission_accepted" then
          accepted = accepted + 1
          assert.are.equal(prompt, publication.prompt)
          assert.is_string(publication.entry_id)
          local persisted = assert(Session.new({ store = assert(storage.open(store:metadata().path, store:workspace_storage())) }))
          local messages = persisted:messages()
          assert.are.equal(prompt, messages[#messages].content)
        elseif publication.type == "finish" then
          finished = finished + 1
        end
      end)
      local run, err = current:send(prompt)
      assert(run ~= true and run ~= nil, vim.inspect(err))
      local result = wait(run)
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.equal("red blue", assert(result.text):lower())
      assert.are.equal(1, reads)
      assert(vim.wait(1000, function() return finished == 1 end))
      assert.are.equal(1, accepted)
      assert.are.equal("idle", current:snapshot().context.state)
      assert.are.equal("succeeded", assert(current:snapshot().result).status)
      unsubscribe()
      local journal = assert(require("neoagent.fs").read(store:metadata().path))
      assert.is_nil((journal:find(PNG, 1, true)))
      assert.is_not_nil((journal:find(assert(file_id), 1, true)))
      assert.are.equal(1, #vim.fn.globpath(store:workspace_storage().directory .. "/provider-cache", "*/*.json", false, true))
    end
  end)

  for _, case in ipairs({
    { provider = "openai", base = "https://compatible.test/v1", reason = "a custom OpenAI endpoint" },
    { provider = "openai-codex", base = "https://compatible.test/v1", reason = "a custom Codex endpoint" },
    { provider = "anthropic", base = "https://compatible.test/v1", reason = "a custom Anthropic endpoint" },
    { provider = "deepseek", base = "https://compatible.test/v1", reason = "a custom DeepSeek endpoint" },
    { provider = "openai", base = "https://api.openai.com/v1", reason = "OpenAI with another protocol" },
    { provider = "openai-codex", base = "https://chatgpt.com/backend-api", reason = "Codex with another protocol" },
    { provider = "deepseek", base = "https://api.deepseek.com", reason = "DeepSeek Messages outside its protocol endpoint" },
    { provider = "deepseek", base = "https://api.deepseek.com/anthropic/v1", responses = true,
      reason = "DeepSeek Responses at its Messages endpoint" },
    { provider = "anthropic", base = "https://api.anthropic.com/v1", responses = true,
      reason = "Anthropic with another protocol" },
    { provider = "openai", auth = "openai-codex", base = "https://api.openai.com/v1",
      reason = "a credential method outside the upload contract" },
    { provider = "deepseek", base = "https://api.deepseek.com/anthropic/v1", override_url = "https://compatible.test/messages",
      reason = "a request URL override" },
    { provider = "deepseek", base = "https://api.deepseek.com/anthropic/v1", override_model = "compatible-vision",
      reason = "a request model override" },
    { provider = "deepseek", base = "https://api.deepseek.com/anthropic/v1", headers = { Authorization = "" },
      reason = "an empty authorization override" },
    { provider = "deepseek", base = "https://api.deepseek.com/anthropic/v1", headers = { ["x-api-key"] = "" },
      reason = "an empty Messages API key override" },
    { provider = "deepseek", base = "https://api.deepseek.com/anthropic/v1", headers = { ["x-api-key"] = "different-key" },
      reason = "conflicting Messages credentials" },
    { provider = "deepseek", base = "https://api.deepseek.com/anthropic/v1", headers = { Authorization = "Basic synthetic" },
      reason = "an unsupported authentication scheme" },
    { provider = "openai", base = "https://api.openai.com/v1", responses = true, headers = { ["OpenAI-Project"] = "" },
      reason = "an empty OpenAI project override" },
    { provider = "openai", base = "https://api.openai.com/v1", responses = true, headers = { ["OpenAI-Organization"] = "" },
      reason = "an empty OpenAI organization override" },
    { provider = "openai-codex", base = "https://chatgpt.com/backend-api", codex = true, responses = true,
      headers = { ["ChatGPT-Account-Id"] = "" }, reason = "an empty Codex account override" },
  }) do
    it("keeps stored images inline for " .. case.reason, function()
      local api = case.codex and "openai-codex-responses" or case.responses and "openai-responses" or "anthropic-messages"
      local folder = case.responses and "deepseek-responses" or "deepseek-anthropic"
      local exchange = replay.read(case.codex and "tests/recordings/openai-codex/codex-lite/09.yaml"
        or "tests/recordings/deepseek/" .. folder .. "/08.yaml")
      -- Adapt the captured inline exchange to a configured compatible route.
      -- Keep its actual protocol response and the first synthetic image turn.
      local body = vim.json.decode((assert(exchange.request.body)))
      if case.responses then body.input = vim.list_slice(body.input, 1, case.codex and 6 or 5)
      else body.messages = vim.list_slice(body.messages, 1, 4) end
      local model_id = body.model
      exchange.request.url = case.override_url or case.base .. (case.codex and "/codex/responses"
        or case.responses and "/responses" or "/messages")
      if case.override_model then body.model = case.override_model end
      exchange.request.body = vim.json.encode(body)
      local method = case.auth or case.provider
      ---@type table<string, string>
      local headers = { ["Content-Type"] = "application/json", Authorization = "Bearer upload-replay-key" }
      if case.responses then headers.Accept = "text/event-stream"
      else headers["anthropic-version"] = "2023-06-01" end
      if method == "anthropic" then
        headers.Authorization = nil
        headers["x-api-key"] = "upload-replay-key"
      elseif method == "openai-codex" then
        headers["ChatGPT-Account-Id"] = "account-replay"
        headers.originator = "neoagent"
        headers["OpenAI-Beta"] = "responses=experimental"
        headers["User-Agent"] = "neoagent"
      end
      if case.codex then headers["x-openai-internal-codex-responses-lite"] = "true" end
      for name, value in pairs(case.headers or {}) do headers[name] = value end
      exchange.request.headers = headers
      if case.headers then
        -- Replay the provider's captured authentication failure with the
        -- inline conversation request, leaving upload preparation unused.
        local rejected = replay.read("tests/recordings/" .. case.provider .. "/validation/upload-denied.yaml")
        exchange.body, exchange.chunks, exchange.response, exchange.terminal =
          rejected.body, rejected.chunks, rejected.response, rejected.terminal
      end
      scenario = replay.new({ exchanges = { { exchange = exchange } } })
      directory = vim.fn.tempname()
      -- Header-routing cases supply credentials through request options;
      -- configured Authentication otherwise takes precedence over them.
      local configured = config.setup({ default_registry = false, providers = { [case.provider] = {
        api = api, base_url = case.base, auth = not case.headers and method or nil,
        models = { [model_id] = { input = { "text", "image" },
          max_output_tokens = not case.codex and 1024 or nil, responses_lite = case.codex } },
      } } })
      local auth = require("tests.helpers.auth_manager").new(configured.auth.methods)
      if method == "openai-codex" then
        assert(auth.store:write(method, { type = "oauth", access = "upload-replay-key", refresh = "unused",
          accountId = "account-replay", expires = util.now_ms() + 3600000 }))
      else
        assert(auth.store:write(method, { type = "api_key", key = "upload-replay-key" }))
      end
      runtimes = assert(runtimes_module.compose(configured, { auth = auth, transport = scenario, startup = false }))
      local model = models.resolve(case.provider, model_id, configured, auth, runtimes)
      local store = storage.new({ directory = directory, cwd = vim.fn.getcwd() })
      local session = assert(Session.new({ store = store }))
      local image = require("tests.helpers.attachments").new(session:files()).image(vim.base64.decode(PNG))
      assert(session:append({ role = "user", content = "Inspect a generated two-color tile." }))
      assert(session:append({ role = "assistant", content = {
        { type = "toolCall", id = "call-generated-tile", name = "sample_tile", arguments = vim.empty_dict() },
      } }))
      assert(session:append({ role = "toolResult", toolCallId = "call-generated-tile", toolName = "sample_tile",
        content = { image, image } }))
      local retained = session:messages()
      local result = wait(chat.send(session, "Name the tile's two colors from left to right. Reply with two words.", {
        model = model, system_prompt = "Describe the provided image briefly.",
        model_options = { request_opts = { url = case.override_url, body = { model = case.override_model },
          headers = case.headers and headers or nil } },
      }))
      if case.headers then
        assert.is_false(result.ok)
        assert.matches(case.codex and "Invalid authorization token"
          or case.provider == "deepseek" and "Authentication Fails" or "Incorrect API key", assert(result.error).message)
      else
        assert.is_true(result.ok, vim.inspect(result.error))
        assert.are.equal("red blue", assert(result.text):lower())
      end
      assert.are.equal(1, #scenario.requests)
      assert.are.equal(0, #vim.fn.globpath(store:workspace_storage().directory .. "/provider-cache", "*/*.json", false, true))
      for index, message in ipairs(retained) do assert.are.same(message, session:messages()[index]) end
    end)
  end

  for _, case in ipairs({
    { provider = "openai-codex", model = "gpt-5.6-luna", api = "openai-codex-responses",
      base = "https://chatgpt.com/backend-api", exchanges = 9, stages = { "upload", "reuse", "restart", "disabled" } },
    { provider = "deepseek", model = "deepseek-v4-flash-vision-exp", api = "openai-completions",
      base = "https://api.deepseek.com", exchanges = 4, stages = { "upload", "restart" } },
    { provider = "openai", model = "gpt-5.6-luna", api = "openai-responses",
      base = "https://api.openai.com/v1", exchanges = 2, stages = { "quota-error" } },
    { provider = "anthropic", model = "claude-sonnet-5", api = "anthropic-messages",
      base = "https://api.anthropic.com/v1", exchanges = 9, stages = { "upload", "reuse", "restart", "repair", "disabled" } },
    { provider = "openai-codex", model = "gpt-5.6-luna", api = "openai-codex-responses", folder = "codex-lite", lite = true,
      base = "https://chatgpt.com/backend-api", exchanges = 9, stages = { "upload", "reuse", "restart", "disabled" } },
    { provider = "deepseek", model = "deepseek-v4-flash-vision-exp", api = "openai-responses", folder = "deepseek-responses",
      max_output_tokens = 1024, base = "https://api.deepseek.com", exchanges = 8,
      stages = { "upload", "restart", "missing", "disabled" } },
    { provider = "deepseek", model = "deepseek-v4-flash-vision-exp", api = "anthropic-messages", folder = "deepseek-anthropic",
      max_output_tokens = 1024, base = "https://api.deepseek.com/anthropic/v1", exchanges = 8,
      stages = { "upload", "restart", "missing", "disabled" } },
  }) do
    it("replays real " .. case.provider .. " " .. (case.folder or "managed-files") .. " conversation requests", function()
      local entries = {}
      for index = 1, case.exchanges do
        entries[#entries + 1] = ("tests/recordings/%s/%s/%02d.yaml"):format(case.provider, case.folder or "managed-files", index)
      end
      scenario = replay.new({ exchanges = entries })
      directory = vim.fn.tempname()
      managers.new = function(options)
        options.now = function() return 1700000000000 end
        return original_new(options)
      end
      local configured = config.setup({ default_registry = false, providers = { [case.provider] = {
        api = case.api, base_url = case.base, auth = case.provider,
        models = { [case.model] = { input = { "text", "image" },
          responses_lite = case.lite,
          max_output_tokens = case.max_output_tokens or (case.provider == "anthropic" and 1024 or nil) } },
      } } })
      local auth = require("tests.helpers.auth_manager").new(configured.auth.methods)
      if case.provider == "openai-codex" then
        assert(auth.store:write(case.provider, { type = "oauth", access = "upload-replay-key",
          refresh = "unused-refresh", accountId = "account-replay", expires = util.now_ms() + 3600000 }))
      else
        assert(auth.store:write(case.provider, { type = "api_key", key = "upload-replay-key" }))
      end
      local function start(uploads)
        if runtimes then runtimes_module.destroy(runtimes) end
        configured.providers[case.provider].file_uploads = uploads ~= false
        runtimes = assert(runtimes_module.compose(configured, { auth = auth, transport = scenario, startup = false }))
        return models.resolve(case.provider, case.model, configured, auth, runtimes)
      end
      local store = storage.new({ directory = directory, cwd = vim.fn.getcwd() })
      local session = assert(Session.new({ store = store }))
      local image = require("tests.helpers.attachments").new(session:files()).image(vim.base64.decode(PNG),
        "image/png", { filename = "synthetic-tile.png" })
      assert(session:append({ role = "user", content = "Inspect a generated two-color tile." }))
      assert(session:append({ role = "assistant", content = {
        { type = "toolCall", id = "call-generated-tile", name = "sample_tile", arguments = vim.empty_dict() },
      } }))
      assert(session:append({ role = "toolResult", toolCallId = "call-generated-tile", toolName = "sample_tile",
        content = { image, image } }))
      local initial = session:messages()
      local model = start()
      for _, stage in ipairs(case.stages) do
        if stage == "restart" then
          session = assert(Session.new({ store = assert(storage.open(store:metadata().path, store:workspace_storage())) }))
          model = start()
        elseif stage == "repair" or stage == "missing" then
          local path = assert(vim.fn.globpath(store:workspace_storage().directory .. "/provider-cache", "*/*.json", false, true)[1])
          local record = vim.json.decode((assert(require("neoagent.fs").read(path))))
          record.object.locator = stage == "repair" and "file_017AAAAAAAAAAAAAAAAAAAAA"
            or "file-api-00000000-0000-4000-8000-000000000000"
          assert(require("neoagent.fs").atomic_replace(path, vim.json.encode(record), {mode = 384}))
          model = start()
        elseif stage == "disabled" then model = start(false) end
        local result = wait(chat.send(session,
          "Name the tile's two colors from left to right. Reply with two words.",
          { model = model, system_prompt = "Describe the provided image briefly.",
            model_options = case.provider == "anthropic" and {request_opts = {body = {thinking = {type = "disabled"}}}} or nil }))
        if stage == "quota-error" then
          assert.is_false(result.ok)
          assert.matches("no credits remaining", assert(result.error).message)
        else
          assert.is_true(result.ok, vim.inspect(result.error))
          assert.are.equal(case.provider == "anthropic" and "blue, red" or "red blue", assert(result.text):lower())
        end
        for index, message in ipairs(initial) do assert.are.same(message, session:messages()[index]) end
      end
      local journal = assert(require("neoagent.fs").read(store:metadata().path))
      assert.is_nil((journal:find(PNG, 1, true)))
      assert.is_not_nil((journal:find(image.file_id, 1, true)))
      assert.are.equal(1, #vim.fn.globpath(store:workspace_storage().directory .. "/provider-cache", "*/*.json", false, true))
    end)
  end
end)
