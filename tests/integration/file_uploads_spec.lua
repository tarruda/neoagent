local assert = require("luassert")
local async = require("neoagent.async")
local config = require("neoagent.config")
local models = require("neoagent.models")
local runtimes_module = require("neoagent.provider_runtimes")
local test_auth = require("tests.helpers.auth_manager")
local util = require("neoagent.util")
local storage = require("neoagent.storage")
local attachment_fixture = require("tests.helpers.attachments")
local manager_module = require("neoagent.files.manager")
local original_manager_new = manager_module.new

local PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII="

---@generic T, E
---@param run Neoagent.Run<T, E>
---@param timeout? integer
---@return Neoagent.RunResult<T>
local function wait(run, timeout)
  if not vim.wait(timeout or 10000, function() return run:is_done() end) then
    run:cancel()
    assert(vim.wait(1000, function() return run:is_done() end), "Timed out cancelling provider image request")
    error("Provider image request did not complete")
  end
  return (assert(run:result()))
end

describe("transparent provider image uploads", function()
  ---@type Neoagent.ProviderRuntimes?
  local runtimes
  local directories = {}
  after_each(function()
    manager_module.new = original_manager_new
    if runtimes then runtimes_module.destroy(runtimes) end
    runtimes = nil
    for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
    directories = {}
    config._reset()
  end)

  ---@class Neoagent.TestUploadProvider
  ---@field model Neoagent.Model
  ---@field store Neoagent.SessionStore
  ---@field attachments Neoagent.AttachmentFixture
  ---@field manager? Neoagent.FileManager
  ---@field runtime Neoagent.ProviderRuntime
  ---@field configured Neoagent.Config<Neoagent.AgentToolEnvironment>
  ---@field auth Neoagent.AuthManager
  ---@field requests Neoagent.HttpRequest[]
  ---@field uploads integer
  ---@field upload_data string
  ---@field upload_mime string
  ---@field inspections integer
  ---@field credential_calls integer
  ---@field key string
  ---@field missing boolean
  ---@field expires number
  ---@field reject? string
  ---@field reject_again? boolean
  ---@field failed_http? boolean
  ---@field disconnect? boolean
  ---@field partial? boolean
  ---@field hold_upload? boolean
  ---@field upload_completions (fun())[]
  ---@field upload_cancelled integer
  ---@field transport Neoagent.ByteBackend
  ---@field directory string
  ---@field fetch_status? integer
  ---@field fetch_body? string
  ---@field body_limit integer

  ---@param provider_id string
  ---@param api string
  ---@param base? string
  ---@param model_id? string
  ---@param input? ("text"|"image")[]
  ---@return Neoagent.TestUploadProvider
  local function provider(provider_id, api, base, model_id, input)
    model_id = model_id or (provider_id == "deepseek" and "deepseek-v4-flash-vision-exp" or "gpt-4.1")
    base = base or (provider_id == "deepseek" and "https://api.deepseek.com" or "https://api.openai.com/v1")
    if api == "anthropic-messages" then
      base = provider_id == "anthropic" and "https://api.anthropic.com/v1" or "https://api.deepseek.com/anthropic/v1"
    end
    ---@type Neoagent.TestUploadProvider
    local state
    local configured = config.setup({ default_registry = false, providers = { [provider_id] = {
      api = api, base_url = base, auth = provider_id,
      api_key = function() state.credential_calls = state.credential_calls + 1; return state.key end,
      models = {
        [model_id] = { input = input or { "text", "image" } },
        ["compatible-vision"] = { input = { "text", "image" } },
      },
    } } })
    local auth = test_auth.new(configured.auth.methods)
    local requests = {}
    local directory = vim.fn.tempname()
    directories[#directories + 1] = directory
    ---@type Neoagent.ByteBackend
    local transport = {
      fetch = function(opts)
        return async.run(function()
          requests[#requests + 1] = util.copy(opts.request)
          if state.fetch_status then
            return { ok = true, status = state.fetch_status, headers = {}, body = state.fetch_body or "" }
          end
          if opts.request.method == "POST" then
            state.uploads = state.uploads + 1
            assert.is_not_nil((assert(opts.request.body):find(state.upload_data, 1, true)))
            if provider_id ~= "anthropic" then
              assert.is_not_nil((assert(opts.request.body):find('name="expires_after[seconds]"\r\n\r\n86400', 1, true)))
            end
            if state.hold_upload then
              async.await(function(done)
                state.upload_completions[#state.upload_completions + 1] = function() done.resolve(true) end
                return function() state.upload_cancelled = state.upload_cancelled + 1 end
              end)
            end
          else
            state.inspections = state.inspections + 1
            if state.missing then return { ok = true, status = 404, headers = {}, body = '{"error":{"message":"missing"}}' } end
          end
          if provider_id == "anthropic" then
            return {ok = true, status = 200, headers = {}, body = util.json_encode({type = "file",
              id = "file-synthetic-" .. state.uploads, size_bytes = #state.upload_data,
              mime_type = state.upload_mime, expires_at = vim.NIL})}
          end
          return { ok = true, status = 200, headers = {}, body = util.json_encode({
            object = "file", id = "file-synthetic-" .. state.uploads, bytes = #state.upload_data,
            purpose = provider_id == "openai" and "vision" or "user_data",
            expires_at = state.expires,
          }) }
        end)
      end,
      request = function(opts)
        return async.run(function()
          requests[#requests + 1] = util.copy(opts.request)
          if state.disconnect then return { ok = false, error = util.error("transport", "synthetic disconnect") } end
          if state.reject then
            local code = state.reject
            if not state.reject_again then state.reject = nil end
            if provider_id == "anthropic" then
              assert(opts.on_chunk)(util.json_encode({error = {type = code, message = "File `file-synthetic-1` not found."}}))
              return {ok = true, response = {status = 404, headers = {}}}
            end
            if state.partial then
              assert(opts.on_chunk)('data: {"type":"response.output_item.added","output_index":0,"item":{"id":"message-synthetic","type":"message","role":"assistant","content":[]}}\n\ndata: {"type":"response.output_text.delta","output_index":0,"delta":"partial"}\n\n')
              return { ok = false, error = { kind = "transport", message = "synthetic interrupted stream",
                response = { status = 400 }, detail = util.json_encode({ error = { code = code } }) } }
            end
            assert(opts.on_chunk)(util.json_encode({ error = { code = code, message = "synthetic rejection" } }))
            if state.failed_http then
              return { ok = false, error = { kind = "transport", message = "synthetic HTTP failure", response = { status = 400 } } }
            end
            return { ok = true, response = { status = 400, headers = {} } }
          end
          assert(#assert(opts.request.body) < state.body_limit)
          if api == "openai-responses" then
            assert(opts.on_chunk)('data: {"type":"response.completed","response":{"id":"response-synthetic","status":"completed","output":[{"type":"message","id":"message-synthetic","role":"assistant","content":[{"type":"output_text","text":"seen","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1}}}\n\n')
          elseif api == "anthropic-messages" then
            assert(opts.on_chunk)('data: {"type":"message_start","message":{"id":"message-synthetic","usage":{}}}\n\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"seen"}}\n\ndata: {"type":"content_block_stop","index":0}\n\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{}}\n\ndata: {"type":"message_stop"}\n\n')
          else
            assert(opts.on_chunk)('data: {"choices":[{"delta":{"content":"seen"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
          end
          return { ok = true, response = { status = 200, headers = {} } }
        end)
      end,
    }
    runtimes = assert(runtimes_module.compose(configured, { auth = auth, transport = transport, startup = false }))
    local store = storage.new({ directory = directory, cwd = vim.fn.getcwd() })
    manager_module.new = function(options)
      local manager = original_manager_new(options)
      state.manager = manager
      return manager
    end
    state = { store = store, attachments = attachment_fixture.new(store:files()), configured = configured, auth = auth, requests = requests, uploads = 0, inspections = 0,
      upload_data = vim.base64.decode(PNG), upload_mime = "image/png",
      credential_calls = 0, key = "ambient-key", missing = false, expires = os.time() + 86400, body_limit = 1024 * 1024,
      directory = directory, transport = transport, upload_cancelled = 0, upload_completions = {},
      runtime = assert(runtimes[provider_id]), model = models.resolve(provider_id, model_id, configured, auth, runtimes) }
    return state
  end

  ---@param state Neoagent.TestUploadProvider
  ---@return Neoagent.Message[]
  local function images(state)
    return { { role = "user", content = {
      { type = "text", text = "Inspect this synthetic pixel" },
      state.attachments.image(vim.base64.decode(PNG)),
    } } }
  end

  ---@param state Neoagent.TestUploadProvider
  local function outgoing(state)
    return vim.json.decode((assert(assert(state.requests[#state.requests]).body)))
  end

  it("reuses image preparation across copied conversation requests", function()
    local state = provider("deepseek", "openai-completions")
    local messages = assert(require("neoagent.semantic_message").normalize_list(images(state)))
    local digest = require("neoagent.files.digest")
    local original, hashes = digest.sha256, 0
    ---@async
    digest.sha256 = function(bytes)
      hashes = hashes + 1
      return original(bytes)
    end
    local ok, err = pcall(function()
      assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = messages })).ok)
      assert.are.equal(1, hashes)
      assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = util.copy(messages) })).ok)
      assert.are.equal(1, state.uploads)
      assert.are.equal("file-synthetic-1", outgoing(state).messages[1].content[2].file_id)
      assert.are.equal(1, hashes, "retained image bytes were hashed again before dispatch")
    end)
    digest.sha256 = original
    assert(ok, err)
  end)

  it("persists in-memory uploads when a later call binds the workspace cache", function()
    local state = provider("openai", "openai-responses")
    ---@type Neoagent.StreamOptions
    local options = {files = state.store:files(), messages = images(state)}
    assert.is_true(wait(state.model:stream(options)).ok)
    local manager = assert(state.manager)
    local key = assert(next(manager.records))
    assert.is_nil(state.store:file_cache():read(key))
    options.file_cache = state.store:file_cache()
    assert.is_true(wait(state.model:stream(options)).ok)
    assert.are.equal("file-synthetic-1", assert(state.store:file_cache():read(key)).object.locator)
    runtimes_module.destroy(assert(runtimes))
    runtimes = assert(runtimes_module.compose(state.configured, {auth = state.auth, transport = state.transport, startup = false}))
    local model = models.resolve("openai", "gpt-4.1", state.configured, state.auth, runtimes)
    assert.is_true(wait(model:stream(options)).ok)
    assert.are.equal(1, state.uploads)
    assert.are.equal(0, state.inspections)
  end)

  for _, binding in ipairs({ { "openai", "openai-responses" }, { "deepseek", "openai-completions" },
    { "deepseek", "openai-responses" }, { "deepseek", "anthropic-messages" }, { "anthropic", "anthropic-messages" } }) do
    it("uses native file references for " .. binding[1] .. " " .. binding[2], function()
      local state = provider(assert(binding[1]), assert(binding[2]))
      local result = wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) }))
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.equal("seen", result.text)
      assert.are.equal(1, state.uploads)
      assert.are.equal(1, state.credential_calls)
      local body = outgoing(state)
      if binding[2] == "openai-responses" then
        assert.are.equal("file-synthetic-1", body.input[1].content[2].file_id)
        assert.are.equal("auto", body.input[1].content[2].detail)
      elseif binding[2] == "anthropic-messages" then
        assert.are.same({ type = "file", file_id = "file-synthetic-1" }, body.messages[1].content[2].source)
        assert.are.equal(binding[1] == "deepseek" and "files-api-2025-04-14" or nil,
          rawget(assert(assert(state.requests[#state.requests]).headers), "anthropic-beta"))
      else
        assert.are.same({ type = "file", file_id = "file-synthetic-1" }, body.messages[1].content[2])
      end
    end)
  end

  it("repairs Anthropic file rejections once and leaves unrelated failures alone", function()
    local state = provider("anthropic", "anthropic-messages")
    local options = {files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state)}
    assert.is_true(wait(state.model:stream(options)).ok)
    state.missing, state.reject, state.reject_again = true, "not_found_error", true
    assert.is_false(wait(state.model:stream(options)).ok)
    assert.are.equal(2, state.uploads)
    assert.are.equal(1, state.inspections)
    state.reject = "permission_error"
    assert.is_false(wait(state.model:stream(options)).ok)
    assert.are.equal(2, state.uploads)
    assert.are.equal(1, state.inspections)
  end)

  it("keeps stored credentials authoritative and snapshots an ambient callback once", function()
    local state = provider("openai", "openai-responses")
    assert(state.auth.store:write("openai", { type = "api_key", key = "stored-key" }))
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state), request_opts = { headers = {
      ["OpenAI-Project"] = "project-synthetic", ["OpenAI-Organization"] = "organization-synthetic",
    } } })).ok)
    assert.are.equal(0, state.credential_calls)
    for _, request in ipairs(state.requests) do
      assert.are.equal("Bearer stored-key", rawget(assert(request.headers), "Authorization"))
      assert.are.equal("project-synthetic", rawget(assert(request.headers), "OpenAI-Project"))
    end
  end)

  it("isolates credential and project changes while retaining each call's authorization", function()
    local state = provider("openai", "openai-responses")
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
    state.key = "second-key"
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state), request_opts = {
      headers = { ["OpenAI-Project"] = "second-project" },
    } })).ok)
    assert.are.equal(3, state.uploads)
    assert.are.equal(3, state.credential_calls)
    for index, request in ipairs(state.requests) do
      assert.are.equal(index <= 2 and "Bearer ambient-key" or "Bearer second-key", rawget(assert(request.headers), "Authorization"))
    end
  end)

  it("preserves other Anthropic-compatible beta options and avoids duplicate Files flags", function()
    local state = provider("deepseek", "anthropic-messages")
    for _, beta in ipairs({ "synthetic-option", "synthetic-option,files-api-2025-04-14" }) do
      assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state), request_opts = {
        headers = { ["anthropic-beta"] = beta },
      } })).ok)
      assert.are.equal("synthetic-option,files-api-2025-04-14",
        rawget(assert(assert(state.requests[#state.requests]).headers), "anthropic-beta"))
    end
    assert.are.equal(1, state.uploads)
  end)

  for _, failure in ipairs({
    { status = 403, body = '{"error":{"message":"private provider response"}}', message = "HTTP 403" },
    { status = 200, body = "", message = "Files request failed" },
    { status = 200, body = '{"object":"file","id":"file-wrong","bytes":1,"purpose":"other"}', message = "invalid image metadata" },
  }) do
    it("stops before inference for Files failure: " .. failure.message, function()
      local state = provider("openai", "openai-responses")
      state.fetch_status, state.fetch_body = failure.status, failure.body
      local result = wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) }))
      assert.is_false(result.ok)
      assert.matches(failure.message, assert(result.error).message)
      assert.is_nil((assert(result.error).message:find("private provider response", 1, true)))
      assert.are.equal(1, #state.requests)
    end)
  end

  for _, id in ipairs({ "openai", "deepseek" }) do
    it("inlines managed images when " .. id .. " uploads are disabled", function()
      local state = provider(id, "openai-responses")
      state.configured.providers[id].file_uploads = false
      runtimes_module.destroy(assert(runtimes))
      runtimes = assert(runtimes_module.compose(state.configured, {
        auth = state.auth, transport = state.transport, startup = false,
      }))
      local model = models.resolve(id, state.model.id, state.configured, state.auth, assert(runtimes))
      local messages = images(state)
      assert.is_true(wait(model:stream({ files = state.store:files(),
        file_cache = state.store:file_cache(), messages = messages })).ok)
      assert.are.equal("data:image/png;base64," .. PNG, outgoing(state).input[1].content[2].image_url)
      assert.are.equal(0, state.uploads)
      assert.are.equal(0, state.inspections)
      assert.are.equal(1, #state.requests)
      assert.is_nil(assert(runtimes)[id].files)
    end)
  end

  for _, uploaded in ipairs({ false, true }) do
    it("bounds large inline Anthropic images " .. (uploaded and "after resuming an uploaded conversation" or "with uploads disabled"), function()
      if vim.fn.executable("magick") ~= 1 then
        pending("requires ImageMagick's magick executable")
        return
      end
      local state = provider("anthropic", "anthropic-messages", nil, "claude-sonnet-4-6")
      state.body_limit = 32 * 1000 * 1000
      local Session = require("neoagent.session")
      local session = assert(Session.new({ store = state.store }))
      assert.are.equal(1, vim.fn.mkdir(state.directory, "p"))
      local source = state.directory .. "/noise.png"
      -- A valid 2000 x 2000 RGB PNG with seeded, poorly compressible pixels.
      -- Generate it locally rather than retaining a multi-megabyte fixture.
      local generated = vim.system({ "python3", "-c", [[
import pathlib, random, struct, sys, zlib
size = 2000
pixels = random.Random(42).getrandbits(size * size * 3 * 8).to_bytes(size * size * 3, "little")
rows = b"".join(b"\0" + pixels[y * size * 3:(y + 1) * size * 3] for y in range(size))
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
pathlib.Path(sys.argv[1]).write_bytes(png)
]], source }, { timeout = 10000 }):wait()
      assert.are.equal(0, generated.code, generated.stderr)
      local input_size = assert(vim.uv.fs_stat(source)).size
      assert.is_true(input_size < 20 * 1024 * 1024)
      assert.is_true(4 * math.ceil(input_size / 3) > 10 * 1000 * 1000)
      local processed = wait(async.run(function()
        return { ok = true, value = require("neoagent.tools.read_file").execute({ path = "noise.png" }, {
          context = {
            workspace = require("neoagent.workspace").new({ root = state.directory, cwd = state.directory }),
            files = session:files(),
          },
          on_update = function() end,
        }) }
      end), 60000)
      assert.is_true(processed.ok, vim.inspect(processed.error))
      local image = assert(assert(processed.value).content[2])
      assert.are.equal("image", image.type)
      ---@cast image Neoagent.ImageBlock
      state.upload_data, state.upload_mime = state.attachments.read(image, 60000), image.mime_type
      assert(session:append({ role = "user", content = { { type = "text", text = "Inspect the noise." }, image } }))
      local retained = session:messages()
      if uploaded then
        local result = wait(state.model:stream({ files = session:files(), file_cache = session:file_cache(),
          messages = assert(session:context_messages()) }), 60000)
        assert.is_true(result.ok, vim.inspect(result.error))
        assert.are.equal("file", outgoing(state).messages[1].content[2].source.type)
        assert.are.equal(1, state.uploads)
      end
      assert.are.equal(0, vim.fn.delete(source))
      runtimes_module.destroy(assert(runtimes))
      state.configured.providers.anthropic.file_uploads = false
      runtimes = assert(runtimes_module.compose(state.configured, {
        auth = state.auth, transport = state.transport, startup = false,
      }))
      local model = models.resolve("anthropic", state.model.id, state.configured, state.auth, runtimes)
      local reopened = assert(Session.new({ store = assert(storage.open(state.store:metadata().path, state.store:workspace_storage())) }))
      local result = wait(model:stream({ files = reopened:files(), file_cache = reopened:file_cache(),
        messages = assert(reopened:context_messages()) }), 60000)
      assert.is_true(result.ok, vim.inspect(result.error))
      local inline = outgoing(state).messages[1].content[2].source
      assert.are.equal("base64", inline.type)
      assert.is_true(#inline.data <= 4.5 * 1024 * 1024,
        "inline image exceeds the conservative encoded budget: " .. #inline.data .. " bytes")
      assert.are.equal("image/jpeg", inline.media_type)
      assert.are.equal("noise.jpg", image.filename)
      assert.are.equal(state.upload_data, vim.base64.decode(inline.data))
      assert.are.equal(uploaded and 1 or 0, state.uploads)
      assert.are.equal(0, state.inspections)
      assert.are.same(retained, reopened:messages())
      assert.are.same(retained, session:messages())
    end)
  end

  it("reuses cached OpenAI images across compatible models and restarts without reading bytes", function()
    local state = provider("openai", "openai-responses")
    local messages = images(state)
    local opts = { files = state.store:files(), file_cache = state.store:file_cache(), messages = messages }
    assert.is_true(wait(state.model:stream(opts)).ok)
    local source = util.copy(opts.files)
    source.open = function() error("remote reuse must not read image bytes") end
    opts.files = source
    local compatible = models.resolve("openai", "compatible-vision", state.configured, state.auth, assert(runtimes))
    assert.is_true(wait(compatible:stream(opts)).ok)
    runtimes_module.destroy(assert(runtimes))
    runtimes = assert(runtimes_module.compose(state.configured, {
      auth = state.auth, transport = state.transport, startup = false,
    }))
    compatible = models.resolve("openai", "compatible-vision", state.configured, state.auth, assert(runtimes))
    assert.is_true(wait(compatible:stream(opts)).ok)
    assert.are.equal(1, state.uploads)
    assert.are.equal(0, state.inspections)
    assert.are.equal("file-synthetic-1", outgoing(state).input[1].content[2].file_id)
  end)

  it("keeps provider mappings independent while a conversation can still be sent inline", function()
    local first = provider("openai", "openai-responses")
    local messages = images(first)
    local opts = { files = first.store:files(), file_cache = first.store:file_cache(), messages = messages }
    assert.is_true(wait(first.model:stream(opts)).ok)
    runtimes_module.destroy(assert(runtimes))
    runtimes = nil
    local second = provider("deepseek", "openai-responses")
    assert.is_true(wait(second.model:stream(opts)).ok)
    local cache_dir = first.store:workspace_storage().directory .. "/provider-cache"
    assert.are.equal(2, #vim.fn.globpath(cache_dir, "*/*.json", false, true))
    assert.are.equal(1, first.uploads)
    assert.are.equal(1, second.uploads)
    local inline = require("neoagent.api.openai_responses").new({
      provider = "inline", model = "synthetic-vision", base_url = "https://inline.example/v1",
      input = { "text", "image" }, transport = second.transport,
    })
    assert.is_true(wait(inline:stream(opts)).ok)
    assert.are.equal("data:image/png;base64," .. PNG, outgoing(second).input[1].content[2].image_url)
    assert.are.equal(1, second.uploads)
    assert.are.same(messages, opts.messages)
  end)

  it("keeps identical images and cancellation independent across workspace producers", function()
    local state = provider("openai", "openai-responses")
    local first_messages = images(state)
    local second = storage.new({ directory = state.directory, cwd = state.directory })
    local image = attachment_fixture.new(second:files()).image(vim.base64.decode(PNG))
    state.hold_upload = true
    local first = state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = first_messages })
    local other = state.model:stream({ files = second:files(), file_cache = second:file_cache(),
      messages = { { role = "user", content = { image } } } })
    assert(vim.wait(1000, function() return #state.upload_completions == 2 end))
    assert.are.equal(2, state.uploads)
    first:cancel()
    assert.is_false(wait(first).ok)
    assert.is_false(other:is_done())
    assert(state.upload_completions[2])()
    assert.is_true(wait(other).ok)
    assert.are.equal(1, state.upload_cancelled)
    assert.are.equal(0, #vim.fn.globpath(state.store:workspace_storage().directory .. "/provider-cache", "*/*.json", false, true))
    assert.are.equal(1, #vim.fn.globpath(second:workspace_storage().directory .. "/provider-cache", "*/*.json", false, true))
  end)

  it("uploads an image filename with a supported extension before OpenAI inference", function()
    local state = provider("openai", "openai-responses")
    local request = assert(state.transport.request)
    state.transport.request = function(opts)
      local upload = assert(state.requests[1])
      if not assert(upload.body):find('filename="image.png"', 1, true) then
        -- Adapted from the 2026-09-08 live OpenAI rejection: Files accepts
        -- an extensionless name, but Responses rejects its image reference.
        return async.run(function()
          assert(opts.on_chunk)('{"error":{"type":"invalid_request_error","code":null,"param":"input","message":"Invalid input: Expected image type to be a supported format: .jpeg, .jpg, .png, .gif, .webp but got none."}}')
          return { ok = true, response = { status = 400, headers = {} } }
        end)
      end
      return request(opts)
    end
    local result = wait(state.model:stream({ files = state.store:files(),
      file_cache = state.store:file_cache(), messages = images(state) }))
    assert.is_true(result.ok, vim.inspect(result.error))
    assert.are.equal(1, state.uploads)
  end)

  it("blocks direct Model access during exclusive provider management", function()
    local state = provider("openai", "openai-responses")
    local release = assert(require("neoagent.provider_service").begin_operation(state.runtime.service, { mutating = true }))
    local result = wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) }))
    release:finish()
    assert.is_false(result.ok)
    assert.are.equal(0, state.credential_calls)
    assert.are.same({}, state.requests)
  end)

  it("reuses persisted uploads after runtime verification and replaces deleted objects", function()
    local state = provider("deepseek", "openai-completions")
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
    local manager = assert(state.manager)
    manager.records, manager.validated = {}, {}
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
    assert.are.equal(1, state.inspections)
    assert.are.equal(1, state.uploads)
    manager.records, manager.validated = {}, {}
    state.missing = true
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
    assert.are.equal(2, state.uploads)
    assert.are.equal("file-synthetic-2", outgoing(state).messages[1].content[2].file_id)
  end)

  it("repairs an explicit OpenAI missing-file rejection once without reshaping", function()
    local state = provider("openai", "openai-responses")
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
    state.reject, state.missing = "image_file_not_found", true
    state.failed_http = true
    local calls = 0
    local result = wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state), request_opts = function()
      calls = calls + 1
      return { body = { metadata = { marker = "same-shaped-request" } } }
    end }))
    assert.is_true(result.ok, vim.inspect(result.error))
    assert.are.equal(1, calls)
    assert.are.equal(2, state.credential_calls)
    assert.are.equal(2, state.uploads)
    assert.are.equal("file-synthetic-2", outgoing(state).input[1].content[2].file_id)
  end)

  it("does not repair unrelated provider rejections", function()
    local state = provider("openai", "openai-responses")
    state.reject = "invalid_request_error"
    assert.is_false(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
    assert.are.equal(1, state.uploads)
    assert.are.equal(2, #state.requests)
  end)

  it("surfaces a disconnect without assuming inference can be replayed", function()
    local state = provider("openai", "openai-responses")
    state.disconnect = true
    local result = wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) }))
    assert.is_false(result.ok)
    assert.matches("synthetic disconnect", assert(result.error).message)
    assert.are.equal(1, state.uploads)
    assert.are.equal(2, #state.requests)
  end)

  it("bounds missing-file recovery to one inference retry", function()
    local state = provider("openai", "openai-responses")
    state.reject, state.reject_again, state.missing = "image_file_not_found", true, true
    assert.is_false(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
    assert.are.equal(2, state.uploads)
    assert.are.equal(5, #state.requests)
    assert.are.equal(1, state.credential_calls)
  end)

  it("does not replay inference after emitting partial output", function()
    local state = provider("openai", "openai-responses")
    state.reject, state.partial = "image_file_not_found", true
    local events = {}
    local result = wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state), on_event = function(event) events[#events + 1] = event end }))
    assert.is_false(result.ok)
    assert.matches("partial", vim.inspect(events))
    assert.are.equal(1, state.uploads)
    assert.are.equal(2, #state.requests)
  end)

  it("holds direct Model and producer use through shared upload cancellation", function()
    local state = provider("openai", "openai-responses")
    state.hold_upload = true
    local first = state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })
    local second = state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })
    local manager = assert(state.manager)
    assert(vim.wait(2000, function()
      local _, producer = next(manager.operations)
      return producer ~= nil and producer.waiters == 2 and #state.upload_completions > 0
    end))
    local service = state.runtime.service
    local services = require("neoagent.provider_service")
    assert.is_false(services.operation_enabled(service, { mutating = true }))
    first:cancel()
    assert.is_false(wait(first).ok)
    assert.are.equal(0, state.upload_cancelled)
    assert.is_false(services.operation_enabled(service, { mutating = true }))
    assert(state.upload_completions[1])()
    assert.is_true(wait(second).ok)
    assert.are.equal(1, state.uploads)
    assert.are.equal(2, #state.requests)
    assert(vim.wait(2000, function() return services.operation_enabled(service, { mutating = true }) end))
  end)

  it("resumes durable image snapshots after runtime restart and local source removal", function()
    local state = provider("deepseek", "openai-completions")
    local Session, storage = require("neoagent.session"), require("neoagent.storage")
    vim.fn.mkdir(state.directory, "p")
    local source = state.directory .. "/source.png"
    assert(require("neoagent.fs").atomic_replace(source, vim.base64.decode(PNG), { mode = 384 }))
    local store = storage.new({ directory = state.directory, cwd = vim.fn.getcwd() })
    local session = assert(Session.new({ store = store }))
    assert(session:append(assert(images(state)[1])))
    local original = session:messages()
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = assert(session:context_messages()) })).ok)
    assert.are.equal(0, vim.fn.delete(source))
    runtimes_module.destroy(assert(runtimes))
    runtimes = assert(runtimes_module.compose(state.configured, { auth = state.auth,
      transport = state.transport, startup = false,
    }))
    local reopened = assert(Session.new({ store = assert(storage.open(assert(store:metadata().path), store:workspace_storage())) }))
    assert.are.equal(1, state.uploads)
    assert.are.equal(0, state.inspections)
    local resumed = models.resolve("deepseek", "deepseek-v4-flash-vision-exp", state.configured, state.auth, assert(runtimes))
    assert.is_true(wait(resumed:stream({ files = reopened:files(), file_cache = reopened:file_cache(), messages = assert(reopened:context_messages()) })).ok)
    assert.are.equal(1, state.inspections)
    assert.are.equal(1, state.uploads)
    assert.are.same(original, reopened:messages())
  end)

  it("uploads resumed tool images for a configured DeepSeek vision model outside the seed catalog", function()
    -- The reported 413 came from this configured model being excluded by an
    -- exact-name upload check. All messages and image bytes here are synthetic.
    local state = provider("deepseek", "openai-completions", nil, "deepseek-v4.1-flash-expires-on-0910")
    local Session, storage = require("neoagent.session"), require("neoagent.storage")
    local store = storage.new({ directory = state.directory, cwd = vim.fn.getcwd() })
    local session = assert(Session.new({ store = store }))
    assert(session:append({ role = "user", content = "Inspect the generated samples" }))
    assert(session:append({ role = "assistant", content = {
      { type = "toolCall", id = "call-synthetic", name = "read", arguments = {} },
    } }))
    ---@type Neoagent.InputBlock[]
    local content = {}
    for _ = 1, 32 do content[#content + 1] = state.attachments.image(vim.base64.decode(PNG)) end
    assert(session:append({ role = "toolResult", toolCallId = "call-synthetic", toolName = "read", content = content }))
    local reopened = assert(Session.new({ store = assert(storage.open(assert(store:metadata().path), store:workspace_storage())) }))
    assert(reopened:append({ role = "user", content = "Describe the sample images" }))
    local original = reopened:messages()
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = assert(reopened:context_messages()) })).ok)
    assert.are.equal(1, state.uploads)
    assert.are.equal(1, state.credential_calls)
    local references = 0
    for _, message in ipairs(outgoing(state).messages) do
      if type(message.content) == "table" then
        for _, block in ipairs(message.content) do
          assert.are_not.equal("image_url", block.type)
          if block.type == "file" then
            references = references + 1
            assert.are.equal("file-synthetic-1", block.file_id)
          end
        end
      end
    end
    assert.are.equal(32, references)
    assert.are.same(original, reopened:messages())
  end)

  it("does not upload images for a configured text-only DeepSeek model", function()
    local state = provider("deepseek", "openai-completions", nil, "deepseek-v4-flash", { "text" })
    assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
    assert.are.equal(0, state.uploads)
    assert.are.equal(1, #state.requests)
  end)

  for _, api in ipairs({ "openai-responses", "openai-completions", "anthropic-messages" }) do
    it("preserves tool image role adaptation through " .. api, function()
      local state = provider("deepseek", api)
      ---@type Neoagent.Message[]
      local messages = {
        { role = "user", content = "Inspect the tool image" },
        { role = "assistant", content = { { type = "toolCall", id = "call-synthetic", name = "read", arguments = {} } } },
        { role = "toolResult", toolCallId = "call-synthetic", toolName = "read", content = {
          { type = "text", text = "before image" }, state.attachments.image(vim.base64.decode(PNG)),
          { type = "text", text = "after image" },
        } },
      }
      local original = util.copy(messages)
      assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = messages })).ok)
      local body = outgoing(state)
      if api == "openai-responses" then
        assert.are.equal("before image\nafter image", body.input[3].output[1].text)
        assert.are.equal("file-synthetic-1", body.input[3].output[2].file_id)
      elseif api == "anthropic-messages" then
        local content = body.messages[3].content[1].content
        assert.are.equal("before image", content[1].text)
        assert.are.equal("file-synthetic-1", content[2].source.file_id)
        assert.are.equal("after image", content[3].text)
      else
        assert.are.equal("tool", body.messages[3].role)
        assert.are.equal("user", body.messages[4].role)
        assert.are.equal("file-synthetic-1", body.messages[4].content[2].file_id)
      end
      assert.are.same(original, messages)
      assert.are.equal(1, state.uploads)
    end)
  end

  it("prepares only images surviving final request shaping", function()
    local state = provider("openai", "openai-responses")
    local result = wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state), request_opts = function()
      return { messages = { { role = "user", content = "text only" } } }
    end }))
    assert.is_true(result.ok)
    assert.are.equal(0, state.uploads)
  end)

  for _, override in ipairs({ { url = "https://gateway.example/responses" }, { body = { model = "different-model" } } }) do
    it("keeps rewritten inference targets inline", function()
      local state = provider("openai", "openai-responses")
      assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state), request_opts = override })).ok)
      assert.are.equal(0, state.uploads)
      assert.are.equal("data:image/png;base64," .. PNG, outgoing(state).input[1].content[2].image_url)
    end)
  end

  it("rejects encoded-message overrides before preparing any files", function()
    local state = provider("deepseek", "openai-responses")
    local result = wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(),
      messages = images(state), request_opts = { body = { input = {} } } }))
    assert.is_false(result.ok)
    assert.matches("encoder%-owned", assert(result.error).message)
    assert.are.equal(0, state.uploads)
    assert.are.same({}, state.requests)
  end)

  for _, binding in ipairs({ { "openai", "openai-completions", "https://api.openai.com/v1" },
    { "openai", "openai-responses", "https://gateway.example/v1" } }) do
    it("keeps unsupported access inline: " .. binding[2] .. " at " .. binding[3], function()
      local state = provider(assert(binding[1]), assert(binding[2]), assert(binding[3]))
      assert.is_true(wait(state.model:stream({ files = state.store:files(), file_cache = state.store:file_cache(), messages = images(state) })).ok)
      assert.are.equal(0, state.uploads)
      assert.are.equal(1, #state.requests)
    end)
  end

  it("fits image history below the wire limit without changing retained messages", function()
    local configured = config.setup({ default_registry = false, providers = {
      deepseek = {
        api = "openai-completions", base_url = "https://api.deepseek.com",
        auth = "deepseek", models = {
          ["deepseek-v4-flash-vision-exp"] = { input = { "text", "image" } },
        },
      },
    } })
    local auth = test_auth.new(configured.auth.methods)
    assert(auth.store:write("deepseek", { type = "api_key", key = "synthetic-upload-key" }))
    local uploads, requests = 0, 0
    ---@type Neoagent.ByteBackend
    local transport = {
      fetch = function(opts)
        return async.run(function()
          assert.are.equal("Bearer synthetic-upload-key", rawget(assert(opts.request.headers), "Authorization"))
          uploads = uploads + 1
          return { ok = true, status = 200, headers = {}, body = util.json_encode({
            object = "file", id = "file-api-synthetic", bytes = #vim.base64.decode(PNG),
            purpose = "user_data", created_at = os.time(), expires_at = os.time() + 86400,
          }) }
        end)
      end,
      request = function(opts)
        return async.run(function()
          requests = requests + 1
          if #assert(opts.request.body) > 1500 then
            return { ok = false, error = util.error("transport", "synthetic request body limit exceeded") }
          end
          local body = vim.json.decode((assert(opts.request.body)))
          assert.are.equal("file-api-synthetic", body.messages[1].content[1].file_id)
          assert(opts.on_chunk)('data: {"choices":[{"delta":{"content":"seen"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
          return { ok = true, response = { status = 200, headers = {} } }
        end)
      end,
    }
    local directory = vim.fn.tempname()
    directories[#directories + 1] = directory
    runtimes = assert(runtimes_module.compose(configured, { auth = auth, transport = transport, startup = false }))
    local store = storage.new({ directory = directory, cwd = vim.fn.getcwd() })
    local attachments = attachment_fixture.new(store:files())
    local model = models.resolve("deepseek", "deepseek-v4-flash-vision-exp", configured, auth, runtimes)
    ---@type Neoagent.InputBlock[]
    local content = {}
    for _ = 1, 12 do content[#content + 1] = attachments.image(vim.base64.decode(PNG)) end
    ---@type Neoagent.Message[]
    local messages = { { role = "user", content = content } }
    local original = util.copy(messages)
    local result = wait(model:stream({ messages = messages, files = store:files(), file_cache = store:file_cache() }))
    assert.is_true(result.ok, vim.inspect(result.error))
    assert.are.equal("seen", result.text)
    assert.is_true(wait(model:stream({ messages = messages, files = store:files(), file_cache = store:file_cache() })).ok)
    assert.are.equal(1, uploads)
    assert.are.equal(2, requests)
    assert.are.same(original, messages)
  end)
end)
