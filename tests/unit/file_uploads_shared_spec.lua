local assert = require("luassert")
local async = require("neoagent.async")
local digest = require("neoagent.files.digest")
local manager_module = require("neoagent.files.manager")
local objects = require("neoagent.files.object")
local provider_service = require("neoagent.provider_service")
local store_module = require("neoagent.files.provider_cache")
local util = require("neoagent.util")
local waiting = require("neoagent.files.wait")
local attachment_fixture = require("tests.helpers.attachments")
local attachments = attachment_fixture.new()
local request_stream = require("neoagent.api.request_stream")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return (assert(run:result()))
end


---@param run Neoagent.Run<Neoagent.FileRecord, nil>
---@return Neoagent.FileRecord
local function file(run)
  local result = wait(run)
  if result.ok == false then error(vim.inspect(result.error), 0) end
  return result
end

---@param data string
---@param mime? string
---@return Neoagent.FileAsset
local function asset(data, mime)
  local image = attachments.image(data, mime)
  return { source = attachments.files, file_id = image.file_id, mime_type = image.mime_type, bytes = image.bytes }
end

---@param id? string
---@param expires? number
---@return Neoagent.RemoteFile
local function remote(id, expires)
  return { locator = id or "file-synthetic", state = "ready",
    lifetime = { kind = "deadline", at = expires or 86400000 } }
end

---@type Neoagent.FileAccess
local access = { storage_scope = "account-a", headers = { Authorization = "Bearer synthetic-key" } }

---@class Neoagent.TestFiles
---@field manager Neoagent.FileManager
---@field cache Neoagent.FileCache
---@field service Neoagent.ProviderService
---@field records table<string, Neoagent.FileRecord>
---@field upload integer
---@field inspect integer
---@field wall number
---@field mono number

