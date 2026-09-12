local assert = require("luassert")
local async = require("neoagent.async")
local config = require("neoagent.config")
local fs = require("neoagent.fs")
local http_backend = require("neoagent.files.http_backend")
local managers = require("neoagent.files.manager")
local objects = require("neoagent.files.object")
local replay = require("neoagent.http_replay")
local service = require("neoagent.provider_service")
local util = require("neoagent.util")
local workspace_storage = require("neoagent.workspace_storage")
local PNG = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAIAAAD4YuoOAAAAIklEQVR4nGP4z8BAEiJR+X9SlY9aMGrBqAWjFoxaMCAWAABQpv4QX+h4RQAAAABJRU5ErkJggg=="

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  if not vim.wait(5000, function() return run:is_done() end) then run:cancel(); error("File lifecycle did not settle") end
  return (assert(run:result()))
end

---@class Neoagent.RecordedFileLifecycle
---@field manager Neoagent.FileManager
---@field backend Neoagent.FileBackend
---@field asset Neoagent.FileAsset
---@field access Neoagent.FileAccess
---@field workspace Neoagent.WorkspaceStorage
---@field service Neoagent.ProviderService
---@field scenario Neoagent.HttpReplay
---@field get fun(): Neoagent.Run<Neoagent.FileRecord, nil>

