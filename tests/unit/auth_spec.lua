local assert = require("luassert")
local async = require("neoagent.async")
local auth = require("neoagent.auth")
local store_module = require("neoagent.auth.store")
local util = require("neoagent.util")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@async
---@param milliseconds integer
local function delay(milliseconds)
  async.await(function(done)
    local timer = vim.defer_fn(function() done.resolve(true) end, milliseconds)
    return function()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
  end)
end

local memory_store = require("tests.helpers.auth_manager").store

---@param overrides? Neoagent.AuthMethodInput<Neoagent.OAuthCredential>
---@return Neoagent.AuthMethod<Neoagent.OAuthCredential>
local function method(overrides)
  ---@type Neoagent.AuthMethod<Neoagent.OAuthCredential>
  local value = {
    name = "Test plan",
    login = function(interaction)
      return async.run(function()
        interaction.notify({ type = "progress", message = "Signing in" })
        local answer = async.await(function(done)
          return interaction.prompt({ type = "text", message = "Code" }, done)
        end)
        return { ok = true, credential = {
          access = assert(answer), refresh = "refresh", expires = 200, accountId = "account",
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
  for key, item in pairs(overrides or {}) do rawset(value, key, item) end
  return value
end

describe("neoagent provider authentication", function()
  it("persists login credentials and decorates an ordinary Model", function()
    local storage = memory_store()
    local manager = auth.new({ methods = { plan = method() }, store = storage, now = function() return 100 end })
    local events = {}
    local result = wait(manager:login("plan", {
      prompt = function(_, done) done.resolve("token") end,
      on_event = function(event)
        assert(event.type == "progress")
        events[#events + 1] = event.message
      end,
    }))
    assert(result.ok)
    assert.are.same({ "Signing in" }, events)
    assert.are.equal("token", assert(storage.values.plan).access)

    ---@type Neoagent.RequestOverride?
    local seen
    local model = require("tests.helpers.fake_model").new()
    model.api, model.provider, model.id = "fake", "provider", "model"
    model.context_window = 128000
    ---@param opts Neoagent.StreamOptions
    ---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
    function model:stream(opts)
      return async.run(function(run)
        local decorate = opts.request_opts
        assert(type(decorate) == "function")
        seen = decorate({
          request = { url = "http://model", headers = { Existing = "yes" }, body = { base = true } },
          tools = {}, messages = {}, model = self, request_context = {},
        })
        run:emit({ type = "text_delta", text = "done" })
        return require("tests.helpers.fake_model").assistant({ { type = "text", text = "done" } })
      end, { on_event = opts.on_event })
    end
    local streamed = {}
    model.thinking = { high = { body = { reasoning_effort = "high" } } }
    local wrapped = manager:wrap(model, "plan")
    assert.are.same(model.thinking, wrapped.thinking)
    assert.are.same({ "text" }, wrapped.input)
    assert.are.equal(128000, wrapped.context_window)
    local model_result = wait(wrapped:stream({
      messages = {},
      request_opts = { body = { caller = true }, headers = { Authorization = "wrong" } },
      on_event = function(event)
        assert(event.type == "text_delta")
        streamed[#streamed + 1] = event.text
      end,
    }))
    assert(model_result.ok)
    assert.are.equal("done", model_result.text)
    assert(vim.wait(1000, function() return #streamed == 1 end))
    assert.are.same({ "done" }, streamed)
    assert.are.equal("Bearer token", rawget(assert(assert(seen).headers), "Authorization"))
    assert.are.equal("yes", rawget(assert(assert(seen).headers), "Existing"))
    assert.are.same({ base = true, caller = true }, assert(seen).body)
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
    assert(result.ok)
    assert.are.equal("api_key", result.credential_type)
    assert.are.same({ type = "secret", message = "Enter Example API key:" }, prompt)
    assert.are.same({ type = "api_key", key = "secret-key" }, storage.values.example)

    local resolved = wait(manager:resolve("example"))
    assert(resolved.ok)
    assert.are.equal("Bearer secret-key", rawget(assert(assert(resolved.request_opts).headers), "Authorization"))
    local listed = assert(manager:list_credentials())
    assert.are.same({ { id = "example", name = "Example API key", type = "api_key" } }, listed)
    assert.is_nil(rawget(assert(listed[1]), "key"))

    assert.is_true(wait(manager:logout("example")).ok)
    assert.is_nil(storage.values.example)
    assert.is_false((manager:has_credentials("example")))
  end)

  it("propagates credential enumeration failures and sorts public metadata", function()
    local failed_store = memory_store()
    failed_store.list = function()
      return nil, { kind = "auth", message = "credential list unavailable" }
    end
    local manager = auth.new({
      methods = { first = method() },
      store = failed_store,
    })
    local listed, err = manager:list_credentials()
    assert.is_nil(listed)
    assert.are.equal("credential list unavailable", assert(err).message)

    local listed_store = memory_store()
    listed_store.list = function()
      return {
        { id = "zeta", type = "oauth" },
        { id = "beta", type = "api_key" },
        { id = "alpha", type = "api_key" },
      }
    end
    manager = auth.new({
      methods = {
        alpha = method({ name = "Same" }),
        beta = method({ name = "Same" }),
        zeta = method({ name = "Zulu" }),
      },
      store = listed_store,
    })
    listed = assert(manager:list_credentials())
    assert.are.same({ "alpha", "beta", "zeta" },
      vim.tbl_map(function(entry) return entry.id end, listed))
  end)

  it("accepts omitted public metadata and validates defensive auth results", function()
    local selected = method({
      public_metadata = function() return nil end,
      cache_identity = function() return nil end,
    })
    local storage = memory_store({ plan = {
      access = "access", refresh = "refresh", expires = 500,
    } })
    local manager = auth.new({
      methods = { plan = selected }, store = storage, now = function() return 100 end,
    })

    local result = wait(manager:resolve("plan"))
    assert.is_true(result.ok)
    assert.is_nil(result.metadata)
    assert.is_nil((manager:cache_identity("plan")))

    local identity, identity_err = manager:derive_cache_identity("plan", "invalid")
    assert.is_nil(identity)
    assert.matches("Credential is invalid", assert(identity_err).message)

    local read_error = util.error("auth", "credential read failed")
    local failed_store = memory_store()
    failed_store.read = function() return nil, read_error end
    manager = auth.new({ methods = { plan = method() }, store = failed_store })
    local login = wait(manager:login("plan", {
      prompt = function(_, done) done.resolve("token") end,
    }))
    assert.is_false(login.ok)
    assert.are.equal(read_error.message, assert(login.error).message)

    failed_store = memory_store()
    failed_store.write = function() return nil, util.error("auth", "credential write failed") end
    manager = auth.new({ methods = { plan = method() }, store = failed_store })
    login = wait(manager:login("plan", {
      prompt = function(_, done) done.resolve("token") end,
    }))
    assert.is_false(login.ok)
    assert.matches("credential write failed", assert(login.error).message)

    failed_store = memory_store()
    failed_store.read = function() return nil, util.error("auth", "credential enumeration failed") end
    manager = auth.new({ methods = { plan = method() }, store = failed_store })
    local listed, list_err = manager:list_credentials()
    assert.is_nil(listed)
    assert.matches("credential enumeration failed", assert(list_err).message)

    failed_store = memory_store({ plan = {
      access = "access", refresh = "refresh", expires = 500,
    } })
    failed_store.write = function() return nil, util.error("auth", "credential deletion failed") end
    manager = auth.new({ methods = { plan = method() }, store = failed_store })
    local logout = wait(manager:logout("plan"))
    assert.is_false(logout.ok)
    assert.matches("credential deletion failed", assert(logout.error).message)

    manager = auth.new({ methods = { plan = method() }, store = memory_store() })
    local wrapped = manager:wrap(require("tests.helpers.fake_model").new(), "plan")
    local streamed = wait(wrapped:stream({ messages = {} }))
    assert.is_false(streamed.ok)
    assert.matches("Not logged in", assert(streamed.error).message)
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
    assert(result.ok)
    local resolved = wait(manager:resolve("header"))
    assert.are.equal("provider-key", rawget(assert(assert(resolved.request_opts).headers), "x-api-key"))
  end)

  it("resolves distinct protocol scopes from one login method", function()
    local seen_scope
    local selected = require("neoagent.auth.api_key").new({
      name = "Scoped credential",
      request_opts = function(credential, scope)
        seen_scope = scope
        local key = scope == "dashboard"
            and credential.dashboard_key or credential.key
        return { headers = { Authorization = "Bearer " .. key } }
      end,
    })
    local manager = auth.new({
      methods = { scoped = selected },
      store = memory_store({ scoped = {
        type = "api_key",
        key = "inference-secret",
        dashboard_key = "dashboard-secret",
      } }),
    })

    local result = wait(manager:resolve("scoped", { scope = "dashboard" }))

    assert(result.ok)
    assert.are.equal("dashboard", seen_scope)
    assert.are.equal("Bearer dashboard-secret",
      rawget(assert(assert(result.request_opts).headers), "Authorization"))

    result = wait(manager:resolve("scoped", { scope = "../dashboard" }))
    assert.is_false(result.ok)
    assert.are.equal("auth", assert(result.error).kind)
    assert.matches("scope is invalid", assert(result.error).message)
  end)

  it("rejects malformed API-key methods and credentials without exposing secrets", function()
    local selected = require("neoagent.auth.api_key").new({ name = "Validated key" })
    local storage = memory_store({ key = {
      type = "api_key", key = "secret", env = { ACCOUNT_ID = "account" },
    } })
    local manager = auth.new({ methods = { key = selected }, store = storage })
    assert.is_true(wait(manager:resolve("key")).ok)

    assert(storage.values.key).env = { "invalid" }
    local available, err = manager:has_credentials("key")
    assert.is_nil(available)
    assert.matches("invalid", assert(err).message)
    assert(storage.values.key).env = { ACCOUNT_ID = "" }
    available, err = manager:has_credentials("key")
    assert.is_nil(available)
    assert.matches("invalid", assert(err).message)

    local blank = wait(manager:login("key", {
      prompt = function(_, done) done.resolve("  ") end,
    }))
    assert.is_false(blank.ok)
    assert.matches("required", assert(blank.error).message)

    local constrained = require("neoagent.auth.api_key").new({
      name = "Constrained key",
    })
    constrained.validate_credential = function(credential)
      return credential.key == "accepted"
    end
    manager = auth.new({
      methods = { constrained = constrained },
      store = memory_store({ constrained = {
        type = "api_key", key = "wrong-kind",
      } }),
    })
    available, err = manager:has_credentials("constrained")
    assert.is_nil(available)
    assert.matches("Stored credential is invalid", assert(err).message)
    assert.is_true(wait(manager:login("constrained", {
      prompt = function(_, done) done.resolve("accepted") end,
    })).ok)

    constrained.validate_credential = function()
      error("private-validator-failure")
    end
    manager = auth.new({
      methods = { constrained = constrained },
      store = memory_store({ constrained = {
        type = "api_key", key = "secret",
      } }),
    })
    local invalid = wait(manager:resolve("constrained"))
    assert.is_false(invalid.ok)
    assert.is_not_matches("private%-validator", assert(invalid.error).message)

    local invalid_result = {
      type = "api_key",
      name = "Invalid result",
      login = function() return { await = function() return nil end } end,
      request_opts = function() return {} end,
    }
    manager = auth.new({ methods = { invalid = invalid_result }, store = memory_store() })
    assert.matches("invalid result", assert(wait(manager:login("invalid", {
      prompt = function() end,
    })).error).message)

    local invalid_options = vim.deepcopy(invalid_result)
    invalid_options.login = selected.login
    invalid_options.request_opts = function() return "invalid" end
    manager = auth.new({
      methods = { invalid = invalid_options },
      store = memory_store({ invalid = { type = "api_key", key = "secret" } }),
    })
    assert.matches("request_opts", assert(wait(manager:resolve("invalid")).error).message)

    local deletion_error = require("neoagent.util").error("auth", "Deletion failed")
    local failing_store = memory_store({ key = { type = "api_key", key = "secret" } })
    failing_store.delete = function() return false, deletion_error end
    manager = auth.new({ methods = { key = selected }, store = failing_store })
    local deleted = wait(manager:logout("key"))
    assert.is_false(deleted.ok)
    assert.are.equal("Deletion failed", assert(deleted.error).message)
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
    assert(result.ok)
    assert.are.equal(1, refreshes)
    assert.are.equal("fresh", assert(storage.values.plan).access)
    assert.are.equal("Bearer fresh", rawget(assert(assert(result.request_opts).headers), "Authorization"))
  end)

  it("publishes secret-free account identity revisions", function()
    local storage = memory_store()
    local selected = method({
      cache_identity = function(credential)
        return tostring(credential.accountId)
      end,
      refresh = function()
        return async.run(function()
          return { ok = true, credential = {
            access = "fresh",
            refresh = "rotated",
            expires = 500,
            accountId = "account-two",
          } }
        end)
      end,
    })
    local manager = auth.new({
      methods = { plan = selected },
      store = storage,
      now = function() return 100 end,
    })
    local revisions = {}
    local unsubscribe = manager:subscribe("plan", function(event)
      revisions[#revisions + 1] = event
    end)

    assert.is_nil((manager:cache_identity("plan")))
    assert.is_true(wait(manager:login("plan", {
      prompt = function(_, done) done.resolve("token") end,
    })).ok)
    local identity = assert(manager:cache_identity("plan"))
    assert.matches("^[0-9a-f]+$", identity)
    assert.are.equal(64, #identity)
    assert.is_nil((identity:find("account", 1, true)))
    assert.are.equal("login", revisions[1].kind)
    assert.are.equal(1, revisions[1].revision)

    storage.values.plan.expires = 100
    assert.is_true(wait(manager:resolve("plan")).ok)
    assert.are.equal("refresh", revisions[2].kind)
    assert.are.equal(2, revisions[2].revision)
    assert.are_not.equal(identity, manager:cache_identity("plan"))

    assert.is_true(wait(manager:logout("plan")).ok)
    assert.are.equal("logout", revisions[3].kind)
    assert.are.equal(3, revisions[3].revision)
    assert.is_nil((manager:cache_identity("plan")))
    assert.is_true(unsubscribe())
    assert.is_false(unsubscribe())
  end)

  it("derives the same hashed identity for stored and ambient API keys", function()
    local api_key = require("neoagent.auth.api_key").new({
      name = "Example API key",
    })
    local storage = memory_store({ key = {
      type = "api_key",
      key = "api-secret",
    } })
    local manager = auth.new({ methods = { key = api_key }, store = storage })

    local stored = assert(manager:cache_identity("key"))
    local ambient = assert(manager:derive_cache_identity("key", {
      type = "api_key",
      key = "api-secret",
    }))
    local different = assert(manager:derive_cache_identity("key", {
      type = "api_key",
      key = "other-secret",
    }))

    assert.are.equal(stored, ambient)
    assert.are_not.equal(stored, different)
    assert.are.equal(64, #stored)
    assert.is_nil((stored:find("secret", 1, true)))
  end)

  it("rejects unsafe account cache identities", function()
    local selected = method({
      cache_identity = function() return "account\nsecret" end,
    })
    local manager = auth.new({
      methods = { plan = selected },
      store = memory_store({ plan = {
        access = "access",
        refresh = "refresh",
        expires = 500,
        accountId = "account",
      } }),
      now = function() return 100 end,
    })

    local identity, err = manager:cache_identity("plan")
    assert.is_nil(identity)
    assert.matches("safe non%-empty text", assert(err).message)
  end)

  it("validates cache identity credentials and exposes revisions", function()
    local storage = memory_store({ plan = {
      access = "access",
      refresh = "refresh",
      expires = 500,
      accountId = "account",
    } })
    local selected = method({
      cache_identity = function()
        error("identity failed")
      end,
    })
    local manager = auth.new({
      methods = { plan = selected },
      store = storage,
      now = function() return 100 end,
    })

    assert.are.equal(0, manager:revision("plan"))
    local identity, err = manager:cache_identity("plan")
    assert.is_nil(identity)
    assert.matches("cache_identity failed", assert(err).message)

    storage.values.plan = { expires = "invalid" }
    identity, err = manager:cache_identity("plan")
    assert.is_nil(identity)
    assert.matches("Stored credential is invalid", assert(err).message)
    identity, err = manager:derive_cache_identity("plan", {})
    assert.is_nil(identity)
    assert.matches("Credential is invalid", assert(err).message)
    assert.has_error(function() manager:revision("missing") end)
  end)

  it("reports missing, malformed, and failed credentials", function()
    local storage = memory_store()
    local manager = auth.new({ methods = { plan = method() }, store = storage })
    assert.is_false((manager:has_credentials("plan")))
    assert.are.equal("auth", assert(wait(manager:resolve("missing")).error).kind)
    assert.are.equal("auth", assert(wait(manager:resolve("plan")).error).kind)

    storage.values.plan = { expires = "later" }
    local available, credential_err = manager:has_credentials("plan")
    assert.is_nil(available)
    assert.are.equal("auth", assert(credential_err).kind)
    assert.matches("invalid", assert(wait(manager:resolve("plan")).error).message)
    storage.values.plan = { access = "old", refresh = "r", expires = 0 }
    local invalid_credential = {}
    local bad = method({ refresh = function()
      return async.run(function() return { ok = true, credential = invalid_credential --[[@as Neoagent.OAuthCredential]] } end)
    end })
    manager = auth.new({ methods = { plan = bad }, store = storage })
    assert.matches("invalid credential", assert(wait(manager:resolve("plan")).error).message)
  end)

  it("protects OAuth refresh against missing support and credential races", function()
    local expired = { access = "old", refresh = "refresh", expires = 10 }
    local without_refresh = auth.new({
      methods = { plan = method({ refresh = false --[[@as fun(credential: Neoagent.OAuthCredential): Neoagent.Run<Neoagent.CredentialResult<Neoagent.OAuthCredential>, nil>]] }) },
      store = memory_store({ plan = expired }),
      now = function() return 10 end,
    })
    assert.matches("cannot refresh", assert(wait(without_refresh:resolve("plan")).error).message)

    local reads = 0
    local refreshed = { access = "concurrent", refresh = "new", expires = 500 }
    local concurrent_store = memory_store()
    concurrent_store.read = function()
      reads = reads + 1
      return vim.deepcopy(reads == 1 and expired or refreshed)
    end
    local concurrent = auth.new({
      methods = { plan = method() }, store = concurrent_store, now = function() return 10 end,
    })
    local result = wait(concurrent:resolve("plan"))
    assert(result.ok)
    assert.are.equal("Bearer concurrent", rawget(assert(assert(result.request_opts).headers), "Authorization"))

    local function modifying_store(current, replacement)
      local store = memory_store({ plan = expired })
      store.modify = function(_, _, fn)
        return async.run(function()
          fn(vim.deepcopy(current))
          return { ok = true, credential = vim.deepcopy(replacement) }
        end)
      end
      return store
    end
    local changed_during_refresh = auth.new({
      methods = { plan = method() },
      store = modifying_store(expired, {}),
      now = function() return 10 end,
    })
    assert.matches("changed during refresh",
      assert(wait(changed_during_refresh:resolve("plan")).error).message)

    local invalid_during_refresh = auth.new({
      methods = { plan = method() },
      store = modifying_store({}, refreshed),
      now = function() return 10 end,
    })
    assert.matches("Stored credential is invalid",
      assert(wait(invalid_during_refresh:resolve("plan")).error).message)
  end)

  it("bounds credential lock contention and reports filesystem errors", function()
    local directory = vim.fn.tempname()
    local path = directory .. "/auth.json"
    local lock_path = path .. ".lock"
    assert(require("neoagent.fs").mkdirp(directory))
    local holder = assert(require("neoagent.file_lock").new({
      path = lock_path,
    }):acquire())
    local store = store_module.new(path, {
      lock_timeout_ms = 30,
      lock_poll_ms = 5,
    })
    local timed_out = wait(store:modify("plan", function()
      return { type = "api_key", key = "unexpected" }
    end))
    assert.is_false(timed_out.ok)
    assert.matches("Timed out acquiring credential lock", assert(timed_out.error).message)
    assert(holder:release())

    local original_open = vim.uv.fs_open
    vim.uv.fs_open = function(candidate, ...)
      if candidate == lock_path then return nil, "EACCES: permission denied" end
      return original_open(candidate, ...)
    end
    local denied = wait(store:modify("plan", function()
      return { type = "api_key", key = "unexpected" }
    end))
    vim.uv.fs_open = original_open
    assert.is_false(denied.ok)
    assert.matches("Failed to acquire credential lock", assert(denied.error).message)
    assert.matches("EACCES", tostring(assert(denied.error).detail))
    vim.fn.delete(directory, "rf")
  end)

  it("reports credential replacement stages and lock release failures", function()
    local directory = vim.fn.tempname()
    local path = directory .. "/auth.json"
    local store = store_module.new(path)
    local fs = require("neoagent.fs")
    local atomic_replace = fs.atomic_replace
    local stages = { "temporary", "write", "mode", "rename" }
    ---@type {written?: true, err?: Neoagent.Error}[]
    local failures = {}
    local patched, patch_err = pcall(function()
      fs.atomic_replace = function()
        local stage = table.remove(stages, 1)
        return nil, stage .. " denied", stage
      end
      for _ = 1, 4 do
        local written, err = store:write("plan", {
          type = "api_key", key = "secret",
        })
        failures[#failures + 1] = { written = written, err = err }
      end
    end)
    fs.atomic_replace = atomic_replace
    assert(patched, patch_err)

    assert.is_nil(assert(failures[1]).written)
    assert.matches("temporary file", assert(assert(failures[1]).err).message)
    assert.matches("write credentials", assert(assert(failures[2]).err).message)
    assert.matches("write credentials", assert(assert(failures[3]).err).message)
    assert.matches("replace credentials", assert(assert(failures[4]).err).message)

    store._file_lock = function()
      return {
        with = function()
          return nil, {
            kind = "file_lock",
            code = "release",
            message = "release failed",
            detail = "unlock denied",
          }
        end,
      }
    end
    local written, err = store:write("plan", {
      type = "api_key", key = "secret",
    })
    assert.is_nil(written)
    assert.matches("release credential lock", assert(err).message)
    assert.are.equal("unlock denied", assert(err).detail)
    vim.fn.delete(directory, "rf")
  end)

  it("contains asynchronous credential publication and lock release failures", function()
    local root = vim.fn.tempname()
    local path = root .. "/auth.json"
    local store = store_module.new(path)
    local fs = require("neoagent.fs")
    assert(store:write("plan", { type = "api_key", key = "original" }))

    local ensure_private_directory = fs.ensure_private_directory
    local patched, patch_err = pcall(function()
      local calls = 0
      fs.ensure_private_directory = function(...)
        calls = calls + 1
        if calls == 1 then return ensure_private_directory(...) end
        return nil, "directory permissions denied"
      end
      local result = wait(store:modify("plan", function()
        return { type = "api_key", key = "replacement" }
      end))
      assert.is_false(result.ok)
      assert.matches("credential directory", assert(result.error).message)
      assert.matches("directory permissions denied", tostring(assert(result.error).detail))
    end)
    fs.ensure_private_directory = ensure_private_directory
    assert(patched, patch_err)
    assert.are.equal("original", assert(store:read("plan")).key)

    store._file_lock = function()
      return {
        acquire_async = function()
          return {
            release = function()
              return nil, util.error("file_lock", "asynchronous release denied")
            end,
          }
        end,
      }
    end
    local result = wait(store:modify("plan", function(current)
      return current
    end))
    assert.is_false(result.ok)
    assert.matches("release credential lock", assert(result.error).message)
    assert.matches("asynchronous release denied", tostring(assert(result.error).detail))
    vim.fn.delete(root, "rf")
  end)

  it("holds credential locks through long mutations", function()
    local directory = vim.fn.tempname()
    local path = directory .. "/auth.json"
    local lock_path = path .. ".lock"
    local store = store_module.new(path, {
      lock_timeout_ms = 500,
      lock_poll_ms = 5,
    })
    assert(store:write("count", { value = 0 }))
    local entered = false
    local first = store:modify("count", function(current)
      entered = true
      delay(100)
      assert(current).value = assert(assert(current).value) + 1
      return current
    end)
    assert(vim.wait(100, function() return entered end, 5))
    local second = store:modify("count", function(current)
      assert(current).value = assert(assert(current).value) + 1
      return current
    end)
    assert.is_true(wait(first).ok)
    assert.is_true(wait(second).ok)
    assert.are.equal(2, assert(store:read("count")).value)
    vim.fn.delete(directory, "rf")
  end)

  it("serializes direct credential writes with a concurrent writer", function()
    local directory = vim.fn.tempname()
    local path = directory .. "/auth.json"
    local lock_path = path .. ".lock"
    local store = store_module.new(path)
    assert(store:write("first", { value = 1 }))
    local holder = assert(require("neoagent.file_lock").new({
      path = lock_path,
    }):acquire())

    local concurrent_done, concurrent_err
    vim.defer_fn(function()
      local written, write_err = require("neoagent.fs").write_all(path,
        vim.json.encode({ first = { value = 1 }, concurrent = { value = 2 } }) .. "\n")
      local released, release_err = holder:release()
      concurrent_err = write_err or release_err
      concurrent_done = written and released
    end, 20)

    assert(store:write("local", { value = 3 }))
    assert(vim.wait(1000, function() return concurrent_done or concurrent_err ~= nil end, 5))
    assert.is_nil(concurrent_err)
    assert.are.same({ value = 1 }, store:read("first"))
    assert.are.same({ value = 2 }, store:read("concurrent"))
    assert.are.same({ value = 3 }, store:read("local"))
    vim.fn.delete(directory, "rf")
  end)

  it("stores credentials only when written and uses restrictive modes", function()
    local directory = vim.fn.tempname()
    local path = directory .. "/nested/auth.json"
    local store = store_module.new(path)
    assert.is_nil((store:read("plan")))
    assert.is_nil(vim.uv.fs_stat(path))
    assert.is_true(wait(store:delete("missing")).ok)
    assert.is_nil(vim.uv.fs_stat(directory))
    assert(store:write("plan", { access = "secret", refresh = "r", expires = 1 }))
    assert.is_true(wait(store:modify("plan", function() return nil end)).ok)
    assert.are.equal("secret", assert(store:read("plan")).access)
    local bit = require("bit")
    assert.are.equal(384, bit.band(assert(vim.uv.fs_stat(path)).mode, 511))
    assert.are.equal(448, bit.band(assert(vim.uv.fs_stat(assert(vim.fs.dirname(path)))).mode, 511))
    assert.is_true(wait(store:modify("stale", function() return { recovered = true } end)).ok)
    assert.is_true(assert(store:read("stale")).recovered)

    local holder = assert(require("neoagent.file_lock").new({
      path = path .. ".lock",
    }):acquire())
    local cancelled = store:modify("cancelled", function() return { written = true } end)
    assert.is_false(cancelled:is_done())
    cancelled:cancel()
    assert.are.equal("cancelled", assert(wait(cancelled).error).kind)
    assert(holder:release())
    local first = store:modify("count", function(current)
      delay(20)
      return { value = (current and current.value or 0) + 1 }
    end)
    local second = store:modify("count", function(current)
      return { value = (current and current.value or 0) + 1 }
    end)
    assert.is_true(wait(first).ok)
    assert.is_true(wait(second).ok)
    assert.are.equal(2, assert(store:read("count")).value)
    assert(store:write("remove", { type = "api_key", key = "secret" }))
    local updating = store:modify("remove", function(current)
      delay(20)
      assert(current).key = "updated"
      return current
    end)
    local deleting = store:delete("remove")
    assert.is_true(wait(updating).ok)
    assert.is_true(wait(deleting).ok)
    assert.is_nil((store:read("remove")))
    local listed = assert(store:list())
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(item) return item.id end, listed), "plan"))
    assert.is_nil(rawget(assert(listed[1]), "access"))
    assert.is_true(wait(store:delete("plan")).ok)
    assert.is_nil((store:read("plan")))
    vim.fn.writefile({ "[]" }, path)
    local value, err = store:read("plan")
    assert.is_nil(value)
    assert.are.equal("auth", assert(err).kind)
    vim.fn.delete(directory, "rf")
  end)

  it("stops credential writes when a new private directory cannot be secured", function()
    local root = vim.fn.tempname()
    local directory = root .. "/credentials"
    local path = directory .. "/auth.json"
    local chmod = vim.uv.fs_chmod
    vim.uv.fs_chmod = function(candidate, ...)
      if candidate == directory then return nil, "chmod denied" end
      return chmod(candidate, ...)
    end
    local store = store_module.new(path)
    local ok, err = store:write("key", {
      type = "api_key", key = "secret",
    })
    vim.uv.fs_chmod = chmod

    assert.is_nil(ok)
    assert.matches("credential directory", assert(err).message)
    assert.matches("chmod denied", tostring(assert(err).detail))
    assert.is_nil(vim.uv.fs_stat(path))
    assert.are.same({}, vim.fn.glob(path .. ".*.tmp", false, true))
    assert.is_nil(vim.uv.fs_stat(path .. ".lock"))
    vim.fn.delete(root, "rf")
  end)

  for _, failure in ipairs({ "malformed document", "unreadable document", "occupied directory" }) do
    it("rejects credential mutation without overwriting an " .. failure, function()
      local fs = require("neoagent.fs")
      local root = vim.fn.tempname()
      local path = root .. "/auth.json"
      local store = store_module.new(path)
      local invoked = false
      local ok, err = pcall(function()
        if failure == "occupied directory" then
          assert(fs.write_all(root, "occupied"))
        else
          assert(fs.mkdirp(root))
          if failure == "malformed document" then assert(fs.write_all(path, "[broken"))
          else assert(fs.mkdirp(path)) end
        end
        local result = wait(store:modify("example", function()
          invoked = true
          return { type = "api_key", key = "synthetic-key" }
        end))
        assert.is_false(result.ok)
        assert.is_false(invoked)
        assert.matches(failure == "occupied directory" and "credential directory"
          or failure == "malformed document" and "Invalid credential file" or "Failed to read credentials",
          assert(result.error).message)
        if failure == "malformed document" then
          local manager = auth.new({ store = store, methods = {
            example = require("neoagent.auth.api_key").new({ name = "Example" }),
          } })
          local resolved = wait(manager:resolve("example"))
          assert.is_false(resolved.ok)
          assert.are.equal("Invalid credential file", assert(resolved.error).message)
          local identity, identity_err = manager:cache_identity("example")
          assert.is_nil(identity)
          assert.are.equal("Invalid credential file", assert(identity_err).message)
          local configured, configured_err = manager:has_credentials("example")
          assert.is_nil(configured)
          assert.are.equal("Invalid credential file", assert(configured_err).message)
          local listed, list_err = store:list()
          assert.is_nil(listed)
          assert.are.equal("Invalid credential file", assert(list_err).message)
          local written, write_err = store:write("example", { type = "api_key", key = "synthetic-key" })
          assert.is_nil(written)
          assert.are.equal("Invalid credential file", assert(write_err).message)
          assert.are.equal("[broken", assert(fs.read(path)))
          assert(fs.write_all(path, "{}"))
          assert(store:write("example", { type = "api_key", key = "recovered-key" }))
          assert.are.equal("recovered-key", assert(store:read("example")).key)
        elseif failure == "occupied directory" then
          assert.are.equal("occupied", assert(fs.read(root)))
        else
          assert.are.equal("directory", assert(vim.uv.fs_stat(path)).type)
        end
      end)
      vim.fn.delete(root, "rf")
      assert(ok, err)
    end)
  end

  for _, operation in ipairs({ "replace", "delete" }) do
    it("preserves credentials and releases its lock when native " .. operation .. " publication fails", function()
      local fs = require("neoagent.fs")
      local root = vim.fn.tempname()
      local path = root .. "/auth.json"
      local store = store_module.new(path)
      local manager = auth.new({ store = store, methods = {
        example = require("neoagent.auth.api_key").new({ name = "Example" }),
      } })
      local rename = vim.uv.fs_rename
      local ok, err = pcall(function()
        assert(store:write("example", { type = "api_key", key = "synthetic-key" }))
        local before = assert(fs.read(path))
        vim.uv.fs_rename = function(from, to)
          if to == path then return nil, "native rename denied" end
          return rename(from, to)
        end
        local result = operation == "delete" and wait(manager:logout("example")) or wait(store:modify("example", function()
          return { type = "api_key", key = "replacement-key" }
        end))
        vim.uv.fs_rename = rename
        assert.is_false(result.ok)
        assert.matches("replace credentials", assert(result.error).message)
        assert.matches("native rename denied", tostring(assert(result.error).detail))
        assert.are.equal(before, assert(fs.read(path)))
        assert.are.same({}, vim.fn.glob(path .. ".*.tmp", false, true))
        assert.is_true(wait(store:modify("example", function(current)
          assert(current).key = "recovered-key"
          return current
        end)).ok)
        assert.are.equal("recovered-key", assert(store:read("example")).key)
      end)
      vim.uv.fs_rename = rename
      vim.fn.delete(root, "rf")
      assert(ok, err)
    end)
  end
end)