describe("shared provider file lifecycle", function()
  ---@type Neoagent.TestFiles[]
  local fixtures = {}
  local directories = {}
  before_each(function() attachments = attachment_fixture.new() end)
  after_each(function()
    for _, f in ipairs(fixtures) do
      f.manager:retire()
      assert(vim.wait(5000, function() return f.manager.active == 0 end))
      assert.is_true(provider_service.operation_enabled(f.service, { mutating = true }))
    end
    for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
    fixtures, directories = {}, {}
  end)

  ---@param overrides? Neoagent.FileBackend
  ---@return Neoagent.TestFiles
  local function fixture(overrides)
    ---@type table<string, Neoagent.FileRecord>
    local records = {}
    ---@type Neoagent.FileCache
    local cache = {
      scope = attachments.files.identity,
      read = function(_, key) return util.copy(records[key]) end,
      publish = function(_, record) records[record.key] = util.copy(record); return true end,
    }
    ---@type Neoagent.ProviderService
    local service = { id = "files", name = "Files", operations = {}, state = function() return false end }
    local f = { records = records, cache = cache, service = service, upload = 0, inspect = 0, wall = 1000000, mono = 0 }
    local backend = overrides or {
      identity = "synthetic-files:vision",
      upload = function()
        f.upload = f.upload + 1
        return async.run(function() return { ok = true, object = remote("file-" .. f.upload, f.wall + 86400000) } end)
      end,
      inspect = function(value)
        f.inspect = f.inspect + 1
        return async.run(function() return { ok = true, object = util.copy(value) } end)
      end,
    }
    f.manager = manager_module.new({ scope = attachments.files.identity, backend = backend, store = cache,
      acquire = function() return provider_service.acquire_use(service) end,
      now = function() return f.wall end, monotonic = function() return waiting.now() + f.mono end })
    fixtures[#fixtures + 1] = f
    return f
  end

  ---@param f Neoagent.TestFiles
  ---@param image? Neoagent.FileAsset
  ---@param authorization? Neoagent.FileAccess
  ---@param budget? number
  ---@return Neoagent.Run<Neoagent.FileRecord, nil>
  local function get(f, image, authorization, budget)
    return async.run(function()
      return f.manager:get(image or asset("picture"), authorization or access,
        f.manager.monotonic() + (budget or 4000))
    end)
  end

  it("hashes complete binary snapshots and preserves MIME-scoped content identity", function()
    local hashes = wait(async.run(function()
      return { ok = true, abc = digest.sha256("abc"), binary = asset("a\0b"),
        newline = asset("a\nb"), jpeg = asset("a\0b", "image/jpeg"),
        long = digest.sha256(string.rep("abc", 22000)) }
    end))
    assert.are.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hashes.abc)
    assert.are.equal("59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138", assert(hashes.binary).file_id)
    assert.are.equal(vim.fn.sha256(string.rep("abc", 22000)), hashes.long)
    local f = fixture()
    local first = file(get(f, hashes.binary))
    assert.are.same(first, file(get(f, hashes.binary)))
    assert.are_not.same(first, file(get(f, hashes.newline)))
    assert.are_not.same(first, file(get(f, hashes.jpeg)))
    assert.are.equal(3, f.upload)
    assert.are.equal(0, f.inspect)
  end)

  it("verifies persisted objects on cold reuse and keys authorization separately", function()
    local f = fixture()
    local first = file(get(f))
    f.manager.records, f.manager.validated = {}, {}
    assert.are.same(first, file(get(f)))
    assert.are.equal(1, f.inspect)
    assert.are.equal(1, f.upload)
    assert.are_not.same(first, file(get(f, nil, { storage_scope = "account-b", headers = {} })))
    assert.are.equal(2, f.upload)
  end)

  it("lets editor timers cancel image hashing before it finishes", function()
    local timer = assert(vim.uv.new_timer())
    local run = async.run(function()
      return { ok = true, digest = digest.sha256(string.rep("synthetic", 100000)) }
    end)
    timer:start(0, 0, vim.schedule_wrap(function()
      timer:stop()
      timer:close()
      run:cancel()
    end))
    local result = wait(run)
    if not timer:is_closing() then timer:stop(); timer:close() end
    assert.is_false(result.ok, "hashing starved the editor's cancellation timer")
    assert.are.equal("cancelled", assert(result.error).kind)
  end)

  it("delivers completed uploads without waiting for a polling interval", function()
    local f = fixture()
    ---@type Neoagent.AwaitCallbacks<Neoagent.FileObjectResult>?
    local pending
    f.manager.backend.upload = function()
      return async.run(function()
        return async.await(function(done) pending = done end)
      end)
    end
    local run = get(f)
    assert(vim.wait(1000, function() return pending ~= nil end, 1))
    assert(pending).resolve({ ok = true, object = remote() })
    local delivered = vim.wait(10, function() return run:is_done() end, 1)
    assert.are.equal("file-synthetic", file(run).object.locator)
    assert.is_true(delivered, "completed upload waited for a polling interval")
  end)

  it("keys immutable content independently of filenames and rejects foreign stores", function()
    local f = fixture()
    local original, renamed = asset("first"), asset("first")
    original.filename, renamed.filename = "first.png", "renamed.png"
    local result = file(get(f, original))
    assert.are.same(result, file(get(f, renamed)))
    assert.are_not.same(result, file(get(f, asset("other"))))
    assert.are_not.same(result, file(get(f, asset("first", "image/jpeg"))))
    local foreign = attachment_fixture.new()
    local image = foreign.image("first")
    local rejected = wait(get(f, { source = foreign.files, file_id = image.file_id,
      mime_type = image.mime_type, bytes = image.bytes }))
    assert.is_false(rejected.ok)
    assert.matches("bound workspace", assert(rejected.error).message)
    assert.are.equal(3, f.upload)
  end)

  it("rejects provider caches belonging to a different workspace", function()
    local f = fixture()
    local cache = util.copy(f.cache)
    cache.scope = "foreign-workspace"
    assert.has_error(function()
      manager_module.new({ scope = attachments.files.identity, backend = f.manager.backend,
        store = cache, acquire = f.manager.acquire })
    end)
  end)

  it("reuploads known expiry without inspecting and never extends trust on clock rollback", function()
    local f = fixture()
    file(get(f))
    f.wall, f.mono = 87350000, 86350000
    file(get(f))
    assert.are.equal(2, f.upload)
    assert.are.equal(0, f.inspect)
    -- Give the refreshed object a useful expiry, then move wall time backward.
    f.wall = 1000000
    f.manager.records, f.manager.validated = {}, {}
    file(get(f))
    assert.are.equal(1, f.inspect)
  end)

  for _, condition in ipairs({ "missing", "expired", "unauthorized", "malformed" }) do
    it("handles " .. condition .. " inspection without misclassifying failures", function()
      local f = fixture()
      file(get(f))
      f.manager.records, f.manager.validated = {}, {}
      f.manager.backend.inspect = function()
        f.inspect = f.inspect + 1
        return async.run(function()
          if condition == "unauthorized" then error(util.error("auth", "denied"), 0) end
          if condition == "missing" then return { ok = true } end
          if condition == "malformed" then return { ok = true, object = { locator = "", state = "ready", lifetime = { kind = "unknown" } } } end
          return { ok = true, object = remote("file-1", 500000) }
        end)
      end
      local result = wait(get(f))
      if condition == "unauthorized" or condition == "malformed" then
        assert.is_false(result.ok)
        assert.are.equal(1, f.upload)
      else
        assert.are.equal("file-2", assert(result.object).locator)
        assert.are.equal(2, f.upload)
      end
    end)
  end

  it("rechecks active metadata after freshness expires", function()
    local f = fixture()
    file(get(f))
    f.wall, f.mono = 1301000, 301000
    file(get(f))
    assert.are.equal(1, f.inspect)
    assert.are.equal(1, f.upload)
  end)

  it("expires remote validation despite frequent cache hits", function()
    local f = fixture()
    f.manager.backend.inspect = function(value)
      f.inspect = f.inspect + 1
      return async.run(function()
        return { ok = true, object = value.locator ~= "file-1" and value or nil }
      end)
    end
    assert.are.equal("file-1", file(get(f)).object.locator)
    for _, elapsed in ipairs({ 240000, 480000, 720000, 960000 }) do
      f.wall, f.mono = 1000000 + elapsed, elapsed
      local result = file(get(f))
      assert.are.equal(elapsed < 300000 and "file-1" or "file-2", result.object.locator,
        "cache hits must not postpone inspecting and replacing a deleted upload")
    end
    assert.are.equal(2, f.inspect, "freshness must restart after each remote check")
    assert.are.equal(2, f.upload)
  end)

  it("polls processing to readiness without creating duplicate objects", function()
    local f = fixture()
    f.manager.backend.upload = function()
      f.upload = f.upload + 1
      local value = remote()
      value.state = "processing"
      return async.run(function() return { ok = true, object = value } end)
    end
    f.manager.backend.inspect = function()
      f.inspect = f.inspect + 1
      return async.run(function() return { ok = true, object = remote() } end)
    end
    assert.are.equal("ready", file(get(f)).object.state)
    assert.are.equal(1, f.upload)
    assert.are.equal(1, f.inspect)
  end)

  it("verifies unknown lifetimes on each reuse without uploading another copy", function()
    local f = fixture()
    local value = remote()
    value.lifetime = { kind = "unknown" }
    f.manager.backend.upload = function()
      f.upload = f.upload + 1
      return async.run(function() return { ok = true, object = util.copy(value) } end)
    end
    local first = file(get(f))
    assert.are.same(first, file(get(f)))
    assert.are.same(first, file(get(f)))
    assert.are.equal(1, f.upload)
    assert.are.equal(2, f.inspect)
    f.manager.records, f.manager.validated = {}, {}
    assert.are.same(first, file(get(f)))
    assert.are.equal(3, f.inspect)
    assert.are.equal(1, f.upload)
  end)

  for _, state in ipairs({ "failed", "invalid" }) do
    it("rejects " .. state .. " upload metadata without retrying", function()
      local f = fixture()
      f.manager.backend.upload = function()
        f.upload = f.upload + 1
        local value = remote()
        if state == "failed" then value.state = "failed"
        else value.locator = "" end
        return async.run(function() return { ok = true, object = value } end)
      end
      assert.is_false(wait(get(f)).ok)
      assert.are.equal(1, f.upload)
      assert.are.same({}, f.records)
    end)
  end

  for _, ending in ipairs({ "cancel", "timeout" }) do
    it("detaches a first waiter's " .. ending .. " while another owns the shared upload", function()
      local f = fixture()
      ---@type Neoagent.AwaitCallbacks<Neoagent.FileObjectResult>?
      local pending
      local cancelled = 0
      f.manager.backend.upload = function()
        f.upload = f.upload + 1
        return async.run(function()
          return async.await(function(done) pending = done; return function() cancelled = cancelled + 1 end end)
        end)
      end
      local first = get(f, nil, nil, ending == "timeout" and 20 or 4000)
      local second = get(f)
      assert(vim.wait(1000, function() return pending ~= nil end))
      if ending == "cancel" then first:cancel() end
      assert.is_false(wait(first).ok)
      assert.are.equal(0, cancelled)
      assert.is_false(provider_service.operation_enabled(f.service, { mutating = true }))
      assert(pending).resolve({ ok = true, object = remote() })
      assert.are.equal("file-synthetic", file(second).object.locator)
      assert.are.equal(1, f.upload)
    end)
  end

  it("cancels the last waiter and prevents stale publication after replacement", function()
    local f = fixture()
    ---@type Neoagent.AwaitCallbacks<Neoagent.FileObjectResult>?
    local pending
    local cancelled = 0
    f.manager.backend.upload = function()
      return async.run(function()
        return async.await(function(done) pending = done; return function() cancelled = cancelled + 1 end end)
      end)
    end
    local first = get(f)
    assert(vim.wait(1000, function() return pending ~= nil end))
    first:cancel()
    wait(first)
    assert(vim.wait(1000, function() return cancelled == 1 end))
    f.manager.backend.upload = function() return async.run(function() return { ok = true, object = remote("file-new") } end) end
    local second = file(get(f))
    assert(pending).resolve({ ok = true, object = remote("file-old") })
    assert.are.equal("file-new", second.object.locator)
    assert.are.same(second, file(get(f)))
  end)

  it("keeps newer account mappings when older credentials finish uploading later", function()
    local f = fixture()
    ---@type table<string, Neoagent.AwaitCallbacks<Neoagent.FileObjectResult>>
    local pending = {}
    f.manager.backend.upload = function(_, authorization)
      return async.run(function()
        return async.await(function(done) pending[authorization.headers.Authorization] = done end)
      end)
    end
    local rotated = { storage_scope = access.storage_scope, headers = { Authorization = "Bearer rotated-key" } }
    local first, second = get(f), get(f, nil, rotated)
    local separate = vim.wait(1000, function() return pending[rotated.headers.Authorization] ~= nil end)
    if not separate then
      first:cancel()
      second:cancel()
      wait(first)
      wait(second)
    end
    assert.is_true(separate, "different credentials must own independent preparation")
    pending[rotated.headers.Authorization].resolve({ ok = true, object = remote("file-new") })
    local newer = file(second)
    pending[access.headers.Authorization].resolve({ ok = true, object = remote("file-old") })
    assert.are.equal("file-old", file(first).object.locator)
    assert.are.same(newer, file(get(f, nil, rotated)))
    assert.are.same(newer, f.records[newer.key], "late completion must not replace the saved newer generation")
  end)

  it("retires producers and rejects new preparation", function()
    local f = fixture()
    f.manager.backend.upload = function() return async.run(function() return async.await(function() end) end) end
    local run = get(f)
    f.manager:retire()
    assert.is_false(wait(run).ok)
    assert.is_false(wait(get(f)).ok)
    assert.are.same({}, f.records)
  end)

  it("ignores a queued preparation check after native timer cancellation", function()
    local calls = 0
    local run = async.run(function()
      waiting.until_ready(function() calls = calls + 1; return false end, waiting.now() + 1000)
      return true
    end)
    local timer = assert(vim.uv.new_timer())
    timer:start(25, 0, function() run:cancel() end)
    local finished = vim.wait(1500, function() return run:is_done() end)
    timer:stop()
    timer:close()
    run:cancel()
    assert.is_true(finished)
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
    assert.are.equal(1, calls)
  end)

  it("closes preparation once when its readiness predicate cancels the owner", function()
    local calls = 0
    ---@type Neoagent.Run<boolean, nil>?
    local run
    run = async.run(function()
      waiting.until_ready(function()
        calls = calls + 1
        if calls > 1 then assert(run):cancel(); return true end
        return false
      end, waiting.now() + 1000)
      return true
    end)
    local finished = vim.wait(1500, function() return run:is_done() end)
    run:cancel()
    assert.is_true(finished)
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
    assert.are.equal(2, calls)
  end)

  it("replaces only the invalidated generation and tolerates unavailable persistence", function()
    local f = fixture()
    local first = file(get(f))
    f.manager:invalidate(first.key, first.generation)
    f.cache.publish = function() return false end
    local second = file(get(f))
    assert.are.equal("file-2", second.object.locator)
    f.manager:invalidate(first.key, first.generation)
    assert.are.same(second, file(get(f)))
    assert.are.equal(2, f.upload)
    f.manager:invalidate(second.key, second.generation)
    f.manager:invalidate(first.key, first.generation)
    assert.are.equal("file-3", file(get(f)).object.locator)
  end)

  it("stops processing at its finite producer deadline", function()
    local f = fixture()
    f.manager.budget_ms = 15
    f.manager.backend.upload = function()
      f.upload = f.upload + 1
      local value = remote()
      value.state = "processing"
      return async.run(function() return { ok = true, object = value } end)
    end
    local result = wait(get(f))
    assert.is_false(result.ok)
    assert.matches("timed out", assert(result.error).message)
    assert.are.equal(1, f.upload)
    assert.are.equal(0, f.inspect)
    assert.are.same({}, f.records)
  end)

  it("surfaces cached processing failures before inspecting or uploading", function()
    local f = fixture()
    local record = file(get(f))
    record.object.state = "failed"
    f.records[record.key] = record
    f.manager.records, f.manager.validated = {}, {}
    local result = wait(get(f))
    assert.is_false(result.ok)
    assert.matches("processing failed", assert(result.error).message)
    assert.are.equal(1, f.upload)
    assert.are.equal(0, f.inspect)
  end)

  it("uploads ordered image bytes and verifies native Files metadata through HTTP", function()
    local f = fixture()
    ---@type Neoagent.HttpRequest[]
    local requests = {}
    local missing = false
    f.manager.backend = require("neoagent.files.http_backend").new({
      url = "https://example.test/files", purpose = "vision", transport = { fetch = function(opts)
        return async.run(function()
          requests[#requests + 1] = util.copy(opts.request)
          if opts.request.method == "GET" then
            f.inspect = f.inspect + 1
            if missing then return { ok = true, status = 404, headers = {}, body = "{}" } end
          else
            f.upload = f.upload + 1
          end
          return { ok = true, status = 200, headers = {}, body = util.json_encode({
            object = "file", id = "file-" .. f.upload, bytes = 7, purpose = "vision", expires_at = 86400,
          }) }
        end)
      end },
    })
    assert.are.equal("file-1", file(get(f)).object.locator)
    assert.matches('name="purpose".-vision.-name="expires_after%[seconds%]".-86400.-name="file".-picture', (assert(assert(requests[1]).body)))
    assert.are.equal("Bearer synthetic-key", rawget(assert(assert(requests[1]).headers), "Authorization"))
    f.manager.records, f.manager.validated = {}, {}
    assert.are.equal("file-1", file(get(f)).object.locator)
    assert.are.equal(1, f.inspect)
    assert.are.equal(1, f.upload)
    local _, cached = next(f.records)
    assert(cached).object.locator = "../unexpected-path"
    f.manager.records, f.manager.validated = {}, {}
    assert.are.equal("file-2", file(get(f)).object.locator)
    assert.are.equal(1, f.inspect)
    f.manager.records, f.manager.validated = {}, {}
    missing = true
    assert.are.equal("file-3", file(get(f)).object.locator)
    assert.are.equal(3, f.upload)
  end)

  it("holds direct API Model use until cancellation settles", function()
    local f = fixture()
    local requested, cancelled, completed = false, false, 0
    local model = require("neoagent.api.openai_completions").new({
      provider = "synthetic", model = "test", base_url = "https://example.test",
      api_key = function()
        assert.is_false(provider_service.operation_enabled(f.service, { mutating = true }))
        return "synthetic-key"
      end,
      transport = { request = function()
        requested = true
        return async.run(function()
          return async.await(function() return function() cancelled = true end end)
        end)
      end },
    })
    local wrapped = require("neoagent.files.model").wrap(model, f.service)
    local run = wrapped:stream({ messages = {}, on_done = function() completed = completed + 1 end })
    assert(vim.wait(1000, function() return requested end))
    run:cancel()
    assert.is_false(wait(run).ok)
    assert(vim.wait(1000, function()
      return cancelled and completed == 1 and provider_service.operation_enabled(f.service, { mutating = true })
    end))
  end)

  it("rejects a prepared set that keeps aging while other images upload", function()
    local f = fixture()
    f.manager.backend.upload = function()
      f.upload, f.wall = f.upload + 1, f.wall + 120000
      return async.run(function() return { ok = true, object = remote("file-" .. f.upload, f.wall + 70000) } end)
    end
    local request = require("neoagent.files.request").new(function() return f.manager end, {
      api = "openai-responses", bind = function() return access end, accepts = function() return true end,
      max_file_bytes = 1024, max_images = 5, max_total_bytes = 1024, max_body_bytes = 4096,
    })
    local requests = 0
    local transport = require("neoagent.transport.http").new({ request = function()
      requests = requests + 1
      return async.run(function() return { ok = true, response = { status = 200, headers = {} } } end)
    end })
    local messages = { { role = "user", content = {
      attachments.image("picture"), attachments.image("other"),
    } } }
    local dependencies = { messages = messages, files = attachments.files }
    local plan = require("neoagent.api.openai_responses").new({
      provider = "synthetic", model = "vision", base_url = "https://example.test",
    }):_request(dependencies)
    local result = wait(request_stream.send(transport, plan, dependencies, { on_event = function() end }, request))
    assert.is_false(result.ok)
    assert.matches("expires before dispatch", assert(result.error).message)
    assert.are.equal(0, requests)
    assert.are.equal(4, f.upload)
  end)

  it("surfaces a disappeared processing object and preserves access failures", function()
    local f = fixture()
    f.manager.backend.upload = function()
      local value = remote()
      value.state = "processing"
      return async.run(function() return { ok = true, object = value } end)
    end
    f.manager.backend.inspect = function() return async.run(function() return { ok = true } end) end
    assert.matches("disappeared", assert(wait(get(f)).error).message)
    f.manager.backend.inspect = function()
      return async.run(function() error(util.error("files", "Processing inspection denied"), 0) end)
    end
    assert.matches("Processing inspection denied", assert(wait(get(f)).error).message)
    f.manager.acquire = function() return nil, util.error("provider", "exclusive operation active") end
    assert.matches("exclusive operation active", assert(wait(get(f)).error).message)
    assert.are.same({}, f.records)
  end)

  it("keeps uploads usable after uncertain cache publication and blocks later writes", function()
    local directory = vim.fn.tempname()
    directories[#directories + 1] = directory
    local warnings = {}
    local store = store_module.new({ scope = attachments.files.identity, directory = directory, report = function(message) warnings[#warnings + 1] = message end })
    local f = fixture()
    f.manager.store = store
    local fs = require("neoagent.fs")
    local original, attempts = fs.atomic_replace, 0
    fs.atomic_replace = function()
      attempts = attempts + 1
      return nil, util.error("storage", "uncertain publication with private path")
    end
    local ok, result = pcall(function() return file(get(f)) end)
    fs.atomic_replace = original
    assert(ok, result)
    assert.are.equal(1, attempts)
    assert.are.equal(1, #warnings)
    assert.is_nil(warnings[1]:find("private path", 1, true))
    f.manager.records, f.manager.validated = {}, {}
    assert.are.equal("file-2", file(get(f)).object.locator)
    assert.are.equal(1, #warnings)
    assert.are.same({}, vim.fn.globpath(directory, "*/*.json", false, true))
  end)

  it("uploads accepted images while inlining unsupported images in one request", function()
    local f = fixture()
    local uploaded = attachments.image("uploaded", "image/png")
    local inlined = attachments.image("inlined", "image/jpeg")
    local request = require("neoagent.files.request").new(function() return f.manager end, {
      api = "openai-responses",
      bind = function() return access end,
      accepts = function(image) return image.mime_type == "image/png" end,
      max_file_bytes = 1024,
      max_images = 5,
      max_total_bytes = 1024,
      max_body_bytes = 4096,
    })
    local sent_body
    local transport = require("neoagent.transport.http").new({ request = function(opts)
      sent_body = assert(opts.request.body)
      return async.run(function()
        return { ok = true, response = { status = 200, headers = {} } }
      end)
    end })
    local dependencies = {
      messages = { { role = "user", content = { uploaded, inlined } } },
      files = attachments.files,
    }
    local plan = require("neoagent.api.openai_responses").new({
      provider = "synthetic", model = "vision", base_url = "https://example.test",
    }):_request(dependencies)
    local result = wait(request_stream.send(transport, plan, dependencies,
      { on_event = function() end }, request))
    assert.is_true(result.ok)
    assert.are.equal(1, f.upload)
    if type(sent_body) ~= "string" then
      error("request body was not sent")
    end
    local wire = vim.json.decode(sent_body)
    assert.are.equal("file-1", wire.input[1].content[1].file_id)
    assert.are.equal("data:image/jpeg;base64," .. vim.base64.encode("inlined"),
      wire.input[1].content[2].image_url)
  end)

  for _, limit in ipairs({ "file", "count", "total", "body", "inline-body", "missing" }) do
    it("checks the " .. limit .. " limit before inference dispatch", function()
      local f = fixture()
      ---@type Neoagent.ImageBlock
      local image = attachments.image("picture")
      if limit == "missing" then image.file_id = string.rep("f", 64) end
      local requests = 0
      local transport = require("neoagent.transport.http").new({ request = function()
        requests = requests + 1
        return async.run(function() return { ok = true, response = { status = 200, headers = {} } } end)
      end })
      local request = require("neoagent.files.request").new(function() return f.manager end, {
        api = "openai-responses", bind = function() return access end, accepts = function() return limit ~= "inline-body" end,
        max_file_bytes = limit == "file" and 1 or 1024,
        max_images = limit == "count" and 0 or 5,
        max_total_bytes = limit == "total" and 1 or 1024,
        max_body_bytes = (limit == "body" or limit == "inline-body") and 1 or 1024,
      })
      local dependencies = { messages = { { role = "user", content = { image } } }, files = attachments.files }
      local plan = require("neoagent.api.openai_responses").new({
        provider = "synthetic", model = "vision", base_url = "https://example.test",
      }):_request(dependencies)
      local run = request_stream.send(transport, plan, dependencies, { on_event = function() end }, request)
      assert.is_false(wait(run).ok)
      assert.are.equal(0, requests)
      assert.are.equal(limit == "body" and 1 or 0, f.upload)
    end)
  end

  it("persists private records with generation comparison and rejects corrupt candidates", function()
    local directory = vim.fn.tempname()
    directories[#directories + 1] = directory
    local store = store_module.new({ scope = attachments.files.identity, directory = directory })
    local f = fixture()
    f.manager.store = store
    local first = file(get(f))
    local path = require("neoagent.fs").join(directory, first.key .. ".json")
    assert.are.equal(384, bit.band(assert(vim.uv.fs_stat(path)).mode, 511))
    assert.are.equal(448, bit.band(assert(vim.uv.fs_stat(directory)).mode, 511))
    assert.are.same(first, store:read(first.key))
    local replacement = util.copy(first)
    replacement.generation = string.rep("b", 64)
    assert.is_false(wait(async.run(function() return { ok = true, saved = store:publish(replacement, "wrong") } end)).saved)
    assert.are.same(first, store:read(first.key))
    assert.is_true(wait(async.run(function() return { ok = true, saved = store:publish(replacement, first.generation) } end)).saved)
    assert.are.same(replacement, store:read(first.key))
    vim.fn.writefile({ "corrupt" }, path)
    assert.is_nil(store:read(first.key))
    assert.is_false(objects.record({ format = "neoagent-provider-file", key = first.key,
      generation = first.generation, object = remote(), credential = "private" }, first.key))
    local invalid = {
      { locator = "https://example.test/secret", state = "ready", lifetime = { kind = "until_deleted" } },
      { locator = "file", state = "ready", lifetime = { kind = "deadline", at = -1 } },
      { locator = "file", state = "ready", lifetime = { kind = "unknown", at = 9000 } },
      { locator = "file", state = "ready", lifetime = { kind = "until_deleted", credential = "secret" } },
      { locator = "file", state = "ready", lifetime = { kind = "until_deleted" }, secret = "secret" },
    }
    for _, candidate in ipairs(invalid) do
      vim.fn.writefile({ util.json_encode({ format = first.format, key = first.key,
        generation = first.generation, object = candidate }) }, path)
      assert.is_nil(store:read(first.key))
    end
    vim.fn.writefile({ string.rep("x", 16385) }, path)
    assert.is_nil(store:read(first.key))
  end)
end)
