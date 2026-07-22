local async = require("neoagent.async")
local auth = require("neoagent.auth")
local store_module = require("neoagent.auth.store")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function memory_store(initial)
  local values = initial or {}
  return {
    read = function(_, id) return vim.deepcopy(values[id]) end,
    write = function(_, id, value) values[id] = vim.deepcopy(value) return true end,
    values = values,
  }
end

local function method(overrides)
  local value = {
    name = "Test plan",
    login = function(interaction)
      return async.run(function()
        interaction.notify({ type = "progress", message = "Signing in" })
        local answer = async.await(function(done)
          return interaction.prompt({ type = "text", message = "Code" }, done)
        end)
        return { ok = true, credential = {
          access = answer, refresh = "refresh", expires = 200, accountId = "account",
        } }
      end)
    end,
    refresh = function()
      return async.run(function()
        return { ok = true, credential = {
          access = "new", refresh = "rotated", expires = 300, accountId = "account",
        } }
      end)
    end,
    request_opts = function(credential)
      return { headers = { Authorization = "Bearer " .. credential.access } }
    end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

describe("neoagent provider authentication", function()
  it("persists login credentials and decorates an ordinary Model", function()
    local storage = memory_store()
    local manager = auth.new({ methods = { plan = method() }, store = storage, now = function() return 100 end })
    local events = {}
    local result = wait(manager:login("plan", {
      prompt = function(_, done) done.resolve("token") end,
      on_event = function(event) events[#events + 1] = event.message end,
    }))
    assert.is_true(result.ok)
    assert.are.same({ "Signing in" }, events)
    assert.are.equal("token", storage.values.plan.access)

    local seen
    local model = { api = "fake", provider = "provider", id = "model", context_window = 128000 }
    function model:stream(opts)
      return async.run(function(run)
        seen = opts.request_opts({
          request = { url = "http://model", headers = { Existing = "yes" }, body = { base = true } },
        })
        run:emit({ type = "text_delta", text = "done" })
        return { ok = true, text = "done" }
      end, { on_event = opts.on_event })
    end
    local streamed = {}
    model.thinking = { high = { body = { reasoning_effort = "high" } } }
    local wrapped = manager:wrap(model, "plan")
    assert.are.same(model.thinking, wrapped.thinking)
    assert.are.equal(128000, wrapped.context_window)
    result = wait(wrapped:stream({
      messages = {},
      request_opts = { body = { caller = true }, headers = { Authorization = "wrong" } },
      on_event = function(event) streamed[#streamed + 1] = event.text end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("done", result.text)
    assert(vim.wait(1000, function() return #streamed == 1 end))
    assert.are.same({ "done" }, streamed)
    assert.are.equal("Bearer token", seen.headers.Authorization)
    assert.are.equal("yes", seen.headers.Existing)
    assert.are.same({ base = true, caller = true }, seen.body)
    assert.are.equal("fake", wrapped.api)
  end)

  it("stores non-expiring API keys and removes only the stored credential", function()
    local storage = memory_store()
    local api_key = require("neoagent.auth.api_key").new({ name = "Example API key" })
    local manager = auth.new({ methods = { example = api_key }, store = storage })
    local prompt
    local result = wait(manager:login("example", {
      prompt = function(value, done)
        prompt = value
        done.resolve("  secret-key  ")
      end,
    }))
    assert.is_true(result.ok)
    assert.are.equal("api_key", result.credential_type)
    assert.are.same({ type = "secret", message = "Enter Example API key:" }, prompt)
    assert.are.same({ type = "api_key", key = "secret-key" }, storage.values.example)

    result = wait(manager:resolve("example"))
    assert.is_true(result.ok)
    assert.are.equal("Bearer secret-key", result.request_opts.headers.Authorization)
    local listed = assert(manager:list_credentials())
    assert.are.same({ { id = "example", name = "Example API key", type = "api_key" } }, listed)
    assert.is_nil(listed[1].key)

    assert.is_true(wait(manager:logout("example")).ok)
    assert.is_nil(storage.values.example)
    assert.is_false(manager:has_credentials("example"))
  end)

  it("derives provider-specific request options from stored API keys", function()
    local storage = memory_store()
    local selected = require("neoagent.auth.api_key").new({
      name = "Header key",
      prompt = "Enter provider secret:",
      request_opts = function(credential)
        return { headers = { ["x-api-key"] = credential.key } }
      end,
    })
    local manager = auth.new({ methods = { header = selected }, store = storage })
    local result = wait(manager:login("header", {
      prompt = function(value, done)
        assert.are.equal("Enter provider secret:", value.message)
        done.resolve("provider-key")
      end,
    }))
    assert.is_true(result.ok)
    result = wait(manager:resolve("header"))
    assert.are.equal("provider-key", result.request_opts.headers["x-api-key"])
  end)

  it("rejects malformed API-key methods and credentials without exposing secrets", function()
    local selected = require("neoagent.auth.api_key").new({ name = "Validated key" })
    local storage = memory_store({ key = {
      type = "api_key", key = "secret", env = { ACCOUNT_ID = "account" },
    } })
    local manager = auth.new({ methods = { key = selected }, store = storage })
    assert.is_true(wait(manager:resolve("key")).ok)

    storage.values.key.env = { "invalid" }
    local available, err = manager:has_credentials("key")
    assert.is_nil(available)
    assert.matches("invalid", err.message)

    local blank = wait(manager:login("key", {
      prompt = function(_, done) done.resolve("  ") end,
    }))
    assert.is_false(blank.ok)
    assert.matches("required", blank.error.message)

    local invalid_result = {
      type = "api_key",
      name = "Invalid result",
      login = function() return { await = function() return nil end } end,
      request_opts = function() return {} end,
    }
    manager = auth.new({ methods = { invalid = invalid_result }, store = memory_store() })
    assert.matches("invalid result", wait(manager:login("invalid", {
      prompt = function() end,
    })).error.message)

    local invalid_options = vim.deepcopy(invalid_result)
    invalid_options.login = selected.login
    invalid_options.request_opts = function() return "invalid" end
    manager = auth.new({
      methods = { invalid = invalid_options },
      store = memory_store({ invalid = { type = "api_key", key = "secret" } }),
    })
    assert.matches("request_opts", wait(manager:resolve("invalid")).error.message)

    local deletion_error = require("neoagent.util").error("auth", "Deletion failed")
    local failing_store = memory_store({ key = { type = "api_key", key = "secret" } })
    failing_store.delete = function() return false, deletion_error end
    manager = auth.new({ methods = { key = selected }, store = failing_store })
    local deleted = wait(manager:logout("key"))
    assert.is_false(deleted.ok)
    assert.are.equal("Deletion failed", deleted.error.message)
  end)

  it("refreshes expired credentials before deriving request options", function()
    local storage = memory_store({ plan = {
      access = "old", refresh = "refresh", expires = 10, accountId = "account",
    } })
    local refreshes = 0
    local selected = method({ refresh = function(credential)
      refreshes = refreshes + 1
      assert.are.equal("old", credential.access)
      return async.run(function() return { ok = true, credential = {
        access = "fresh", refresh = "new-refresh", expires = 500, accountId = "account",
      } } end)
    end })
    local manager = auth.new({ methods = { plan = selected }, store = storage, now = function() return 10 end })
    local result = wait(manager:resolve("plan"))
    assert.is_true(result.ok)
    assert.are.equal(1, refreshes)
    assert.are.equal("fresh", storage.values.plan.access)
    assert.are.equal("Bearer fresh", result.request_opts.headers.Authorization)
  end)

  it("reports missing, malformed, and failed credentials", function()
    local storage = memory_store()
    local manager = auth.new({ methods = { plan = method() }, store = storage })
    assert.is_false(manager:has_credentials("plan"))
    assert.are.equal("auth", wait(manager:resolve("missing")).error.kind)
    assert.are.equal("auth", wait(manager:resolve("plan")).error.kind)

    storage.values.plan = { expires = "later" }
    local available, credential_err = manager:has_credentials("plan")
    assert.is_nil(available)
    assert.are.equal("auth", credential_err.kind)
    assert.matches("invalid", wait(manager:resolve("plan")).error.message)
    storage.values.plan = { access = "old", refresh = "r", expires = 0 }
    local bad = method({ refresh = function()
      return async.run(function() return { ok = true, credential = {} } end)
    end })
    manager = auth.new({ methods = { plan = bad }, store = storage })
    assert.matches("invalid credential", wait(manager:resolve("plan")).error.message)
  end)

  it("stores credentials only when written and uses restrictive modes", function()
    local directory = vim.fn.tempname()
    local path = directory .. "/nested/auth.json"
    local store = store_module.new(path)
    assert.is_nil(store:read("plan"))
    assert.is_nil(vim.uv.fs_stat(path))
    assert.is_true(wait(store:delete("missing")).ok)
    assert.is_nil(vim.uv.fs_stat(directory))
    assert(store:write("plan", { access = "secret", refresh = "r", expires = 1 }))
    assert.is_true(wait(store:modify("plan", function() return nil end)).ok)
    assert.are.equal("secret", store:read("plan").access)
    local bit = require("bit")
    assert.are.equal(384, bit.band(vim.uv.fs_stat(path).mode, 511))
    assert.are.equal(448, bit.band(vim.uv.fs_stat(vim.fs.dirname(path)).mode, 511))
    assert(require("neoagent.fs").write_all(path .. ".lock", "", "wx", 384))
    local old = os.time() - 121
    assert(vim.uv.fs_utime(path .. ".lock", old, old))
    assert.is_true(wait(store:modify("stale", function() return { recovered = true } end)).ok)
    assert.is_true(store:read("stale").recovered)

    assert(require("neoagent.fs").write_all(path .. ".lock", "", "wx", 384))
    local cancelled = store:modify("cancelled", function() return { written = true } end)
    cancelled:cancel()
    assert.are.equal("cancelled", wait(cancelled).error.kind)
    vim.uv.fs_unlink(path .. ".lock")
    local first = store:modify("count", function(current)
      async.await(function(done)
        local timer = vim.defer_fn(function() done.resolve(true) end, 20)
        return function() pcall(vim.fn.timer_stop, timer) end
      end)
      return { value = (current and current.value or 0) + 1 }
    end)
    local second = store:modify("count", function(current)
      return { value = (current and current.value or 0) + 1 }
    end)
    assert.is_true(wait(first).ok)
    assert.is_true(wait(second).ok)
    assert.are.equal(2, store:read("count").value)
    assert(store:write("remove", { type = "api_key", key = "secret" }))
    local updating = store:modify("remove", function(current)
      async.await(function(done)
        local timer = vim.defer_fn(function() done.resolve(true) end, 20)
        return function() pcall(vim.fn.timer_stop, timer) end
      end)
      current.key = "updated"
      return current
    end)
    local deleting = store:delete("remove")
    assert.is_true(wait(updating).ok)
    assert.is_true(wait(deleting).ok)
    assert.is_nil(store:read("remove"))
    local listed = assert(store:list())
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(item) return item.id end, listed), "plan"))
    assert.is_nil(listed[1].access)
    assert.is_true(wait(store:delete("plan")).ok)
    assert.is_nil(store:read("plan"))
    vim.fn.writefile({ "[]" }, path)
    local value, err = store:read("plan")
    assert.is_nil(value)
    assert.are.equal("auth", err.kind)
    vim.fn.delete(directory, "rf")
  end)
end)