describe("recorded file lifecycle", function()
  local atomic_replace = fs.atomic_replace
  ---@type Neoagent.RecordedFileLifecycle[]
  local fixtures = {}
  after_each(function()
    fs.atomic_replace = atomic_replace
    for _, f in ipairs(fixtures) do
      f.manager:retire()
      assert(vim.wait(5000, function() return f.manager.active == 0 end))
      assert.is_true(service.operation_enabled(f.service, { mutating = true }))
      f.scenario.close()
      vim.fn.delete(f.workspace.directory, "rf")
    end
    config._reset()
    local completed = fixtures
    fixtures = {}
    for _, f in ipairs(completed) do f.scenario.assert_consumed() end
  end)

  ---@param provider string
  ---@param entries (string|Neoagent.ReplayEntryOptions)[]
  ---@return Neoagent.RecordedFileLifecycle
  local function fixture(provider, entries)
    local configured = config.setup({ default_registry = false })
    local auth = require("tests.helpers.auth_manager").new(configured.auth.methods)
    local codex = provider == "openai-codex"
    assert(auth.store:write(provider, codex and {type = "oauth", access = "upload-replay-key", refresh = "unused",
      accountId = "account-replay", expires = util.now_ms() + 3600000} or {type = "api_key", key = "upload-replay-key"}))
    local bound = wait(auth:resolve(provider))
    assert.is_true(bound.ok)
    local request = require("neoagent.api.request_opts").apply({url = "https://api.test", body = {}}, bound.request_opts,
      {model = require("tests.helpers.fake_model").new(), messages = {}, tools = {}})
    local headers = {}
    for name, value in pairs(request.headers or {}) do
      if provider == "anthropic" then
        if name:lower() == "x-api-key" then headers["x-api-key"] = value
        elseif name:lower() == "authorization" then headers["x-api-key"] = value:match("^Bearer (.+)$") end
      elseif name:lower() == "authorization" or name:lower() == "chatgpt-account-id" then headers[name] = value end
    end
    if provider == "anthropic" then headers["anthropic-version"] = "2023-06-01" end
    local scenario = replay.new({exchanges = entries})
    local workspace = workspace_storage.new(vim.fn.tempname())
    local image = require("tests.helpers.attachments").new(workspace.files).image(vim.base64.decode(PNG))
    local backend = codex and require("neoagent.providers.codex.files").new({transport = scenario})
      or provider == "anthropic" and require("neoagent.providers.anthropic.files").new({transport = scenario}) or http_backend.new({
      url = provider == "openai" and "https://api.openai.com/v1/files" or "https://api.deepseek.com/files",
      purpose = provider == "openai" and "vision" or "user_data", transport = scenario,
    })
    ---@type Neoagent.ProviderService
    local owner = { id = "files", name = "Files", operations = {}, state = function() return false end }
    local manager = managers.new({backend = backend, scope = workspace.files.identity, store = workspace.file_cache,
      now = function() return 1700000000000 end, acquire = function() return service.acquire_use(owner) end})
    local asset = {source = workspace.files, file_id = image.file_id, bytes = image.bytes, mime_type = image.mime_type}
    local access = {storage_scope = "recorded-account", headers = headers}
    ---@type Neoagent.RecordedFileLifecycle
    local f = {manager = manager, backend = backend, scenario = scenario, workspace = workspace, service = owner,
      asset = asset, access = access,
      get = function() return async.run(function() return manager:get(asset, access, manager.monotonic() + 4000) end) end}
    fixtures[#fixtures + 1] = f
    return f
  end

  for _, provider in ipairs({"openai", "deepseek", "openai-codex", "anthropic"}) do
    it("rejects the recorded " .. provider .. " upload authentication failure without caching it", function()
      local f = fixture(provider, {"tests/recordings/" .. provider .. "/validation/upload-denied.yaml"})
      local result = wait(f.get())
      assert.is_false(result.ok)
      assert.matches(provider == "anthropic" and "HTTP 404" or "HTTP 401", assert(result.error).message)
      assert.are.same({}, f.manager.records)
      assert.are.equal(0, #vim.fn.globpath(f.workspace.directory .. "/provider-cache", "*/*.json", false, true))
      assert.are.equal(1, #f.scenario.requests)
    end)
  end

  for _, provider in ipairs({ "openai", "deepseek", "openai-codex", "anthropic" }) do
    for _, failure in ipairs({ "corrupt bytes", "mismatched size" }) do
      it("rejects local " .. failure .. " before sending a " .. provider .. " upload", function()
        local f = fixture(provider, {})
        if failure == "corrupt bytes" then
          local path = fs.join(f.workspace.directory, "files", f.asset.file_id, "content")
          assert(fs.write_all(path, string.rep("x", f.asset.bytes)))
        else
          f.asset.bytes = f.asset.bytes + 1
        end
        local result = wait(f.get())
        assert.is_false(result.ok)
        assert.matches(failure == "corrupt bytes" and "content does not match" or "size does not match",
          assert(result.error).message)
        assert.are.same({}, f.scenario.requests)
        assert.are.same({}, f.manager.records)
      end)
    end
  end

  it("rejects file preparation while an exclusive Service operation holds the provider", function()
    local f = fixture("openai", {})
    local operation = assert(service.begin_operation(f.service, { mutating = true }))
    local messages = {{ role = "user", content = {{ type = "image", file_id = f.asset.file_id,
      mime_type = f.asset.mime_type, bytes = f.asset.bytes }} }}
    local dependencies = { messages = messages, files = f.workspace.files }
    local plan = require("neoagent.api.openai_responses").new({
      provider = "openai", model = "gpt-4.1", base_url = "https://api.openai.com/v1",
    }):_request(dependencies)
    local images = require("neoagent.files.request").new(function() return f.manager end, {
      api = "openai-responses", bind = function() return f.access end,
      accepts = function() return true end, max_file_bytes = 1024,
    })
    local result = wait(require("neoagent.api.request_stream").send(
      require("neoagent.transport.http").new(f.scenario), plan, dependencies,
      { on_event = function() error("exclusive provider must not start inference") end }, images))
    operation:finish()
    assert.is_false(result.ok)
    assert.matches("Cannot acquire provider use during a mutating provider operation", assert(result.error).message)
    assert.are.same({}, f.scenario.requests)
    assert.are.same({}, f.manager.records)
    assert.is_true(service.operation_enabled(f.service, { mutating = true }))
  end)

  it("reads actual OpenAI metadata and recognizes its missing-object response", function()
    local f = fixture("openai", {"tests/recordings/openai/validation/inspect.yaml",
      "tests/recordings/openai/validation/inspect-missing.yaml"})
    ---@type Neoagent.RemoteFile
    local object = {locator = "file-openai-inspected", state = "ready", lifetime = {kind = "unknown"}}
    local result = wait(f.backend.inspect(object, f.access, 1000))
    assert.is_true(result.ok)
    assert.are.same({kind = "deadline", at = 1700086400000}, assert(result.object).lifetime)
    object.locator = "file-000000000000000000000000"
    result = wait(f.backend.inspect(object, f.access, 1000))
    assert.is_true(result.ok)
    assert.is_nil(result.object)
  end)

  it("recognizes the retained lifetime in real Anthropic inspection metadata", function()
    local f = fixture("anthropic", {"tests/recordings/anthropic/validation/inspect.yaml"})
    local result = wait(f.backend.inspect({locator = "file_anthropic_inspected", state = "ready",
      lifetime = {kind = "unknown"}}, f.access, 1000))
    assert.is_true(result.ok)
    assert.are.same({kind = "until_deleted"}, assert(result.object).lifetime)
  end)

  for _, ending in ipairs({"cancel", "timeout"}) do
    it("detaches one waiter's " .. ending .. " while a second consumes the recorded upload", function()
      local f = fixture("openai", {{path = "tests/recordings/openai/managed-files/01.yaml", id = "upload",
        finish_after = {"release-upload"}}})
      local first = async.run(function()
        return f.manager:get(f.asset, f.access, f.manager.monotonic() + (ending == "timeout" and 25 or 4000))
      end)
      local second = f.get()
      assert(vim.wait(1000, function() return #f.scenario.requests == 1 end))
      if ending == "cancel" then first:cancel() end
      local failed = wait(first)
      assert.is_false(failed.ok)
      assert.matches(ending == "cancel" and "cancel" or "timed out", assert(failed.error).message:lower())
      assert.is_false(second:is_done())
      assert.is_false(service.operation_enabled(f.service, {mutating = true}))
      f.scenario.release("release-upload")
      local result = wait(second)
      assert.is_nil(result.error, vim.inspect(result.error))
      assert.are.equal("file-managed-openai-fixed", assert(result.object).locator)
      assert.are.equal(1, #f.scenario.requests)
    end)
  end

  it("rejects an expired subscriber while another waits for the recorded upload", function()
    local f = fixture("openai", {{path = "tests/recordings/openai/managed-files/01.yaml",
      finish_after = {"release-upload"}}})
    local first = f.get()
    assert(vim.wait(1000, function() return #f.scenario.requests == 1 end))
    local expired = async.run(function()
      return f.manager:get(f.asset, f.access, f.manager.monotonic() - 1)
    end)
    assert.matches("timed out", assert(wait(expired).error).message)
    assert.is_false(first:is_done())
    assert.is_false(service.operation_enabled(f.service, { mutating = true }))
    f.scenario.release("release-upload")
    assert.are.equal("file-managed-openai-fixed", assert(wait(first).object).locator)
    assert.are.equal(1, #f.scenario.requests)
  end)

  it("rejects a recorded upload delivered beyond its subscriber deadline", function()
    local f = fixture("openai", {{path = "tests/recordings/openai/managed-files/01.yaml",
      finish_after = {"release-upload"}}})
    local monotonic = f.manager.monotonic
    local elapsed = 0
    f.manager.monotonic = function() return monotonic() + elapsed end
    local run = f.get()
    assert(vim.wait(1000, function() return #f.scenario.requests == 1 end))
    elapsed = 5000
    f.scenario.release("release-upload")
    local result = wait(run)
    assert.is_false(result.ok)
    assert.matches("timed out", assert(result.error).message)
    local retained = assert(f.manager.records[f.manager:key(f.asset, f.access)])
    assert.are.equal("file-managed-openai-fixed", retained.object.locator)
    assert.are.equal(1, #f.scenario.requests)
  end)

  it("does not start a replacement upload when recorded inspection exhausts the producer budget", function()
    local f = fixture("openai", {{ path = "tests/recordings/openai/validation/inspect-missing.yaml",
      finish_after = { "release-inspection" } }})
    local monotonic = f.manager.monotonic
    local elapsed = 0
    f.manager.monotonic = function() return monotonic() + elapsed end
    f.manager.budget_ms = 1000
    local key = f.manager:key(f.asset, f.access)
    local cached = {
      format = "neoagent-provider-file", key = key, generation = string.rep("a", 64),
      object = { locator = "file-000000000000000000000000", state = "ready", lifetime = { kind = "unknown" } },
    }
    local saved = wait(async.run(function()
      return { ok = true, saved = f.workspace.file_cache:publish(cached) }
    end))
    assert.is_true(saved.saved)
    local run = async.run(function()
      return f.manager:get(f.asset, f.access, f.manager.monotonic() + 10000)
    end)
    assert(vim.wait(1000, function() return #f.scenario.requests == 1 end))
    elapsed = 2000
    f.scenario.release("release-inspection")
    local result = wait(run)
    assert.is_false(result.ok)
    assert.matches("Image preparation timed out", assert(result.error).message)
    assert.are.equal("GET", assert(f.scenario.requests[1]).method)
    assert.are.equal(1, #f.scenario.requests)
    assert.are.same({}, f.manager.records)
    assert.is_true(service.operation_enabled(f.service, { mutating = true }))
  end)

  it("cancels an upload when the manager retires during backend startup", function()
    local f = fixture("openai", {})
    local upload = f.backend.upload
    ---@type Neoagent.Run<Neoagent.FileObjectResult, nil>?
    local child
    f.backend.upload = function(...)
      child = upload(...)
      f.manager:retire()
      return child
    end
    local run = f.get()
    local propagated = assert(child):is_cancelled()
    local leased = not service.operation_enabled(f.service, { mutating = true })
    assert(child):cancel()
    local result = wait(run)
    assert(vim.wait(1000, function() return f.manager.active == 0 end))
    assert.is_true(propagated)
    assert.is_true(leased)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.same({}, f.scenario.requests)
    assert.are.same({}, f.manager.records)
    assert.is_true(service.operation_enabled(f.service, { mutating = true }))
  end)

  it("cancels the last waiter before publication and permits a later recorded upload", function()
    local f = fixture("openai", {{path = "tests/recordings/openai/managed-files/01.yaml", id = "cancelled",
      finish_after = {"never-released"}}, {path = "tests/recordings/openai/managed-files/01.yaml", id = "replacement"}})
    local first = f.get()
    assert(vim.wait(1000, function() return #f.scenario.requests == 1 end))
    first:cancel()
    assert.is_false(wait(first).ok)
    assert(vim.wait(1000, function() return f.manager.active == 0 end))
    assert.are.same({}, f.manager.records)
    assert.is_nil(wait(f.get()).error)
    assert.are.equal(2, #f.scenario.requests)
  end)

  for _, boundary in ipairs({"upload", "cache"}) do
    it("prevents a replaced producer from publishing after " .. boundary, function()
      local f = fixture("openai", {"tests/recordings/openai/managed-files/01.yaml"})
      local function replace()
        local key = assert(next(f.manager.operations))
        f.manager.operations[key] = {waiters = 0}
      end
      if boundary == "upload" then
        local upload = f.backend.upload
        f.backend.upload = function(asset, access, timeout)
          return async.run(function()
            local result = upload(asset, access, timeout):await()
            if result.ok == false then error(result.error, 0) end
            replace()
            return result
          end)
        end
      else
        f.workspace.file_cache.publish = function() replace(); return false end
      end
      local result = wait(f.get())
      assert.is_false(result.ok)
      assert.are.equal("cancelled", assert(result.error).kind)
      assert.are.same({}, f.manager.records)
      assert.are.equal(0, #vim.fn.globpath(f.workspace.directory .. "/provider-cache", "*/*.json", false, true))
    end)
  end

  it("keeps the upload usable after uncertain cache publication and blocks subsequent cache writes", function()
    local f = fixture("openai", {"tests/recordings/openai/managed-files/01.yaml"})
    local original = fs.atomic_replace
    fs.atomic_replace = function(path, data, options)
      assert(original(path, data, options))
      return nil, "synthetic uncertain cache publication"
    end
    local result = wait(f.get())
    fs.atomic_replace = original
    assert.is_nil(result.error)
    assert.are.equal("file-managed-openai-fixed", assert(result.object).locator)
    local record = assert(f.manager.records[assert(result.key)])
    local published = wait(async.run(function() return {ok = true, saved = f.workspace.file_cache:publish(record)} end))
    assert.is_false(published.saved)
    assert.is_true(objects.usable(record.object, f.manager.now(), 60000))
  end)

  it("keeps a recorded upload usable when its publication lock is replaced", function()
    local f = fixture("openai", {"tests/recordings/openai/managed-files/01.yaml"})
    local original = fs.atomic_replace
    ---@type string?
    local displaced_lock
    fs.atomic_replace = function(path, data, options)
      local saved, identity, stage = original(path, data, options)
      assert(saved)
      displaced_lock = path .. ".lock"
      assert(original(displaced_lock, "another owner\n", { mode = 384 }))
      return saved, identity, stage
    end
    local result = wait(f.get())
    fs.atomic_replace = original
    assert.is_nil(result.error, vim.inspect(result.error))
    assert.are.equal("file-managed-openai-fixed", assert(result.object).locator)
    assert.are.equal("another owner\n", assert(fs.read((assert(displaced_lock)))))
    local record = assert(f.manager.records[assert(result.key)])
    assert.is_true(objects.usable(record.object, f.manager.now(), 60000))
    local later = wait(async.run(function()
      return { ok = true, saved = f.workspace.file_cache:publish(record) }
    end))
    assert.is_false(later.saved)
    assert.are.equal(1, #f.scenario.requests)
  end)
end)
