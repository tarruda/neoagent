local assert = require("luassert")
local async = require("neoagent.async")
local attachments = require("tests.helpers.attachments").new()
local util = require("neoagent.util")
local waiting = require("neoagent.files.wait")

local image = attachments.image("synthetic")
---@type Neoagent.FileAsset
local asset = { source = attachments.files, file_id = image.file_id, bytes = image.bytes, mime_type = image.mime_type }
---@type Neoagent.FileAccess
local access = { storage_scope = "account", headers = { Authorization = "Bearer synthetic-key" } }
---@type Neoagent.RemoteFile
local object = { locator = "file-synthetic", state = "ready", lifetime = { kind = "unknown" } }
local original_now = waiting.now
local original_timer = vim.uv.new_timer

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  if not vim.wait(5000, function() return run:is_done() end) then
    run:cancel()
    error("File request did not settle")
  end
  return (assert(run:result()))
end

---@param code unknown
---@return Neoagent.AsyncFailure
local function failure(code)
  return { ok = false, error = { kind = "transport", exit_code = code,
    message = "private-message", detail = "https://storage.example.test/?sig=private-capability",
    stderr = "private-stderr", response = { headers = { Authorization = "private-key" } } } }
end

for _, provider in ipairs({ "generic", "anthropic", "codex" }) do
  describe(provider .. " file request failures", function()
    ---@type Neoagent.FileBackend
    local backend
    ---@type Neoagent.HttpRequest[]
    local requests
    ---@type Neoagent.ByteFetchResult
    local success
    ---@type fun(request: Neoagent.HttpRequest, attempt: integer): Neoagent.ByteFetchResult
    local respond

    before_each(function()
      requests = {}
      local value = provider == "codex" and { status = "success", download_url = "https://storage.example.test/image",
          file_size_bytes = 9, mime_type = "image/png" }
        or provider == "anthropic" and { type = "file", id = object.locator, size_bytes = 9, mime_type = "image/png" }
        or { object = "file", id = object.locator, bytes = 9, purpose = "user_data", expires_at = 4102444800 }
      success = { ok = true, status = 200, headers = {}, body = util.json_encode(value) }
      respond = function(_request, _attempt) return success end
      ---@type Neoagent.ByteBackend
      local transport = { fetch = function(opts)
        return async.run(function()
          requests[#requests + 1] = util.copy(opts.request)
          return respond(opts.request, #requests)
        end)
      end }
      backend = provider == "generic" and require("neoagent.files.http_backend").new({
          url = "https://api.example.test/files", purpose = "user_data", transport = transport,
        })
        or require("neoagent.providers." .. provider .. ".files").new({ transport = transport })
    end)

    after_each(function()
      waiting.now = original_now
      vim.uv.new_timer = original_timer
    end)

    it("reports DNS failures without exposing transport data or repeating uploads", function()
      respond = function() return failure(6) end
      local result = wait(backend.upload(asset, access, 2000))
      assert.is_false(result.ok)
      local err = assert(result.error)
      assert.are.equal("dns", err.code)
      assert.are.equal(6, rawget(err, "exit_code"))
      assert.matches("DNS resolution failed", err.message, 1, true)
      assert.is_false(err.retryable)
      assert.is_nil((vim.inspect(result):find("private-", 1, true)))
      assert.are.equal(1, #requests)
    end)

    it("retries metadata within its original deadline and authorization", function()
      respond = function(_, attempt) return attempt == 1 and failure(6) or success end
      local result = wait(backend.inspect(object, access, 2000))
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.equal(object.locator, assert(result.object).locator)
      assert.are.equal(2, #requests)
      local first, second = assert(requests[1]), assert(requests[2])
      assert.are.equal("GET", first.method)
      assert.are.equal(first.url, second.url)
      assert.are.same(first.headers, second.headers)
      assert.is_true(assert(second.timeout_ms) < assert(first.timeout_ms))
    end)

    it("stops after three failed metadata attempts", function()
      respond = function() return failure(6) end
      local result = wait(backend.inspect(object, access, 3000))
      assert.is_false(result.ok)
      assert.are.equal("dns", assert(result.error).code)
      assert.is_false(assert(result.error).retryable)
      assert.are.equal(3, #requests)
    end)

    it("does not renew the budget after a slow failed request", function()
      local now = 0
      waiting.now = function() return now end
      respond = function() now = 950; return failure(6) end
      local result = wait(backend.inspect(object, access, 1000))
      assert.is_false(result.ok)
      assert.are.equal("dns", assert(result.error).code)
      assert.are.equal(1, #requests)
    end)

    it("cancels retry backoff and releases its timer", function()
      respond = function() return failure(6) end
      ---@type uv.uv_timer_t?
      local timer
      vim.uv.new_timer = function()
        if not async.current() then return original_timer() end
        timer = original_timer()
        return timer
      end
      local run = backend.inspect(object, access, 2000)
      local started = vim.wait(1000, function() return timer ~= nil end)
      vim.uv.new_timer = original_timer
      run:cancel()
      local result = wait(run)
      assert.is_true(started)
      assert.are.equal("cancelled", assert(result.error).kind)
      assert.is_true(assert(timer):is_closing())
      assert.are.equal(1, #requests)
    end)

    it("preserves cancellation returned by the byte transport", function()
      respond = function() return { ok = false, error = util.copy(async.cancelled_error) } end
      local result = wait(backend.inspect(object, access, 2000))
      assert.are.equal("cancelled", assert(result.error).kind)
      assert.are.equal(1, #requests)
    end)

    it("honors a transport's explicit refusal to retry", function()
      respond = function()
        local result = failure(7)
        result.error.retryable = false
        return result
      end
      local result = wait(backend.inspect(object, access, 2000))
      assert.are.equal("connection", assert(result.error).code)
      assert.are.equal(1, #requests)
    end)

    it("does not send a request after its metadata budget expires", function()
      local result = wait(backend.inspect(object, access, 0))
      assert.matches("timed out", assert(result.error).message)
      assert.are.equal(0, #requests)
    end)

    for _, code in ipairs({ 23, 35, 60 }) do
      it("does not retry permanent curl failure " .. code, function()
        respond = function() return failure(code) end
        local result = wait(backend.inspect(object, access, 2000))
        assert.is_false(result.ok)
        assert.are.equal(code, rawget(assert(result.error), "exit_code"))
        assert.is_nil((vim.inspect(result):find("private-", 1, true)))
        assert.are.equal(1, #requests)
      end)
    end

    it("does not retry HTTP denial or invalid metadata responses", function()
      for _, response in ipairs({
        { ok = true, status = 401, headers = {}, body = '{"error":"private-denial"}' },
        { ok = true, status = 200, headers = {}, body = "private-invalid-json" },
      }) do
        requests = {}
        respond = function() return response end
        local result = wait(backend.inspect(object, access, 2000))
        assert.is_false(result.ok)
        assert.are.equal("files", assert(result.error).kind)
        assert.is_nil((vim.inspect(result):find("private-", 1, true)))
        assert.are.equal(1, #requests)
      end
    end)

    it("does not retry a denied HTTP response whose body transfer failed", function()
      respond = function()
        local result = failure(56)
        rawset(result.error, "response", { status = 401, headers = {} })
        return result
      end
      local result = wait(backend.inspect(object, access, 2000))
      assert.matches("HTTP 401", assert(result.error).message, 1, true)
      assert.are.equal(401, rawget(assert(result.error), "status"))
      assert.are.equal(1, #requests)
    end)

    it("retains HTTP rejection classification for request-level recovery", function()
      respond = function()
        local result = failure(22)
        rawset(result.error, "response", { status = 503, headers = {} })
        return result
      end
      local result = wait(backend.inspect(object, access, 2000))
      assert.matches("HTTP 503", assert(result.error).message, 1, true)
      assert.is_nil(assert(result.error).retryable)
      assert.is_nil(rawget(assert(result.error), "exit_code"))
      assert.are.equal(1, #requests)
    end)

    if provider == "generic" then
      it("retries metadata through the live curl adapter's fetch failure", function()
        local original_system = vim.system
        local attempts = 0
        vim.system = function(command, opts, completed)
          attempts = attempts + 1
          if attempts == 1 then
            assert(completed)({ code = 6, signal = 0, stderr = "private host could not be resolved" })
          else
            for index, argument in ipairs(command) do
              if argument == "--dump-header" then
                vim.fn.writefile({ "HTTP/1.1 200 OK", "Content-Type: application/json", "" }, (assert(command[index + 1])))
              end
            end
            local stdout = assert(opts).stdout
            assert(type(stdout) == "function")
            stdout(nil, success.body .. "\n200")
            assert(completed)({ code = 0, signal = 0, stderr = "" })
          end
          return { kill = function() end } --[[@as vim.SystemObj]]
        end
        local selected = require("neoagent.files.http_backend").new({
          url = "https://api.example.test/files", purpose = "user_data",
        })
        local ok, result = pcall(wait, selected.inspect(object, access, 2000))
        vim.system = original_system
        assert.is_true(ok, vim.inspect(result))
        assert.is_true(result.ok, vim.inspect(result))
        assert.are.equal(2, attempts)
      end)

      for _, case in ipairs({
        { 5, "proxy_dns" }, { 7, "connection" }, { 16, "http2" }, { 18, "incomplete_response" },
        { 28, "timeout" }, { 52, "empty_response" }, { 55, "send" }, { 56, "receive" }, { 92, "http2" },
      }) do
        it("retries transient curl failure " .. case[1], function()
          respond = function(_, attempt) return attempt == 1 and failure(case[1]) or success end
          assert.is_true(wait(backend.inspect(object, access, 2000)).ok)
          assert.are.equal(2, #requests)
          respond = function() return failure(case[1]) end
          assert.are.equal(case[2], assert(wait(backend.upload(asset, access, 1000)).error).code)
          assert.are.equal(3, #requests)
        end)
      end

      for _, code in ipairs({ -1, 0, 256, 6.5, math.huge, vim.NIL, "6" }) do
        it("does not interpret an invalid curl code " .. tostring(code), function()
          respond = function() return failure(code) end
          local result = wait(backend.inspect(object, access, 2000))
          assert.are.equal("transport", assert(result.error).code)
          assert.is_nil(rawget(assert(result.error), "exit_code"))
          assert.are.equal(1, #requests)
        end)
      end

      it("reports certificate-authority failures without retrying", function()
        respond = function() return failure(77) end
        local result = wait(backend.inspect(object, access, 2000))
        assert.are.equal("certificate", assert(result.error).code)
        assert.are.equal(1, #requests)
      end)

      it("retains the last transport failure if backoff exhausts the deadline", function()
        local now = 0
        waiting.now = function() return now end
        respond = function() return failure(6) end
        local started = false
        vim.uv.new_timer = function()
          if async.current() then started = true end
          return original_timer()
        end
        local run = backend.inspect(object, access, 1000)
        local observed = vim.wait(1000, function() return started end)
        vim.uv.new_timer = original_timer
        now = 1001
        local result = wait(run)
        assert.is_true(observed)
        assert.are.equal("dns", assert(result.error).code)
        assert.is_false(assert(result.error).retryable)
        assert.are.equal(1, #requests)
      end)

      it("reports retry-timer allocation failure without restarting preparation", function()
        respond = function() return failure(6) end
        vim.uv.new_timer = function()
          if not async.current() then return original_timer() end
          return nil
        end
        local run = backend.inspect(object, access, 2000)
        local result = wait(run)
        vim.uv.new_timer = original_timer
        assert.matches("Could not create file retry timer", assert(result.error).message, 1, true)
        assert.is_false(assert(result.error).retryable)
        assert.are.equal(1, #requests)
      end)

      for _, throws in ipairs({ false, true }) do
        it("closes the retry timer when starting it fails with throw=" .. tostring(throws), function()
          respond = function() return failure(6) end
          local probe = assert(original_timer())
          local methods = getmetatable(probe).__index
          probe:close()
          local start = methods.start
          ---@type uv.uv_timer_t?
          local timer
          methods.start = function(value, ...)
            if not async.current() then return start(value, ...) end
            timer = value
            if throws then error("synthetic timer failure") end
            return nil, "synthetic timer failure"
          end
          local run = backend.inspect(object, access, 2000)
          local settled = vim.wait(5000, function() return run:is_done() end)
          methods.start = start
          local result = wait(run)
          assert.is_true(settled)
          assert.matches("Could not start file retry timer", assert(result.error).message, 1, true)
          assert.is_false(assert(result.error).retryable)
          assert.is_true(assert(timer):is_closing())
          assert.are.equal(1, #requests)
        end)
      end
    end
  end)
end
