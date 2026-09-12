local assert = require("luassert")
local async = require("neoagent.async")
local files = require("neoagent.providers.codex.files")
local util = require("neoagent.util")

local attachments = require("tests.helpers.attachments").new()
local image = attachments.image("synthetic")
---@type Neoagent.FileAsset
local asset = { source = attachments.files, file_id = image.file_id, bytes = image.bytes, mime_type = image.mime_type }
---@type Neoagent.FileAccess
local access = { storage_scope = "account", headers = { Authorization = "Bearer private-key", ["chatgpt-account-id"] = "account" } }
---@type Neoagent.RemoteFile
local object = { locator = "file-synthetic", state = "ready", lifetime = { kind = "unknown" } }

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(2000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe("Codex file protocol", function()
  ---@class Neoagent.TestCodexFiles
  ---@field responses table<string, Neoagent.ByteFetchResult>
  ---@field requests Neoagent.HttpRequest[]
  ---@field hold? string
  ---@field cancelled integer
  ---@field backend Neoagent.FileBackend
  ---@return Neoagent.TestCodexFiles
  local function fixture()
    ---@type Neoagent.TestCodexFiles
    local state
    ---@type Neoagent.ByteBackend
    local transport = { fetch = function(opts)
      return async.run(function()
        state.requests[#state.requests + 1] = util.copy(opts.request)
        local stage = opts.request.method == "PUT" and "put"
          or opts.request.method == "GET" and "inspect"
          or opts.request.url:match("/uploaded$") and "finalize" or "create"
        if state.hold == stage then
          async.await(function() return function() state.cancelled = state.cancelled + 1 end end)
        end
        return util.copy(assert(state.responses[stage]))
      end)
    end }
    local ready = util.json_encode({ status = "success", download_url = "https://storage.example.test/image?sig=private-capability",
      file_size_bytes = 9, mime_type = "image/png" })
    state = { requests = {}, cancelled = 0, responses = {
      create = { ok = true, status = 200, headers = {}, body = util.json_encode({
        file_id = "file-synthetic", upload_url = "https://storage.example.test/image?sig=private-capability",
      }) },
      put = { ok = true, status = 201, headers = {}, body = "" },
      finalize = { ok = true, status = 200, headers = {}, body = ready },
      inspect = { ok = true, status = 200, headers = {}, body = ready },
    }, backend = files.new({ transport = transport }) }
    return state
  end

  for _, value in ipairs({
    { file_id = "../escape", upload_url = "https://storage.example.test/blob" },
    { file_id = "file-synthetic", upload_url = "http://storage.example.test/blob" },
    { file_id = "file-synthetic", upload_url = "https://user:pass@storage.example.test/blob" },
    { file_id = "file-synthetic", upload_url = "https://storage.example.test/blob", pdf_c2pa_reservation = true },
  }) do
    it("rejects unsafe creation metadata before sending image bytes: " .. util.json_encode(value), function()
      local state = fixture()
      state.responses.create = { ok = true, status = 200, headers = {}, body = util.json_encode(value) }
      local result = wait(state.backend.upload(asset, access, 1000))
      assert.is_false(result.ok)
      assert.are.equal("files", assert(result.error).kind)
      assert.are.equal(1, #state.requests)
    end)
  end

  for _, value in ipairs({
    {}, { status = "error" }, { status = "success", download_url = "http://storage.example.test/blob" },
    { status = "success", download_url = "https://storage.example.test/blob", file_size_bytes = 10 },
    { status = "success", download_url = "https://storage.example.test/blob", mime_type = "image/jpeg" },
    { status = "success", download_url = "https://storage.example.test/blob", file_size_bytes = -1 },
  }) do
    it("rejects invalid finalized image metadata: " .. util.json_encode(value), function()
      local state = fixture()
      state.responses.finalize = { ok = true, status = 200, headers = {}, body = util.json_encode(value) }
      local result = wait(state.backend.upload(asset, access, 1000))
      assert.is_false(result.ok)
      assert.are.equal("files", assert(result.error).kind)
      assert.are.equal(3, #state.requests)
    end)
  end

  it("accepts finalization without optional size and MIME fields", function()
    local state = fixture()
    state.responses.finalize = { ok = true, status = 200, headers = {}, body = util.json_encode({
      status = "success", download_url = "https://storage.example.test/blob",
    }) }
    local result = wait(state.backend.upload(asset, access, 1000))
    assert.is_true(result.ok)
    assert.are.same(object, result.object)
  end)

  it("reuses an image when download inspection returns a null MIME type", function()
    local state = fixture()
    state.responses.inspect = { ok = true, status = 200, headers = {}, body = util.json_encode({
      status = "success", download_url = "https://storage.example.test/blob",
      file_size_bytes = 9, mime_type = vim.NIL, creation_time = vim.NIL,
      metadata = vim.NIL, no_auth_user_upload = vim.NIL, file_name = "image.png",
    }) }
    local result = wait(state.backend.inspect(object, access, 1000))
    assert.is_true(result.ok)
    assert.are.same(object, result.object)
    assert.are.equal(1, #state.requests)
  end)

  for _, stage in ipairs({ "create", "put", "finalize", "inspect" }) do
    it("cancels the active " .. stage .. " request", function()
      local state = fixture()
      state.hold = stage
      local run = stage == "inspect" and state.backend.inspect(object, access, 1000)
        or state.backend.upload(asset, access, 1000)
      local count = ({ create = 1, put = 2, finalize = 3, inspect = 1 })[stage]
      assert(vim.wait(1000, function() return #state.requests == count end))
      run:cancel()
      assert.is_false(wait(run).ok)
      assert.are.equal(1, state.cancelled)
      assert.are.equal(count, #state.requests)
    end)
  end

  it("bounds repeated finalization retries by the producer's remaining budget", function()
    local state = fixture()
    state.responses.finalize = { ok = true, status = 200, headers = {}, body = '{"status":"retry"}' }
    local result = wait(state.backend.upload(asset, access, 30))
    assert.is_false(result.ok)
    assert.matches("timed out", assert(result.error).message)
    assert.are.equal(3, #state.requests)
    assert.is_false(wait(state.backend.upload(asset, access, 0)).ok)
    assert.are.equal(3, #state.requests)
  end)

  it("does not disclose signed URLs when transport or decoding fails", function()
    for _, response in ipairs({
      { ok = false, error = { kind = "transport", message = "failed https://storage.example.test/?sig=private-capability" } },
      { ok = true, status = 200, headers = {}, body = "private-capability: invalid JSON" },
    }) do
      local state = fixture()
      state.responses.create = response
      local result = wait(state.backend.upload(asset, access, 1000))
      assert.is_false(result.ok)
      assert.is_nil((vim.inspect(result):find("private-capability", 1, true)))
    end
  end)

  it("rejects invalid cached identifiers without an authenticated request", function()
    local state = fixture()
    local invalid = util.copy(object)
    invalid.locator = "../another-endpoint"
    local result = wait(state.backend.inspect(invalid, access, 1000))
    assert.is_true(result.ok)
    assert.is_nil(result.object)
    assert.are.equal(0, #state.requests)
  end)
end)
